-- How a connection keeps its idea of the engine session in step with the
-- engine's: the requireSession flag, recovery from a session the engine no
-- longer holds, and the release on close.
--
-- The scripted groups run over the fake transport, where every request a case
-- makes is one it scripted; the last group releases a session behind a
-- connection's back on a real engine, and skips without one.

local t = require("harness")
local frostlake = require("frostlake")
local fakebackend = require("fakebackend")
local testserver = require("testserver")
local json = frostlake.json

local SCOPED = "frostlake://example:18082/APP?schema=PUBLIC"
local SCOPE = { 'USE DATABASE "APP"', 'USE SCHEMA "PUBLIC"' }

local STATUS = '{"columns":[{"dataType":"VARCHAR","name":"status","nullable":false,'
    .. '"precision":0,"scale":0}],"rowCount":1,"rows":[["Statement executed successfully."]],'
    .. '"updateCount":-1}'

local function numberset(name, value)
    return string.format('{"columns":[{"dataType":"NUMBER","name":%q,"nullable":false,'
        .. '"precision":38,"scale":0}],"rowCount":1,"rows":[[%d]],"updateCount":-1}', name, value)
end

-- An answer from an engine that reports newSession (0.1.0 and later).
local function answer(session, started, sets)
    return { body = string.format('{"errorMessage":null,"executionTimeMs":1,"newSession":%s,'
        .. '"resultSets":[%s],"sessionId":%q,"success":true}',
        started and "true" or "false", table.concat(sets or { STATUS }, ","), session) }
end

-- An answer from an engine that predates newSession (0.0.7).
local function legacy(session, sets)
    return { body = string.format('{"errorMessage":null,"executionTimeMs":1,'
        .. '"resultSets":[%s],"sessionId":%q,"success":true}',
        table.concat(sets or { STATUS }, ","), session) }
end

local function refused(session, message)
    return { body = string.format('{"errorMessage":%q,"executionTimeMs":0,"newSession":true,'
        .. '"resultSets":[],"sessionId":%q,"success":false}', message, session) }
end

-- The 404 a requireSession request gets when its session is gone.
local function gone(session)
    return { status = 404, reason = "Not Found", body = string.format(
        '{"errorMessage":"Session \'%s\' does not exist or has expired.","executionTimeMs":0,'
        .. '"newSession":false,"resultSets":[],"sessionId":null,"success":false}', session) }
end

local RELEASED = { body = '{"errorMessage":null,"executionTimeMs":0,"newSession":false,'
    .. '"resultSets":[],"sessionId":null,"success":true}' }

