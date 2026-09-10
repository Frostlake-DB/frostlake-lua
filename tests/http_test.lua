-- The HTTP layer, driven through a scripted transport: no port, no server, and
-- every response shape a real one could produce -- including the ones it should
-- not.

local t = require("harness")
local http = require("frostlake.http")
local dsn = require("frostlake.dsn")
local fakebackend = require("fakebackend")

local function config(overrides)
    local c = dsn.parse("frostlake://example:18082")
    for key, item in pairs(overrides or {}) do c[key] = item end
    return c
end

-- Runs one exchange against `handler` and returns the response plus the
-- backend, so a test can look at what went out as well as what came back.
local function exchange(handler, method, path, payload, overrides)
    local backend = fakebackend.new(handler)
    local c = config(overrides)
    local sock = http.connect(backend, c)
    local answer = http.exchange(backend, sock, c, method or "POST",
                                 path or "/api/execute", payload or "{}", "test/1")
    return answer, backend
end

t.describe("http: requests")

t.it("writes a well-formed request", function()
    local _, backend = exchange(fakebackend.always({ body = "{}" }), "POST",
                                "/api/execute", '{"sql":"SELECT 1"}')
    local request = backend.requests[1]
    t.eq(request.method, "POST")
    t.eq(request.path, "/api/execute")
    t.eq(request.version, "HTTP/1.1")
    t.eq(request.headers["host"], "example:18082")
    t.eq(request.headers["content-type"], "application/json")
    t.eq(request.headers["content-length"], "18")
    t.eq(request.headers["accept"], "application/json")
    t.eq(request.headers["connection"], "keep-alive")
    t.eq(request.headers["user-agent"], "test/1")
    t.eq(request.body, '{"sql":"SELECT 1"}')
end)

t.it("brackets an IPv6 host in the Host header", function()
    local _, backend = exchange(fakebackend.always({ body = "{}" }), "GET", "/api/health", nil,
                                { host = "::1" })
    t.eq(backend.requests[1].headers["host"], "[::1]:18082")
end)

t.it("sends no body headers on a GET", function()
    local _, backend = exchange(fakebackend.always({ body = "{}" }), "GET", "/api/health", nil)
    t.eq(backend.requests[1].headers["content-length"], nil)
    t.eq(backend.requests[1].headers["content-type"], nil)
end)

t.it("counts Content-Length in bytes, not characters", function()
    local payload = '{"sql":"caf\195\169"}'
    local _, backend = exchange(fakebackend.always({ body = "{}" }), "POST", "/api/execute", payload)
    t.eq(backend.requests[1].headers["content-length"], tostring(#payload))
    t.eq(backend.requests[1].body, payload)
end)

t.describe("http: responses")

t.it("reads a Content-Length body", function()
    local answer = exchange(fakebackend.always({ body = '{"ok":1}' }))
    t.eq(answer.status, 200)
    t.eq(answer.reason, "OK")
    t.eq(answer.body, '{"ok":1}')
    t.eq(answer.close, false)
end)

t.it("reads a chunked body", function()
    local body = string.rep("abcdefghij", 5)
    local answer = exchange(fakebackend.always({ body = body, chunked = true, chunksize = 7 }))
    t.eq(answer.body, body)
end)

t.it("reads a chunked body whose size line carries extensions", function()
    local raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        .. "5;name=value\r\nhello\r\n0\r\n\r\n"
    t.eq(exchange(fakebackend.always({ raw = raw })).body, "hello")
end)

t.it("reads an empty body", function()
    t.eq(exchange(fakebackend.always({ body = "" })).body, "")
end)

t.it("reads a body that runs to end of stream, and marks the socket unusable", function()
    local raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}"
    local answer = exchange(fakebackend.always({ raw = raw }))
    t.eq(answer.body, '{"a":1}')
    t.eq(answer.close, true)
end)

t.it("folds header names to lower case", function()
    -- The engine spells it `Content-length`, and the client must not care.
    local raw = "HTTP/1.1 200 OK\r\nCoNtEnT-LeNgTh: 2\r\n\r\n{}"
    local answer = exchange(fakebackend.always({ raw = raw }))
    t.eq(answer.body, "{}")
    t.eq(answer.headers["content-length"], "2")
end)

t.it("honours a Connection: close", function()
    local answer = exchange(fakebackend.always({
        body = "{}", headers = { ["Connection"] = "close" } }))
    t.eq(answer.close, true)
end)

t.it("treats HTTP/1.0 as closing", function()
    local raw = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}"
    t.eq(exchange(fakebackend.always({ raw = raw })).close, true)
end)

