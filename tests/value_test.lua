local t = require("harness")
local value = require("frostlake.value")

local function lit(v, kind) return value.literal(v, kind) end

t.describe("value: literals from Lua types")

t.it("renders a string as a quoted literal", function()
    t.eq(lit("Ada"), "'Ada'")
    t.eq(lit(""), "''")
end)

t.it("doubles quotes and backslashes the way the engine reads them", function()
    t.eq(lit("O'Hara"), "'O''Hara'")
    t.eq(lit("a\\b"), "'a\\\\b'")
    t.eq(lit("it's a\\b"), "'it''s a\\\\b'")
end)

t.it("renders a number as a bare numeric literal", function()
    t.eq(lit(42), "42")
    -- A negative in parentheses: bare after a minus it would open a -- comment.
    t.eq(lit(-7), "(-7)")
    t.eq(lit(-1.5), "(-1.5)")
    -- A 5.3+ integer past 2^53 keeps its digits; a float there has none to keep.
    if math.type then
        t.eq(lit(9007199254740993), "9007199254740993")
        t.eq(lit(math.maxinteger), tostring(math.maxinteger))
    end
    t.eq(lit(0), "0")
end)

t.it("renders an integer-valued float without a decimal point", function()
    -- `tostring(2.0)` is "2.0" on 5.3+ and "2" on 5.1; neither is wrong SQL, but
    -- one spelling everywhere is what makes the tests portable.
    t.eq(lit(2.0), "2")
end)

t.it("renders a float so it reads back as the same number", function()
    -- Lua prints a float with %.14g, which would send a third of the digits the
    -- process actually holds.
    local third = 1 / 3
    t.eq(tonumber(lit(third)), third)
    t.eq(tonumber(lit(0.1)), 0.1)
    t.eq(tonumber(lit(1e300)), 1e300)
    t.eq(tonumber(lit(2 ^ 53 + 2)), 2 ^ 53 + 2)
end)

t.it("renders booleans", function()
    t.eq(lit(true), "TRUE")
    t.eq(lit(false), "FALSE")
end)

t.it("renders nil and the null sentinel as NULL", function()
    t.eq(lit(nil), "NULL")
    t.eq(lit(value.null), "NULL")
end)

t.it("casts NaN and the infinities from text, the engine's own spellings", function()
    t.eq(lit(0 / 0), "'NaN'::FLOAT")
    t.eq(lit(math.huge), "'Infinity'::FLOAT")
    t.eq(lit(-math.huge), "'-Infinity'::FLOAT")
end)

t.it("refuses a value it has no literal for, and says what to do", function()
    local err = t.raises("usage", lit, function() end)
    t.contains(err.message, "frostlake.raw")
end)

t.describe("value: typed wrappers")

t.it("renders numeric text as a number", function()
    t.eq(lit(value.number("5")), "5")
    -- Bare and negative, so parenthesized the same way a Lua number is.
    t.eq(lit(value.number("-1.5e3")), "(-1.5e3)")
    t.eq(lit(value.number(" 42 ")), "42", "surrounding space is trimmed")
end)

t.it("refuses text that is not a number", function()
    t.raises("usage", lit, value.number("five"))
    t.raises("usage", lit, value.number("0x10"))
    t.raises("usage", lit, value.number("inf"))
end)

t.it("splices raw SQL verbatim", function()
    t.eq(lit(value.raw("CURRENT_DATE()")), "CURRENT_DATE()")
end)

t.it("renders binary as the engine writes it", function()
    t.eq(lit(value.binary("\1\255z")), "X'01FF7A'")
    t.eq(lit(value.binary("")), "X''")
end)

t.it("renders the temporal types with their casts", function()
    t.eq(lit(value.date("2024-01-15")), "'2024-01-15'::DATE")
    t.eq(lit(value.time("10:30:00")), "'10:30:00'::TIME")
    t.eq(lit(value.timestamp("2024-01-15 10:30:00")), "'2024-01-15 10:30:00'::TIMESTAMP_NTZ")
    t.eq(lit(value.timestampntz("2024-01-15 10:30:00")), "'2024-01-15 10:30:00'::TIMESTAMP_NTZ")
end)

t.it("repairs an offset the engine printed but cannot parse", function()
    -- The engine prints +0100 and parses only +01:00, so a value read straight
    -- back out of a result works rather than being refused.
    t.eq(lit(value.timestamptz("2024-01-15 10:30:00 +0100")),
         "'2024-01-15 10:30:00 +01:00'::TIMESTAMP_TZ")
    t.eq(lit(value.timestamptz("2024-01-15 10:30:00 +01:00")),
         "'2024-01-15 10:30:00 +01:00'::TIMESTAMP_TZ")
end)

t.it("wraps a variant in PARSE_JSON", function()
    t.eq(lit(value.variant('{"a":1}')), [[PARSE_JSON('{"a":1}')]])
end)

t.it("forces a string literal with text()", function()
    t.eq(lit(value.text(42)), "'42'")
    -- The parentheses a bare negative gets are SQL syntax, not part of the
    -- number: inside a string literal the digits stay as they are.
    t.eq(lit(value.text(-7)), "'-7'")
    t.eq(lit(-7, "string"), "'-7'")
    t.eq(lit(value.raw(-7)), "-7", "raw is verbatim")
end)

