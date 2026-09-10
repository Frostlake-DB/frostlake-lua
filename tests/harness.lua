-- A small test harness, so the suite needs no rock of its own.
--
-- busted and telescope are both good and neither is installed by default, and a
-- driver whose tests cannot be run without first installing something else gets
-- run less. This is the part of them the suite uses: grouped cases, a handful
-- of assertions, and a report that exits non-zero when anything failed.

local M = {}

M.groups = {}
M.passed = 0
M.failed = 0
M.skipped = 0
M.failures = {}

local current = nil

-- Starts a group. Every `it` after this belongs to it until the next `describe`.
function M.describe(name)
    current = { name = name, cases = {} }
    M.groups[#M.groups + 1] = current
end

function M.it(name, body)
    if not current then M.describe("(ungrouped)") end
    current.cases[#current.cases + 1] = { name = name, body = body }
end

-- Records a case as skipped, with the reason. Used where a test needs something
-- the machine may not have -- an engine, a corpus -- so that a missing
-- dependency reads as "not run" rather than as a pass.
function M.skip(name, why)
    if not current then M.describe("(ungrouped)") end
    current.cases[#current.cases + 1] = { name = name, skip = why }
end

-- ---------------------------------------------------------------- assertions

local function fail(message, level)
    error({ assertion = message }, (level or 2) + 1)
end

M.fail = function(message) fail(message, 2) end

-- Renders a value for a failure message: strings quoted so an empty one and a
-- missing one look different, tables shown one level deep.
local function show(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local mt = getmetatable(value)
    if mt and mt.__tostring then return tostring(value) end
    local parts = {}
    for i, item in ipairs(value) do parts[i] = show(item) end
    local n = #parts
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > n then
            parts[#parts + 1] = tostring(key) .. " = " .. show(item)
        end
    end
    table.sort(parts, function(a, b) return tostring(a) < tostring(b) end)
    return "{" .. table.concat(parts, ", ") .. "}"
end

M.show = show

function M.ok(value, message)
    if not value then
        fail(message or ("expected a true value, got " .. show(value)))
    end
    return value
end

function M.eq(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%sexpected %s, got %s",
            message and (message .. ": ") or "", show(expected), show(actual)))
    end
end

function M.neq(actual, unexpected, message)
    if actual == unexpected then
        fail(string.format("%sexpected anything but %s",
            message and (message .. ": ") or "", show(unexpected)))
    end
end

-- Deep equality over lists and maps, which is what most result comparisons are.
local function deepeq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for key, value in pairs(a) do
        if not deepeq(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

M.deepeq = deepeq

function M.same(actual, expected, message)
    if not deepeq(actual, expected) then
        fail(string.format("%sexpected %s, got %s",
            message and (message .. ": ") or "", show(expected), show(actual)))
    end
end

function M.contains(haystack, needle, message)
    if type(haystack) ~= "string" or not haystack:lower():find(needle:lower(), 1, true) then
        fail(string.format("%sexpected %s to contain %s",
            message and (message .. ": ") or "", show(haystack), show(needle)))
    end
end

-- Runs `body` expecting it to raise one of the driver's errors of `kind`, and
-- returns the error so the caller can check its message. A body that succeeds
-- is a failure, and so is one that raises something else -- a Lua error from a
-- typo in the test would otherwise read as the expected refusal.
function M.raises(kind, body, ...)
    local ok, err = pcall(body, ...)
    if ok then
        fail("expected a " .. kind .. " error, the call succeeded")
    end
    if type(err) ~= "table" or err.kind == nil then
        fail("expected a " .. kind .. " error, got: " .. tostring(err))
    end
    if err.kind ~= kind then
        fail(string.format("expected a %s error, got a %s error: %s",
                           kind, err.kind, err.message))
    end
    return err
end

-- ------------------------------------------------------------------ running

local function describe(err)
    if type(err) == "table" and err.assertion then return err.assertion end
    if type(err) == "table" and err.message then
        return "unexpected " .. tostring(err.kind) .. " error: " .. err.message
    end
    return tostring(err)
end

-- Runs everything registered so far. `filter` narrows to the groups whose name
-- contains it.
function M.run(filter)
    for _, group in ipairs(M.groups) do
        if not filter or group.name:find(filter, 1, true) then
            io.write(group.name, "\n")
            for _, case in ipairs(group.cases) do
                if case.skip then
                    M.skipped = M.skipped + 1
                    io.write("  - ", case.name, " (skipped: ", case.skip, ")\n")
                else
                    local ok, err = pcall(case.body)
                    if ok then
                        M.passed = M.passed + 1
                    else
                        M.failed = M.failed + 1
                        local where = group.name .. " / " .. case.name
                        M.failures[#M.failures + 1] = where .. "\n      " .. describe(err)
                        io.write("  x ", case.name, "\n      ", describe(err), "\n")
                    end
                end
            end
        end
    end
end

-- Prints the tally and answers the process exit code.
function M.report()
    io.write("\n")
    if #M.failures > 0 then
        io.write("failures:\n")
        for _, failure in ipairs(M.failures) do io.write("  ", failure, "\n") end
        io.write("\n")
    end
    io.write(string.format("%d passed, %d failed, %d skipped\n",
                           M.passed, M.failed, M.skipped))
    return M.failed == 0 and 0 or 1
end

return M
