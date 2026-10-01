-- A connection to a Frostlake HTTP server, and the engine session behind it.
--
-- The connection is the one thing in this module that has a lifetime: it owns a
-- socket and a server-side session. Results, configs and rows are plain values.
--
-- Statements are serialized over the one session, which is what makes session
-- state -- USE, session variables, an open transaction -- carry from one
-- statement to the next.

local dsnmodule = require("frostlake.dsn")
local json = require("frostlake.json")
local http = require("frostlake.http")
local transport = require("frostlake.transport")
local bind = require("frostlake.bind")
local sqlscan = require("frostlake.sql")
local value = require("frostlake.value")
local result = require("frostlake.result")
local errors = require("frostlake.errors")
local compat = require("frostlake.compat")

local M = {}

-- What `post` answers when the engine refused the session id as one it does
-- not hold: nothing ran.
local GONE = setmetatable({}, { __tostring = function() return "session gone" end })

local Connection = {}
Connection.__index = Connection
Connection.__name = "frostlake.connection"
Connection.__tostring = function(self)
    return "frostlake.connection(" .. self:baseurl()
        .. (self.closed and ", closed" or "") .. ")"
end

local OPTIONS = {
    timeout = true, connecttimeout = true, idlelimit = true,
    database = true, schema = true, role = true, warehouse = true,
    null = true, cacert = true, verify = true, transport = true, useragent = true,
}

local OPTION_LIST = "cacert, connecttimeout, database, idlelimit, null, role, "
    .. "schema, timeout, transport, useragent, verify, warehouse"

-- ------------------------------------------------------------------ opening

-- Opens a connection to a Frostlake HTTP server.
--
--     local conn = frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
--
-- Every option may also be given in the DSN query string, where an explicit
-- option outranks it. Durations are written the way a DSN writes them -- `30s`,
-- `500ms`, `5m` -- or as a bare number of seconds.
--
-- The server is contacted before this returns: the health endpoint is called
-- and the scope the DSN names is selected, so a database that does not exist is
-- reported here rather than surfacing later on whichever query happened to run
-- first.
-- The DSN spells two of its parameters in camelCase; the same spelling is
-- accepted as an option, so "every parameter can also be given as an option"
-- holds without the caller having to know which case each side uses.
local OPTION_ALIASES = { connectTimeout = "connecttimeout", idleLimit = "idlelimit" }

function M.connect(dsn, options)
    options = options or {}
    if type(options) ~= "table" then
        errors.usage("connect options must be a table, got " .. type(options))
    end
    local given = {}
    for key, value in pairs(options) do
        given[OPTION_ALIASES[key] or key] = value
    end
    options = given
    for key in pairs(options) do
        if not OPTIONS[key] then
            errors.usage(string.format("unknown option %q (expected %s)",
                                       tostring(key), OPTION_LIST))
        end
    end

    local config = dsnmodule.parse(dsn)
    config.verify = options.verify == nil and true or (options.verify and true or false)
    config.cacert = options.cacert

    if options.timeout ~= nil then
        config.timeout = dsnmodule.duration("timeout", options.timeout)
    end
    if options.connecttimeout ~= nil then
        config.connecttimeout = dsnmodule.duration("connecttimeout", options.connecttimeout)
    end
    if options.idlelimit ~= nil then
        config.idlelimit = dsnmodule.duration("idlelimit", options.idlelimit)
    end
    for _, key in ipairs({ "database", "schema", "role", "warehouse" }) do
        if options[key] ~= nil then config[key] = options[key] end
    end
    if not config.secure and (config.cacert ~= nil or options.verify == false) then
        errors.usage("cacert and verify apply to https DSNs only")
    end

    local backend = options.transport
        and transport.adopt(options.transport)
        or transport.require()

    -- Not `options.null ~= nil and options.null or value.null`: that reads
    -- `null = false` -- a perfectly reasonable stand-in -- as "not given", and
    -- silently hands back the sentinel instead of what was asked for.
    local nullvalue = value.null
    if options.null ~= nil then nullvalue = options.null end

    local self = setmetatable({
        config = config,
        backend = backend,
        sock = nil,
        sessionid = nil,
        autocommit = true,
        closed = false,
        null = nullvalue,
        useragent = options.useragent or http.USER_AGENT,
        lastused = nil,
        -- Whether a statement left behind state a fresh session would not
        -- have: a scope the caller selected themselves (after which the DSN's
        -- defaults are no longer the whole truth about this session), a
        -- session variable or setting, or a temporary object.
        touched = false,
        -- Whether the session holds an open transaction, however it was
        -- opened: `begin`, or a BEGIN or START TRANSACTION statement.
        opentransaction = false,
        -- Whether the engine reports newSession, which arrived together with
        -- requireSession and DELETE /api/sessions/{id}: nil until the first
        -- answer that names a session settles it as true or false.
        tracks = nil,
        busy = false,
    }, Connection)

    self.defaults = dsnmodule.usestatements(config)
    -- USE statements still owed to the session, in dependency order.
    self.pending = { }
    for i, statement in ipairs(self.defaults) do self.pending[i] = statement end

    local ok, why = pcall(function()
        self:ping()
        self:applyscope()
    end)
    if not ok then
        self:release()
        error(why, 0)
    end
    return self
