-- The connection, driven through a scripted transport. Everything here runs the
-- real session handling, result shaping and error paths; only the socket is
-- replaced.

local t = require("harness")
local frostlake = require("frostlake")
local fakebackend = require("fakebackend")

local DSN = "frostlake://example:18082"

local function connect(handler, dsn, options)
    local backend = fakebackend.new(handler)
    options = options or {}
    options.transport = backend
    return frostlake.connect(dsn or DSN, options), backend
end

-- The SQL of every /api/execute request the driver sent, in order.
local function statements(backend)
    local out = {}
    for _, request in ipairs(backend.requests) do
        if request.path == "/api/execute" then
            out[#out + 1] = frostlake.json.textat(frostlake.json.parse(request.body), "sql")
        end
    end
    return out
end

t.describe("connection: opening")

t.it("pings the health endpoint before returning", function()
    local _, backend = connect(fakebackend.always(fakebackend.acknowledged()))
    t.eq(backend.requests[1].path, "/api/health")
    t.eq(backend.requests[1].method, "GET")
end)

t.it("refuses a server whose health body is not a Frostlake response", function()
    local err = t.raises("connection", connect, function(request)
        if request.path == "/api/health" then return { body = '{"nginx":"welcome"}' } end
        return { body = fakebackend.acknowledged() }
    end)
    t.contains(err.message, "not a Frostlake response")
end)

t.it("refuses a health endpoint that answers a non-200", function()
    local err = t.raises("connection", connect, function()
        return { status = 502, body = "<html>bad gateway</html>" }
    end)
    t.contains(err.message, "502")
end)

t.it("applies the DSN scope before returning, in dependency order", function()
    local _, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }),
        "frostlake://example:18082/SALES?schema=PUBLIC&role=R&warehouse=W")
    t.same(statements(backend), {
        'USE ROLE "R"', 'USE WAREHOUSE "W"', 'USE DATABASE "SALES"', 'USE SCHEMA "PUBLIC"',
    })
end)

t.it("reports a database that does not exist at connect time", function()
    -- Rather than letting it surface later on whichever query happened to run
    -- first.
    local err = t.raises("query", connect, function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        return { body = fakebackend.refused("Database 'NOPE' does not exist") }
    end, "frostlake://example:18082/NOPE")
    t.contains(err.message, "does not exist")
end)

t.it("closes the socket when the constructor fails", function()
    local backend = fakebackend.new(function() return { status = 500, body = "no" } end)
    pcall(frostlake.connect, DSN, { transport = backend })
    t.eq(backend.closed, backend.opened, "every socket opened was closed again")
end)

t.it("refuses an unknown option and lists the real ones", function()
    local err = t.raises("usage", frostlake.connect, DSN, { timeuot = 5 })
    t.contains(err.message, "timeuot")
    t.contains(err.message, "timeout")
end)

t.it("lets an option outrank the DSN", function()
    local _, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }),
        "frostlake://example:18082/FROM_DSN", { database = "FROM_OPTION" })
    t.same(statements(backend), { 'USE DATABASE "FROM_OPTION"' })
end)

t.it("refuses TLS options on a plain DSN", function()
    t.raises("usage", frostlake.connect, DSN, { verify = false })
end)

t.describe("connection: statements")

