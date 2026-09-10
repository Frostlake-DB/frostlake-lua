local t = require("harness")
local bind = require("frostlake.bind")
local value = require("frostlake.value")

t.describe("bind: locating sites")

t.it("finds positional markers", function()
    t.eq(bind.count("SELECT ?, ?, ?"), 3)
    t.eq(bind.count("SELECT 1"), 0)
end)

t.it("finds named markers, counting each name once", function()
    t.eq(bind.count("SELECT :a, :b, :a"), 2)
    t.same(bind.names("SELECT :b, :a, :b"), { "B", "A" })
end)

t.it("reports -1 for a statement mixing the styles", function()
    t.eq(bind.count("SELECT ?, :a"), -1)
end)

t.it("ignores markers inside literals, identifiers, comments and bodies", function()
    t.eq(bind.count("SELECT '?'"), 0)
    t.eq(bind.count('SELECT "a?b"'), 0)
    t.eq(bind.count("SELECT 1 -- ?\n"), 0)
    t.eq(bind.count("SELECT 1 /* ? */"), 0)
    t.eq(bind.count("CREATE PROCEDURE p() AS $$ SELECT ? $$"), 0)
    t.eq(bind.count("SELECT '?', ?"), 1, "a real marker after a fake one")
end)

t.it("does not read a cast or an assignment as a marker", function()
    t.eq(bind.count("SELECT '1'::INT"), 0)
    t.eq(bind.count("SET x := 1"), 0)
end)

t.it("does not read VARIANT path access as a marker", function()
    -- A colon ADJACENT to the end of an expression is a path step, not a bind.
    t.eq(bind.count("SELECT v:field FROM t"), 0)
    t.eq(bind.count("SELECT PARSE_JSON('{}'):k"), 0)
    t.eq(bind.count("SELECT OBJECT_CONSTRUCT('a', 1):a"), 0)
    t.eq(bind.count('SELECT "V":k FROM t'), 0)
    t.eq(bind.count("SELECT v:a:b FROM t"), 0)
    -- A path step on a positional bind is one marker, not a mix of styles.
    t.eq(bind.count("SELECT ?:a"), 1)
    t.eq(bind.render("SELECT ?:a", { value.variant('{"a":1}') }),
         [[SELECT PARSE_JSON('{"a":1}'):a]])
end)

t.it("does not read a positional reference as a name", function()
    t.eq(bind.count("SELECT :1"), 0)
end)

t.describe("bind: positional")

t.it("inlines arguments in order", function()
    t.eq(bind.render("SELECT ?, ?", { 1, "a" }), "SELECT 1, 'a'")
end)

t.it("requires the counts to match in both directions", function()
    local err = t.raises("usage", bind.render, "SELECT ?, ?", { 1 })
    t.contains(err.message, "2 placeholder")
    t.raises("usage", bind.render, "SELECT ?", { 1, 2 })
end)

t.it("passes a statement through when no arguments are given at all", function()
    -- With no arguments the `?` marks belong to the SERVER -- a Scripting
    -- cursor placeholder bound by `OPEN c USING (...)`.
    t.eq(bind.render("OPEN c USING (?)", nil), "OPEN c USING (?)")
    t.eq(bind.render("OPEN c USING (?)", {}), "OPEN c USING (?)")
end)

t.it("takes a types option as one name for all or a list of them", function()
    t.eq(bind.render("SELECT ?, ?", { "1", "2" }, "number"), "SELECT 1, 2")
    t.eq(bind.render("SELECT ?, ?", { "1", "2" }, { "number", "string" }), "SELECT 1, '2'")
end)

t.it("refuses a types list that does not line up", function()
    t.raises("usage", bind.render, "SELECT ?, ?", { 1, 2 }, { "number" })
end)

t.it("binds the null sentinel as NULL, in any position", function()
    t.eq(bind.render("SELECT ?, ?", { value.null, 1 }), "SELECT NULL, 1")
end)