local function concat(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, item in ipairs(list) do out[#out + 1] = item end
    end
    return out
end

-- A connection to a scripted engine: the health check, then every other request
-- -- statement or release -- answered from `answers`, in order. A request the
-- script did not expect is answered with a 500 that fails whatever sent it.
local function connect(answers, dsn, options)
    local backend = fakebackend.new(fakebackend.script(answers))
    options = options or {}
    options.transport = backend
    return frostlake.connect(dsn or SCOPED, options), backend
end

-- The same, on an engine that reports newSession, with the DSN's two USE
-- statements already answered in session s1.
local function opened(answers, dsn, options)
    return connect(concat({ answer("s1", true), answer("s1", false) }, answers), dsn, options)
end

local function executes(backend)
    local out = {}
    for _, request in ipairs(backend.requests) do
        if request.path == "/api/execute" then out[#out + 1] = request end
    end
    return out
end

local function statements(backend)
    local out = {}
    for i, request in ipairs(executes(backend)) do
        out[i] = json.textat(json.parse(request.body), "sql")
    end
    return out
end

local function deletes(backend)
    local out = {}
    for _, request in ipairs(backend.requests) do
        if request.method == "DELETE" then out[#out + 1] = request end
    end
    return out
end

-- A string field of a request's body, or nil when it has none.
local function text(request, name)
    local field = json.at(json.parse(request.body), name)
    if json.kind(field) == "string" then return field.text end
    return nil
end

-- A boolean field of a request's body, or nil when it has none.
local function flag(request, name)
    local field = json.at(json.parse(request.body), name)
    if json.kind(field) == "boolean" then return field.value end
    return nil
end

-- --------------------------------------------------------------- the flag

t.describe("session: requireSession")

t.it("is never sent to an engine that predates newSession", function()
    local conn, backend = connect({ legacy("old1"), legacy("old1"),
                                    legacy("old1", { numberset("N", 1) }) })
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
    for _, request in ipairs(executes(backend)) do
        t.eq(flag(request, "requireSession"), nil, text(request, "sql"))
    end
    -- The id still travels, once the engine has named one.
    local sent = executes(backend)
    t.eq(text(sent[1], "sessionId"), nil)
    t.eq(text(sent[3], "sessionId"), "old1")
    -- And an engine without newSession has no DELETE /api/sessions either.
    local before = #backend.requests
    conn:close()
    t.eq(#backend.requests, before, "nothing is sent on close")
end)

t.it("is sent on every request naming the session once the engine has it", function()
    local conn, backend = opened({ answer("s1", false, { numberset("N", 1) }) })
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
    local sent = executes(backend)
    -- The first request has no session to name, so nothing to require.
    t.eq(text(sent[1], "sessionId"), nil)
    t.eq(flag(sent[1], "requireSession"), nil)
    -- From the first answer on, every request that names the session requires it.
    t.eq(text(sent[2], "sessionId"), "s1")
    t.eq(flag(sent[2], "requireSession"), true)
    t.eq(text(sent[3], "sessionId"), "s1")
    t.eq(flag(sent[3], "requireSession"), true)
end)

-- ----------------------------------------------------------- a lost session

t.describe("session: a lost session")

t.it("is replaced on the DSN's scope, and the statement sent once more", function()
    local conn, backend = opened({ gone("s1"), answer("s2", true), answer("s2", false),
                                   answer("s2", false, { numberset("N", 1) }) })
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
    t.same(statements(backend), concat(SCOPE, { "SELECT 1 AS N" }, SCOPE, { "SELECT 1 AS N" }))
    local sent = executes(backend)
    -- The fresh session starts without an id, and the statement goes again in
    -- the one the engine named.
    t.eq(text(sent[4], "sessionId"), nil)
    t.eq(text(sent[6], "sessionId"), "s2")
    t.eq(conn:session(), "s2")
end)

t.it("is reported when it is lost again straight away", function()
    local conn, backend = opened({ gone("s1"), answer("s2", true), answer("s2", false),
                                   gone("s2"),
                                   answer("s3", true), answer("s3", false),
                                   answer("s3", false, { numberset("N", 2) }) })
    t.raises("sessionlost", conn.execute, conn, "SELECT 1 AS N")
    local count = 0
    for _, sql in ipairs(statements(backend)) do
        if sql == "SELECT 1 AS N" then count = count + 1 end
    end
    t.eq(count, 2, "sent twice, never a third time")
    -- And the connection is still good for the next statement.
    t.ok(conn:isopen())
    t.eq(conn:execute("SELECT 2 AS N"):value(), "2")
    t.eq(conn:session(), "s3")
end)

t.it("is reported, not replaced, when it held a transaction", function()
    local conn, backend = opened({ answer("s1", false), gone("s1"),
                                   answer("s2", true), answer("s2", false),
                                   answer("s2", false, { numberset("N", 1) }) })
    conn:begin()
    t.ok(conn:intransaction())
    local err = t.raises("sessionlost", conn.execute, conn, "INSERT INTO t VALUES (1)")
    t.contains(err.message, "transaction")
    t.eq(err.statement, "INSERT INTO t VALUES (1)")
    t.eq(conn:intransaction(), false)
    t.ok(conn:isopen())
    -- The next statement starts over on the DSN's scope.
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
    t.same(statements(backend), concat(SCOPE, { "BEGIN", "INSERT INTO t VALUES (1)" },
                                       SCOPE, { "SELECT 1 AS N" }))
    local sent = executes(backend)
    t.eq(text(sent[5], "sessionId"), nil)
    t.eq(flag(sent[7], "autoCommit"), true,
         "the transaction went with the session, and autocommit is back")
end)

t.it("is reported when a statement opened the transaction", function()
    for _, opener in ipairs({ "BEGIN", "BEGIN TRANSACTION", "START TRANSACTION" }) do
        local conn, backend = opened({ answer("s1", false), gone("s1") })
        conn:execute(opener)
        t.raises("sessionlost", conn.execute, conn, "SELECT 1")
        t.same(statements(backend), concat(SCOPE, { opener, "SELECT 1" }), opener)
    end
    -- And one that was committed is no longer there to lose.
    local conn = opened({ answer("s1", false), answer("s1", false), gone("s1"),
                          answer("s2", true), answer("s2", false),
                          answer("s2", false, { numberset("N", 1) }) })
    conn:execute("BEGIN")
    conn:execute("COMMIT")
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
end)

t.it("is reported, not replaced, when its context had moved", function()
    for _, mover in ipairs({ "USE SCHEMA other", "SET v = 1", "UNSET v",
                             "ALTER SESSION SET TIMEZONE = 'UTC'",
                             "CREATE TEMPORARY TABLE tmp (i INT)",
                             "CREATE DATABASE other", "SELECT 1; USE SCHEMA other" }) do
        local conn, backend = opened({ answer("s1", false), gone("s1") })
        conn:execute(mover)
        local err = t.raises("sessionlost", conn.execute, conn, "SELECT * FROM t")
        t.contains(err.message, "context", mover)
        -- Not sent a second time.
        t.same(statements(backend), concat(SCOPE, { mover, "SELECT * FROM t" }), mover)
    end
end)

t.it("is reported once, and the connection starts over on the scope", function()
    local conn, backend = opened({ answer("s1", false), gone("s1"),
                                   answer("s2", true), answer("s2", false),
                                   answer("s2", false, { numberset("N", 1) }) })
    conn:execute("USE SCHEMA other")
    t.raises("sessionlost", conn.execute, conn, "SELECT 0")
    -- The context went with the session, so the scope goes back on before the
    -- next statement, which is not refused a second time.
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
    t.same(statements(backend), concat(SCOPE, { "USE SCHEMA other", "SELECT 0" },
                                       SCOPE, { "SELECT 1 AS N" }))
end)

t.it("puts the whole scope back on when it goes part way through", function()
    -- The scope that goes back on before the next statement -- after an answer
    -- that said the engine replaced the session -- meets a session gone again.
    local conn, backend = opened({ answer("s1", true, { numberset("N", 1) }),
                                   gone("s1"), answer("s2", true), answer("s2", false),
                                   answer("s2", false, { numberset("N", 2) }) })
    t.eq(conn:execute("SELECT 1 AS N"):value(), "1")
    t.eq(conn:execute("SELECT 2 AS N"):value(), "2")
    t.same(statements(backend), concat(SCOPE, { "SELECT 1 AS N", SCOPE[1] }, SCOPE,
                                       { "SELECT 2 AS N" }))
end)

t.it("gets the scope back after an answer says the engine replaced it", function()
    local conn, backend = opened({ answer("s1", true, { numberset("N", 1) }),
                                   answer("s1", false), answer("s1", false),
                                   answer("s1", false, { numberset("N", 2) }) })
    conn:execute("SELECT 1 AS N")
    conn:execute("SELECT 2 AS N")
    t.same(statements(backend), concat(SCOPE, { "SELECT 1 AS N" }, SCOPE, { "SELECT 2 AS N" }))
end)

t.it("leaves the idle re-scope to the engines that need it", function()
    -- An engine that reports newSession refuses a session it no longer holds,
    -- so an idle connection to one does not guess: no scope goes back on.
    local conn, backend = opened({ answer("s1", false, { numberset("N", 1) }) },
                                 SCOPED .. "&idleLimit=1s")
    backend.now = backend.now + 3600
    conn:execute("SELECT 1 AS N")
    t.same(statements(backend), concat(SCOPE, { "SELECT 1 AS N" }))
end)

-- -------------------------------------------------------------- closing

t.describe("session: close")

t.it("releases the session once", function()
    local conn, backend = opened({ answer("s1", false), RELEASED })
    conn:begin()
    conn:close()
    local sent = deletes(backend)
    t.eq(#sent, 1)
    t.eq(sent[1].path, "/api/sessions/s1")
    -- A second close sends nothing.
    local before = #backend.requests
    conn:close()
    t.eq(#backend.requests, before)
    t.raises("usage", conn.execute, conn, "SELECT 1")
end)

t.it("never raises, whatever the release meets", function()
    local cases = {
        { "a 404", { status = 404, body = '{"success":false,"sessionId":null}' } },
        { "a 405", { status = 405, body = '{"error":"Method not allowed"}' } },
        { "a socket closed without a reply", "die" },
        { "a server that never answers", "hang" },
    }
    for _, case in ipairs(cases) do
        local conn, backend = opened({ case[2] })
        local timeouts = {}
        local settimeout = backend.settimeout
        backend.settimeout = function(sock, ms)
            timeouts[#timeouts + 1] = ms
            return settimeout(sock, ms)
        end
        local ok, why = pcall(conn.close, conn)
        t.ok(ok, case[1] .. ": raised " .. tostring(why))
        t.eq(conn:isopen(), false, case[1])
        t.eq(#deletes(backend), 1, case[1])
        -- Bounded by five seconds, not by the five minutes a statement may take.
        for _, ms in ipairs(timeouts) do
            t.ok(ms ~= nil and ms > 0 and ms <= 5000, case[1] .. ": waited up to " .. tostring(ms))
        end
    end
    -- A server that has gone altogether: the last answer closes the socket, and
    -- nothing is listening any more when the release reconnects.
    local conn, backend = opened({ { body = answer("s1", false).body,
                                     headers = { Connection = "close" } } })
    conn:execute("SELECT 1")
    backend.open = function() return nil, "connection refused" end
    local ok, why = pcall(conn.close, conn)
    t.ok(ok, "a server that has gone: raised " .. tostring(why))
    t.eq(conn:isopen(), false)
end)

t.it("releases the session when the scope it applied is refused", function()
    local backend = fakebackend.new(fakebackend.script({
        refused("s9", "Database 'APP' does not exist or not authorized."), RELEASED }))
    local err = t.raises("query", frostlake.connect, SCOPED, { transport = backend })
    t.contains(err.message, "APP")
    local sent = deletes(backend)
    t.eq(#sent, 1)
    t.eq(sent[1].path, "/api/sessions/s9")
end)

-- ---------------------------------------------------------- statement kinds

t.describe("session: statement kinds")

t.it("knows the statements that leave state behind", function()
    local scan = frostlake.sql
    for _, sql in ipairs({ "USE SCHEMA other", "SET v = 1", "UNSET v",
                           "ALTER SESSION SET TIMEZONE = 'UTC'", "CREATE DATABASE d",
                           "DROP SCHEMA IF EXISTS s", "CREATE TEMPORARY TABLE t (i INT)",
                           "CREATE OR REPLACE TEMP VIEW v AS SELECT 1",
                           "CREATE LOCAL TEMPORARY TABLE t (i INT)",
                           "create volatile table t (i int)" }) do
        t.ok(scan.touchessession(sql), sql)
    end
    for _, sql in ipairs({ "SELECT 1", "CREATE TABLE t (i INT)", "CREATE TRANSIENT TABLE t (i INT)",
                           "DROP TABLE t", "INSERT INTO t VALUES (1)", "SELECT 'USE SCHEMA x'", "" }) do
        t.ok(not scan.touchessession(sql), sql)
    end
end)

t.it("knows the statements that open and end a transaction", function()
    local scan = frostlake.sql
    for _, sql in ipairs({ "BEGIN", "begin transaction", "BEGIN WORK", "BEGIN NAME t1",
                           "START TRANSACTION", "  -- open one\n BEGIN" }) do
        t.eq(scan.transactioneffect(sql), "begins", sql)
    end
    for _, sql in ipairs({ "COMMIT", "commit work", "ROLLBACK" }) do
        t.eq(scan.transactioneffect(sql), "ends", sql)
    end
    -- BEGIN followed by a statement opens a scripting block, not a transaction.
    for _, sql in ipairs({ "BEGIN SELECT 1", "SELECT 1", "BEGIN_X", "STARTED" }) do
        t.eq(scan.transactioneffect(sql), nil, sql)
    end
end)

-- ------------------------------------------------------------ a live engine

t.describe("session: against an engine")

local reason = testserver.skipreason()
if reason then
    t.skip("a released session", reason)
else
    local dsnmodule = require("frostlake.dsn")
    local http = require("frostlake.http")
    local transport = require("frostlake.transport")

    local function address()
        return dsnmodule.parse(testserver.shared().dsn)
    end

    -- One raw request to the engine, beside any connection: its status and its
    -- body, parsed.
    local function enginerequest(method, path)
        local config = address()
        config.timeout = 30000
        local backend = transport.require()
        local sock = http.connect(backend, config)
        local ok, reply = pcall(http.exchange, backend, sock, config, method, path, nil)
        http.disconnect(backend, sock)
        if not ok then error(reply, 0) end
        return reply.status, json.parse(reply.body)
    end

    local function activesessions()
        local _, body = enginerequest("GET", "/api/sessions")
        return tonumber(json.at(body, "activeSessions").text)
    end

    -- Releases a connection's session the way an expiry or a restart would lose it.
    local function releasebehinditsback(conn)
        t.eq(enginerequest("DELETE", "/api/sessions/" .. conn:session()), 200)
    end

    local function scopeddsn()
        local base = "frostlake://" .. dsnmodule.hostport(address())
        frostlake.with(base, function(setup)
            setup:execute("CREATE DATABASE IF NOT EXISTS lua_session_db")
            setup:execute("USE DATABASE lua_session_db")
            setup:execute("CREATE SCHEMA IF NOT EXISTS lua_session_schema")
        end)
        -- This driver quotes a DSN's names exactly as given, so the DSN names the
        -- upper-case objects the unquoted names above fold to.
        return base .. "/LUA_SESSION_DB?schema=LUA_SESSION_SCHEMA"
    end

    t.it("a released session is replaced on the DSN's scope", function()
        frostlake.with(scopeddsn(), function(conn)
            local first = conn:session()
            releasebehinditsback(conn)
            t.eq(conn:execute("SELECT CURRENT_DATABASE()"):value(), "LUA_SESSION_DB")
            t.eq(conn:execute("SELECT CURRENT_SCHEMA()"):value(), "LUA_SESSION_SCHEMA")
            t.neq(conn:session(), first, "a fresh session took over")
        end)
    end)

    t.it("a released session that held a transaction is reported", function()
        frostlake.with(scopeddsn(), function(conn)
            conn:execute("CREATE OR REPLACE TABLE lost_tx (i INT)")
            conn:begin()
            conn:execute("INSERT INTO lost_tx VALUES (1)")
            releasebehinditsback(conn)
            t.raises("sessionlost", conn.execute, conn, "INSERT INTO lost_tx VALUES (2)")
            t.eq(conn:intransaction(), false)
            -- The release rolled the first insert back, the second never ran, and
            -- the connection carries on in a fresh session on the DSN's scope.
            t.eq(conn:execute("SELECT COUNT(*) FROM lost_tx"):value(), "0")
            t.eq(conn:execute("SELECT CURRENT_SCHEMA()"):value(), "LUA_SESSION_SCHEMA")
        end)
    end)

    t.it("a released session whose context moved is reported", function()
        frostlake.with(scopeddsn(), function(conn)
            conn:execute("SET v = 41")
            releasebehinditsback(conn)
            t.raises("sessionlost", conn.execute, conn, "SELECT $v + 1")
            t.eq(conn:execute("SELECT CURRENT_DATABASE()"):value(), "LUA_SESSION_DB")
        end)
    end)

    t.it("close releases the session", function()
        local before = activesessions()
        local conn = frostlake.connect("frostlake://" .. dsnmodule.hostport(address()))
        conn:execute("SELECT 1")
        t.eq(activesessions(), before + 1)
        conn:close()
        t.eq(activesessions(), before)
    end)

    t.it("(cleanup)", function()
        frostlake.with("frostlake://" .. dsnmodule.hostport(address()), function(conn)
            conn:execute("DROP DATABASE IF EXISTS lua_session_db")
        end)
    end)
end
