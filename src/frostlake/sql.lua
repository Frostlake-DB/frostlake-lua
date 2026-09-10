-- Lexical helpers shared by parameter binding and session-scope tracking.
--
-- Both need to walk a statement while stepping over the places where SQL syntax
-- stops meaning what it says -- string literals, quoted identifiers,
-- dollar-quoted bodies and comments -- so both read the same scanner and cannot
-- disagree about what is inside one.
--
-- Positions are 1-based byte indices, the way every Lua string function counts.
-- A multi-byte UTF-8 character is never split, because the scanner only ever
-- stops on the ASCII punctuation that delimits these regions, and no byte of a
-- multi-byte sequence is ASCII.

local M = {}

-- The characters that may appear in an unquoted identifier.
local WORD = "[%w_%$]"

-- Modifiers that may sit between CREATE/DROP/ALTER and the kind of object being
-- named.
local OBJECT_MODIFIERS = {
    OR = true, REPLACE = true, TRANSIENT = true, TEMPORARY = true, TEMP = true,
    VOLATILE = true, LOCAL = true, GLOBAL = true, SECURE = true,
    IF = true, NOT = true, EXISTS = true,
}

local function iswordchar(c)
    return c ~= "" and c:match(WORD) ~= nil
end

M.iswordchar = iswordchar

-- The index just past the single-quoted literal starting at `i`. Both '' and
-- backslash escapes end up inside the literal -- a backslash always escapes in
-- Frostlake's string dialect.
local function skipstring(text, i)
    local n = #text
    local j = i + 1
    while j <= n do
        local c = text:sub(j, j)
        if c == "\\" then
            j = j + 2
        elseif c == "'" then
            if text:sub(j + 1, j + 1) == "'" then
                j = j + 2
            else
                return j + 1
            end
        else
            j = j + 1
        end
    end
    return j
end

-- The index just past the double-quoted identifier starting at `i`.
local function skipquoted(text, i)
    local n = #text
    local j = i + 1
    while j <= n do
        if text:sub(j, j) == '"' then
            if text:sub(j + 1, j + 1) == '"' then
                j = j + 2
            else
                return j + 1
            end
        else
            j = j + 1
        end
    end
    return j
end

-- Whether the `$` at `i` opens a dollar-quoted body. A `$` is legal inside an
-- unquoted identifier, so `A$$B` is a name rather than the start of a body: a
-- real delimiter is never preceded by an identifier character.
local function opensdollarquote(text, i)
    if text:sub(i + 1, i + 1) ~= "$" then return false end
    if i == 1 then return true end
    return not iswordchar(text:sub(i - 1, i - 1))
end

-- The index just past the dollar-quoted body starting at `i`. Function and
-- procedure bodies are written this way, and their contents are not SQL -- a `?`
-- inside one is part of the body, never a placeholder.
local function skipdollarquoted(text, i)
    local stop = text:find("$$", i + 2, true)
    if not stop then return #text + 1 end
    return stop + 2
end

local function skipline(text, i)
    local stop = text:find("\n", i, true)
    if not stop then return #text + 1 end
    return stop + 1
end

local function skipblockcomment(text, i)
    local stop = text:find("*/", i + 2, true)
    if not stop then return #text + 1 end
    return stop + 2
end

-- Whether a comment or a quoted region opens at `i`, and where it ends: the
-- index just past the region, or nil when `i` opens none. Every walk over a
-- statement starts here, so none of them can forget a case.
function M.skipenclosure(text, i)
    local c = text:sub(i, i)
    if c == "'" then return skipstring(text, i) end
    if c == '"' then return skipquoted(text, i) end
    if c == "$" then
        if opensdollarquote(text, i) then return skipdollarquoted(text, i) end
        return nil
    end
    if c == "-" then
        if text:sub(i + 1, i + 1) == "-" then return skipline(text, i) end
        return nil
    end
    if c == "/" then
        local next = text:sub(i + 1, i + 1)
        if next == "/" then return skipline(text, i) end
        if next == "*" then return skipblockcomment(text, i) end
        return nil
    end
    return nil
end

-- Splits a request on its top-level semicolons, leaving alone any that sit
-- inside a string literal, a quoted identifier, a dollar-quoted body or a
-- comment.
--
-- A procedural block is split along with everything else, which only makes the
-- scope check below more willing to flag -- the safe direction.
function M.splitstatements(text)
    local out = {}
    local n = #text
    local start = 1
    local i = 1
    while i <= n do
        local skip = M.skipenclosure(text, i)
        if skip then
            i = skip
        else
            if text:sub(i, i) == ";" then
                out[#out + 1] = text:sub(start, i - 1)
                start = i + 1
            end
            i = i + 1
        end
    end
    out[#out + 1] = text:sub(start)
    return out
end

-- Up to `n` words from the start of a statement, upper-cased, skipping
-- whitespace and comments and stopping at the first thing that is not a word.
function M.leadingwords(statement, n)
    local out = {}
    local len = #statement
    local i = 1
    while i <= len and #out < n do
        local c = statement:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == "-" or c == "/" then
            -- Only comments are stepped over here: a leading string literal or
            -- quoted identifier means the statement does not start with a
            -- keyword at all.
            local skip = M.skipenclosure(statement, i)
            if not skip then return out end
            i = skip
        elseif not iswordchar(c) then
            return out
        else
            local start = i
            while i <= len and iswordchar(statement:sub(i, i)) do i = i + 1 end
            out[#out + 1] = statement:sub(start, i - 1):upper()
        end
    end
    return out
end

-- Walks the words between the verb and the object being named, stepping over
-- the modifiers that may sit between them -- `CREATE OR REPLACE DATABASE`,
-- `DROP SCHEMA IF EXISTS` -- and reports whether the object is one of `want`.
local function namesobject(words, from, want)
    for i = from, #words do
        local word = words[i]
        if not OBJECT_MODIFIERS[word] then return want[word] == true end
    end
    return false
end

local SESSION = { SESSION = true }
local SCOPED = { DATABASE = true, SCHEMA = true }

-- Only USE, the SET family, ALTER SESSION, and CREATE/DROP of a DATABASE or
-- SCHEMA move the session -- CREATE TABLE and its kind leave the scope exactly
-- where it was, and counting those would mark the session dirty for every DDL
-- statement a caller runs.
local function statementchangesscope(statement)
    local words = M.leadingwords(statement, 6)
    local first = words[1]
    if not first then return false end
    if first == "USE" or first == "SET" or first == "UNSET" then return true end
    if first == "ALTER" then return namesobject(words, 2, SESSION) end
    if first == "CREATE" or first == "DROP" then return namesobject(words, 2, SCOPED) end
    return false
end

-- Whether a request can move the session off the scope the DSN established.
--
-- A request may hold more than one statement, and a `USE` riding behind a
-- leading `SELECT` moves the scope just as surely as one standing alone, so
-- every statement is examined rather than only the first.
function M.changesscope(text)
    for _, statement in ipairs(M.splitstatements(text)) do
        if statementchangesscope(statement) then return true end
    end
    return false
end

return M
