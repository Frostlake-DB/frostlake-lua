-- Rendering Lua values as SQL literals, and reading the engine's cells back.
--
-- ------------------------------------------------------------------- writing
--
-- The HTTP protocol has no server-side binding, so a bound parameter is inlined
-- as a literal here. Lua's types say enough to do that without being told:
--
--     nil, frostlake.null  ->  NULL
--     true / false         ->  TRUE / FALSE
--     42, 3.5              ->  a numeric literal
--     "text"               ->  a quoted string literal
--
-- A Lua string is bound as a *string literal*, always. The engine coerces
-- freely in expressions, so `WHERE id = '42'` finds the row with id 42; but the
-- reverse -- rendering "007" as a bare number -- would store 7 in a VARCHAR and
-- there would be no way to ask for the zeros back. Where SQL syntax needs a
-- real numeric literal and the value arrives as text, `value.number` says so:
--
--     conn:execute("SELECT * FROM t LIMIT ?", { frostlake.number("5") })
--
-- The other wrappers cover the types Lua has no value for -- dates, timestamps,
-- binary, VARIANT -- and `value.raw` covers the escape hatch of splicing SQL
-- text in verbatim. Each is a one-field table carrying its own intent, so a
-- bound parameter says what it is at the point it is written rather than in a
-- parallel list of type names somewhere else. The parallel list exists too, as
-- the `types` option, because the other Frostlake drivers spell it that way.
--
-- ------------------------------------------------------------------- reading
--
-- Almost nothing happens on the way back, and that is deliberate.
--
-- Lua's only number is a double. Frostlake's NUMBER(38,0) holds values a double
-- cannot: convert `12345678901234567890123456789012345678` and twenty of its
-- digits come back invented. Lua also has no date, no timestamp and no decimal
-- type, so a temporal cell has nowhere to go that is not lossier than the text
-- the engine sent. So a cell is the engine's own text, exactly, and the
-- converters below are offered rather than applied: `value.tonumber`,
-- `value.parsetimestamp` and `value.hextobinary` are there for callers who want
-- another form and know what it costs.

local errors = require("frostlake.errors")
local compat = require("frostlake.compat")

local M = {}

-- The type names the `types` option accepts, mirroring the other drivers.
local TYPES = {
    string = true, number = true, boolean = true, null = true,
    binary = true, raw = true, date = true, time = true, timestamp = true,
    timestampntz = true, timestamptz = true, variant = true,
}

local TYPE_LIST = "binary, boolean, date, null, number, raw, string, time, "
    .. "timestamp, timestampntz, timestamptz, variant"

function M.types()
    return TYPE_LIST
end

-- The stand-in for SQL NULL, in both directions.
--
-- Not `nil`: a `nil` in the middle of a Lua list ends it, so a row whose second
-- of four columns is NULL would come back as a one-element row, and a `{1, nil,
-- 3}` argument list would bind one parameter instead of three. A sentinel is
-- the only representation that survives both.
local NULL = setmetatable({}, {
    __tostring = function() return "NULL" end,
    __name = "frostlake.null",
})
M.null = NULL

-- ------------------------------------------------------------ typed wrappers

local WRAPPER = {}
WRAPPER.__index = WRAPPER
WRAPPER.__name = "frostlake.value"
WRAPPER.__tostring = function(self)
    return "frostlake." .. self.type .. "(" .. tostring(self.value) .. ")"
end

local function wrap(kind)
    return function(value)
        return setmetatable({ type = kind, value = value }, WRAPPER)
    end
end

M.number = wrap("number")
M.binary = wrap("binary")
M.raw = wrap("raw")
M.date = wrap("date")
M.time = wrap("time")
M.timestamp = wrap("timestamp")
M.timestampntz = wrap("timestampntz")
M.timestamptz = wrap("timestamptz")
M.variant = wrap("variant")
M.text = wrap("string")

function M.iswrapped(value)
    return type(value) == "table" and getmetatable(value) == WRAPPER
end

-- ---------------------------------------------------------------- rendering

