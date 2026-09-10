local t = require("harness")
local result = require("frostlake.result")

local function grid()
    return result.new(
        { { name = "ID", datatype = "NUMBER(38,0)" },
          { name = "NAME", datatype = "VARCHAR(16777216)" } },
        { { "1", "Ada" }, { "2", "Grace" } })
end

t.describe("result: shape")

t.it("reports its size", function()
    local r = grid()
    t.eq(r:rowcount(), 2)
    t.eq(r:columncount(), 2)
    t.same(r:names(), { "ID", "NAME" })
end)

t.it("is empty for a statement that returned no grid", function()
    local r = result.new({}, {})
    t.eq(r:rowcount(), 0)
    t.eq(r:value(), nil)
    t.same(r:names(), {})
end)

t.it("answers the first cell", function()
    t.eq(grid():value(), "1")
end)

t.it("reads a cell by index or by name, case-insensitively", function()
    local r = grid()
    t.eq(r:get(1, 2), "Ada")
    t.eq(r:get(1, "NAME"), "Ada")
    t.eq(r:get(1, "name"), "Ada")
    t.eq(r:get(2, "ID"), "2")
end)

t.it("answers nil rather than failing for a cell that is not there", function()
    local r = grid()
    t.eq(r:get(99, 1), nil)
    t.eq(r:get(1, "MISSING"), nil)
    t.eq(r:get(1, 99), nil)
end)

t.it("builds a row keyed by column name", function()
    t.same(grid():record(1), { ID = "1", NAME = "Ada" })
    t.eq(grid():record(9), nil)
end)

t.it("iterates rows as records and as lists", function()
    local names = {}
    for row in grid():records() do names[#names + 1] = row.NAME end
    t.same(names, { "Ada", "Grace" })

    local ids = {}
    for cells, n in grid():each() do ids[n] = cells[1] end
    t.same(ids, { "1", "2" })
end)

t.it("answers a whole column", function()
    t.same(grid():column("NAME"), { "Ada", "Grace" })
    t.raises("usage", grid().column, grid(), "NOPE")
end)

t.it("reports a column's declared type as the engine spelled it", function()
    t.eq(grid():datatype("ID"), "NUMBER(38,0)")
    t.eq(grid():datatype("nope"), nil)
end)

t.it("keeps the first position of a repeated column name", function()
    -- `SELECT a, a` names one column twice; the duplicate stays reachable by
    -- index, and `record` and `get` agree with each other about which is which.
    local r = result.new({ { name = "A" }, { name = "A" } }, { { "first", "second" } })
    t.eq(r:get(1, "A"), "first")
    t.eq(r:get(1, 2), "second")
end)

t.describe("result: update counts")

t.it("reports -1 for a statement that was not DML", function()
    t.eq(grid().updatecount, -1)
end)

t.it("carries a count and its counters when there was one", function()
    local r = result.new({ { name = "number of rows inserted" } }, { { "3" } }, 3,
                         { ["number of rows inserted"] = 3 })
    t.eq(r.updatecount, 3)
    t.eq(r.counters["number of rows inserted"], 3)
    t.eq(r:rowcount(), 1, "the grid itself is kept, not folded away")
end)

t.it("prints as something a person can read", function()
    t.eq(tostring(grid()), "frostlake.result(2 rows, 2 columns)")
    t.eq(tostring(result.new({ { name = "A" } }, { { "x" } })),
         "frostlake.result(1 row, 1 column)")
end)