t.it("sends the statement, the session id and the autocommit flag", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged("S9") }))
    conn:execute("SELECT 1")
    conn:execute("SELECT 2")
    local last = frostlake.json.parse(backend.requests[#backend.requests].body)
    t.eq(frostlake.json.textat(last, "sql"), "SELECT 2")
    t.eq(frostlake.json.textat(last, "sessionId"), "S9", "the id from the first answer")
    t.eq(frostlake.json.boolean(frostlake.json.at(last, "autoCommit")), true)
end)

t.it("sends no session id until the server has given one", function()
    local backend = fakebackend.new(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        return { body = fakebackend.acknowledged("S1") }
    end)
    frostlake.connect(DSN, { transport = backend }):execute("SELECT 1")
    local first = frostlake.json.parse(backend.requests[2].body)
    t.eq(frostlake.json.kind(frostlake.json.at(first, "sessionId")), "missing")
end)

t.it("keeps the session id across statements", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged("S7") }))
    conn:execute("SELECT 1")
    conn:execute("SELECT 2")
    t.eq(conn:session(), "S7")
    local last = frostlake.json.parse(backend.requests[#backend.requests].body)
    t.eq(frostlake.json.textat(last, "sessionId"), "S7")
end)

t.it("does not drop the session when one statement fails", function()
    -- A failure answers with sessionId null, and taking that would silently
    -- start a new session for every statement after a typo.
    local step = 0
    local conn = connect(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        step = step + 1
        if step == 2 then return { body = fakebackend.refused("no such table") } end
        return { body = fakebackend.acknowledged("S3") }
    end)
    conn:execute("SELECT 1")
    t.raises("query", conn.execute, conn, "SELECT * FROM missing")
    t.eq(conn:session(), "S3")
end)

t.it("reports a refused statement as a query error carrying the statement", function()
    local conn = connect(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        return { body = fakebackend.refused("Object 'MISSING' does not exist") }
    end)
    local err = t.raises("query", conn.execute, conn, "SELECT * FROM missing")
    t.contains(err.message, "does not exist")
    t.eq(err.statement, "SELECT * FROM missing")
end)

t.it("never reports an empty error message", function()
    local conn = connect(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        return { status = 400, body = '{"success":false}' }
    end)
    local err = t.raises("query", conn.execute, conn, "")
    t.contains(err.message, "400")
end)

t.it("reports a body that is not a Frostlake response, naming the address", function()
    local conn = connect(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        return { status = 502, body = "<html>bad gateway</html>" }
    end)
    local err = t.raises("connection", conn.execute, conn, "SELECT 1")
    t.contains(err.message, "example:18082")
    t.contains(err.message, "bad gateway")
end)

t.it("binds parameters before sending", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    conn:execute("SELECT ?, ?", { 1, "Ada" })
    t.eq(statements(backend)[1], "SELECT 1, 'Ada'")
end)

t.it("renders without sending", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    t.eq(conn:render("SELECT ?", { "x" }), "SELECT 'x'")
end)

t.it("refuses a statement that is not a string", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    t.raises("usage", conn.execute, conn, 42)
end)

t.describe("connection: results")

t.it("shapes a grid into columns and rows", function()
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { { "ID", "NUMBER(38,0)" }, { "NAME", "VARCHAR(16777216)" } },
        { { "1", "Ada" }, { "2", "Grace" } }) }))
    local r = conn:execute("SELECT id, name FROM people")
    t.same(r:names(), { "ID", "NAME" })
    t.eq(r:rowcount(), 2)
    t.eq(r:get(1, "NAME"), "Ada")
    t.eq(r:datatype("ID"), "NUMBER(38,0)")
end)

t.it("hands back numeric cells as the engine's own text", function()
    local big = "12345678901234567890123456789012345678"
    local conn = connect(fakebackend.always({
        raw = nil,
        body = '{"success":true,"sessionId":"S1","resultSets":[{"columns":'
            .. '[{"name":"N","dataType":"NUMBER(38,0)"}],"rows":[[' .. big .. "]]}]}" }))
    t.eq(conn:execute("SELECT n FROM t"):value(), big)
end)

t.it("hands back a NULL cell as the null sentinel, keeping the row's width", function()
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "A", "B", "C" }, { { "x", nil, "z", n = 3 } }) }))
    local r = conn:execute("SELECT a, b, c FROM t")
    t.eq(r:get(1, "B"), frostlake.null)
    t.eq(r:get(1, "C"), "z", "a NULL in the middle does not truncate the row")
    t.eq(tostring(r:get(1, "B")), "NULL")
end)

t.it("uses a caller's own NULL stand-in", function()
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "A" }, { { nil, n = 1 } }) }), nil, { null = "(nothing)" })
    t.eq(conn:execute("SELECT a FROM t"):value(), "(nothing)")
end)