-- Mirrors the engine's canonical literal encoder: backslashes doubled (a
-- backslash always escapes), quotes doubled.
local function stringliteral(text)
    return "'" .. text:gsub("\\", "\\\\"):gsub("'", "''") .. "'"
end

M.stringliteral = stringliteral

-- Renders a Lua number as a literal that reads back as the same number.
--
-- `tostring` is not enough: Lua prints a float with `%.14g`, so 1/3 would go to
-- the engine three digits short of what this process holds. The shortest form
-- that round-trips is used instead -- 14 digits when they suffice, 17 when they
-- do not -- so `WHERE x = ?` finds the row that `INSERT` put there.
local function numberliteral(n)
    -- Lua spells these nan and inf, which the parser reads as identifiers; cast
    -- from text they are the engine's own spellings (the shorter 'Inf' is refused).
    if n ~= n then return "'NaN'::FLOAT" end
    if n == math.huge then return "'Infinity'::FLOAT" end
    if n == -math.huge then return "'-Infinity'::FLOAT" end
    -- A 5.3+ integer prints exactly at any width; only a float has to be
    -- squeezed through %g, and a float past 2^53 has no exact digits anyway.
    if math.type and math.type(n) == "integer" then
        return string.format("%d", n)
    end
    if compat.isinteger(n) and n >= -9007199254740992 and n <= 9007199254740992 then
        return string.format("%d", n)
    end
    local short = string.format("%.14g", n)
    if tonumber(short) == n then return short end
    return string.format("%.17g", n)
end

M.numberliteral = numberliteral

-- A negative numeral spliced BARE into a statement goes in parentheses: straight
-- after a minus it would otherwise open a `--` comment, so `SELECT 3-?` bound -5
-- became `SELECT 3--5`, which the engine reads as `SELECT 3`. Only the bare
-- numeric literal needs this; the same digits inside a string literal
-- (`frostlake.text(-7)` is '-7') or behind a cast stay as they are.
local function bare(text)
    if text:sub(1, 1) == "-" then return "(" .. text .. ")" end
    return text
end

-- Numeric text a `number` bind may carry. Deliberately not `tonumber`: that
-- accepts "0x1f", "1e", " 3 " and "inf", and each of those means something
-- different to the engine than it does to Lua.
local function numbertext(value)
    local text = tostring(value):match("^%s*(.-)%s*$")
    -- Assembled rather than written as one pattern, because Lua patterns have
    -- no alternation and the three shapes -- integer, fixed point, exponent --
    -- do not collapse into one class.
    if text:match("^[-+]?%d+$")
        or text:match("^[-+]?%d*%.%d+$")
        or text:match("^[-+]?%d+%.%d*$")
        or text:match("^[-+]?%d*%.?%d+[eE][-+]?%d+$") then
        return text
    end
    errors.usage(string.format("a number bind needs a number, got %q", tostring(value)))
end

-- Puts the colon back into a `+0100`-style offset, leaving `+01:00` and `Z`
-- alone. The engine prints an offset without the colon but parses only with
-- one, so a value read straight out of a result is repaired on the way back in
-- rather than refused.
local function colonizeoffset(text)
    local head, hours, minutes = text:match("^(.*[-+])(%d%d)(%d%d)$")
    if head then return head .. hours .. ":" .. minutes end
    return text
end

M.colonizeoffset = colonizeoffset

-- The inverse of `hextobinary`: a Lua byte string as the upper-case hex the
-- engine expects.
function M.binarytohex(bytes)
    return (bytes:gsub(".", function(c)
        return string.format("%02X", string.byte(c))
    end))
end

