-- The HTTP/1.1 transport: one socket, held open across statements.
--
-- LuaSocket ships an `http` module, and this does not use it. Two reasons, both
-- about what a database driver needs that a general web client does not:
--
--  * A connection keeps ONE socket for its whole life. A driver that opens a
--    socket per statement burns a TCP port per statement, and a corpus run of a
--    few thousand statements will exhaust a machine's ephemeral port range and
--    start failing on connections that have nothing to do with the query. Here
--    the socket is opened once and every statement rides it.
--  * The deadline is the caller's. `timeout` bounds the whole exchange --
--    connect, write, status line, headers and body -- rather than any one read,
--    so a server answering a byte a minute still fails when it said it would.
--    LuaSocket's own timeout is per operation, which a slow drip resets
--    forever.

local errors = require("frostlake.errors")
local dsn = require("frostlake.dsn")

local M = {}

-- Sent so a server's logs and any proxy in between can tell what is talking to
-- it. `init.lua` overwrites this with the versioned form as it loads; the
-- version cannot simply be read from there, because that module requires this
-- one and the cycle would leave one of them half-built.
M.USER_AGENT = "frostlake-lua"

-- ---------------------------------------------------------------- deadlines

-- One deadline for the whole exchange, so a server dribbling a byte at a time
-- cannot outlast it by resetting a per-read timer.
local Deadline = {}
Deadline.__index = Deadline

local function deadline(backend, limit)
    return setmetatable({
        backend = backend,
        limit = limit,
        at = limit > 0 and (backend.gettime() + limit / 1000) or nil,
    }, Deadline)
end

-- Milliseconds left, or nil for an exchange with no bound. Raises when the
-- budget is already spent.
function Deadline:remaining(endpoint)
    if not self.at then return nil end
    local left = (self.at - self.backend.gettime()) * 1000
    if left <= 0 then self:expired(endpoint) end
    return left
end

function Deadline:expired(endpoint)
    errors.connection(string.format("%s did not answer within %s",
        endpoint, M.describe(self.limit)), { endpoint = endpoint, timeout = true })
end

function M.describe(ms)
    if ms < 1000 then return string.format("%dms", ms) end
    if ms % 1000 == 0 then return string.format("%ds", ms / 1000) end
    return string.format("%.3gs", ms / 1000)
end

-- ------------------------------------------------------------------ reading

-- Reads one unit -- a byte count, "line" or "all" -- inside the deadline.
local function read(sock, backend, what, clock, endpoint)
    backend.settimeout(sock, clock:remaining(endpoint))
    local data, why = backend.receive(sock, what)
    if data then return data end
    if why == "timeout" then clock:expired(endpoint) end
    errors.connection(string.format("%s closed the connection mid-response", endpoint),
        { endpoint = endpoint })
end

local function readline(sock, backend, clock, endpoint)
    return read(sock, backend, "line", clock, endpoint)
end

-- ---------------------------------------------------------------- connecting

-- Opens a socket to the server named by `config`, waiting no longer than its
-- connect timeout.
function M.connect(backend, config)
    local endpoint = dsn.baseurl(config)
    local sock, why = backend.open({
        host = config.host,
        port = config.port,
        secure = config.secure,
        verify = config.verify,
        cacert = config.cacert,
        connecttimeout = config.connecttimeout,
    })
    if not sock then
        errors.connection(string.format("cannot reach %s: %s", endpoint, tostring(why)),
            { endpoint = endpoint })
    end
    return sock
end

function M.disconnect(backend, sock)
    if sock then backend.close(sock) end
end

-- ------------------------------------------------------------------- bodies

local function readcounted(sock, backend, clock, endpoint, count)
    if count == 0 then return "" end
    return read(sock, backend, count, clock, endpoint)
end