t.it("hands back a cell that arrived as a nested value as its JSON text", function()
    -- The wire sends a bare VECTOR as a descriptor object rather than as text;
    -- whatever the shape, a cell must not quietly become NULL.
    local conn = connect(fakebackend.always({
        body = '{"success":true,"sessionId":"S1","resultSets":[{"columns":'
            .. '[{"name":"V"},{"name":"A"}],"rows":[[{"elementType":"INT"},[1,null]]]}]}' }))
    local r = conn:execute("SELECT v, a FROM t")
    t.eq(r:get(1, "V"), '{"elementType":"INT"}')
    t.eq(r:get(1, "A"), "[1,null]")
end)

t.it("pads a row the server sent short of the column count", function()
    local conn = connect(fakebackend.always({
        body = '{"success":true,"sessionId":"S1","resultSets":[{"columns":'
            .. '[{"name":"A"},{"name":"B"}],"rows":[["only one"]]}]}' }))
    local r = conn:execute("SELECT a, b FROM t")
    t.eq(r:get(1, "B"), frostlake.null)
end)

t.it("answers one empty result for a statement that returned no grid", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    local r = conn:execute("CREATE TABLE t (a INT)")
    t.ok(frostlake.result.is(r))
    t.eq(r:rowcount(), 0)
    t.eq(r.updatecount, -1)
end)

t.it("derives an update count from a DML status grid", function()
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "number of rows inserted" }, { { "3" } }) }))
    local r = conn:execute("INSERT INTO t VALUES (1),(2),(3)")
    t.eq(r.updatecount, 3)
    t.eq(r.counters["number of rows inserted"], 3)
end)

t.it("sums the row counters of a MERGE", function()
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "number of rows inserted", "number of rows updated" }, { { "2", "5" } }) }))
    t.eq(conn:execute("MERGE INTO t ...").updatecount, 7)
end)

t.it("leaves the multi-joined diagnostic out of the sum", function()
    -- It is a sub-count of rows already counted as updated.
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "number of rows updated", "number of multi-joined rows updated" },
        { { "4", "9" } }) }))
    local r = conn:execute("UPDATE t SET a = 1")
    t.eq(r.updatecount, 4)
    t.eq(r.counters["number of multi-joined rows updated"], 9)
end)

t.it("does not read an ordinary one-row grid as a status grid", function()
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "TOTAL" }, { { "3" } }) }))
    t.eq(conn:execute("SELECT COUNT(*) AS total FROM t").updatecount, -1)
end)

