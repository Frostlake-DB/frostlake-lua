local t = require("harness")
local json = require("frostlake.json")

t.describe("json: parsing")

t.it("reads the shape of a Frostlake response", function()
    local node = json.parse('{"success":true,"sessionId":"S1","resultSets":[]}')
    t.eq(json.kind(node), "object")
    t.eq(json.boolean(json.at(node, "success")), true)
    t.eq(json.textat(node, "sessionId"), "S1")
    t.eq(json.kind(json.at(node, "resultSets")), "array")
    t.eq(json.count(json.at(node, "resultSets")), 0)
end)

t.it("tells an absent field from a null one", function()
    local node = json.parse('{"a":null}')
    t.eq(json.kind(json.at(node, "a")), "null", "a null field is present")
    t.eq(json.kind(json.at(node, "b")), "missing", "an absent field is not")
    t.ok(json.exists(node, "a"))
    t.ok(not json.exists(node, "b"))
end)

t.it("tells an empty array from an empty object", function()
    t.eq(json.kind(json.parse("[]")), "array")
    t.eq(json.kind(json.parse("{}")), "object")
end)

t.it("keeps a number's digits exactly as they were written", function()
    -- The point of the whole typed-node design: a double cannot hold this, and
    -- a driver that converted on the way in would hand back invented digits.
    local big = "12345678901234567890123456789012345678"
    local node = json.parse('{"n":' .. big .. "}")
    t.eq(json.textat(node, "n"), big)
end)

t.it("keeps a decimal's trailing zeros", function()
    local node = json.parse('{"n":2.500}')
    t.eq(json.textat(node, "n"), "2.500")
    t.eq(json.number(json.at(node, "n")), 2.5)
end)

t.it("reads the number forms JSON allows", function()
    for _, text in ipairs({ "0", "-0", "12", "-12", "1.5", "-1.5", "1e3",
                            "1E3", "1e+3", "1e-3", "1.5e10", "0.5" }) do
        local node = json.parse('{"n":' .. text .. "}")
        t.eq(json.textat(node, "n"), text, "for " .. text)
    end
end)

t.it("refuses the number forms it does not", function()
    for _, text in ipairs({ "01", "+1", ".5", "0x10", "1.", "--1" }) do
        t.raises("usage", json.parse, '{"n":' .. text .. "}")
    end
end)

t.it("decodes escapes, including surrogate pairs", function()
    local node = json.parse('{"s":"a\\"b\\\\c\\n\\t\\u00e9\\ud83d\\ude00"}')
    t.eq(json.textat(node, "s"), 'a"b\\c\n\t\195\169\240\159\152\128')
end)

t.it("replaces an unpaired surrogate rather than refusing the response", function()
    local node = json.parse('{"s":"x\\ud83dy"}')
    t.eq(json.textat(node, "s"), "x\239\191\189y")
end)

t.it("reads a string with no escapes at all", function()
    t.eq(json.textat(json.parse('{"s":"plain text here"}'), "s"), "plain text here")
end)

t.it("keeps the last value of a repeated key, at its first position", function()
    local node = json.parse('{"a":1,"b":2,"a":3}')
    t.eq(json.textat(node, "a"), "3")
    t.same(node.order, { "a", "b" })
end)

t.it("skips a UTF-8 BOM", function()
    t.eq(json.kind(json.parse("\239\187\191{}")), "object")
end)

t.it("names the offset when the text is not JSON", function()
    local err = t.raises("usage", json.parse, '{"a": }')
    t.contains(err.message, "offset")
end)

t.it("refuses trailing content", function()
    t.raises("usage", json.parse, '{"a":1} {"b":2}')
end)

t.it("refuses a document nested past its depth limit", function()
    t.raises("usage", json.parse, string.rep("[", 500) .. string.rep("]", 500))
end)

t.it("accepts whitespace anywhere it is allowed", function()
    local node = json.parse('  {\n "a" : [ 1 , 2 ] ,\t"b" : null\r\n}  ')
    t.eq(json.count(json.at(node, "a")), 2)
end)

t.describe("json: accessors")

t.it("answers safely for the wrong kind", function()
    local node = json.parse('{"a":1}')
    t.eq(json.at(json.at(node, "a"), "b"), nil, "a field of a number")
    t.same(json.items(json.at(node, "a")), {}, "the elements of a number")
    t.eq(json.count(json.at(node, "a")), 0)
    t.eq(json.text(json.at(node, "zz"), "fallback"), "fallback")
    t.eq(json.boolean(json.at(node, "zz")), nil)
    t.eq(json.number(json.at(node, "zz")), nil)
end)

t.it("renders booleans as text", function()
    local node = json.parse('{"y":true,"n":false}')
    t.eq(json.textat(node, "y"), "true")
    t.eq(json.textat(node, "n"), "false")
end)

t.it("converts a whole tree to plain Lua values", function()
    local node = json.parse('{"a":[1,"x",null],"b":{"c":true}}')
    local plain = json.tolua(node, "NULL")
    t.same(plain, { a = { 1, "x", "NULL" }, b = { c = true } })
end)

t.describe("json: encoding")

t.it("escapes what JSON forbids raw and leaves UTF-8 alone", function()
    t.eq(json.encodestring('a"b'), '"a\\"b"')
    t.eq(json.encodestring("a\\b"), '"a\\\\b"')
    t.eq(json.encodestring("a\nb"), '"a\\nb"')
    t.eq(json.encodestring("a\tb\rc"), '"a\\tb\\rc"')
    t.eq(json.encodestring("caf\195\169"), '"caf\195\169"', "UTF-8 passes through")
end)

t.it("escapes a NUL byte", function()
    -- A statement carrying a NUL would otherwise reach the wire unescaped, and
    -- an unescaped NUL is not JSON.
    t.eq(json.encodestring("a\0b"), '"a\\u0000b"')
end)

t.it("escapes the other control characters", function()
    t.eq(json.encodestring("\1\2\31"), '"\\u0001\\u0002\\u001f"')
    t.eq(json.encodestring("\127"), '"\\u007f"')
end)

t.it("renders a tree back into compact JSON, digits and key order intact", function()
    local text = '{"a":[1,null,"x\\ny"],"b":{"c":true,"d":false},"n":2.500,"e":{},"f":[]}'
    t.eq(json.stringify(json.parse(text)), text)
    t.eq(json.stringify(json.parse("null")), "null")
end)

t.it("round-trips whatever it encodes", function()
    for _, text in ipairs({ "", "plain", 'quo"te', "back\\slash", "line\nbreak",
                            "\0\1\31\127", "caf\195\169 \240\159\152\128" }) do
        local doc = "{\"s\":" .. json.encodestring(text) .. "}"
        t.eq(json.textat(json.parse(doc), "s"), text, "for " .. t.show(text))
    end
end)
