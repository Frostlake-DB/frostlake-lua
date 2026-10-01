-- frostlake -- a Lua driver for Frostlake.
--
--     local frostlake = require "frostlake"
--
--     local conn = frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
--     conn:execute("CREATE TABLE people (id INTEGER, name VARCHAR)")
--     conn:execute("INSERT INTO people VALUES (?, ?)", {1, "Ada"})
--     print(conn:execute("SELECT name FROM people WHERE id = ?", {1}):value())
--     conn:close()
--
-- Everything the driver does travels the engine's HTTP protocol to a running
-- `DatabaseHttpServer`: no JVM in this process, no native database library,
-- nothing to build. The one thing outside Lua's standard library is a socket,
-- which comes from LuaSocket, from OpenResty's cosockets, or from whatever the
-- caller passes as the `transport` option -- see `transport.lua`.
--
-- Failures are RAISED, as tables carrying a `kind` ("usage", "connection",
-- "query" or "sessionlost") and a `message`. `pcall` hands the whole table back:
--
--     local ok, err = pcall(conn.execute, conn, "SELECT * FROM missing")
--     if not ok and err.kind == "query" then print(err.message) end
--
-- See `errors.lua` for what the four kinds mean and why the difference
-- matters.

local connection = require("frostlake.connection")
local value = require("frostlake.value")
local result = require("frostlake.result")
local errors = require("frostlake.errors")
local dsn = require("frostlake.dsn")
local json = require("frostlake.json")
local sql = require("frostlake.sql")
local bind = require("frostlake.bind")
local transport = require("frostlake.transport")
local http = require("frostlake.http")

local M = {}

M.VERSION = "0.2.0"

-- The engine floor. The driver speaks the HTTP protocol rather than linking the
-- jar, so this is a minimum rather than a lockstep pin; ask a running server
-- which one it is with `SELECT CURRENT_VERSION()`.
M.ENGINE_VERSION = "0.2.0"

http.USER_AGENT = "frostlake-lua/" .. M.VERSION

-- ------------------------------------------------------------------ opening

-- Opens a connection. See `connection.lua` for the options.
function M.connect(url, options)
    return connection.connect(url, options)
end

-- Opens a connection, runs `body(conn)`, and closes it however the body ends:
--
--     frostlake.with("frostlake://localhost:18082", function(conn)
--         return conn:execute("SELECT CURRENT_VERSION()"):value()
--     end)
--
-- The close happens before the error propagates, so a body that throws still
-- gives its socket back.
function M.with(url, options, body)
    if body == nil and type(options) == "function" then
        options, body = nil, options
    end
    if type(body) ~= "function" then
        errors.usage("frostlake.with takes a function, got " .. type(body))
    end
    local conn = M.connect(url, options)
    local ok, outcome = pcall(body, conn)
    conn:close()
    if not ok then error(outcome, 0) end
    return outcome
end

-- --------------------------------------------------------------- SQL values

-- The two-way stand-in for SQL NULL. Not `nil`, which cannot survive in a Lua
-- list -- see the note in `value.lua`.
M.null = value.null

-- Wrappers that say what a bound value is where Lua's own type does not:
--
--     frostlake.number("5")             a numeric literal, from text
--     frostlake.raw("CURRENT_DATE()")   SQL spliced in verbatim
--     frostlake.binary(bytes)           X'...'
--     frostlake.date("2024-01-15")
--     frostlake.time("10:30:00")
--     frostlake.timestamp("2024-01-15 10:30:00")     ::TIMESTAMP_NTZ
--     frostlake.timestamptz("2024-01-15 10:30:00 +01:00")
--     frostlake.variant('{"a":1}')      PARSE_JSON(...)
--     frostlake.text(42)                force a string literal
M.number = value.number
M.raw = value.raw
M.binary = value.binary
M.date = value.date
M.time = value.time
M.timestamp = value.timestamp
M.timestampntz = value.timestampntz
M.timestamptz = value.timestamptz
M.variant = value.variant
M.text = value.text

-- Quotes an identifier assembled at runtime, so it can be spliced into a
-- statement safely. Embedded quotes are doubled.
M.identifier = dsn.quote

-- Reads a VARIANT, OBJECT or ARRAY cell -- which arrives as JSON text -- into
-- plain Lua values, with SQL NULL and JSON null both landing on `frostlake.null`
-- so a parsed cell and an ordinary one compare the same way.
--
--     local doc = frostlake.parsejson(row.PAYLOAD)
--     doc.items[1].price
--
-- Numbers become Lua numbers here, which is lossy for a value wider than a
-- double. `frostlake.json.parse` keeps the digits and hands back a tree that
-- has to be walked with accessors; this is the convenient half of that trade.
function M.parsejson(text)
    return json.tolua(json.parse(text), value.null)
end

-- ------------------------------------------------------------------- errors

-- Whether a value is one of this driver's errors, and of which kind. Anything
-- else caught by a `pcall` around driver code -- a bug in here, an
-- out-of-memory -- is not one, and should not be swallowed as though it were.
M.iserror = errors.is
M.iskind = errors.iskind

-- ------------------------------------------------------------- the internals

-- Exposed because they are useful on their own and because the test suite
-- drives them directly. `json` in particular is worth having: a VARIANT column
-- comes back as text, and this is a parser for it that keeps a NUMBER(38,0)'s
-- digits intact.
M.json = json
M.dsn = dsn
M.sql = sql
M.bind = bind
M.value = value
M.result = result
M.errors = errors
M.transport = transport

return M
