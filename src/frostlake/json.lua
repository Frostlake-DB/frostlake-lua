-- JSON, parsed into a typed node rather than into plain Lua values.
--
-- A Lua table cannot say what a JSON document says. `{}` is both the empty
-- object and the empty array; a missing field and a field whose value is `null`
-- both read back as `nil`; and `nil` in the middle of an array ends it, because
-- `#` stops there. A driver that decoded into plain tables would lose the
-- difference between "the engine sent no `sessionId`" and "the engine sent
-- `sessionId: null`" -- and those mean opposite things.
--
-- So a parsed document is a tree of nodes, each carrying its own kind:
--
--     {kind = "object",  fields = {name = node}, order = {names in order}}
--     {kind = "array",   items  = {node, ...},   n = count}
--     {kind = "string",  text   = "decoded"}
--     {kind = "number",  text   = "1.25e3"}     -- the SOURCE text, verbatim
--     {kind = "boolean", value  = true}
--     {kind = "null"}
--
-- **Numbers keep their source text.** A Lua number is a double, and Frostlake's
-- NUMBER(38,0) holds values a double cannot: read
-- `12345678901234567890123456789012345678` through `tonumber` and it comes back
-- with the last twenty digits invented. The engine wrote the digits it meant,
-- so the digits it wrote are what a cell hands back. `json.number` is there for
-- callers who want the arithmetic form and are willing to pay for it.
--
-- The same parser reads the engine's responses and the testkit's suite files,
-- so the two cannot disagree about what a document says.

local errors = require("frostlake.errors")

local M = {}

-- Deep enough for any Frostlake response, shallow enough that a hostile or
-- corrupt document cannot exhaust the C stack before it is rejected.
local MAX_DEPTH = 200

local NULL = { kind = "null" }
local TRUE = { kind = "boolean", value = true }
local FALSE = { kind = "boolean", value = false }

M.null = NULL

-- ---------------------------------------------------------------- accessors

-- The kind of a node: "object", "array", "string", "number", "boolean" or
-- "null". A node that is not there at all -- an absent field -- answers
-- "missing", which is how a caller tells `{}` from `{"a": null}` from
-- `{"a": 1}`.
function M.kind(node)
    if type(node) ~= "table" or node.kind == nil then return "missing" end
    return node.kind
end

-- The value of an object's field, or nil when the node is not an object or has
-- no such field.
function M.at(node, key)
    if type(node) ~= "table" or node.kind ~= "object" then return nil end
    return node.fields[key]
end

-- Whether an object carries a field, however that field is spelled -- a field
-- explicitly set to null exists.
function M.exists(node, key)
    return M.at(node, key) ~= nil
end

-- An array's elements as a Lua list of nodes. Anything that is not an array
-- answers the empty list, so a caller can iterate a field that may be missing
-- without checking first.
function M.items(node)
    if type(node) ~= "table" or node.kind ~= "array" then return {} end
    return node.items
end

-- The number of elements in an array. Kept alongside `items` because a JSON
-- array may hold nulls, and `#` on a list of node tables is only reliable
-- because every element -- null included -- is a table.
function M.count(node)
    if type(node) ~= "table" or node.kind ~= "array" then return 0 end
    return node.n
end

-- A scalar as text, exactly as the document spelled it: a string's decoded
-- characters, a number's source digits, "true"/"false", and `default` for null
-- or for anything that is not a scalar.
function M.text(node, default)
    local kind = M.kind(node)
    if kind == "string" or kind == "number" then return node.text end
    if kind == "boolean" then return node.value and "true" or "false" end
    return default
end

-- A scalar as a Lua number, or nil for anything that is not one. A number's
-- source text is converted here and nowhere else, which is what keeps the
-- conversion opt-in.
function M.number(node)
    local kind = M.kind(node)
    if kind == "number" then return tonumber(node.text) end
    if kind == "string" then return tonumber(node.text) end
    return nil
end

