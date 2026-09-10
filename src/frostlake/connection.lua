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
        -- Whether the caller has selected a scope themselves; if they have, the
        -- DSN's defaults are no longer the whole truth about this session.
        touched = false,
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

-- Releases the socket. The HTTP API has no endpoint for ending a session, so
-- the engine's own idle sweep is what reclaims the session behind it.
function Connection:release()
    self.closed = true
    if self.sock then
        http.disconnect(self.backend, self.sock)
        self.sock = nil
    end
end

function Connection:close()
    self:release()
end

local function check(self)
    if self.closed then errors.usage("the connection is closed") end
end

-- --------------------------------------------------------------- statements

-- Runs one statement and returns its first result set.
--
--     conn:execute("INSERT INTO people VALUES (?, ?)", {1, "Ada"})
--     conn:execute("SELECT :a + :b AS total", {a = 2, b = 40})
--     conn:execute("SELECT * FROM t LIMIT ?", {frostlake.number("5")})
--
-- Whether `params` is read as a list of positional arguments or a table of
-- named ones is decided by the STATEMENT: `?` markers take a list, `:name`
-- markers take a table keyed by name.
function Connection:execute(statement, params, options)
    return (self:executeall(statement, params, options))[1]
end

-- Runs a statement string and returns every result set it produced, in order. A
-- single statement gives a one-element list.
function Connection:executeall(statement, params, options)
    if type(statement) ~= "string" then
        errors.usage("a statement must be a string, got " .. type(statement))
    end
    if options ~= nil and type(options) ~= "table" then
        errors.usage("execute options must be a table, got " .. type(options))
    end
    local types = options and options.types or nil
    local rendered = bind.render(statement, params, types, self.null)
    return self:run(statement, rendered)
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

function Connection:run(statement, rendered)
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
        self:drainpending()
        local decoded = self:roundtrip(rendered)
        if sqlscan.changesscope(statement) then self.touched = true end
        return self:shape(decoded)
    end)
    self.busy = false
    if not ok then error(answer, 0) end
    return answer
end

-- Each USE leaves the queue only once it has succeeded. A DSN naming a database
-- that does not exist has to keep failing; the alternative is later statements
-- quietly running in the default scope.
function Connection:drainpending()
    while #self.pending > 0 do
        self:roundtrip(self.pending[1])
        table.remove(self.pending, 1)
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
    return self:roundtrip(statement)
end

-- The engine reclaims a session once it has been idle long enough, then quietly
-- builds a fresh one for the id we keep sending -- losing the scope we
-- selected. Nothing in the reply gives it away: the id we sent is echoed back
-- either way. So past the limit the only safe reading is that the session is
-- new, and the DSN's defaults go back on.
--
-- Not once the caller has selected a scope themselves: putting our defaults
-- over their choice is its own surprise.
function Connection:restoredefaults()
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

function Connection:roundtrip(statement)
    local endpoint = self:baseurl() .. "/api/execute"
    local payload = { '{"sql":', json.encodestring(statement) }
    if self.sessionid then
        payload[#payload + 1] = ',"sessionId":'
        payload[#payload + 1] = json.encodestring(self.sessionid)
    end
    payload[#payload + 1] = ',"autoCommit":'
    payload[#payload + 1] = self.autocommit and "true" or "false"
    payload[#payload + 1] = "}"

    local answer = self:send("POST", "/api/execute", table.concat(payload))
    local decoded = self:decode(endpoint, answer)

    -- On a failure the engine answers with sessionId null, so the id is taken
    -- only when it is really there -- otherwise one bad statement would drop
    -- the session and silently start a new one.
    local session = json.at(decoded, "sessionId")
    if json.kind(session) == "string" and session.text ~= "" then
        self.sessionid = session.text
    end

    if json.boolean(json.at(decoded, "success")) ~= true then
        errors.query(self:failuremessage(decoded, answer),
            { statement = statement, status = answer.status,
              sessionid = self.sessionid, endpoint = endpoint })
    end
    self.lastused = self.backend.gettime()
    return decoded
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
