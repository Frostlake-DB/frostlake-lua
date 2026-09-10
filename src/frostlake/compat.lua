-- The handful of places where Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT differ.
--
-- The driver runs on all of them, and it does so by naming the differences here
-- once rather than testing for them at every call site. Nothing in this module
-- is Frostlake-specific.

local M = {}

-- Whether a Lua number holds an exact integer value, however it is spelled.
-- 5.3 split numbers into integers and floats and `tostring` shows the seam --
-- `tostring(2/1)` is "2.0" there and "2" on 5.1 -- so anything that has to be
-- WRITTEN as an integer asks this first and formats with `%d`.
function M.isinteger(n)
    return type(n) == "number" and n == n
        and n ~= math.huge and n ~= -math.huge
        and math.floor(n) == n
end

-- 5.3 added `//`; using it would make this file a syntax error on 5.1, so the
-- floor is spelled out.
function M.idiv(a, b)
    return math.floor(a / b)
end

-- `os.time` counts whole seconds, which is too coarse for a millisecond
-- deadline. A real clock comes from the transport (LuaSocket's `gettime`), and
-- this is the fallback for a transport that offers none: `os.clock` measures
-- CPU time on some builds and wall time on others, so it is used only to keep
-- deadlines moving, never to report a time to anyone.
function M.monotonic()
    return os.clock()
end

-- Lua 5.1 has no `%g`-safe integer formatting for very large values and no
-- `math.tointeger`; this is the portable "is this text an integer" test the
-- driver needs for update counts. Deliberately strict, and deliberately not
-- `tonumber`: `tonumber` accepts "0x10", " 12 " and "1e3", none of which is how
-- JSON spells an integer.
function M.parseinteger(text)
    if type(text) ~= "string" then return nil end
    if not text:match("^%-?%d+$") then return nil end
    -- No leading zeros, the way JSON writes a number -- "010" is a typo, not
    -- eight and not ten, and guessing which would be worse than refusing.
    if text:match("^%-?0%d") then return nil end
    return tonumber(text)
end

return M