-- A boolean node's value, or nil for anything else. Deliberately not truthy:
-- `json.boolean(node)` on a missing field is nil, and `if json.boolean(x)` then
-- reads false, which is the safe direction for a flag the server did not send.
function M.boolean(node)
    if M.kind(node) == "boolean" then return node.value end
    return nil
end

-- A field of an object as text, in one step. The common shape by far.
function M.textat(node, key, default)
    return M.text(M.at(node, key), default)
end

-- Converts a node tree into plain Lua values, for a caller who would rather
-- have a table than an accessor. Objects and arrays become tables, strings and
-- booleans become themselves, numbers become Lua numbers -- losing the exact
-- digits, which is the price of the convenience -- and null becomes `nullvalue`
-- (`json.null` when none is given, never `nil`, because a `nil` in an array
-- truncates it).
function M.tolua(node, nullvalue)
    if nullvalue == nil then nullvalue = NULL end
    local kind = M.kind(node)
    if kind == "missing" then return nil end
    if kind == "null" then return nullvalue end
    if kind == "string" then return node.text end
    if kind == "number" then return tonumber(node.text) end
    if kind == "boolean" then return node.value end
    if kind == "array" then
        local out = {}
        for i = 1, node.n do out[i] = M.tolua(node.items[i], nullvalue) end
        return out
    end
    local out = {}
    for _, key in ipairs(node.order) do
        out[key] = M.tolua(node.fields[key], nullvalue)
    end
    return out
end

-- ------------------------------------------------------------------ parsing

local ESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

-- A codepoint as UTF-8. Lua 5.3 has `utf8.char`, 5.1 and LuaJIT do not, and the
-- four-byte case is short enough that having one implementation everywhere is
-- worth more than using the built-in where it exists.
local function utf8char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40),
                           0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
                           0x80 + math.floor(code / 0x40) % 0x40,
                           0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
                       0x80 + math.floor(code / 0x1000) % 0x40,
                       0x80 + math.floor(code / 0x40) % 0x40,
                       0x80 + code % 0x40)
end

local Parser = {}
Parser.__index = Parser

local function fail(self, i, what)
    -- The offset is given in characters from the start, and a few characters of
    -- context come with it: "unexpected 'x'" on its own does not say where in a
    -- 200KB response the trouble is.
    local near = self.text:sub(math.max(1, i - 20), i + 20):gsub("[\r\n\t]", " ")
    errors.usage(string.format("malformed JSON at offset %d: %s (near %q)",
                               i, what, near))
end

function Parser:skipspace(i)
    local _, stop = self.text:find("^[ \t\r\n]+", i)
    if stop then return stop + 1 end
    return i
end

function Parser:parsestring(i)
    -- `i` sits on the opening quote.
    local text = self.text
    local pieces, count = nil, 0
    local start = i + 1
    local j = start
    while true do
        local stop = text:find('[\\"]', j)
        if not stop then fail(self, i, "a string is never closed") end
        local c = text:sub(stop, stop)
        if c == '"' then
            -- The overwhelmingly common case is a string with no escape at all,
            -- and that one is a single `sub` with no table built for it.
            if not pieces then return text:sub(start, stop - 1), stop + 1 end
            count = count + 1
            pieces[count] = text:sub(j, stop - 1)
            return table.concat(pieces), stop + 1
        end
        -- A backslash: flush what came before it and decode the escape.
        pieces = pieces or {}
        count = count + 1
        pieces[count] = text:sub(j, stop - 1)
        local esc = text:sub(stop + 1, stop + 1)
        local simple = ESCAPES[esc]
        if simple then
            count = count + 1
            pieces[count] = simple
            j = stop + 2
        elseif esc == "u" then
            local hex = text:sub(stop + 2, stop + 5)
            if not hex:match("^%x%x%x%x$") then
                fail(self, stop, "\\u must be followed by four hex digits")
            end
            local code = tonumber(hex, 16)
            j = stop + 6
            -- A codepoint above the BMP arrives as a surrogate pair, and the
            -- two halves are only meaningful together: decoding them
            -- separately would produce two invalid characters where the
            -- document meant one emoji.
            if code >= 0xD800 and code <= 0xDBFF then
                local low = text:sub(j, j + 1) == "\\u" and text:sub(j + 2, j + 5) or nil
                if low and low:match("^%x%x%x%x$") then
                    local tail = tonumber(low, 16)
                    if tail >= 0xDC00 and tail <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 0x400 + (tail - 0xDC00)
                        j = j + 6
                    end
                end
            end
            count = count + 1
            -- An unpaired surrogate is not a character. U+FFFD is what the
            -- document can be read as, and refusing the whole response over one
            -- broken escape would lose the other 200KB of it.
            pieces[count] = (code >= 0xD800 and code <= 0xDFFF)
                and "\239\191\189" or utf8char(code)
        else
            fail(self, stop, string.format("\\%s is not an escape", esc))
        end
    end
