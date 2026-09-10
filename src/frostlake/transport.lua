-- Where the bytes actually move.
--
-- Lua's standard library has no sockets. Every other part of this driver is
-- plain Lua that runs anywhere a Lua interpreter does; this module is the one
-- seam where something outside the language has to be borrowed, so it is the
-- only place that names one.
--
-- Three backends, picked in this order and overridable:
--
--   * **OpenResty / ngx_lua cosockets**, when running inside one. Preferred
--     over LuaSocket there even if both are present: a blocking LuaSocket call
--     inside nginx blocks the whole worker and every other request on it.
--   * **LuaSocket**, the ecosystem's de-facto standard. `luarocks install
--     luasocket`, plus `luasec` for `https://`.
--   * **anything the caller passes in**, as `frostlake.connect(dsn, {transport
--     = t})`. The interface is four functions wide, which is what makes the
--     HTTP layer above testable against a scripted socket with no network at
--     all, and what lets a Copas or cqueues application supply its own
--     non-blocking one.
--
-- A backend is a table:
--
--     name                              a word for error messages
--     gettime()   -> seconds            a clock, any epoch, must move forward
--     open(spec)  -> sock | nil, reason
--
-- and a socket is a table:
--
--     settimeout(sock, ms)              0 or nil removes the bound
--     send(sock, bytes)   -> true | nil, reason
--     receive(sock, what) -> data | nil, reason, partial
--     close(sock)
--
-- `what` is a byte count, "line" for one CRLF-terminated line without its
-- terminator, or "all" for everything up to end of stream. `reason` is
-- "timeout", "closed", or any other text.
--
-- The deadline arithmetic, the HTTP framing and the retry rules all live above
-- this line, so a new backend is these four functions and nothing else.

local errors = require("frostlake.errors")
local compat = require("frostlake.compat")

local M = {}

-- ------------------------------------------------------------- LuaSocket

-- LuaSocket counts timeouts in SECONDS and takes nil for "block forever". At
-- module level rather than inside the backend, because the TLS wrapper below
-- needs the same rule for the handshake and has the same interface.
local function settimeout(sock, ms)
    if ms == nil or ms <= 0 then
        sock:settimeout(nil)
    else
        sock:settimeout(ms / 1000)
    end
end

local function luasocketbackend()
    local ok, socket = pcall(require, "socket")
    if not ok or type(socket) ~= "table" or type(socket.tcp) ~= "function" then
        return nil
    end

    local backend = { name = "luasocket" }

    backend.gettime = socket.gettime or compat.monotonic
    backend.settimeout = settimeout

    function backend.open(spec)
        local sock, why = socket.tcp()
        if not sock then return nil, why or "cannot create a socket" end
        settimeout(sock, spec.connecttimeout)
        local connected
        connected, why = sock:connect(spec.host, spec.port)
        if not connected then
            sock:close()
            return nil, why or "connection refused"
        end
        -- Nagle's algorithm holds a small write back waiting for company. A
        -- statement is one small write followed by a wait for the answer, so
        -- the company never comes and the delay is pure latency -- up to 40ms
        -- on every statement, which over a corpus of thousands is minutes.
        pcall(function() sock:setoption("tcp-nodelay", true) end)

        if spec.secure then
            local wrapped
            wrapped, why = M.wraptls(sock, spec)
            if not wrapped then
                sock:close()
                return nil, why
            end
            sock = wrapped
        end
        return sock
    end

    function backend.send(sock, bytes)
        local total = #bytes
        local from = 1
        while from <= total do
            local sent, why, lastsent = sock:send(bytes, from)
            if sent then return true end
            -- A partial write reports how far it got, and the rest still has to
            -- go: dropping it here would send the engine half a statement.
            if why ~= "timeout" or not lastsent or lastsent < from then
                return nil, why or "closed"
            end
            from = lastsent + 1
        end
        return true
    end

    function backend.receive(sock, what)
        if what == "line" then return sock:receive("*l") end
        if what == "all" then
            local data, why, partial = sock:receive("*a")
            -- Reading to end of stream ENDS at a close, so a "closed" here is
            -- the whole answer arriving, not a failure.
            if not data and why == "closed" then return partial or "" end
            return data, why, partial
        end
        return sock:receive(what)
    end

    function backend.close(sock)
        pcall(function() sock:close() end)
    end

    -- Whether the socket cannot carry another request: the peer closed it while
    -- we were idle, or there are bytes left over from the last exchange and the
    -- stream is out of step. Between exchanges there is nothing left to read,
    -- so anything readable at all means one of the two.
    function backend.stale(sock)
        -- 1ms rather than 0: `settimeout` above reads 0 as "no bound", so a
        -- zero here would block on a healthy idle socket forever. One
        -- millisecond is a poll in every way that matters.
        settimeout(sock, 1)
        local data, why = sock:receive(1)
        -- Anything readable between exchanges is either data left over from a
        -- desynchronised stream or the close the server did while we were
        -- idle. A timeout -- nothing to say -- is the healthy answer.
        if data then return true end
        return why ~= "timeout"
    end

    return backend
end

