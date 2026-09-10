-- Parsing a DSN into everything a connection needs.
--
-- Lua has no URI parser, so the grammar is spelled out here. It is a small one,
-- and owning it keeps the module free of dependencies that a URL library would
-- drag in.
--
-- A parsed DSN is a plain table, so it prints, stores and compares without
-- ceremony:
--
--     host port secure database schema role warehouse
--     connecttimeout timeout idlelimit      -- milliseconds; 0 means no bound
--
-- The parameter spellings match the other Frostlake drivers, so one DSN string
-- works across all of them.

local errors = require("frostlake.errors")

local M = {}

-- The port a DatabaseHttpServer listens on unless told otherwise.
M.DEFAULT_PORT = 18082

-- Long enough for a slow query, short enough that an unreachable host fails
-- while someone is still watching.
M.DEFAULT_CONNECT_TIMEOUT = 10000
M.DEFAULT_REQUEST_TIMEOUT = 300000

-- The engine reclaims a session after 30 minutes idle. Past that the driver has
-- to assume its own is gone, because nothing in a response says so.
M.DEFAULT_IDLE_LIMIT = 1800000

-- Everything the DSN query string may carry. Anything else is a typo, and a
-- typo in `schema` or `timeout` changes behaviour without saying so.
local PARAMETERS = {
    connectTimeout = "connecttimeout",
    idleLimit = "idlelimit",
    role = "role",
    schema = "schema",
    timeout = "timeout",
    tls = "tls",
    warehouse = "warehouse",
}

local PARAMETER_LIST = "connectTimeout, idleLimit, role, schema, timeout, tls, warehouse"

-- Percent-decoding, over bytes: `%C3%A9` is one UTF-8 character written as two
-- escapes, so the bytes are rebuilt and left as UTF-8 rather than decoded one
-- escape at a time into two broken characters.
local function percentdecode(text)
    if not text:find("[%%+]") then return text end
    text = text:gsub("%+", " ")
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- Reads a duration the way a connection string writes one: a bare number of
-- seconds, or a number with an `ms`/`s`/`m`/`h` suffix. Answers milliseconds.
--
-- Zero is meaningful -- it removes the bound -- so it is accepted where a
-- negative number is not.
function M.duration(name, text)
    text = tostring(text):match("^%s*(.-)%s*$")
    local amount, unit = text:match("^(%d+%.?%d*)(%a*)$")
    if not amount or (unit ~= "" and unit ~= "ms" and unit ~= "s"
                      and unit ~= "m" and unit ~= "h") then
        errors.usage(string.format(
            "%s must be a duration such as 30s, 500ms or 5m, got %q", name, text))
    end
    local factor = 1000
    if unit == "ms" then factor = 1
    elseif unit == "m" then factor = 60000
    elseif unit == "h" then factor = 3600000 end
    return math.floor(tonumber(amount) * factor + 0.5)
end

local function boolean(name, value)
    local folded = tostring(value):lower()
    if folded == "true" or folded == "1" or folded == "yes" then return true end
    if folded == "false" or folded == "0" or folded == "no" then return false end
    errors.usage(string.format("%s must be true or false, got %q", name, tostring(value)))
end

M.boolean = boolean

local function port(text)
    if not text:match("^%d+$") then
        errors.usage(string.format("the DSN port must be a number, got %q", text))
    end
    -- `tonumber` rather than a hand-rolled scan, but only after the pattern has
    -- ruled out everything it would read too generously -- "0x1f" and " 12 "
    -- are both numbers to `tonumber` and neither is a port.
    return tonumber(text)
end

-- Splits `host`, `host:port` or `[v6::addr]:port`.
--
-- A scheme that has a port of its own keeps it: reading the engine's default
-- into `https://h` would quietly move the DSN to another port, so only the
-- custom scheme -- which has no default of its own -- falls back to the
-- engine's.
local function splitauthority(authority, scheme)
    local fallback = M.DEFAULT_PORT
    if scheme == "http" then fallback = 80
    elseif scheme == "https" then fallback = 443 end

    if authority:sub(1, 1) == "[" then
        local close = authority:find("]", 1, true)
        if not close then errors.usage("the DSN has an unclosed IPv6 address") end
        local host = authority:sub(2, close - 1)
        local rest = authority:sub(close + 1)
        if rest == "" then return host, fallback end
        if rest:sub(1, 1) ~= ":" then errors.usage("the DSN is missing host[:port]") end
        return host, port(rest:sub(2))
    end

    -- The LAST colon, so an unbracketed IPv6 address is at least reported as a
    -- bad port rather than silently truncated at its first group.
    local colon = authority:match("^.*()%:")
    if not colon then return authority, fallback end
    return authority:sub(1, colon - 1), port(authority:sub(colon + 1))
end

local function parsequery(query)
    local out = {}
    if not query or query == "" then return out end
    for pair in query:gmatch("[^&]+") do
        local eq = pair:find("=", 1, true)
        if eq then
            out[percentdecode(pair:sub(1, eq - 1))] = percentdecode(pair:sub(eq + 1))
        else
            out[percentdecode(pair)] = ""
        end
    end
    return out
