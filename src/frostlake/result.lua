-- One result set: the grid the engine sent, plus what could be read from it.
--
-- A result is a plain value with no connection behind it -- nothing here talks
-- to the server, and a result outlives the connection that produced it. The
-- whole grid arrives in one response, so there is no cursor to exhaust and no
-- order in which the accessors have to be called.
--
-- Cells are the engine's own text, or the connection's NULL stand-in. See the
-- note at the top of `value.lua` for why they are not converted.

local errors = require("frostlake.errors")

local M = {}

local Result = {}
Result.__index = Result
Result.__name = "frostlake.result"

-- `#res` is the row count on Lua 5.2 and newer. Lua 5.1 and LuaJIT ignore a
-- table's `__len`, so `res:rowcount()` is the spelling that works everywhere
-- and the one the driver's own code uses.
Result.__len = function(self) return #self.rows end

Result.__tostring = function(self)
    return string.format("frostlake.result(%d row%s, %d column%s)",
        #self.rows, #self.rows == 1 and "" or "s",
        #self.columns, #self.columns == 1 and "" or "s")
end

-- Builds a result. `updatecount` is -1 for a statement that was not DML, which
-- is what distinguishes "no rows were changed" from "this did not change rows".
function M.new(columns, rows, updatecount, counters)
    return setmetatable({
        columns = columns or {},
        rows = rows or {},
        updatecount = updatecount or -1,
        counters = counters or {},
    }, Result)
end

function M.is(value)
    return type(value) == "table" and getmetatable(value) == Result
end

function Result:rowcount()
    return #self.rows
end

function Result:columncount()
    return #self.columns
end

-- The column names, in order.
function Result:names()
    local out = {}
    for i, column in ipairs(self.columns) do out[i] = column.name end
    return out
end

-- Column names to their positions, folded to upper case. Built once on first
-- use: a result that is only ever iterated positionally never pays for it.
--
-- A name the engine returned twice -- `SELECT a, a` -- keeps its FIRST
-- position, so `record` and `get` agree with each other, and the duplicate
-- stays reachable by index.
function Result:index()
    if not self._index then
        local index = {}
        for i, column in ipairs(self.columns) do
            local folded = (column.name or ""):upper()
            if index[folded] == nil then index[folded] = i end
        end
        self._index = index
    end
    return self._index
end

-- The position of a column named `name`, or nil. Case-insensitive, because the
-- engine upper-cases an unquoted identifier and a caller who wrote
-- `SELECT name` should not have to remember that.
function Result:columnindex(name)
    if type(name) == "number" then
        return (name >= 1 and name <= #self.columns) and name or nil
    end
    return self:index()[tostring(name):upper()]
end

-- One cell, by row number and column number or name.
function Result:get(row, column)
    local cells = self.rows[row]
    if not cells then return nil end
    local at = self:columnindex(column)
    if not at then return nil end
    return cells[at]
end

-- The first cell of the first row: what a one-value query answers. Returns nil
-- for an empty grid, which is distinguishable from a NULL cell -- that comes
-- back as the connection's NULL stand-in.
function Result:value()
    local first = self.rows[1]
    if not first then return nil end
    return first[1]
end

-- One row as a table keyed by column name, upper-cased the way the engine
-- reports it.
function Result:record(row)
    local cells = self.rows[row]
    if not cells then return nil end
    local out = {}
    -- Through the index, so a name the engine returned twice keeps its FIRST
    -- position here too and `record` agrees with `get`.
    for folded, at in pairs(self:index()) do
        out[folded] = cells[at]
    end
    return out
end

-- Iterates the rows as name-keyed tables:
--
--     for row in result:records() do print(row.NAME) end
function Result:records()
    local i = 0
    return function()
        i = i + 1
        if i > #self.rows then return nil end
        return self:record(i), i
    end
end

-- Iterates the rows as positional lists, with the row number alongside:
--
--     for cells, n in result:each() do print(n, cells[1]) end
function Result:each()
    local i = 0
    return function()
        i = i + 1
        if i > #self.rows then return nil end
        return self.rows[i], i
    end
end

-- Every value in one column, in row order.
function Result:column(name)
    local at = self:columnindex(name)
    if not at then
        errors.usage(string.format("no column named %q in this result", tostring(name)))
    end
    local out = {}
    for i, cells in ipairs(self.rows) do out[i] = cells[at] end
    return out
end

-- The declared type of a column as the engine reports it: the base name --
-- "NUMBER", "VARCHAR", "TIMESTAMP_NTZ" -- with `precision` and `scale` carried
-- in the column's own entry rather than folded into the name.
function Result:datatype(name)
    local at = self:columnindex(name)
    if not at then return nil end
    return self.columns[at].datatype
end

return M