-- Wraps a connected socket in TLS. Split out so a caller supplying their own
-- LuaSocket-shaped backend gets the same handshake for free.
function M.wraptls(sock, spec)
    local ok, ssl = pcall(require, "ssl")
    if not ok then
        return nil, "an https DSN needs LuaSec (luarocks install luasec), which is"
            .. " not installed"
    end
    local params = {
        mode = "client",
        protocol = "any",
        verify = spec.verify and "peer" or "none",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    }
    if spec.cacert then
        params.cafile = spec.cacert
    elseif spec.verify then
        -- Without a CA file LuaSec verifies against nothing and every
        -- certificate fails, which reads as a broken server rather than as
        -- missing configuration.
        return nil, "verifying an https DSN needs a CA bundle; pass cacert = "
            .. "\"/path/to/ca.pem\", or verify = false to skip verification"
    end
    local wrapped, why = ssl.wrap(sock, params)
    if not wrapped then return nil, why or "cannot start TLS" end
    -- SNI: a host serving several names needs to be told which one, and
    -- without it the wrong certificate comes back.
    if wrapped.sni then pcall(function() wrapped:sni(spec.host) end) end
    -- The same rule as the plain socket: zero (or nothing) means no bound. A
    -- literal 0 would make the handshake non-blocking and fail at once.
    settimeout(wrapped, spec.connecttimeout)
    local shaken
    shaken, why = wrapped:dohandshake()
    if not shaken then return nil, "TLS handshake failed: " .. tostring(why) end
    return wrapped
end

-- ------------------------------------------------------- ngx_lua cosockets

local function ngxbackend()
    if type(ngx) ~= "table" or type(ngx.socket) ~= "table" then return nil end
    local tcp = ngx.socket.tcp
    if type(tcp) ~= "function" then return nil end

    local backend = { name = "ngx.socket" }

    function backend.gettime()
        ngx.update_time()
        return ngx.now()
    end

    -- Cosockets already count in milliseconds, and take 0 for "no bound".
    function backend.settimeout(sock, ms)
        sock:settimeout(ms and ms > 0 and ms or 0)
    end

    function backend.open(spec)
        local sock = tcp()
        sock:settimeout(spec.connecttimeout and spec.connecttimeout > 0
            and spec.connecttimeout or 0)
        local ok, why = sock:connect(spec.host, spec.port)
        if not ok then return nil, why or "connection refused" end
        if spec.secure then
            local shaken
            shaken, why = sock:sslhandshake(nil, spec.host, spec.verify and true or false)
            if not shaken then
                sock:close()
                return nil, "TLS handshake failed: " .. tostring(why)
            end
        end
        return sock
    end

    function backend.send(sock, bytes)
        -- A cosocket's `send` is all-or-nothing; there is no partial write to
        -- resume.
        local sent, why = sock:send(bytes)
        if not sent then return nil, why or "closed" end
        return true
    end

    function backend.receive(sock, what)
        if what == "line" then return sock:receive("*l") end
        if what == "all" then
            local data, why, partial = sock:receive("*a")
            if not data and why == "closed" then return partial or "" end
            return data, why, partial
        end
        return sock:receive(what)
    end

    function backend.close(sock)
        pcall(function() sock:close() end)
    end

    -- A cosocket has no non-blocking peek, and a zero timeout would be read as
    -- "no bound" rather than "do not wait". Saying so is better than a poll
    -- that blocks: the HTTP layer then treats every socket as possibly fresh
    -- and relies on the error path, which never re-sends a statement anyway.
    function backend.stale() return false end

    return backend
end

-- ------------------------------------------------------------------ choosing

local cached = nil

-- The backend this interpreter can use, or nil with the reason it cannot.
function M.detect()
    if cached then return cached end
    cached = ngxbackend() or luasocketbackend()
    return cached
end

-- The backend to use, raising a `usage` error that says how to get one when
-- there is none. The message is the whole install instruction, because "module
-- 'socket' not found" is a Lua error about a missing file rather than an
-- answer to what the caller needs to do.
function M.require()
    local backend = M.detect()
    if backend then return backend end
    errors.usage("this driver needs a socket, and Lua's standard library has none."
        .. " Install LuaSocket (luarocks install luasocket), run under OpenResty,"
        .. " or pass your own with frostlake.connect(dsn, {transport = ...})")
end

-- Checks that a caller-supplied backend has the four functions the layer above
-- calls, and fills in the two optional ones. A backend missing `receive` fails
-- on the first response otherwise, a long way from the mistake.
function M.adopt(backend)
    if type(backend) ~= "table" then
        errors.usage("a transport must be a table, got " .. type(backend))
    end
    for _, name in ipairs({ "open", "send", "receive", "close" }) do
        if type(backend[name]) ~= "function" then
            errors.usage("a transport needs a " .. name .. " function")
        end
    end
    if type(backend.settimeout) ~= "function" then
        backend.settimeout = function() end
    end
    if type(backend.gettime) ~= "function" then
        backend.gettime = compat.monotonic
    end
    if type(backend.stale) ~= "function" then
        backend.stale = function() return false end
    end
    backend.name = backend.name or "custom"
    return backend
end

return M
