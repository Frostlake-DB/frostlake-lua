-- A tour of the driver against a running engine.
--
--     lua examples/basic.lua [dsn]
--
-- Start an engine first:
--
--     java -cp 'path/to/frostlake/lib/*' dev.frostlake.http.DatabaseHttpServer 18082

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local frostlake = require("frostlake")

local dsn = arg[1] or "frostlake://localhost:18082"

print("frostlake-lua " .. frostlake.VERSION
    .. " over " .. (frostlake.transport.detect() or {}).name)

local conn = frostlake.connect(dsn)
print("connected to " .. conn:baseurl())
print("engine       " .. conn:execute("SELECT CURRENT_VERSION()"):value())

-- A scratch space of our own, so this can be run twice in a row.
conn:execute("CREATE OR REPLACE DATABASE example_db")
conn:execute("USE DATABASE example_db")
conn:execute("CREATE OR REPLACE SCHEMA example_schema")
conn:execute("USE SCHEMA example_schema")

-- ------------------------------------------------------------------- writing

conn:execute([[
    CREATE TABLE people (
        id     INTEGER,
        name   VARCHAR,
        joined DATE,
        score  NUMBER(10,2)
    )
]])

-- Positional parameters, inlined by the driver: the HTTP protocol has no
-- server-side binding, so the driver renders each value as the literal that
-- stands in for it.
local inserted = conn:execute(
    "INSERT INTO people VALUES (?, ?, ?, ?), (?, ?, ?, ?)",
    { 1, "Ada",   frostlake.date("1842-01-01"), 99.5,
      2, "Grace", frostlake.date("1952-06-15"), 87.25 })
print("inserted     " .. inserted.updatecount)

-- Named parameters. Which style applies is decided by the statement, not by the
-- table: `?` takes a list, `:name` takes a table keyed by name.
conn:execute("INSERT INTO people VALUES (:id, :name, :joined, :score)",
    { id = 3, name = "Alan", joined = frostlake.date("1936-05-28"), score = 92 })

-- A NULL, in a position a Lua `nil` could not survive: `{4, nil, ...}` would
-- bind one argument, not four.
conn:execute("INSERT INTO people VALUES (?, ?, ?, ?)",
    { 4, "Unknown", frostlake.null, frostlake.null })

-- ------------------------------------------------------------------- reading

local people = conn:execute("SELECT id, name, joined, score FROM people ORDER BY id")

print(string.format("\n%-4s %-10s %-12s %s", "ID", "NAME", "JOINED", "SCORE"))
for row in people:records() do
    print(string.format("%-4s %-10s %-12s %s",
        tostring(row.ID), tostring(row.NAME), tostring(row.JOINED), tostring(row.SCORE)))
end

-- Cells are the engine's own text. `score` is a NUMBER(10,2), and the engine
-- wrote "99.50": the trailing zero is real, and converting on the way in would
-- have thrown it away.
print("\nscore text   " .. tostring(people:get(1, "SCORE")))
print("score number " .. tostring(frostlake.value.tonumber(people:get(1, "SCORE"))))
print("declared as  " .. people:datatype("SCORE"))

-- A NULL comes back as the sentinel, which prints as NULL and compares by
-- identity.
local unknown = conn:execute("SELECT score FROM people WHERE id = 4"):value()
print("null cell    " .. tostring(unknown) .. "  (is the sentinel: "
    .. tostring(unknown == frostlake.null) .. ")")

-- --------------------------------------------------------------- aggregates

print("\naverage      " .. conn:execute("SELECT AVG(score) FROM people"):value())
print("count        " .. conn:execute("SELECT COUNT(*) FROM people"):value())

-- -------------------------------------------------------------- transactions

conn:transaction(function(c)
    c:execute("UPDATE people SET score = score + 1 WHERE id = ?", { 1 })
    c:execute("UPDATE people SET score = score + 1 WHERE id = ?", { 2 })
end)
print("after commit " .. conn:execute("SELECT score FROM people WHERE id = 1"):value())

-- A body that fails rolls back, and the error carries through.
local ok, err = pcall(conn.transaction, conn, function(c)
    c:execute("UPDATE people SET score = 0")
    c:execute("SELECT * FROM no_such_table")
end)
print("after rollback " .. conn:execute("SELECT score FROM people WHERE id = 1"):value()
    .. "  (" .. err.kind .. ": " .. err.message:sub(1, 40) .. "...)")

-- ------------------------------------------------------------------- errors

local ok2, refused = pcall(conn.execute, conn, "SELECT * FROM missing")
print("\nkind         " .. refused.kind)
print("message      " .. refused.message)
print("statement    " .. refused.statement)

-- ------------------------------------------------------------------ cleanup

conn:execute("DROP DATABASE IF EXISTS example_db")
conn:close()
print("\nclosed       " .. tostring(not conn:isopen()))