end

-- ---------------------------------------------------------------- reporting

-- The server this connection speaks to, as scheme://host:port.
function Connection:baseurl()
    return dsnmodule.baseurl(self.config)
end

-- The engine's id for this connection's session, once it has one.
function Connection:session()
    return self.sessionid
end

-- Whether a transaction is open -- `begin` without a matching `commit` or
-- `rollback`.
function Connection:intransaction()
    return not self.autocommit
end

function Connection:isopen()
    return not self.closed
end

-- The stand-in this connection uses for SQL NULL, in both directions.
function Connection:nullvalue()
    return self.null
end

-- ------------------------------------------------------------------ closing

-- Releases the engine session and the socket.
--
-- An engine that reports newSession (0.1.0 and later) is sent DELETE
-- /api/sessions/{id}, which ends the session and rolls back a transaction left
-- open on it. The request is a courtesy: it is bounded by the shorter of the
-- statement timeout and five seconds, and nothing it meets is raised -- a server
-- already gone has nothing left to release. An older engine has no such endpoint
-- and is sent nothing; its own idle sweep reclaims the session. Releasing twice
-- sends nothing the second time.
function Connection:release()
    if not self.closed then self:releasesession() end
    self.closed = true
    if self.sock then
        http.disconnect(self.backend, self.sock)
        self.sock = nil
    end
end

function Connection:close()
    self:release()
end

-- The most, in milliseconds, that releasing the session may take on close.
local RELEASE_LIMIT = 5000