t.it("lets the null sentinel through any wrapper", function()
    t.eq(lit(value.number(value.null)), "NULL")
    t.eq(lit(value.date(nil)), "NULL")
end)

t.it("refuses a wrapper contradicted by an explicit type", function()
    local err = t.raises("usage", value.literal, value.number("5"), "string")
    t.contains(err.message, "types option")
end)

t.describe("value: explicit type names")

t.it("renders each named type", function()
    t.eq(lit("5", "number"), "5")
    t.eq(lit(5, "string"), "'5'")
    t.eq(lit("true", "boolean"), "TRUE")
    t.eq(lit("1", "boolean"), "TRUE")
    t.eq(lit("0", "boolean"), "FALSE")
    t.eq(lit("anything", "null"), "NULL")
    t.eq(lit("2024-01-15", "date"), "'2024-01-15'::DATE")
end)

t.it("refuses an unknown type name and lists the real ones", function()
    local err = t.raises("usage", lit, "x", "flooat")
    t.contains(err.message, "number")
end)

t.it("refuses a boolean it cannot read", function()
    t.raises("usage", lit, "yes please", "boolean")
end)

t.describe("value: type names")

t.it("strips a precision suffix", function()
    t.eq(value.basetype("NUMBER(38,0)"), "NUMBER")
    t.eq(value.basetype("varchar(16777216)"), "VARCHAR")
    t.eq(value.basetype("  TIMESTAMP_NTZ(9) "), "TIMESTAMP_NTZ")
    t.eq(value.basetype("BOOLEAN"), "BOOLEAN")
end)

t.it("names the temporal shapes", function()
    t.eq(value.istemporal("DATE"), "date")
    t.eq(value.istemporal("TIME(9)"), "time")
    t.eq(value.istemporal("TIMESTAMP_NTZ(9)"), "naive")
    t.eq(value.istemporal("TIMESTAMP_TZ"), "zoned")
    t.eq(value.istemporal("VARCHAR"), nil)
end)

t.it("names the binary types", function()
    t.ok(value.isbinary("BINARY(8)"))
    t.ok(value.isbinary("VARBINARY"))
    t.ok(not value.isbinary("VARCHAR"))
end)

t.describe("value: conversions")

t.it("round-trips binary through hex", function()
    local bytes = "\0\1\127\128\255"
    t.eq(value.hextobinary(value.binarytohex(bytes)), bytes)
    t.eq(value.binarytohex(bytes), "00017F80FF")
end)

t.it("refuses hex that is not an even run of digits", function()
    t.raises("usage", value.hextobinary, "ABC")
    t.raises("usage", value.hextobinary, "ZZ")
end)

t.it("reads a timestamp into its parts", function()
    local parts = value.parsetimestamp("2024-01-15 10:30:45.123456789")
    t.eq(parts.year, 2024)
    t.eq(parts.month, 1)
    t.eq(parts.day, 15)
    t.eq(parts.hour, 10)
    t.eq(parts.minute, 30)
    t.eq(parts.second, 45)
    t.eq(parts.nanos, 123456789)
    t.eq(parts.offset, 0)
end)

t.it("reads the ISO T separator and an offset in both spellings", function()
    t.eq(value.parsetimestamp("2024-01-15T10:30:45Z").offset, 0)
    t.eq(value.parsetimestamp("2024-01-15 10:30:45 +01:00").offset, 3600)
    t.eq(value.parsetimestamp("2024-01-15 10:30:45 -0530").offset, -19800)
end)

t.it("reads a bare date and a bare time", function()
    local date = value.parsetimestamp("2024-01-15")
    t.eq(date.day, 15)
    t.eq(date.hour, 0)
    local time = value.parsetimestamp("10:30:45.5")
    t.eq(time.hour, 10)
    t.eq(time.nanos, 500000000)
end)

t.it("refuses text that is not a date or a time", function()
    t.raises("usage", value.parsetimestamp, "not a date")
end)

t.it("renders parts back into a literal's text", function()
    t.eq(value.formattimestamp({ year = 2024, month = 1, day = 15,
                                 hour = 10, minute = 30, second = 45 }),
         "2024-01-15 10:30:45")
    t.eq(value.formattimestamp({ year = 2024, month = 1, day = 15, nanos = 500000000 }),
         "2024-01-15 00:00:00.5")
    t.eq(value.formattimestamp({ year = 2024, month = 1, day = 15, offset = 3600 }),
         "2024-01-15 00:00:00 +01:00")
end)

t.it("round-trips a timestamp through its parts", function()
    local text = "2024-06-30 23:59:59.25"
    t.eq(value.formattimestamp(value.parsetimestamp(text)), text)
end)

t.it("reads a cell as a number only when it is one", function()
    t.eq(value.tonumber("42"), 42)
    t.eq(value.tonumber("-1.5"), -1.5)
    t.eq(value.tonumber("abc"), nil)
    t.eq(value.tonumber("0x10"), nil)
end)

t.it("reads a cell as a boolean only when the engine wrote one", function()
    t.eq(value.toboolean("true"), true)
    t.eq(value.toboolean("false"), false)
    -- A NUMBER holding 1 is deliberately not TRUE: that would make
    -- `SELECT COUNT(*)` of one row indistinguishable from a boolean.
    t.eq(value.toboolean("1"), nil)
    t.eq(value.toboolean("TRUE"), nil)
end)