local function readchunked(sock, backend, clock, endpoint)
    local pieces, n = {}, 0
    while true do
        local line = readline(sock, backend, clock, endpoint)
        -- A chunk size may carry `;ext=value` extensions after a semicolon.
        local size = line:match("^%s*(%x+)")
        if not size then
            errors.connection(string.format(
                "%s sent a chunk header that is not a size: %s",
                endpoint, errors.snippet(line)), { endpoint = endpoint })
        end
        size = tonumber(size, 16)
        if size == 0 then
            -- Trailers, then the blank line that ends them.
            while readline(sock, backend, clock, endpoint) ~= "" do end
            return table.concat(pieces)
        end
        n = n + 1
        pieces[n] = readcounted(sock, backend, clock, endpoint, size)
        readline(sock, backend, clock, endpoint) -- the CRLF after the chunk
    end
end

local function readbody(sock, backend, clock, endpoint, headers, status, method)
    -- A response to HEAD, and the statuses defined to carry no body, have none
    -- however the headers read.
    if method == "HEAD" or status == 204 or status == 304
        or (status >= 100 and status < 200) then
        return "", false
    end
    local encoding = headers["transfer-encoding"]
    if encoding and encoding:lower():find("chunked", 1, true) then
        return readchunked(sock, backend, clock, endpoint), false
    end
    local length = headers["content-length"]
    if length then
        length = length:match("^%s*(.-)%s*$")
        if not length:match("^%d+$") then
            errors.connection(string.format(
                "%s sent a Content-Length that is not a number: %s",
                endpoint, errors.snippet(length)),
                { endpoint = endpoint, status = status })
        end
        return readcounted(sock, backend, clock, endpoint, tonumber(length)), false
    end
    -- No length and no chunking: the body runs to end of stream, and the socket
    -- cannot be reused afterwards.
    return read(sock, backend, "all", clock, endpoint), true
end

-- ------------------------------------------------------------------ exchange

-- Sends one request and reads its response.
--
-- Answers a table of `status`, `reason`, `headers` (keys folded to lower case),
-- `body`, and `close` -- whether the server said this socket may not be reused.
function M.exchange(backend, sock, config, method, path, payload, agent)
    local endpoint = dsn.baseurl(config) .. path
    local clock = deadline(backend, config.timeout or 0)

    local request = {
        method .. " " .. path .. " HTTP/1.1",
        "Host: " .. dsn.hostport(config),
        "User-Agent: " .. (agent or M.USER_AGENT),
        "Accept: application/json",
        "Connection: keep-alive",
    }
    if method ~= "GET" and method ~= "HEAD" then
        request[#request + 1] = "Content-Type: application/json"
        request[#request + 1] = "Content-Length: " .. tostring(#(payload or ""))
    end
    -- The blank line that ends the headers, then the body, in ONE write: a
    -- separate write for the body gives a proxy the chance to forward a
    -- headers-only request and wait.
    local bytes = table.concat(request, "\r\n") .. "\r\n\r\n" .. (payload or "")

    backend.settimeout(sock, clock:remaining(endpoint))
    local sent, why = backend.send(sock, bytes)
    if not sent then
        errors.connection(string.format("cannot write to %s: %s", endpoint, tostring(why)),
            { endpoint = endpoint })
    end

    local statusline = readline(sock, backend, clock, endpoint)
    local version, code, reason = statusline:match("^HTTP/(%d%.%d)%s+(%d%d%d)%s*(.*)$")
    if not version then
        errors.connection(string.format("%s answered something that is not HTTP: %s",
            endpoint, errors.snippet(statusline)), { endpoint = endpoint })
    end
    code = tonumber(code)

    local headers = {}
    while true do
        local line = readline(sock, backend, clock, endpoint)
        if line == "" then break end
        local name, item = line:match("^([^:]+):%s*(.-)%s*$")
        -- Header names are case-insensitive, and this server spells it
        -- `Content-length`. Folding here is what keeps that from mattering.
        if name then headers[name:match("^%s*(.-)%s*$"):lower()] = item end
    end

    local closing = version == "1.0"
    if headers["connection"] then
        closing = headers["connection"]:lower():find("close", 1, true) ~= nil
    end

    local body, unbounded = readbody(sock, backend, clock, endpoint, headers, code, method)

    return {
        status = code,
        reason = reason,
        headers = headers,
        body = body,
        close = closing or unbounded,
    }
end

return M