end

function Parser:parsevalue(i, depth)
    if depth > MAX_DEPTH then
        fail(self, i, "nested more than " .. MAX_DEPTH .. " deep")
    end
    local text = self.text
    local c = text:sub(i, i)

    if c == '"' then
        local value, next = self:parsestring(i)
        return { kind = "string", text = value }, next
    end

    if c == "{" then
        local fields, order, n = {}, {}, 0
        i = self:skipspace(i + 1)
        if text:sub(i, i) == "}" then
            return { kind = "object", fields = fields, order = order }, i + 1
        end
        while true do
            if text:sub(i, i) ~= '"' then fail(self, i, "an object key must be a string") end
            local key, next = self:parsestring(i)
            i = self:skipspace(next)
            if text:sub(i, i) ~= ":" then fail(self, i, "expected ':' after an object key") end
            local value
            i = self:skipspace(i + 1)
            value, i = self:parsevalue(i, depth + 1)
            -- A repeated key keeps its last value, and appears once in `order`
            -- at its first position -- the reading every JSON parser in this
            -- driver family takes, and the one that keeps `order` a faithful
            -- index of `fields`.
            if fields[key] == nil then
                n = n + 1
                order[n] = key
            end
            fields[key] = value
            i = self:skipspace(i)
            local d = text:sub(i, i)
            if d == "," then
                i = self:skipspace(i + 1)
            elseif d == "}" then
                return { kind = "object", fields = fields, order = order }, i + 1
            else
                fail(self, i, "expected ',' or '}' in an object")
            end
        end
    end

    if c == "[" then
        local items, n = {}, 0
        i = self:skipspace(i + 1)
        if text:sub(i, i) == "]" then
            return { kind = "array", items = items, n = 0 }, i + 1
        end
        while true do
            local value
            value, i = self:parsevalue(i, depth + 1)
            n = n + 1
            items[n] = value
            i = self:skipspace(i)
            local d = text:sub(i, i)
            if d == "," then
                i = self:skipspace(i + 1)
            elseif d == "]" then
                return { kind = "array", items = items, n = n }, i + 1
            else
                fail(self, i, "expected ',' or ']' in an array")
            end
        end
    end

    if c == "t" then
        if text:sub(i, i + 3) == "true" then return TRUE, i + 4 end
        fail(self, i, "expected 'true'")
    end
    if c == "f" then
        if text:sub(i, i + 4) == "false" then return FALSE, i + 5 end
        fail(self, i, "expected 'false'")
    end
    if c == "n" then
        if text:sub(i, i + 3) == "null" then return NULL, i + 4 end
        fail(self, i, "expected 'null'")
    end

    -- A number, matched to JSON's grammar rather than to Lua's: `tonumber`
    -- would also take "0x1f", "1e", " 3 " and "inf", none of which is JSON, and
    -- accepting them here would let a malformed body through as data.
    local number = text:match("^%-?%d+%.?%d*[eE][-+]?%d+", i)
        or text:match("^%-?%d+%.%d+", i)
        or text:match("^%-?%d+", i)
    if number then
        -- JSON has no leading zeros and no leading `+`; "01" is a typo whose
        -- two readings (one, or eleven) differ, so it is refused rather than
        -- guessed at.
        local digits = number:gsub("^%-", "")
        if digits:match("^0%d") then fail(self, i, "a number may not have a leading zero") end
        return { kind = "number", text = number }, i + #number
    end

    if c == "" then fail(self, i, "the document ends early") end
    fail(self, i, string.format("unexpected %q", c))
