-- A transport backend that answers from a script instead of from a network.
--
-- This is the payoff of making the transport injectable. Everything above the
-- socket -- the HTTP framing, the keep-alive rules, the session handling, the
-- result shaping, every error path -- runs here exactly as it runs against a
-- real engine, with no port to bind, no server to boot, no timing to flake on,
-- and no way for a test to pass because something else happened to be listening
-- on 18082.
--
-- What it cannot do is prove the driver talks to a *Frostlake*. That is what
-- `testserver.lua` and the testkit corpus are for; the two together are the
-- whole story, and neither replaces the other.
--
--     local fake = fakebackend.new(function(request)
--         return { body = '{"success":true,"resultSets":[]}' }
--     end)
--     local conn = frostlake.connect("frostlake://fake:18082", {transport = fake})

local M = {}

-- A health response, so a handler that only cares about statements does not
-- have to spell one out: `connect` pings before it returns.
function M.healthy()
    return '{"status":"ok","service":"frostlake","version":"0.0.7"}'
end

-- The engine's answer to a statement that produced no grid.
function M.acknowledged(sessionid)
    return '{"success":true,"sessionId":"' .. (sessionid or "S1")
        .. '","resultSets":[]}'
end

-- A grid. `columns` is a list of names or of {name, dataType} pairs; `rows` is a
-- list of lists whose cells are strings, numbers-as-text, booleans or nil for
-- JSON null.
function M.grid(columns, rows, sessionid)
    local pieces = { '{"success":true,"sessionId":"', sessionid or "S1",
                     '","resultSets":[{"columns":[' }
    for i, column in ipairs(columns) do
        if i > 1 then pieces[#pieces + 1] = "," end
        local name = type(column) == "table" and column[1] or column
        local datatype = type(column) == "table" and column[2] or "VARCHAR"
        pieces[#pieces + 1] = string.format('{"name":%q,"dataType":%q}', name, datatype)
    end
    pieces[#pieces + 1] = '],"rows":['
    for i, row in ipairs(rows) do
        if i > 1 then pieces[#pieces + 1] = "," end
        pieces[#pieces + 1] = "["
        for j = 1, row.n or #row do
            if j > 1 then pieces[#pieces + 1] = "," end
            local cell = row[j]
            if cell == nil then
                pieces[#pieces + 1] = "null"
            elseif type(cell) == "boolean" then
                pieces[#pieces + 1] = tostring(cell)
            elseif type(cell) == "number" then
                pieces[#pieces + 1] = tostring(cell)
            else
                pieces[#pieces + 1] = string.format("%q", cell)
            end
        end
        pieces[#pieces + 1] = "]"
    end
    pieces[#pieces + 1] = "]}]}"
    return table.concat(pieces)
end

function M.refused(message)
    return string.format('{"success":false,"sessionId":null,"errorMessage":%q}', message)
end

-- --------------------------------------------------------------- the backend

local Socket = {}
Socket.__index = Socket

-- Parses whatever has been written so far, returning the request and the
-- leftover bytes once a whole one has arrived, or nil while it is still coming.
local function takerequest(buffer)
    local headend = buffer:find("\r\n\r\n", 1, true)
    if not headend then return nil end
    local head = buffer:sub(1, headend - 1)
    local rest = buffer:sub(headend + 4)

    local lines = {}
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do lines[#lines + 1] = line end
    local method, path, version = lines[1]:match("^(%S+)%s+(%S+)%s+(%S+)$")
    local headers = {}
    for i = 2, #lines do
        local name, item = lines[i]:match("^([^:]+):%s*(.-)%s*$")
        if name then headers[name:lower()] = item end
    end

    local length = tonumber(headers["content-length"] or "0") or 0
    if #rest < length then return nil end
    return {
        method = method, path = path, version = version,
        headers = headers, body = rest:sub(1, length),
    }, rest:sub(length + 1)
end

-- Renders a handler's answer as the bytes a server would put on the wire. A
-- handler may return raw bytes instead, for the malformed cases a well-behaved
-- server would never produce.
local function renderresponse(answer)
    if type(answer) == "string" then return answer end
    answer = answer or {}
    if answer.raw then return answer.raw end
    local body = answer.body or ""
    local status = answer.status or 200
    local reason = answer.reason or (status == 200 and "OK" or "Error")
    local pieces = { string.format("HTTP/1.1 %d %s", status, reason) }
    local headers = answer.headers or {}
    local hasType, hasLength, hasEncoding = false, false, false
    for name, item in pairs(headers) do
        local folded = name:lower()
        if folded == "content-type" then hasType = true end
        if folded == "content-length" then hasLength = true end
        if folded == "transfer-encoding" then hasEncoding = true end
        pieces[#pieces + 1] = name .. ": " .. item
    end
    if not hasType then pieces[#pieces + 1] = "Content-Type: application/json" end
    if answer.chunked then
        if not hasEncoding then pieces[#pieces + 1] = "Transfer-Encoding: chunked" end
        local chunks = {}
        local size = answer.chunksize or 7
        for i = 1, #body, size do
            local piece = body:sub(i, i + size - 1)
            chunks[#chunks + 1] = string.format("%x\r\n%s\r\n", #piece, piece)
        end
        chunks[#chunks + 1] = "0\r\n\r\n"
        return table.concat(pieces, "\r\n") .. "\r\n\r\n" .. table.concat(chunks)
    end
    -- `Content-length`, spelled the way the engine spells it, so the header
    -- folding in the client stays exercised.
    if not hasLength then
        pieces[#pieces + 1] = "Content-length: " .. tostring(#body)
    end
    return table.concat(pieces, "\r\n") .. "\r\n\r\n" .. body
end

M.renderresponse = renderresponse

function M.new(handler, options)
    options = options or {}
    local backend = { name = "fake" }

    -- Every request the driver sent, in order, so a test can assert on what
    -- went out as well as on what came back.
    backend.requests = {}
    backend.opened = 0
    backend.closed = 0
    -- A clock the tests drive: nothing here waits on a real one, so a timeout
    -- test does not cost the time it is testing.
    backend.now = 0

    function backend.gettime() return backend.now end

    function backend.open(spec)
        backend.opened = backend.opened + 1
        if options.refuse then return nil, options.refuse end
        backend.lastspec = spec
        return setmetatable({ inbox = "", outbox = "", cursor = 1, dead = false }, Socket)
    end

    function backend.settimeout(sock, ms) sock.timeout = ms end

    function backend.send(sock, bytes)
        if sock.dead then return nil, "closed" end
        if options.writefails then return nil, options.writefails end
        sock.outbox = sock.outbox .. bytes
        while true do
            local request, rest = takerequest(sock.outbox)
            if not request then break end
            sock.outbox = rest
            backend.requests[#backend.requests + 1] = request
            local answer = handler(request, #backend.requests)
            if answer == "hang" then
                -- Nothing comes back at all: the read below runs out its
                -- deadline, which is how a timeout is tested without waiting.
                sock.hang = true
            elseif answer == "die" then
                sock.dead = true
            else
                sock.inbox = sock.inbox .. renderresponse(answer)
            end
        end
        return true
    end

    local function pending(sock)
        return #sock.inbox - sock.cursor + 1
    end

    function backend.receive(sock, what)
        if sock.hang then
            -- The deadline is the caller's, and this is the socket that never
            -- answers: move the clock past it and report the timeout the real
            -- one would.
            backend.now = backend.now + 1e6
            return nil, "timeout"
        end
        if what == "line" then
            local stop = sock.inbox:find("\r\n", sock.cursor, true)
            -- No terminator left in what the server said: the stream ended
            -- mid-line, which is what a connection dropped in the middle of a
            -- response looks like from here.
            if not stop then return nil, "closed" end
            local line = sock.inbox:sub(sock.cursor, stop - 1)
            sock.cursor = stop + 2
            return line
        end
        if what == "all" then
            local rest = sock.inbox:sub(sock.cursor)
            sock.cursor = #sock.inbox + 1
            return rest
        end
        if pending(sock) < what then
            local partial = sock.inbox:sub(sock.cursor)
            sock.cursor = #sock.inbox + 1
            return nil, "closed", partial
        end
        local data = sock.inbox:sub(sock.cursor, sock.cursor + what - 1)
        sock.cursor = sock.cursor + what
        return data
    end

    function backend.close(sock)
        backend.closed = backend.closed + 1
        sock.dead = true
    end

    -- A socket with bytes still unread between exchanges is out of step, and one
    -- the handler killed is gone: the same two conditions the LuaSocket backend
    -- detects, reported without a poll.
    function backend.stale(sock)
        return sock.dead or pending(sock) > 0
    end

    return backend
end

-- The handler most tests want: health checks answered, and one canned reply to
-- every statement.
function M.always(answer)
    return function(request)
        if request.path == "/api/health" then return { body = M.healthy() } end
        return answer
    end
end

-- A handler that answers each statement from a list, in order.
function M.script(answers)
    local at = 0
    return function(request)
        if request.path == "/api/health" then return { body = M.healthy() } end
        at = at + 1
        local answer = answers[at]
        if answer == nil then
            return { status = 500, body = M.refused("the script ran out at request " .. at) }
        end
        return answer
    end
end

return M