t.it("returns every result set a multi-statement request produced", function()
    local conn = connect(fakebackend.always({
        body = '{"success":true,"sessionId":"S1","resultSets":['
            .. '{"columns":[{"name":"A"}],"rows":[["1"]]},'
            .. '{"columns":[{"name":"B"}],"rows":[["2"]]}]}' }))
    local all = conn:executeall("SELECT 1; SELECT 2")
    t.eq(#all, 2)
    t.eq(all[1]:value(), "1")
    t.eq(all[2]:value(), "2")
    t.eq(conn:execute("SELECT 1; SELECT 2"):value(), "1", "execute takes the first")
end)

t.describe("connection: transactions")

t.it("sends BEGIN and COMMIT, and turns autocommit off in between", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    t.eq(conn:intransaction(), false)
    conn:begin()
    t.eq(conn:intransaction(), true)
    conn:execute("INSERT INTO t VALUES (1)")
    conn:commit()
    t.eq(conn:intransaction(), false)
    t.same(statements(backend), { "BEGIN", "INSERT INTO t VALUES (1)", "COMMIT" })

    local inside = frostlake.json.parse(backend.requests[3].body)
    t.eq(frostlake.json.boolean(frostlake.json.at(inside, "autoCommit")), false)
end)

t.it("rolls back and re-raises when the body fails", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    local err = t.raises("query", conn.transaction, conn, function()
        error(frostlake.errors.make("query", "boom"), 0)
    end)
    t.eq(err.message, "boom")
    t.same(statements(backend), { "BEGIN", "ROLLBACK" })
end)

t.it("returns what the body returned", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    t.eq(conn:transaction(function() return "done" end), "done")
end)

t.it("restores autocommit even when BEGIN itself fails", function()
    local step = 0
    local conn = connect(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        step = step + 1
        if step == 1 then return { body = fakebackend.refused("cannot begin") } end
        return { body = fakebackend.acknowledged() }
    end)
    t.raises("query", conn.begin, conn)
    t.eq(conn:intransaction(), false)
end)

t.describe("connection: the socket")

t.it("keeps one socket across statements", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    for _ = 1, 5 do conn:execute("SELECT 1") end
    t.eq(backend.opened, 1, "one socket for the whole connection")
end)

t.it("opens a fresh socket after the server closed one", function()
    local conn, backend = connect(fakebackend.always({
        body = fakebackend.acknowledged(), headers = { ["Connection"] = "close" } }))
    conn:execute("SELECT 1")
    conn:execute("SELECT 2")
    t.ok(backend.opened >= 2, "a closed socket is replaced rather than reused")
end)

t.it("drops the socket when an exchange breaks, and does not re-send", function()
    -- The statement's fate is unknown -- it may have run before the connection
    -- broke -- so nothing is sent twice.
    local sent = 0
    local conn = connect(function(request)
        if request.path == "/api/health" then return { body = fakebackend.healthy() } end
        sent = sent + 1
        return "die"
    end)
    t.raises("connection", conn.execute, conn, "INSERT INTO t VALUES (1)")
    t.eq(sent, 1)
end)

t.it("refuses to work once closed", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    conn:close()
    t.eq(conn:isopen(), false)
    t.raises("usage", conn.execute, conn, "SELECT 1")
end)

t.it("closes twice without complaint", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    conn:close()
    conn:close()
end)

t.describe("connection: session defaults")

t.it("puts the DSN scope back on after the engine's idle limit", function()
    -- Past the limit the engine may have reclaimed the session and built a
    -- fresh one for the same id, losing the scope. Nothing in the reply says
    -- so, and the id is echoed back either way.
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }),
        "frostlake://example:18082/DB?idleLimit=1s")
    conn:execute("SELECT 1")
    local before = #statements(backend)
    backend.now = backend.now + 5
    conn:execute("SELECT 2")
    local after = statements(backend)
    t.eq(after[before + 1], 'USE DATABASE "DB"', "the scope goes back on")
end)

t.it("does not put it back once the caller has chosen a scope themselves", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }),
        "frostlake://example:18082/DB?idleLimit=1s")
    conn:execute("USE DATABASE OTHER")
    backend.now = backend.now + 5
    conn:execute("SELECT 1")
    t.same(statements(backend), { 'USE DATABASE "DB"', "USE DATABASE OTHER", "SELECT 1" })
end)

t.it("does not put it back inside the limit", function()
    local conn, backend = connect(fakebackend.always({ body = fakebackend.acknowledged() }),
        "frostlake://example:18082/DB?idleLimit=1h")
    conn:execute("SELECT 1")
    backend.now = backend.now + 5
    conn:execute("SELECT 2")
    t.same(statements(backend), { 'USE DATABASE "DB"', "SELECT 1", "SELECT 2" })
end)

t.describe("connection: reporting")

t.it("answers what it is connected to", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }))
    t.eq(conn:baseurl(), "http://example:18082")
    t.eq(conn:nullvalue(), frostlake.null)
    t.contains(tostring(conn), "http://example:18082")
end)

t.describe("frostlake.with")

t.it("closes the connection however the body ends", function()
    local backend = fakebackend.new(fakebackend.always({ body = fakebackend.acknowledged() }))
    local seen
    local outcome = frostlake.with(DSN, { transport = backend }, function(conn)
        seen = conn
        return conn:execute("SELECT 1")
    end)
    t.ok(frostlake.result.is(outcome))
    t.eq(seen:isopen(), false)

    local backend2 = fakebackend.new(fakebackend.always({ body = fakebackend.acknowledged() }))
    local captured
    t.raises("query", frostlake.with, DSN, { transport = backend2 }, function(conn)
        captured = conn
        error(frostlake.errors.make("query", "boom"), 0)
    end)
    t.eq(captured:isopen(), false, "closed before the error propagated")
end)