end

-- Parses a whole document. Raises a `usage` error naming the offset if the text
-- is not JSON, and refuses trailing content: a response with a second document
-- glued to the end of the first is not one this driver will read half of.
function M.parse(text)
    if type(text) ~= "string" then
        errors.usage("JSON to parse must be a string, got " .. type(text))
    end
    local self = setmetatable({ text = text }, Parser)
    -- A UTF-8 BOM is not JSON, but plenty of tools write one; skipping it is
    -- cheaper than explaining the error it would otherwise cause.
    local i = text:sub(1, 3) == "\239\187\191" and 4 or 1
    i = self:skipspace(i)
    local node, next = self:parsevalue(i, 1)
    next = self:skipspace(next)
    if next <= #text then
        fail(self, next, "trailing content after the document")
    end
    return node
end

-- ------------------------------------------------------------------ encoding

-- Everything below 0x20 must be escaped, and the two-character forms are
-- shorter and more readable than \u00XX for the ones that have them.
local STRING_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\",
    ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
for i = 0, 0x1F do
    local c = string.char(i)
    if not STRING_ESCAPES[c] then STRING_ESCAPES[c] = string.format("\\u%04x", i) end
end
-- DEL is legal unescaped in JSON, and is escaped anyway: it travels through
-- logs and terminals on its way to a person, and an invisible byte in a
-- statement is worth spelling out.
STRING_ESCAPES["\127"] = "\\u007f"

-- Spelling NUL inside a character class is the one pattern difference between
-- the Lua versions this driver runs on: 5.1 and LuaJIT need `%z` and cannot
-- carry a raw \0 in a pattern, while 5.4's manual documents `%z` as gone. Both
-- spellings happen to work on the interpreter in front of us more often than
-- not, so which one is right is settled by asking rather than by version
-- number -- a statement carrying a NUL byte would otherwise reach the wire
-- unescaped, and an unescaped NUL is not JSON.
local NUL_CLASS = ("\0"):find("[%z]") and "%z" or "\0"
local ESCAPE_PATTERN = "[" .. NUL_CLASS .. '\1-\31\\"\127]'
do
    local ok, matched = pcall(string.find, "\0", ESCAPE_PATTERN)
    if not ok or not matched then
        error("frostlake.json: this Lua build matches NUL with neither [%z] nor [\\0]")
    end
end

-- Renders a Lua string as a JSON string literal, quotes included.
--
-- The bytes are passed through as they are, so a UTF-8 statement stays UTF-8 --
-- the request declares that encoding and the engine reads it that way. Only
-- what JSON forbids raw is escaped.
function M.encodestring(text)
    if type(text) ~= "string" then
        errors.usage("a JSON string must be a string, got " .. type(text))
    end
    return '"' .. text:gsub(ESCAPE_PATTERN, STRING_ESCAPES) .. '"'
end

-- Renders a node tree back into compact JSON text: the inverse of `parse`, with
-- a number's source digits and an object's key order kept exactly as they were
-- read. It exists for a cell that arrives as a nested value rather than as
-- text, where handing back its JSON is the one reading that loses nothing.
function M.stringify(node)
    local kind = M.kind(node)
    if kind == "string" then return M.encodestring(node.text) end
    if kind == "number" then return node.text end
    if kind == "boolean" then return node.value and "true" or "false" end
    if kind == "array" then
        local parts = {}
        for i = 1, node.n do parts[i] = M.stringify(node.items[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    if kind == "object" then
        local parts = {}
        for i, key in ipairs(node.order) do
            parts[i] = M.encodestring(key) .. ":" .. M.stringify(node.fields[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

return M
