-- The driver's error taxonomy.
--
-- Every failure leaves this driver as a raised Lua error whose value is a
-- TABLE, not a string. `pcall` therefore hands the caller the whole error --
-- its kind, its message and whatever context the failure had -- instead of a
-- line of text with a file:line prefix glued to the front:
--
--     local ok, err = pcall(conn.execute, conn, "SELECT * FROM missing")
--     if not ok then
--         print(err.kind)      --> "query"
--         print(err.message)   --> "Object 'MISSING' does not exist ..."
--         print(err.statement) --> "SELECT * FROM missing"
--     end
--
-- The table has a `__tostring`, so `print(err)` and `..` still read as a
-- message, and an error that escapes to the interpreter prints as one.
--
-- Four kinds, and the difference between them is who has to do something:
--
--   * `usage`       -- the calling code is wrong: a malformed DSN, an unknown
--                      option, a bind count that does not match the statement.
--                      Fix the program.
--   * `connection`  -- the server could not be reached, did not answer in time,
--                      or answered something that is not a Frostlake response.
--                      The statement's fate is UNKNOWN; it may well have run.
--   * `query`       -- the engine was reached, understood the statement, and
--                      refused it. The message is the engine's own.
--   * `sessionlost` -- the engine no longer holds the connection's session, and
--                      an open transaction or a context set up on it (USE, SET,
--                      ALTER SESSION, a temporary object) went with it. The
--                      statement did NOT run, and the connection carries on in
--                      a fresh session on the DSN's scope.
--
-- The testkit corpus leans on that last distinction: a refused statement is a
-- test result, while a broken connection is an infrastructure failure, and a
-- runner that confused the two would report the wrong status for both.

local M = {}

-- The metatable is the identity: `errors.is` compares against it rather than
-- looking for a marker field, so a plain table carrying `kind` and `message` --
-- one a caller built, or one that arrived as data -- is not mistaken for an
-- error this driver raised.
local mt = {
    __tostring = function(self) return self.message end,
    __name = "frostlake.error",
}

-- Builds an error table of `kind`. `context` is copied in field by field, so a
-- caller can attach whatever the failure knew -- an endpoint, a status, the
-- statement -- without every raiser needing its own constructor.
local function make(kind, message, context)
    local err = setmetatable({ kind = kind, message = message }, mt)
    if context then
        for key, value in pairs(context) do
            if key ~= "kind" and key ~= "message" then err[key] = value end
        end
    end
    return err
end

M.make = make

-- Raised with level 0: the message is the driver's, and prefixing it with the
-- line inside the driver that noticed would name the wrong place. The traceback
-- still points there for anyone who wants it.
local function raise(kind, message, context)
    error(make(kind, message, context), 0)
end

function M.usage(message, context) raise("usage", message, context) end
function M.connection(message, context) raise("connection", message, context) end
function M.query(message, context) raise("query", message, context) end
function M.sessionlost(message, context) raise("sessionlost", message, context) end

-- Whether a value is one of this driver's errors. Anything else caught by a
-- `pcall` around driver code -- a bug in here, an out-of-memory -- is not, and
-- a caller that means to handle Frostlake failures should not swallow those.
function M.is(value)
    return type(value) == "table" and getmetatable(value) == mt
end

-- Whether a value is a driver error of a particular kind.
function M.iskind(value, kind)
    return M.is(value) and value.kind == kind
end

-- Trims a server's reply down to something that fits in an error message. A
-- proxy's HTML error page is 40KB of markup, and pasting all of it into a
-- message hides the message.
function M.snippet(text)
    if type(text) ~= "string" then return "(nothing)" end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed == "" then return "(nothing)" end
    if #trimmed > 512 then return trimmed:sub(1, 512) .. "..." end
    return trimmed
end

return M
