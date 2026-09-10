local t = require("harness")
local sql = require("frostlake.sql")

t.describe("sql: enclosures")

t.it("steps over a single-quoted literal", function()
    t.eq(sql.skipenclosure("'abc' rest", 1), 6)
end)

t.it("steps over a doubled quote inside a literal", function()
    t.eq(sql.skipenclosure("'a''b' x", 1), 7)
end)

t.it("steps over a backslash escape inside a literal", function()
    -- A backslash always escapes in Frostlake's string dialect, so the quote it
    -- shields does not end the literal.
    t.eq(sql.skipenclosure([['a\'b' x]], 1), 7)
end)

t.it("steps over a quoted identifier, doubled quotes included", function()
    t.eq(sql.skipenclosure('"a""b" x', 1), 7)
end)

t.it("steps over the comment forms", function()
    t.eq(sql.skipenclosure("-- gone\nrest", 1), 9)
    t.eq(sql.skipenclosure("// gone\nrest", 1), 9)
    t.eq(sql.skipenclosure("/* gone */rest", 1), 11)
end)

t.it("steps over a dollar-quoted body", function()
    t.eq(sql.skipenclosure("$$ body $$rest", 1), 11)
end)

t.it("does not read a dollar inside an identifier as opening a body", function()
    -- `A$$B` is a name, not the start of a procedure body.
    t.eq(sql.skipenclosure("A$$B", 2), nil)
end)

t.it("opens nothing on an ordinary character", function()
    t.eq(sql.skipenclosure("SELECT 1", 1), nil)
    t.eq(sql.skipenclosure("a - b", 3), nil, "a minus that is not a comment")
    t.eq(sql.skipenclosure("a / b", 3), nil, "a slash that is not a comment")
end)

t.it("runs an unterminated region to the end rather than looping", function()
    t.eq(sql.skipenclosure("'never closed", 1), 14)
    t.eq(sql.skipenclosure("/* never closed", 1), 16)
end)

t.describe("sql: splitting")

t.it("splits on top-level semicolons", function()
    t.same(sql.splitstatements("A; B; C"), { "A", " B", " C" })
end)

t.it("leaves alone a semicolon inside a literal, comment or body", function()
    t.eq(#sql.splitstatements("SELECT ';'"), 1)
    t.eq(#sql.splitstatements("SELECT 1 -- ; not a split\n"), 1)
    t.eq(#sql.splitstatements('SELECT "a;b"'), 1)
    t.eq(#sql.splitstatements("CREATE PROCEDURE p() AS $$ BEGIN a; b; END $$"), 1)
end)

t.describe("sql: leading words")

t.it("reads the first words upper-cased", function()
    t.same(sql.leadingwords("create or replace table t", 3), { "CREATE", "OR", "REPLACE" })
end)

t.it("skips leading comments and whitespace", function()
    t.same(sql.leadingwords("/* note */\n  use schema s", 2), { "USE", "SCHEMA" })
end)

t.it("stops at the first thing that is not a word", function()
    t.same(sql.leadingwords("SELECT (1)", 4), { "SELECT" })
end)

t.it("reads nothing from a statement starting with a literal", function()
    t.same(sql.leadingwords("'text' rest", 3), {})
end)

t.describe("sql: scope changes")

t.it("flags the statements that move the session", function()
    for _, statement in ipairs({
        "USE DATABASE d", "use schema s", "SET x = 1", "UNSET x",
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        "CREATE DATABASE d", "DROP DATABASE IF EXISTS d",
        "CREATE OR REPLACE SCHEMA s", "CREATE TRANSIENT DATABASE d",
    }) do
        t.ok(sql.changesscope(statement), statement .. " should change scope")
    end
end)

t.it("leaves alone the statements that do not", function()
    for _, statement in ipairs({
        "SELECT 1", "CREATE TABLE t (a INT)", "DROP TABLE t",
        "ALTER TABLE t ADD COLUMN b INT", "INSERT INTO t VALUES (1)",
        "CREATE OR REPLACE VIEW v AS SELECT 1",
        "CREATE WAREHOUSE w",
    }) do
        t.ok(not sql.changesscope(statement), statement .. " should not change scope")
    end
end)

t.it("finds a USE riding behind another statement", function()
    -- A request may hold more than one statement, and the second moves the
    -- scope just as surely as a first would.
    t.ok(sql.changesscope("SELECT 1; USE SCHEMA other"))
end)

t.it("is not fooled by the word USE inside a literal", function()
    t.ok(not sql.changesscope("SELECT 'USE DATABASE d'"))
end)