-- Decodes the hex text the engine renders BINARY as into a Lua byte string.
function M.hextobinary(text)
    if not text:match("^%x*$") or #text % 2 ~= 0 then
        errors.usage(string.format("%q is not an even run of hex digits", text))
    end
    return (text:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function astext(value, what)
    if type(value) == "string" then return value end
    if type(value) == "number" then return numberliteral(value) end
    errors.usage(string.format("a %s bind needs text, got %s", what, type(value)))
end

-- Renders one bound value as the SQL literal that stands in for it.
--
-- `kind` forces a type; without one the Lua type decides. `null` is the
-- connection's stand-in for SQL NULL: a value equal to it becomes NULL whatever
-- type was asked for, which is what makes the same value mean NULL in both
-- directions.
function M.literal(value, kind, null)
    if M.iswrapped(value) then
        -- A wrapper says what it is; an explicit `types` entry alongside it
        -- would be a second, possibly different answer to the same question.
        if kind and kind ~= value.type then
            errors.usage(string.format(
                "the value is a frostlake.%s but the types option says %q",
                value.type, kind))
        end
        kind, value = value.type, value.value
    end

    if value == nil or value == NULL or (null ~= nil and value == null) then
        return "NULL"
    end

    if kind == nil then
        local luatype = type(value)
        if luatype == "string" then kind = "string"
        elseif luatype == "number" then return bare(numberliteral(value))
        elseif luatype == "boolean" then return value and "TRUE" or "FALSE"
        else
            errors.usage("cannot bind a " .. luatype
                .. "; wrap it with frostlake.raw, frostlake.variant or one of the"
                .. " other value constructors, or convert it to a string first")
        end
    elseif not TYPES[kind] then
        errors.usage(string.format("unknown bind type %q (expected %s)",
                                   tostring(kind), TYPE_LIST))
    end

    if kind == "null" then return "NULL" end
    if kind == "string" then
        if type(value) == "boolean" then return stringliteral(value and "true" or "false") end
        return stringliteral(type(value) == "number" and numberliteral(value) or value)
    end
    if kind == "number" then
        if type(value) == "number" then return bare(numberliteral(value)) end
        return bare(numbertext(value))
    end
    if kind == "boolean" then
        if type(value) == "boolean" then return value and "TRUE" or "FALSE" end
        local folded = tostring(value):lower()
        if folded == "true" or folded == "1" then return "TRUE" end
        if folded == "false" or folded == "0" then return "FALSE" end
        errors.usage(string.format("a boolean bind needs true or false, got %q",
                                   tostring(value)))
    end
    if kind == "binary" then
        if type(value) ~= "string" then
            errors.usage("a binary bind needs a byte string, got " .. type(value))
        end
        return "X'" .. M.binarytohex(value) .. "'"
    end
    if kind == "raw" then
        -- Inserted verbatim. The caller owns whatever it says -- this is the
        -- one bind that can carry SQL syntax, and so the one that can carry an
        -- injection. It exists because the alternative, callers splicing text
        -- into the statement themselves, is strictly worse.
        return astext(value, "raw")
    end
    if kind == "date" then return stringliteral(astext(value, "date")) .. "::DATE" end
    if kind == "time" then return stringliteral(astext(value, "time")) .. "::TIME" end
    if kind == "timestamp" or kind == "timestampntz" then
        return stringliteral(astext(value, "timestamp")) .. "::TIMESTAMP_NTZ"
    end
    if kind == "timestamptz" then
        return stringliteral(colonizeoffset(astext(value, "timestamptz"))) .. "::TIMESTAMP_TZ"
    end
    -- variant
    return "PARSE_JSON(" .. stringliteral(astext(value, "variant")) .. ")"
end

-- ---------------------------------------------------------------- type names

-- Strips any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike.
function M.basetype(datatype)
    local name = tostring(datatype or ""):upper():match("^%s*(.-)%s*$")
    local open = name:find("(", 1, true)
    if not open then return name end
    return name:sub(1, open - 1):match("^%s*(.-)%s*$")
end

local TEMPORAL = {
    DATE = "date", TIME = "time",
    TIMESTAMP = "naive", TIMESTAMP_NTZ = "naive", DATETIME = "naive",
    TIMESTAMP_LTZ = "zoned", TIMESTAMP_TZ = "zoned",
}

-- Which temporal shape a declared type names: "date", "time", "naive", "zoned",
-- or nil for anything that is not temporal.
function M.istemporal(datatype)
    return TEMPORAL[M.basetype(datatype)]
end

function M.isbinary(datatype)
    local name = M.basetype(datatype)
    return name == "BINARY" or name == "VARBINARY"
end

-- --------------------------------------------------------------- conversions

-- A cell as a Lua number, or nil when it does not read as one. Offered rather
-- than applied -- see the note at the top about what a double cannot hold.
function M.tonumber(cell)
    if type(cell) == "number" then return cell end
    if type(cell) ~= "string" then return nil end
    if not cell:match("^%s*[-+]?%d*%.?%d+[eE]?[-+]?%d*%s*$") then return nil end
    return tonumber(cell)
end

-- A cell as a boolean: the engine writes these as "true"/"false", and a NUMBER
-- holding 1 or 0 is deliberately NOT read as one -- that would make
-- `SELECT COUNT(*)` of one row indistinguishable from TRUE.
function M.toboolean(cell)
    if type(cell) == "boolean" then return cell end
    if cell == "true" then return true end
    if cell == "false" then return false end
    return nil
end

-- Reads a temporal cell into its parts: `year`, `month`, `day`, `hour`,
-- `minute`, `second`, `nanos` for the fraction the second does not carry, and
-- `offset` in seconds east of UTC (0 for a value that named none).
--
-- The parts rather than an instant, because `os.time` works in local time and
-- cannot hold a sub-second fraction: converting through it would move a
-- TIMESTAMP_NTZ by the machine's own zone and round its nanoseconds away. A
-- caller who wants an epoch can build one from these and say which zone they
-- meant.
function M.parsetimestamp(text)
    text = tostring(text):match("^%s*(.-)%s*$")
    local year, month, day, rest = text:match("^(%d%d%d%d+)%-(%d%d)%-(%d%d)(.*)$")
    local hour, minute, second, fraction, zone
    if year then
        if rest ~= "" then
            hour, minute, second, fraction, zone =
                rest:match("^[ T](%d%d?):(%d%d):(%d%d)%.?(%d*)%s*(.*)$")
            if not hour then
                -- A date followed by something that is not a time of day.
                zone = rest:match("^%s*(.*)$")
                if zone ~= "" and not zone:match("^Z$") and not zone:match("^[-+]%d%d:?%d%d$") then
                    errors.usage(string.format("cannot read %q as a date or time", text))
                end
            end
        end
    else
        -- A bare TIME, which carries no date at all.
        hour, minute, second, fraction = text:match("^(%d%d?):(%d%d):(%d%d)%.?(%d*)$")
        if not hour then
            errors.usage(string.format("cannot read %q as a date or time", text))
        end
        year, month, day = 0, 0, 0
    end

    local offset = 0
    if zone and zone ~= "" and zone ~= "Z" then
        local sign, hours, minutes = zone:match("^([-+])(%d%d):?(%d%d)$")
        if not sign then
            errors.usage(string.format("cannot read %q as a time zone offset", zone))
        end
        offset = tonumber(hours) * 3600 + tonumber(minutes) * 60
        if sign == "-" then offset = -offset end
    end

    local nanos = 0
    if fraction and fraction ~= "" then
        nanos = tonumber((fraction .. "000000000"):sub(1, 9))
    end

    return {
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour) or 0, minute = tonumber(minute) or 0,
        second = tonumber(second) or 0, nanos = nanos, offset = offset,
    }
end

-- Renders parts back into the text a TIMESTAMP literal is written as. `offset`
-- is seconds east of UTC; a non-zero one produces the `+HH:MM` form the engine
-- parses.
function M.formattimestamp(parts)
    local text = string.format("%04d-%02d-%02d %02d:%02d:%02d",
        parts.year or 0, parts.month or 1, parts.day or 1,
        parts.hour or 0, parts.minute or 0, parts.second or 0)
    local nanos = parts.nanos or 0
    if nanos ~= 0 then
        text = text .. (string.format(".%09d", nanos):gsub("0+$", ""))
    end
    local offset = parts.offset or 0
    if offset ~= 0 then
        local sign = offset < 0 and "-" or "+"
        local total = math.abs(offset)
        text = text .. string.format(" %s%02d:%02d", sign,
            compat.idiv(total, 3600), compat.idiv(total % 3600, 60))
    end
    return text
end

return M