end

local function nonempty(name, params)
    local value = params[name]
    if value == nil then return nil end
    if value == "" then
        errors.usage("the DSN parameter " .. name .. " cannot be empty")
    end
    return value
end

-- Parses `frostlake://host[:port][/DATABASE][?param=value&...]`.
--
-- `http://` and `https://` are accepted too and mean the same thing; the custom
-- scheme exists so a DSN reads as a database URL rather than a web one.
function M.parse(text)
    if type(text) ~= "string" then
        errors.usage("a DSN must be a string, got " .. type(text))
    end
    -- A fragment would otherwise fail the whole pattern and be reported as a
    -- bad scheme, which names the wrong end of the string.
    if text:find("#", 1, true) then
        errors.usage("a DSN carries no fragment; remove the # and what follows it")
    end
    local scheme, authority, path, query =
        text:match("^([%a][%w+.-]*)://([^/?#]*)([^?#]*)%??([^#]*)$")
    if not scheme then
        errors.usage("a DSN must start with frostlake://, http:// or https://")
    end
    scheme = scheme:lower()
    if scheme ~= "frostlake" and scheme ~= "http" and scheme ~= "https" then
        errors.usage("a DSN must start with frostlake://, http:// or https://")
    end

    -- The server authenticates nobody, so credentials in a DSN would be
    -- silently dropped -- and silently dropping a password is worse than
    -- saying so.
    if authority:find("@", 1, true) then
        errors.usage("the server takes no credentials; remove user:password from the DSN")
    end

    local host, hostport = splitauthority(authority, scheme)
    if host == "" then errors.usage("the DSN is missing host[:port]") end
    if hostport < 1 or hostport > 65535 then
        errors.usage("the DSN port must be between 1 and 65535, got " .. tostring(hostport))
    end

    local segments = {}
    for segment in path:gmatch("[^/]+") do segments[#segments + 1] = segment end
    if #segments > 1 then
        errors.usage(string.format("the DSN path names one database, got %q", path))
    end
    local database = segments[1] and percentdecode(segments[1]) or nil

    local params = parsequery(query)
    local unknown = {}
    for key in pairs(params) do
        if not PARAMETERS[key] then unknown[#unknown + 1] = key end
    end
    if #unknown > 0 then
        table.sort(unknown)
        errors.usage("unknown DSN parameter: " .. table.concat(unknown, ", ")
            .. " (expected " .. PARAMETER_LIST .. ")")
    end

    local secure = scheme == "https"
    if params.tls ~= nil and boolean("tls", params.tls) then secure = true end

    local config = {
        host = host,
        port = hostport,
        secure = secure,
        database = database,
        schema = nonempty("schema", params),
        role = nonempty("role", params),
        warehouse = nonempty("warehouse", params),
        connecttimeout = M.DEFAULT_CONNECT_TIMEOUT,
        timeout = M.DEFAULT_REQUEST_TIMEOUT,
        idlelimit = M.DEFAULT_IDLE_LIMIT,
    }
    if params.connectTimeout then
        config.connecttimeout = M.duration("connectTimeout", params.connectTimeout)
    end
    if params.timeout then
        config.timeout = M.duration("timeout", params.timeout)
    end
    if params.idleLimit then
        config.idlelimit = M.duration("idleLimit", params.idleLimit)
    end
    return config
end

-- `host:port` as a URL and a Host header spell it: an IPv6 address goes back
-- into the brackets the DSN wrote it with, or its colons read as port
-- separators.
function M.hostport(config)
    local host = config.host
    if host:find(":", 1, true) then host = "[" .. host .. "]" end
    return host .. ":" .. tostring(config.port)
end

-- The base URL of a server, without a trailing slash.
function M.baseurl(config)
    return (config.secure and "https://" or "http://") .. M.hostport(config)
end

-- Quotes an identifier for use in a statement.
--
-- Always quoted. Leaving "unambiguous" names bare lets through ones that cannot
-- legally appear that way -- `1ABC` starts with a digit, `SELECT` is reserved --
-- and quoting costs nothing: "NAME" and NAME name the same object, so only
-- genuinely lower-case names are affected, and those had to be quoted anyway.
-- Embedded quotes are doubled, so a name arriving from a DSN cannot break out.
function M.quote(name)
    if type(name) ~= "string" or name == "" then
        errors.usage("an identifier cannot be empty")
    end
    return '"' .. name:gsub('"', '""') .. '"'
end

-- The DSN's scope rendered as the USE statements a fresh session needs, in
-- dependency order. Rebuilt on demand, so a session that may have lapsed can be
-- put back on this scope.
function M.usestatements(config)
    local out = {}
    local order = {
        { "role", "ROLE" }, { "warehouse", "WAREHOUSE" },
        { "database", "DATABASE" }, { "schema", "SCHEMA" },
    }
    for _, pair in ipairs(order) do
        local name = config[pair[1]]
        if name and name ~= "" then
            out[#out + 1] = "USE " .. pair[2] .. " " .. M.quote(name)
        end
    end
    return out
end

return M