t.it("keeps a NULL in the middle of a list from truncating it", function()
    -- The whole reason the sentinel exists: `{1, nil, 3}` would bind one
    -- argument, and the statement would then be reported as under-supplied.
    local rendered = bind.render("SELECT ?, ?, ?", { 1, value.null, 3 })
    t.eq(rendered, "SELECT 1, NULL, 3")
end)

t.describe("bind: named")

t.it("inlines by name, in any order, case-insensitively", function()
    t.eq(bind.render("SELECT :a + :b", { a = 2, b = 40 }), "SELECT 2 + 40")
    t.eq(bind.render("SELECT :A", { a = 1 }), "SELECT 1")
    t.eq(bind.render("SELECT :a", { A = 1 }), "SELECT 1")
end)

t.it("repeats a name at every site it appears", function()
    t.eq(bind.render("SELECT :x, :x", { x = 7 }), "SELECT 7, 7")
end)

t.it("refuses a placeholder with no argument", function()
    local err = t.raises("usage", bind.render, "SELECT :a, :b", { a = 1 })
    t.contains(err.message, ":b")
end)

t.it("refuses an argument no placeholder mentions", function()
    -- Almost always a name misspelled on one side or the other.
    local err = t.raises("usage", bind.render, "SELECT :a", { a = 1, bb = 2 })
    t.contains(err.message, ":bb")
end)

t.it("binds false rather than reporting it missing", function()
    t.eq(bind.render("SELECT :flag", { flag = false }), "SELECT FALSE")
end)

t.it("takes a types table keyed the same way the arguments are", function()
    t.eq(bind.render("SELECT :n", { n = "5" }, { n = "number" }), "SELECT 5")
    t.eq(bind.render("SELECT :n", { n = "5" }, "number"), "SELECT 5")
end)

t.it("passes a statement through when no arguments are given at all", function()
    -- With no arguments the colon references are the SERVER's Scripting
    -- variables.
    t.eq(bind.render("EXECUTE IMMEDIATE :v", nil), "EXECUTE IMMEDIATE :v")
    t.eq(bind.render("IFF(:flag, 1, 2)", {}), "IFF(:flag, 1, 2)")
end)

t.it("refuses named arguments for a statement with no placeholders", function()
    t.raises("usage", bind.render, "SELECT 1", { a = 1 })
end)

t.describe("bind: mixing")

t.it("refuses a statement using both styles", function()
    local err = t.raises("usage", bind.render, "SELECT ?, :a", { 1, 2 })
    t.contains(err.message, "not both")
end)

t.it("refuses a list where the statement wants names", function()
    local err = t.raises("usage", bind.render, "SELECT :a", { 1 })
    t.contains(err.message, ":name")
end)

t.it("refuses a name table where the statement wants a list", function()
    local err = t.raises("usage", bind.render, "SELECT ?", { a = 1 })
    t.contains(err.message, "positional")
end)

t.it("refuses parameters that are not a table", function()
    t.raises("usage", bind.render, "SELECT ?", "just one")
    t.raises("usage", bind.render, "SELECT ?", 1)
end)

t.describe("bind: injection")

t.it("cannot be escaped from by a quote in an argument", function()
    t.eq(bind.render("SELECT ?", { "'; DROP TABLE t; --" }),
         "SELECT '''; DROP TABLE t; --'")
end)

t.it("cannot be escaped from by a backslash before a quote", function()
    -- A backslash escapes in this dialect, so a lone one before the closing
    -- quote would shield it; doubling the backslash is what stops that.
    t.eq(bind.render("SELECT ?", { "a\\" }), "SELECT 'a\\\\'")
end)

t.it("refuses a table that is both a list and keyed", function()
    -- `{1, 2, name = "x"}` would bind the list and drop the rest without a
    -- word, which is the silent-typo failure the unused-argument check exists
    -- to prevent.
    local err = t.raises("usage", bind.render, "SELECT ?, ?", { 1, 2, name = "x" })
    t.contains(err.message, "name")
end)

t.it("says so when a single wrapped value was passed without its list", function()
    local err = t.raises("usage", bind.render, "SELECT ?", value.number("5"))
    t.contains(err.message, "still goes in a list")
end)