-- A session id made safe as one URL path segment.
local function pathsegment(text)
    return (text:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Sends DELETE /api/sessions/{id} for the session this connection holds, when
-- the engine is known to have that endpoint. Never raises.
function Connection:releasesession()
    local id = self.sessionid
    if not id or self.tracks ~= true then return end
    local limit = RELEASE_LIMIT
    if (self.config.timeout or 0) > 0 and self.config.timeout < limit then
        limit = self.config.timeout
    end
    local bounded = {}
    for key, item in pairs(self.config) do bounded[key] = item end
    bounded.timeout = limit
    if (bounded.connecttimeout or 0) <= 0 or bounded.connecttimeout > limit then
        bounded.connecttimeout = limit
    end
    pcall(function()
        if self.sock and self.backend.stale(self.sock) then
            http.disconnect(self.backend, self.sock)
            self.sock = nil
        end
        if not self.sock then self.sock = http.connect(self.backend, bounded) end
        -- What it answers does not matter: a 404 means the session had already
        -- gone, and anything else is not this close's to fix.
        http.exchange(self.backend, self.sock, bounded, "DELETE",
            "/api/sessions/" .. pathsegment(id), nil, self.useragent)
    end)
end

local function check(self)
    if self.closed then errors.usage("the connection is closed") end
end

-- --------------------------------------------------------------- statements

-- The statement count an execute option declares, checked here so a bad value
-- is a usage error rather than a request body the engine cannot read.
local function statementcount(given)
    if given == nil then return nil end
    if type(given) ~= "number" or given < 0 or given % 1 ~= 0 then
        errors.usage("multistatementcount must be a whole number of statements, "
            .. "0 for any number, got " .. tostring(given))
    end
    return given
end

-- Runs one statement and returns its first result set.
--
--     conn:execute("INSERT INTO people VALUES (?, ?)", {1, "Ada"})
--     conn:execute("SELECT :a + :b AS total", {a = 2, b = 40})
--     conn:execute("SELECT * FROM t LIMIT ?", {frostlake.number("5")})
--
-- Whether `params` is read as a list of positional arguments or a table of
-- named ones is decided by the STATEMENT: `?` markers take a list, `:name`
-- markers take a table keyed by name.
--
-- `options.multistatementcount` says how many statements this one request
-- carries; see `executeall`.
function Connection:execute(statement, params, options)
    return (self:executeall(statement, params, options))[1]
end

-- Runs a statement string and returns every result set it produced, in order. A
-- single statement gives a one-element list.
--
-- The engine refuses a request holding more statements than it was told to
-- expect, so a pack says how many it holds:
--
--     conn:executeall("SELECT 1; SELECT 2", nil, {multistatementcount = 2})
--
-- The count travels with this one request. It outranks the session's
-- MULTI_STATEMENT_COUNT without changing it, so there is nothing to put back
-- afterwards, and 0 allows any number. Left out, no count is sent at all and the
-- session's value decides.
function Connection:executeall(statement, params, options)
    if type(statement) ~= "string" then
        errors.usage("a statement must be a string, got " .. type(statement))
    end
    if options ~= nil and type(options) ~= "table" then
        errors.usage("execute options must be a table, got " .. type(options))
    end
    local types = options and options.types or nil
    local count = statementcount(options and options.multistatementcount)
    local rendered = bind.render(statement, params, types, self.null)
    return self:run(statement, rendered, count)
end

-- Renders a statement with its parameters inlined, without sending it. Useful
-- for logging, and for seeing what a bind actually produced.
--
-- WARNING: the result holds bound values verbatim -- a password bound into a
-- statement appears in it in the clear.
function Connection:render(statement, params, options)
    local types = options and options.types or nil
    return bind.render(statement, params, types, self.null)
end

function Connection:run(statement, rendered, multistatementcount)
    check(self)
    -- The pending USE statements and the statement itself have to reach the
    -- session as one unit. A caller who re-enters from a coroutine resumed
    -- inside one of the transport's waits would interleave two statements on
    -- one session -- so that is refused rather than half-done.
    if self.busy then
        errors.usage("this connection is already running a statement; a connection"
            .. " carries one session and cannot interleave two")
    end
    self.busy = true
    local ok, answer = pcall(function()
        self:restoredefaults()
        -- The pending USE statements are one statement each, whatever this
        -- request declares, so the count goes only on the caller's own.
        self:drainpending()
        local decoded = self:roundtrip(rendered, multistatementcount)
        self:noteeffects(statement)
        return self:shape(decoded)
    end)
    self.busy = false
    if not ok then error(answer, 0) end
    return answer
end

-- Updates what the driver knows of the session once `text` has succeeded on it:
-- whether it now holds state a fresh session would not have, and whether a
-- transaction is open.
--
-- A request may hold more than one statement, and a `USE` riding behind a
-- leading `SELECT` moves the scope just as surely as one standing alone, so
-- every statement is examined, in order.
function Connection:noteeffects(text)
    for _, statement in ipairs(sqlscan.splitstatements(text)) do
        if sqlscan.touchessession(statement) then self.touched = true end
        local effect = sqlscan.transactioneffect(statement)
        if effect == "begins" then
            self.opentransaction = true
        elseif effect == "ends" then
            self.opentransaction = false
        end
    end
end

-- Each USE leaves the queue only once it has succeeded. A DSN naming a database
-- that does not exist has to keep failing; the alternative is later statements
-- quietly running in the default scope.
--
-- A session lost part way through takes whatever part of the scope was on with
-- it, so the whole scope goes on again, on a fresh session -- once. The DSN's
-- own USE statements are the driver's, not the caller's, so they never count as
-- a context the caller set up.
function Connection:drainpending()
    local restarted = false
    while #self.pending > 0 do
        local statement = self.pending[1]
        local decoded, answer = self:post(statement)
        if decoded ~= GONE then
            self:accept(statement, decoded, answer)
            table.remove(self.pending, 1)
        elseif restarted then
            self:dropsession()
            errors.sessionlost("the engine refused a session it had just started",
                { statement = statement, endpoint = self:baseurl() .. "/api/execute" })
        else
            restarted = true
            self:losesession(statement)
        end
    end
end

-- Selects the database, schema, role and warehouse the DSN names. The
-- constructor calls this, so it is only worth calling again after the session
-- has been moved somewhere else deliberately.
function Connection:applyscope()
    check(self)
    if #self.defaults == 0 then return end
    -- Re-queue the whole scope: the constructor drained the queue already, so
    -- without this a second call would send nothing and report success.
    self.pending = {}
    for i, statement in ipairs(self.defaults) do self.pending[i] = statement end
    self.touched = false
    self:drainpending()
end

-- BEGIN, COMMIT and ROLLBACK are session statements like any other: they go
-- out after the scope has been put back on a session the engine may have
-- reclaimed, or a transaction started after a long idle would open in the
-- default database.
function Connection:sessionstatement(statement)
    self:restoredefaults()
    self:drainpending()
    local decoded = self:roundtrip(statement)
    self:noteeffects(statement)
    return decoded
end

-- An engine before 0.1.0 reclaims a session once it has been idle long enough,
-- then quietly builds a fresh one for the id we keep sending -- losing the scope
-- we selected. Nothing in its reply gives it away: the id we sent is echoed back
-- either way. So past the limit the only safe reading is that the session is
-- new, and the DSN's defaults go back on.
--
-- A later engine reports newSession, and refuses a session it no longer holds
-- rather than rebuilding it (see `recover`), so it is left out of the guessing.
--
-- Not once the caller has selected a scope themselves: putting our defaults
-- over their choice is its own surprise.
function Connection:restoredefaults()
    if self.tracks ~= false then return end
    if #self.defaults == 0 or self.touched then return end
    local limit = self.config.idlelimit
    if limit == 0 or not self.lastused then return end
    if (self.backend.gettime() - self.lastused) * 1000 < limit then return end
    self.pending = {}
    for i, statement in ipairs(self.defaults) do self.pending[i] = statement end
end

-- -------------------------------------------------------------- transactions

-- Opens a transaction: autocommit goes off and BEGIN is sent.
function Connection:begin()
    check(self)
    self.autocommit = false
    local ok, why = pcall(function() self:sessionstatement("BEGIN") end)
    if not ok then
        self.autocommit = true
        error(why, 0)
    end
end

-- Commits the open transaction and restores autocommit.
function Connection:commit()
    check(self)
    local ok, why = pcall(function() self:sessionstatement("COMMIT") end)
    self.autocommit = true
    if not ok then error(why, 0) end
end

-- Rolls the open transaction back and restores autocommit.
function Connection:rollback()
    check(self)
    local ok, why = pcall(function() self:sessionstatement("ROLLBACK") end)
    self.autocommit = true
    if not ok then error(why, 0) end
end

-- Runs `body(conn)` between BEGIN and COMMIT, rolling back if it fails and
-- re-raising the original error either way.
--
--     conn:transaction(function(c)
--         c:execute("INSERT INTO acc VALUES (1)")
--     end)
--
-- The connection is NOT held for the duration: a transaction lives on the
-- session, so anything else run on this same connection meanwhile joins the
-- transaction. Give a transaction its own connection if that is not what you
-- want.
function Connection:transaction(body)
    if type(body) ~= "function" then
        errors.usage("transaction takes a function, got " .. type(body))
    end
    self:begin()
    local ok, outcome = pcall(body, self)
    if not ok then
        -- A failed rollback must not replace the error that caused it.
        pcall(function() self:rollback() end)
        error(outcome, 0)
    end
    self:commit()
    return outcome
end

-- ---------------------------------------------------------------- transport

-- Checks that a Frostlake engine is answering, via GET /api/health.
--
-- A 200 on its own only says something is listening -- anything can serve that.
-- The health payload is what says it is an engine, so a body that is not one is
-- reported rather than passed off as healthy.
function Connection:ping()
    check(self)
    local endpoint = self:baseurl() .. "/api/health"
    local answer = self:send("GET", "/api/health", nil)
    if answer.status ~= 200 then
        errors.connection(string.format("%s answered HTTP %d: %s",
            endpoint, answer.status, errors.snippet(answer.body)),
            { endpoint = endpoint, status = answer.status })
    end
    local health = self:decode(endpoint, answer)
    if not json.exists(health, "status") then
        errors.connection(string.format(
            "%s answered HTTP %d with a body that is not a Frostlake response: %s",
            endpoint, answer.status, errors.snippet(answer.body)),
            { endpoint = endpoint, status = answer.status })
    end
    return true
end

-- Sends one statement and returns the decoded reply, or raises. A session the
-- engine no longer holds is dealt with here, before anything else sees the
-- answer: see `recover`.
function Connection:roundtrip(statement, multistatementcount)
    local decoded, answer = self:post(statement, multistatementcount)
    if decoded == GONE then
        decoded, answer = self:recover(statement, multistatementcount)
    end
    self:accept(statement, decoded, answer)
    return decoded
end

-- The session id an answer names, or nil when it names none.
local function namedsession(decoded)
    local session = json.at(decoded, "sessionId")
    if json.kind(session) == "string" and session.text ~= "" then return session.text end
    return nil
end

-- One POST /api/execute, without any recovery. Answers the decoded reply and
-- the response it came in, or GONE when the engine refused the session id as
-- one it does not hold -- which it does only for a request that asked it to
-- (requireSession), and then nothing ran.
function Connection:post(statement, multistatementcount)
    local endpoint = self:baseurl() .. "/api/execute"
    local sent = self.sessionid
    local payload = { '{"sql":', json.encodestring(statement) }
    if sent then
        payload[#payload + 1] = ',"sessionId":'
        payload[#payload + 1] = json.encodestring(sent)
        -- Resume this session or refuse: without it, an engine whose session
        -- has gone runs the statement in a fresh one under the same id, at its
        -- default scope. Only an engine known to understand the field is sent
        -- it -- an older one's parser may refuse a field it never knew.
        if self.tracks == true then
            payload[#payload + 1] = ',"requireSession":true'
        end
    end
    payload[#payload + 1] = ',"autoCommit":'
    payload[#payload + 1] = self.autocommit and "true" or "false"
    -- Absent unless the caller asked for a count: a request without the field is
    -- the one the server has always seen, and the session's value decides.
    if multistatementcount then
        payload[#payload + 1] = ',"multiStatementCount":'
        payload[#payload + 1] = string.format("%d", multistatementcount)
    end
    payload[#payload + 1] = "}"

    local answer = self:send("POST", "/api/execute", table.concat(payload))
    local decoded = self:decode(endpoint, answer)

    if sent and answer.status == 404
        and json.boolean(json.at(decoded, "success")) ~= true
        and not namedsession(decoded) then
        return GONE, answer
    end
    self:absorb(decoded, sent)
    return decoded, answer
end

-- Takes in what an answer says of the session: the id it ran in and, from the
-- presence of newSession, whether the engine tracks sessions at all.
function Connection:absorb(decoded, sent)
    -- On a failure the engine answers with sessionId null, so the id is taken
    -- only when it is really there -- otherwise one bad statement would drop
    -- the session and silently start a new one.
    local session = namedsession(decoded)
    if not session then return end
    self.sessionid = session
    local started = json.at(decoded, "newSession")
    if json.kind(started) == "boolean" then
        self.tracks = true
        if started.value == true and sent then
            -- The engine ran the statement in a fresh session in place of ours:
            -- whatever the old one held is gone, and the DSN's scope goes back
            -- on before the next statement.
            self:resetsession()
        end
    elseif self.tracks == nil then
        self.tracks = false
    end
end

-- Raises the engine's refusal of `statement`, when that is what `decoded` reports.
function Connection:accept(statement, decoded, answer)
    if json.boolean(json.at(decoded, "success")) ~= true then
        errors.query(self:failuremessage(decoded, answer),
            { statement = statement, status = answer.status,
              sessionid = self.sessionid, endpoint = self:baseurl() .. "/api/execute" })
    end
    self.lastused = self.backend.gettime()
end

-- The engine no longer holds this connection's session -- it expired, was
-- released, or the server restarted -- and nothing ran.
--
-- With a transaction or a moved context gone along with it, running the
-- statement again would put it somewhere its author did not intend, so that is
-- refused. Otherwise a fresh session on the DSN's scope takes over and the
-- statement is sent once more; a second refusal is raised rather than chased.
function Connection:recover(statement, multistatementcount)
    self:losesession(statement)
    self:drainpending()
    local decoded, answer = self:post(statement, multistatementcount)
    if decoded == GONE then
        self:dropsession()
        errors.sessionlost("the engine refused a session it had just started; "
            .. "the statement did not run",
            { statement = statement, endpoint = self:baseurl() .. "/api/execute" })
    end
    return decoded, answer
end

-- Forgets a session the engine no longer holds, and raises a `sessionlost`
-- error when it held something a fresh session would not have. Returns when
-- `statement` may be sent again on a fresh session.
function Connection:losesession(statement)
    local hadtransaction = self.opentransaction
    local hadcontext = self.touched
    self:dropsession()
    local context = { statement = statement, endpoint = self:baseurl() .. "/api/execute" }
    if hadtransaction then
        -- The transaction went with the session, so the connection is back in
        -- autocommit mode, as the fresh session will be.
        self.autocommit = true
        errors.sessionlost("the engine no longer holds this connection's session (it "
            .. "expired, was released, or the server restarted), so its open transaction "
            .. "is gone; the statement did not run", context)
    end
    if hadcontext then
        errors.sessionlost("the engine no longer holds this connection's session (it "
            .. "expired, was released, or the server restarted), and the context set up on "
            .. "it (USE, SET, ALTER SESSION or a temporary object) went with it, so the "
            .. "statement was not run again; the next statement starts a fresh session on "
            .. "the connection's scope", context)
    end
end

-- Forgets the session id and what the driver knew of the session behind it, so
-- the next statement starts a fresh one on the DSN's scope.
function Connection:dropsession()
    self.sessionid = nil
    self:resetsession()
end

-- Back to what a fresh session holds: none of the caller's context, no
-- transaction, and the DSN's scope still to apply.
function Connection:resetsession()
    self.touched = false
    self.opentransaction = false
    self.pending = {}
    for i, statement in ipairs(self.defaults) do self.pending[i] = statement end
end

-- Sends one request, opening the socket if this connection has none and
-- replacing it if the server has closed the one it had.
function Connection:send(method, path, payload)
    check(self)
    if self:stale() then
        http.disconnect(self.backend, self.sock)
        self.sock = nil
    end
    if not self.sock then
        self.sock = http.connect(self.backend, self.config)
    end
    local ok, answer = pcall(http.exchange, self.backend, self.sock, self.config,
                             method, path, payload, self.useragent)
    if not ok then
        -- The statement's fate is unknown -- it may have run before the
        -- connection broke -- so the socket goes, but nothing is re-sent.
        http.disconnect(self.backend, self.sock)
        self.sock = nil
        error(answer, 0)
    end
    if answer.close then
        http.disconnect(self.backend, self.sock)
        self.sock = nil
    end
    return answer
end

-- Whether the socket cannot carry another request. Checked BEFORE the statement
-- is written, which is what keeps this from ever re-sending one that may have
-- run.
function Connection:stale()
    if not self.sock then return false end
    return self.backend.stale(self.sock)
end

-- Reads a response body as the JSON object a Frostlake answer is.
--
-- A proxy error page, the wrong port, a crashed server: report what came back
-- rather than where the JSON parser gave up, which is the difference between
-- "malformed JSON at offset 0" and a message naming the address that answered.
function Connection:decode(endpoint, answer)
    local ok, decoded = pcall(json.parse, answer.body)
    if ok and json.kind(decoded) == "object" then return decoded end
    errors.connection(string.format(
        "%s answered HTTP %d with a body that is not a Frostlake response: %s",
        endpoint, answer.status, errors.snippet(answer.body)),
        { endpoint = endpoint, status = answer.status })
end

-- Never answers the empty string: a response can report failure carrying no
-- message at all, and an error that prints as nothing tells the caller less
-- than the status code would.
function Connection:failuremessage(decoded, answer)
    for _, key in ipairs({ "errorMessage", "error" }) do
        local field = json.at(decoded, key)
        if json.kind(field) == "string" and field.text ~= "" then return field.text end
    end
    return string.format(
        "the statement failed with HTTP %d and no error message: %s",
        answer.status, errors.snippet(answer.body))
end

-- ------------------------------------------------------------- result shape

function Connection:shape(decoded)
    local out = {}
    for _, entry in ipairs(json.items(json.at(decoded, "resultSets"))) do
        if json.kind(entry) == "object" then out[#out + 1] = self:shapeone(entry) end
    end
    -- A statement that returned no grid at all -- DDL, a bare USE -- still
    -- answers with one result, so that `execute` always has one to hand back.
    if #out == 0 then return { result.new({}, {}) } end
    return out
end

local function flag(object, key)
    local field = json.at(object, key)
    if json.kind(field) == "boolean" then return field.value end
    -- nil rather than false: an engine that predates a field reports nothing,
    -- and reading that as "not nullable" would be an invented answer.
    return nil
end

local function number(object, key)
    local field = json.at(object, key)
    if json.kind(field) == "number" then return tonumber(field.text) end
    return nil
end

function Connection:shapeone(entry)
    local columns = {}
    for _, column in ipairs(json.items(json.at(entry, "columns"))) do
        if json.kind(column) == "object" then
            columns[#columns + 1] = {
                name = json.textat(column, "name", ""),
                datatype = json.textat(column, "dataType", ""),
                nullable = flag(column, "nullable"),
                precision = number(column, "precision"),
                scale = number(column, "scale"),
                -- The declared width of a text or binary column: characters
                -- for VARCHAR, bytes for BINARY. Every other type sends none,
                -- and so does an engine that predates the field -- nil, which
                -- is what "the server did not say" reads as here.
                length = number(column, "length"),
            }
        end
    end

    local rows = {}
    for _, row in ipairs(json.items(json.at(entry, "rows"))) do
        if json.kind(row) == "array" then
            local cells = {}
            for i, cell in ipairs(json.items(row)) do
                -- The engine's own text, verbatim; only null becomes something
                -- else. See value.lua for why nothing is converted. A cell
                -- that arrives as a nested JSON value rather than as text --
                -- the wire sends a bare VECTOR that way -- is handed back as
                -- its JSON: reading it as NULL would lose it without a word.
                local kind = json.kind(cell)
                if kind == "object" or kind == "array" then
                    cells[i] = json.stringify(cell)
                else
                    cells[i] = json.text(cell, self.null)
                    if cells[i] == nil then cells[i] = self.null end
                end
            end
            -- A row the server sent short of the column count is padded, so
            -- every row lines up with `columns` positionally.
            for i = #cells + 1, #columns do cells[i] = self.null end
            rows[#rows + 1] = cells
        end
    end

    -- The protocol carries no statement type, so a DML answer is recognised by
    -- its shape: a single row whose every column is a "number of ..." counter.
    -- INSERT and DELETE report one, UPDATE adds "number of multi-joined rows
    -- updated", and MERGE reports an inserted and an updated count.
    if #rows == 1 and #columns > 0 then
        local allcounters = true
        for _, column in ipairs(columns) do
            if not column.name:lower():match("^number of ") then
                allcounters = false
                break
            end
        end
        if allcounters then
            local counters, affected = {}, 0
            for i, column in ipairs(columns) do
                local parsed = compat.parseinteger(rows[1][i])
                if parsed then
                    counters[column.name] = parsed
                    -- "number of multi-joined rows updated" is a diagnostic
                    -- sub-count of rows already counted as updated, so only the
                    -- "number of rows ..." counters are summed.
                    if column.name:lower():match("^number of rows ") then
                        affected = affected + parsed
                    end
                end
            end
            -- The grid itself is kept rather than folded away: a statement
            -- whose answer merely LOOKS like a status grid is indistinguishable
            -- from one that is, and hiding its rows would lose the only copy of
            -- them.
            return result.new(columns, rows, affected, counters)
        end
    end
    return result.new(columns, rows)
end

M.Connection = Connection

return M
