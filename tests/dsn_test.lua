local t = require("harness")
local dsn = require("frostlake.dsn")

t.describe("dsn: parsing")

t.it("reads host, port, database and parameters", function()
    local c = dsn.parse("frostlake://db.example:1234/SALES?schema=PUBLIC&role=ANALYST")
    t.eq(c.host, "db.example")
    t.eq(c.port, 1234)
    t.eq(c.database, "SALES")
    t.eq(c.schema, "PUBLIC")
    t.eq(c.role, "ANALYST")
    t.eq(c.secure, false)
end)

t.it("defaults the port to the engine's own for the custom scheme", function()
    t.eq(dsn.parse("frostlake://localhost").port, 18082)
end)

t.it("defaults http and https to THEIR ports, not the engine's", function()
    -- Reading 18082 into `https://h` would quietly move the DSN somewhere else.
    t.eq(dsn.parse("http://localhost").port, 80)
    t.eq(dsn.parse("https://localhost").port, 443)
end)

t.it("treats https as secure, and tls=true as the same thing", function()
    t.eq(dsn.parse("https://h/DB").secure, true)
    t.eq(dsn.parse("frostlake://h?tls=true").secure, true)
    t.eq(dsn.parse("frostlake://h?tls=false").secure, false)
end)

t.it("accepts a bracketed IPv6 address, with and without a port", function()
    local c = dsn.parse("frostlake://[::1]:18082/DB")
    t.eq(c.host, "::1")
    t.eq(c.port, 18082)
    t.eq(dsn.parse("frostlake://[2001:db8::1]").host, "2001:db8::1")
end)

t.it("percent-decodes the path and the query", function()
    local c = dsn.parse("frostlake://h/MY%20DB?schema=A%2FB")
    t.eq(c.database, "MY DB")
    t.eq(c.schema, "A/B")
end)

t.it("decodes a multi-byte character from its escapes", function()
    t.eq(dsn.parse("frostlake://h/CAF%C3%89").database, "CAF\195\137")
end)

t.it("reads durations in every form", function()
    t.eq(dsn.parse("frostlake://h?timeout=30").timeout, 30000)
    t.eq(dsn.parse("frostlake://h?timeout=30s").timeout, 30000)
    t.eq(dsn.parse("frostlake://h?timeout=500ms").timeout, 500)
    t.eq(dsn.parse("frostlake://h?timeout=5m").timeout, 300000)
    t.eq(dsn.parse("frostlake://h?timeout=1h").timeout, 3600000)
    t.eq(dsn.parse("frostlake://h?timeout=1.5s").timeout, 1500)
    t.eq(dsn.parse("frostlake://h?timeout=0").timeout, 0, "zero removes the bound")
end)

t.it("carries the defaults when nothing says otherwise", function()
    local c = dsn.parse("frostlake://h")
    t.eq(c.connecttimeout, 10000)
    t.eq(c.timeout, 300000)
    t.eq(c.idlelimit, 1800000)
    t.eq(c.database, nil)
    t.eq(c.schema, nil)
end)

t.describe("dsn: refusals")

t.it("refuses a scheme it does not speak", function()
    t.raises("usage", dsn.parse, "postgres://h/db")
    t.raises("usage", dsn.parse, "localhost:18082")
    t.raises("usage", dsn.parse, "")
end)

t.it("refuses credentials rather than dropping them silently", function()
    -- The server authenticates nobody, and silently discarding a password is
    -- worse than saying so.
    local err = t.raises("usage", dsn.parse, "frostlake://user:secret@h/db")
    t.contains(err.message, "credentials")
end)

t.it("refuses an unknown parameter", function()
    local err = t.raises("usage", dsn.parse, "frostlake://h?shema=PUBLIC")
    t.contains(err.message, "shema")
    t.contains(err.message, "schema", "the message lists what was expected")
end)

t.it("refuses an empty parameter", function()
    t.raises("usage", dsn.parse, "frostlake://h?schema=")
end)

t.it("refuses a path naming more than one database", function()
    t.raises("usage", dsn.parse, "frostlake://h/A/B")
end)

t.it("refuses a port that is not a number or not in range", function()
    t.raises("usage", dsn.parse, "frostlake://h:abc")
    t.raises("usage", dsn.parse, "frostlake://h:0")
    t.raises("usage", dsn.parse, "frostlake://h:70000")
end)

t.it("refuses an unclosed IPv6 address", function()
    t.raises("usage", dsn.parse, "frostlake://[::1/DB")
end)

t.it("refuses a duration it cannot read", function()
    t.raises("usage", dsn.parse, "frostlake://h?timeout=soon")
    t.raises("usage", dsn.parse, "frostlake://h?timeout=-5")
    t.raises("usage", dsn.parse, "frostlake://h?timeout=5d")
end)

t.it("refuses a tls flag that is not a boolean", function()
    t.raises("usage", dsn.parse, "frostlake://h?tls=maybe")
end)

t.it("refuses a missing host", function()
    t.raises("usage", dsn.parse, "frostlake:///DB")
end)

t.describe("dsn: rendering")

t.it("builds the base URL without a trailing slash", function()
    t.eq(dsn.baseurl(dsn.parse("frostlake://h:1/DB")), "http://h:1")
    t.eq(dsn.baseurl(dsn.parse("https://h/DB")), "https://h:443")
    -- An IPv6 address goes back into its brackets, or its colons would read
    -- as port separators.
    t.eq(dsn.baseurl(dsn.parse("frostlake://[::1]:18082")), "http://[::1]:18082")
    t.eq(dsn.hostport(dsn.parse("frostlake://[::1]")), "[::1]:18082")
end)

t.it("renders the scope as USE statements in dependency order", function()
    local c = dsn.parse("frostlake://h/DB?schema=S&role=R&warehouse=W")
    t.same(dsn.usestatements(c), {
        'USE ROLE "R"', 'USE WAREHOUSE "W"', 'USE DATABASE "DB"', 'USE SCHEMA "S"',
    })
end)

t.it("renders nothing for a DSN that names no scope", function()
    t.same(dsn.usestatements(dsn.parse("frostlake://h")), {})
end)

t.it("always quotes an identifier, doubling any quote inside it", function()
    t.eq(dsn.quote("NAME"), '"NAME"')
    t.eq(dsn.quote("lower"), '"lower"')
    t.eq(dsn.quote('a"b'), '"a""b"')
    t.raises("usage", dsn.quote, "")
end)

t.it("cannot be broken out of by a name from a DSN", function()
    local c = dsn.parse('frostlake://h/A%22%20OR%201%3D1%20--')
    t.eq(dsn.usestatements(c)[1], 'USE DATABASE "A"" OR 1=1 --"')
end)

t.it("names the fragment rather than blaming the scheme", function()
    local err = t.raises("usage", dsn.parse, "frostlake://h/DB#frag")
    t.contains(err.message, "fragment")
end)