t.describe("errors")

t.it("carries a kind, a message and its context", function()
    local err = frostlake.errors.make("query", "boom", { statement = "SELECT 1" })
    t.eq(err.kind, "query")
    t.eq(err.message, "boom")
    t.eq(err.statement, "SELECT 1")
    t.eq(tostring(err), "boom", "it prints as its message")
    t.ok(frostlake.iserror(err))
    t.ok(frostlake.iskind(err, "query"))
    t.ok(not frostlake.iskind(err, "usage"))
end)

t.it("does not claim someone else's error", function()
    t.ok(not frostlake.iserror("just a string"))
    t.ok(not frostlake.iserror({ kind = "query", message = "forged" }))
end)

t.describe("transport: the contract")

t.it("adopts a backend that has the four functions", function()
    local adopted = frostlake.transport.adopt({
        open = function() end, send = function() end,
        receive = function() end, close = function() end,
    })
    t.eq(type(adopted.settimeout), "function", "the optional ones are filled in")
    t.eq(type(adopted.gettime), "function")
    t.eq(type(adopted.stale), "function")
    t.eq(adopted.name, "custom")
end)

t.it("refuses one that is missing a function, naming it", function()
    local err = t.raises("usage", frostlake.transport.adopt, {
        open = function() end, send = function() end, close = function() end })
    t.contains(err.message, "receive")
end)

t.describe("transport: TLS wrapping")

t.it("bounds the handshake by the connect timeout, in LuaSocket's seconds", function()
    -- LuaSec is stood in for, so the wrapping runs with no OpenSSL anywhere.
    local timeouts, shaken = {}, 0
    package.preload["ssl"] = function()
        return { wrap = function()
            return {
                settimeout = function(_, seconds) timeouts[#timeouts + 1] = seconds end,
                dohandshake = function() shaken = shaken + 1 return true end,
            }
        end }
    end
    package.loaded["ssl"] = nil
    local ok, wrapped = pcall(frostlake.transport.wraptls, {},
                              { host = "h", verify = false, connecttimeout = 2500 })
    local ok2, wrapped2 = pcall(frostlake.transport.wraptls, {},
                                { host = "h", verify = false, connecttimeout = 0 })
    package.preload["ssl"] = nil
    package.loaded["ssl"] = nil
    t.ok(ok, "wrapping raised: " .. tostring(wrapped))
    t.ok(ok2, "wrapping raised: " .. tostring(wrapped2))
    t.eq(type(wrapped), "table")
    t.eq(shaken, 2)
    t.same(timeouts, { 2.5, nil }, "2500ms is 2.5s; zero means no bound")
end)

t.describe("json convenience")

t.it("reads a VARIANT cell into plain Lua values", function()
    local doc = frostlake.parsejson('{"items":[{"price":9.5},{"price":null}],"ok":true}')
    t.eq(doc.items[1].price, 9.5)
    t.eq(doc.ok, true)
    -- SQL NULL and JSON null land on the same sentinel, so a parsed cell and an
    -- ordinary one compare the same way.
    t.eq(doc.items[2].price, frostlake.null)
end)

t.it("keeps a NULL inside an array from truncating it", function()
    local list = frostlake.parsejson('[1,null,3]')
    t.eq(#list, 3)
    t.eq(list[2], frostlake.null)
end)

t.describe("connection: a false NULL stand-in")

t.it("honours null = false rather than reading it as 'not given'", function()
    -- `options.null ~= nil and options.null or value.null` would quietly hand
    -- back the sentinel here, because `false or x` is `x`.
    local conn = connect(fakebackend.always({ body = fakebackend.grid(
        { "A" }, { { nil, n = 1 } }) }), nil, { null = false })
    t.eq(conn:nullvalue(), false)
    t.eq(conn:execute("SELECT a FROM t"):value(), false)
end)

t.it("binds that stand-in back out as NULL", function()
    local conn = connect(fakebackend.always({ body = fakebackend.acknowledged() }),
                         nil, { null = false })
    t.eq(conn:render("SELECT ?", { false }), "SELECT NULL")
end)