t.it("expects no body where the status defines none", function()
    for _, status in ipairs({ 204, 304 }) do
        local raw = string.format("HTTP/1.1 %d No Body\r\n\r\n", status)
        local answer = exchange(fakebackend.always({ raw = raw }))
        t.eq(answer.status, status)
        t.eq(answer.body, "")
    end
end)

t.it("carries a non-200 status and its body back rather than raising", function()
    -- Whether an HTTP status is a failure is the caller's decision: a 400 from
    -- the engine still carries the message that explains it.
    local answer = exchange(fakebackend.always({
        status = 400, reason = "Bad Request", body = '{"success":false}' }))
    t.eq(answer.status, 400)
    t.eq(answer.body, '{"success":false}')
end)

t.describe("http: failures")

t.it("reports a server that answers something that is not HTTP", function()
    local err = t.raises("connection", exchange,
        fakebackend.always({ raw = "<html>hello</html>\r\n\r\n" }))
    t.contains(err.message, "not HTTP")
    t.contains(err.message, "example:18082")
end)

t.it("reports a Content-Length that is not a number", function()
    local raw = "HTTP/1.1 200 OK\r\nContent-Length: many\r\n\r\n{}"
    local err = t.raises("connection", exchange, fakebackend.always({ raw = raw }))
    t.contains(err.message, "Content-Length")
end)

t.it("reports a chunk header that is not a size", function()
    local raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"
    local err = t.raises("connection", exchange, fakebackend.always({ raw = raw }))
    t.contains(err.message, "chunk header")
end)

t.it("reports a connection that dies mid-response", function()
    local raw = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort"
    local err = t.raises("connection", exchange, fakebackend.always({ raw = raw }))
    t.contains(err.message, "mid-response")
end)

t.it("reports a server that never answers, naming the deadline", function()
    local err = t.raises("connection", exchange, fakebackend.always("hang"),
                         "POST", "/api/execute", "{}", { timeout = 2500 })
    t.contains(err.message, "did not answer within")
    t.contains(err.message, "2.5s")
    t.eq(err.timeout, true)
end)

t.it("reports a server it cannot reach at all", function()
    local backend = fakebackend.new(fakebackend.always({ body = "{}" }),
                                    { refuse = "connection refused" })
    local err = t.raises("connection", http.connect, backend, config())
    t.contains(err.message, "cannot reach")
    t.contains(err.message, "connection refused")
end)

t.it("reports a write that fails", function()
    local backend = fakebackend.new(fakebackend.always({ body = "{}" }),
                                    { writefails = "broken pipe" })
    local c = config()
    local sock = http.connect(backend, c)
    local err = t.raises("connection", http.exchange, backend, sock, c,
                         "POST", "/api/execute", "{}", "test/1")
    t.contains(err.message, "cannot write")
end)

t.describe("http: deadlines")

t.it("describes a duration the way a person writes one", function()
    t.eq(http.describe(500), "500ms")
    t.eq(http.describe(1000), "1s")
    t.eq(http.describe(30000), "30s")
    t.eq(http.describe(2500), "2.5s")
end)

t.it("bounds the whole exchange, not each read", function()
    -- A server dribbling one byte at a time must not outlast the deadline by
    -- resetting a per-read timer. The scripted clock is advanced from inside
    -- the backend on every read, so the exchange runs out of budget partway
    -- through a body it is otherwise happily receiving.
    local backend = fakebackend.new(fakebackend.always({
        body = string.rep("x", 40), chunked = true, chunksize = 1 }))
    local reads = 0
    local receive = backend.receive
    backend.receive = function(sock, what)
        reads = reads + 1
        backend.now = backend.now + 0.2
        return receive(sock, what)
    end
    local c = config({ timeout = 1000 })
    local sock = http.connect(backend, c)
    local err = t.raises("connection", http.exchange, backend, sock, c,
                         "POST", "/api/execute", "{}", "test/1")
    t.contains(err.message, "did not answer within")
    t.ok(reads > 1, "it got several reads in before the deadline")
end)

t.it("does not bound an exchange whose timeout is zero", function()
    local backend = fakebackend.new(fakebackend.always({ body = "{}" }))
    backend.now = 1e9
    local c = config({ timeout = 0 })
    local sock = http.connect(backend, c)
    local answer = http.exchange(backend, sock, c, "POST", "/api/execute", "{}", "test/1")
    t.eq(answer.body, "{}")
end)
