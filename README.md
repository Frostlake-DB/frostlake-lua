# frostlake-lua

A Lua driver for [Frostlake](https://frostlake.dev), speaking the engine's HTTP protocol against
a running `DatabaseHttpServer`. No JVM in the process, no native database library, nothing to
build.

Pure Lua apart from one thing: Lua's standard library has no sockets. That one seam is a
[pluggable transport](#the-transport) — LuaSocket by default, OpenResty's cosockets when running
inside one, or anything you pass in.

Runs on Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.

## Engine version

Requires a Frostlake engine **0.0.7 or newer**. Ask a running server which one it is with
`SELECT CURRENT_VERSION()` — every release answers it, so the check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not the jar, so
this is a floor rather than a lockstep pin.

## Install

```bash
luarocks install frostlake
```

That pulls in LuaSocket. For an `https://` DSN, add [LuaSec](https://github.com/lunarmodules/luasec)
as well (`luarocks install luasec`); it is not a hard dependency because it needs OpenSSL headers
to build and only a TLS DSN uses it.

Not published yet, so for now clone and install from the rockspec:

```bash
git clone https://github.com/Frostlake-DB/frostlake-lua.git
cd frostlake-lua
luarocks make frostlake-0.1.0-1.rockspec
```

## Usage

```lua
local frostlake = require "frostlake"

local conn = frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")

conn:execute("CREATE TABLE people (id INTEGER, name VARCHAR)")

local inserted = conn:execute("INSERT INTO people VALUES (?, ?), (?, ?)",
                              {1, "Ada", 2, "Grace"})
print(inserted.updatecount)                 --> 2

local result = conn:execute("SELECT id, name FROM people WHERE id = ?", {1})
print(result:get(1, "NAME"))                --> Ada
print(result:value())                       --> "1", a string: cells are text

conn:close()
```

`connect` contacts the server before it returns: it calls the health endpoint and applies the
scope the DSN names, so a database that does not exist is reported there rather than surfacing
later on whichever query happened to run first.

`frostlake.with` closes on the way out, however the body leaves:

```lua
local version = frostlake.with("frostlake://localhost:18082", function(conn)
    return conn:execute("SELECT CURRENT_VERSION()"):value()
end)
```

`examples/basic.lua` is a longer tour you can run against a live engine.

### DSN

```
frostlake://host[:port][/DATABASE][?param=value&…]
```

`http://` and `https://` are accepted too and mean the same thing. Omitting the port means the
engine's own default, `18082`; for `http`/`https` it means their standard ports. An IPv6 address
goes in brackets: `frostlake://[::1]:18082`.

| parameter | meaning | default |
|---|---|---|
| `schema` | schema to `USE` | — |
| `role` | role to `USE` | — |
| `warehouse` | warehouse to `USE` | — |
| `timeout` | bound on a whole request | `300s` |
| `connectTimeout` | bound on opening the socket | `10s` |
| `idleLimit` | how long a session may sit idle before its scope is reapplied | `30m` |
| `tls` | force TLS on a `frostlake://` DSN | `false` |

Durations are a bare number of seconds, or carry a unit: `30s`, `500ms`, `5m`, `1h`. Zero removes
the bound. An unknown parameter is an error rather than a shrug — a typo in `schema` or `timeout`
would otherwise change behaviour without saying so.

The server authenticates nobody, so a DSN carrying `user:password@` is refused rather than having
its credentials silently dropped.

Every parameter can also be given as an option, where it outranks the DSN:

```lua
frostlake.connect("frostlake://localhost:18082", {
    database = "MY_DB", schema = "PUBLIC",
    timeout = "60s", null = false,
})
```

Options that have no DSN spelling: `null` (below), `cacert` and `verify` (TLS), `transport`
(below), and `useragent`.

## Parameters

The HTTP protocol has no server-side binding, so the driver inlines each value as the SQL literal
that stands in for it. Lua's types say enough to do that without being told:

| Lua value | literal |
|---|---|
| `"text"` | `'text'` — quotes and backslashes doubled |
| `42`, `3.5` | `42`, `3.5` |
| `true` / `false` | `TRUE` / `FALSE` |
| `nil`, `frostlake.null` | `NULL` |

Which marker style applies is decided by the **statement**, not by the table: `?` takes a list,
`:name` takes a table keyed by name (case-insensitively).

```lua
conn:execute("SELECT * FROM t WHERE a = ? AND b = ?", {1, "x"})
conn:execute("SELECT :a + :b AS total", {a = 2, b = 40})
```

A statement mixing the two is refused, as is a count that does not line up in either direction —
a placeholder left without an argument is an error, never a silently bound `NULL`.

For the types Lua has no value for, and for the places SQL syntax needs something other than what
the Lua type implies, wrap the value:

```lua
frostlake.number("5")                  -- a numeric literal, from text
frostlake.raw("CURRENT_DATE()")        -- SQL spliced in verbatim
frostlake.binary(bytes)                -- X'…'
frostlake.date("2024-01-15")
frostlake.time("10:30:00")
frostlake.timestamp("2024-01-15 10:30:00")          -- ::TIMESTAMP_NTZ
frostlake.timestamptz("2024-01-15 10:30:00 +01:00")
frostlake.variant('{"a":1}')           -- PARSE_JSON(…)
frostlake.text(42)                     -- force a string literal
```

`frostlake.raw` is the one bind that can carry SQL syntax, and so the one that can carry an
injection. It exists because the alternative — callers splicing text into statements themselves —
is strictly worse.

For parity with the other Frostlake drivers there is also a `types` option, taking one name for
every placeholder or one per placeholder:

```lua
conn:execute("SELECT * FROM t LIMIT ?", {"5"}, {types = "number"})
```

`conn:render(sql, params)` shows what a bind produced without sending it. It holds bound values
verbatim, so a password bound into a statement appears in it in the clear.

## Results

A result is a plain value with no connection behind it: the whole grid arrives in one response,
so there is no cursor to exhaust and no order the accessors have to be called in.

```lua
local r = conn:execute("SELECT id, name FROM people ORDER BY id")

r:rowcount()            --> 2
r:names()               --> {"ID", "NAME"}
r:value()               --> the first cell of the first row
r:get(1, "NAME")        --> by row number and column name or index
r:record(1)             --> {ID = "1", NAME = "Ada"}
r:column("NAME")        --> {"Ada", "Grace"}
r:datatype("ID")        --> "NUMBER"
r.updatecount           --> rows a DML statement changed, or -1
r.counters              --> {["number of rows inserted"] = 2}

for row in r:records() do print(row.NAME) end
for cells, n in r:each() do print(n, cells[1]) end
```

`#r` is the row count on Lua 5.2 and newer; 5.1 and LuaJIT ignore a table's `__len`, so
`r:rowcount()` is the spelling that works everywhere.

`r.columns` is the full metadata, one entry per column in order:

```lua
r.columns[1]   --> {name = "ID", datatype = "NUMBER", precision = 38, scale = 0, nullable = true}
```

The engine reports a base type name with `precision` and `scale` beside it rather than folded into
the name, so `datatype` is `"NUMBER"`, not `"NUMBER(38,0)"`. `frostlake.value.basetype` strips a
`(p,s)` suffix anyway, for a query that produces one.

`conn:executeall(sql, params)` returns every result set a multi-statement request produced;
`conn:execute` hands back the first.

### Cells are text

**A cell is the engine's own text, exactly as it was sent.** Nothing is converted on the way in,
and that is deliberate.

Lua's only number is a double. Frostlake's `NUMBER(38,0)` holds values a double cannot: convert
`12345678901234567890123456789012345678` and twenty of its digits come back invented. A
`NUMBER(10,2)` holding `99.50` would lose its trailing zero. Lua also has no date, no timestamp
and no decimal type, so a temporal cell has nowhere to go that is not lossier than the text.

The converters are offered rather than applied:

```lua
frostlake.value.tonumber(cell)          -- a Lua number, or nil
frostlake.value.toboolean(cell)         -- only for "true"/"false", never for 1/0
frostlake.value.parsetimestamp(cell)    -- {year=…, month=…, nanos=…, offset=…}
frostlake.value.hextobinary(cell)       -- a byte string, for BINARY columns
frostlake.parsejson(cell)               -- a VARIANT cell as plain Lua values
frostlake.json.parse(cell)              -- the same, keeping every digit exactly
```

`frostlake.parsejson` maps JSON `null` onto `frostlake.null` too, so a value dug out of a VARIANT
compares the same way an ordinary cell does.

### NULL

SQL `NULL` comes back as `frostlake.null`, a sentinel — not `nil`.

A `nil` in the middle of a Lua list ends it. A row whose second of four columns was NULL would
read back as a one-element row, and `{1, nil, 3}` as an argument list would bind one parameter
instead of three. The sentinel is the only representation that survives both directions:

```lua
local score = r:get(1, "SCORE")
if score == frostlake.null then ... end
tostring(frostlake.null)                --> "NULL"
```

Pass `null = <your value>` to `connect` to use something else — `false`, or a string — in both
directions.

## Sessions and transactions

One connection carries one engine session, so `USE`, session variables and open transactions
persist across statements on it.

```lua
conn:begin()
conn:execute("INSERT INTO t VALUES (1)")
conn:commit()       -- or conn:rollback()

conn:transaction(function(c)
    c:execute("INSERT INTO t VALUES (2)")
end)                -- rolls back and re-raises if the body fails
```

A transaction lives on the *session*, so anything else run on the same connection meanwhile joins
it. Give a transaction its own connection if that is not what you want.

The engine reclaims a session after 30 minutes idle and then quietly builds a fresh one for the id
the driver keeps sending — losing the scope the DSN selected, with nothing in the reply to say so.
Past `idleLimit` the driver therefore reapplies the DSN's `USE` statements. It stops doing that
once you have selected a scope yourself, because putting its defaults over your choice would be
its own surprise.

## Errors

Failures are **raised**, as tables carrying a `kind` and a `message`. `pcall` hands the whole
table back rather than a line of text with a `file:line` prefix glued on:

```lua
local ok, err = pcall(conn.execute, conn, "SELECT * FROM missing")
if not ok then
    print(err.kind)         --> "query"
    print(err.message)      --> "Object 'MISSING' does not exist …"
    print(err.statement)    --> "SELECT * FROM missing"
end
```

The table has a `__tostring`, so it still prints and concatenates as a message.

| kind | meaning |
|---|---|
| `usage` | the calling code is wrong: a malformed DSN, an unknown option, a bind count that does not match. Fix the program. |
| `connection` | the server could not be reached, did not answer in time, or answered something that is not a Frostlake response. **The statement's fate is unknown** — it may well have run. |
| `query` | the engine was reached, understood the statement, and refused it. The message is the engine's own. |

`frostlake.iserror(e)` and `frostlake.iskind(e, "query")` tell one of these from anything else a
`pcall` might have caught — a bug in the driver, an out-of-memory — which should not be swallowed
as though it were a refused statement.

Errors carry a message only; the HTTP protocol has no error code or SQLSTATE.

## The transport

Everything except the byte-moving is plain Lua. The socket comes from, in order:

1. **OpenResty / ngx_lua cosockets**, when running inside one — preferred there even if LuaSocket
   is also present, because a blocking LuaSocket call inside nginx blocks the whole worker.
2. **LuaSocket**, otherwise.
3. **Whatever you pass in.**

```lua
frostlake.connect(dsn, {transport = mybackend})
```

A backend is four functions — `open`, `send`, `receive`, `close` — plus three optional ones
(`settimeout`, `gettime`, `stale`) that are filled in with no-ops when absent. `src/frostlake/transport.lua` documents the contract. That
seam is what lets a Copas or cqueues application supply a non-blocking socket, and it is how this
repo's own protocol tests run: `tests/fakebackend.lua` is a scripted backend, so the HTTP framing,
keep-alive rules, session handling and every error path are tested with no port bound and no
timing to flake on.

One connection keeps **one socket** for its whole life. A driver that opened a socket per
statement would burn an ephemeral port per statement, and a few thousand statements later start
failing on connections that have nothing to do with the query.

The `timeout` bounds the **whole exchange** — connect, write, status line, headers and body —
rather than any one read, so a server answering a byte a minute still fails when it said it would.

## Tests

```bash
lua tests/all.lua              # unit tests: no network, no engine
lua tests/all.lua bind         # only the groups whose name contains "bind"
```

The unit suite needs **no rocks at all** — not even LuaSocket — because the protocol tests run
against the scripted transport. So it is also the portability check: the same command passes on
`lua5.4` and on `luajit` with an empty `LUA_PATH`.

With an engine classpath, the same command also boots a real `DatabaseHttpServer` and runs the
engine-owned, language-neutral [testkit corpus](https://github.com/mlorek/frostlake) through
this driver:

```bash
JAVA_HOME=/path/to/jdk \
FROSTLAKE_CLASSPATH='/path/to/frostlake/lib/*' \
FROSTLAKE_TESTKIT_SUITES=/path/to/frostlake/engine/src/test/resources/testkit/suites \
lua tests/all.lua
```

That server is the run's own: a free port the OS picks, its own `SQL_ENGINE_DATA_DIR`, its own
`user.home` (so `.frostlake_engine` and `.frostlake_stages` are fresh too), and its own working
directory — all under `$TMPDIR/frostlake-lua-<port>`, and stopped when the run ends. Without that,
account-level objects — warehouses, users, compute pools, databases — outlive the per-test reset
and collide with the next run, which turns a clean sweep into hundreds of phantom failures.

Without `FROSTLAKE_CLASSPATH` the engine-backed groups **skip** rather than pass: a green suite
that never reached an engine would be worse than a missing one. Results land in
`results/testkit-lua.tsv`, and any capability the transport cannot express in
`results/missing-apis-lua.md`.

| variable | effect |
|---|---|
| `FROSTLAKE_CLASSPATH` | engine classpath; the harness boots a server of its own on a free port |
| `FROSTLAKE_URL` | use an engine that is *already* running, and leave it running — takes precedence over booting one |
| `FROSTLAKE_JAVA_OPTS` | extra JVM options for the server the harness boots |
| `FROSTLAKE_TESTKIT_SUITES` | where the corpus is |
| `FROSTLAKE_TESTKIT_FILTER` | run only the suite files whose name contains this |
| `FROSTLAKE_TESTKIT_FROM` / `_TO` | run a slice — a suite position, an exact suite name, or a name prefix |
| `FROSTLAKE_TESTKIT_SESSION` | `suite` (default), `test`, or `run` — how much session one connection spans |

`FROM`/`TO` exist so a run that lost its engine partway can be picked up where it stopped, by name:

```bash
FROSTLAKE_TESTKIT_FROM=query-composed-relational lua tests/all.lua
```

Progress lines are numbered against the whole corpus (`[470/685]`) whichever slice is running, so
they line up with the run being continued. A slice is **not** equivalent to one continuous run: the
corpus is order-sensitive, so a suite whose fixture depends on an account-level object an earlier
suite created can fail on a fresh engine. Read a slice's failures with that in mind.

If the engine stops answering partway through, the run stops after three consecutive suites that
fail purely on the transport and says so, rather than reporting several thousand cases that never
reached a server.

## Layout

| file | what it holds |
|---|---|
| `src/frostlake/init.lua` | the public API |
| `src/frostlake/connection.lua` | the connection, the session, result shaping |
| `src/frostlake/dsn.lua` | DSN parsing, identifier quoting |
| `src/frostlake/http.lua` | HTTP/1.1 framing and the exchange deadline |
| `src/frostlake/transport.lua` | socket backends and the contract they meet |
| `src/frostlake/json.lua` | JSON as a typed tree, preserving exact numeric text |
| `src/frostlake/sql.lua` | the lexical scanner both binding and scope tracking read |
| `src/frostlake/bind.lua` | client-side parameter binding |
| `src/frostlake/value.lua` | Lua values to SQL literals, and cells back |
| `src/frostlake/result.lua` | one result set |
| `src/frostlake/errors.lua` | the error taxonomy |
| `src/frostlake/compat.lua` | where 5.1 … 5.4 and LuaJIT differ |

## License

Apache 2.0. See [LICENSE](LICENSE).
