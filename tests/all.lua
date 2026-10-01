-- Runs the whole suite.
--
--     lua tests/all.lua                     the unit tests
--     JAVA_HOME=... FROSTLAKE_CLASSPATH=... lua tests/all.lua
--                                           those, plus a real engine
--     FL_CORPUS=.../testkit JAVA_HOME=... FROSTLAKE_CLASSPATH=... lua tests/all.lua
--                                           and the language-neutral testkit
--                                           corpus from that directory
--
--     lua tests/all.lua bind                only the groups whose name contains
--                                           "bind"
--
-- Without FROSTLAKE_CLASSPATH the engine-backed groups SKIP rather than pass:
-- a green suite that never reached an engine would be worse than a missing one.

local here = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$") or "tests"
local root = here:match("^(.*)[/\\][^/\\]+$") or "."

package.path = table.concat({
    root .. "/src/?.lua",
    root .. "/src/?/init.lua",
    here .. "/?.lua",
    package.path,
}, ";")

-- Line-buffered, so a long corpus run reports progress as it happens rather
-- than in one block at the end. Redirected output is block-buffered by default,
-- which makes a run that stalls indistinguishable from one that is working.
io.stdout:setvbuf("line")

local harness = require("harness")

local FILES = {
    "json_test", "dsn_test", "sql_test", "value_test", "bind_test",
    "result_test", "http_test", "connection_test", "session_test",
}

for _, name in ipairs(FILES) do
    require(name)
end

-- The corpus runner is optional. It needs things the unit tests do not -- the
-- engine-owned suite files, and a classpath to boot a server from -- so a
-- checkout without it should still run everything else rather than die on a
-- missing module. A file that IS present and broken still raises, which is the
-- distinction worth keeping: absent is fine, unloadable is not.
-- `package.searchpath` would be the tidy test, but Lua 5.1 and some LuaJIT
-- builds do not have it, and a missing `searchpath` would silently skip a
-- runner that IS there. Asking `require` and reading its complaint works
-- everywhere.
local ok, why = pcall(require, "suites_test")
if not ok and not tostring(why):find("module 'suites_test' not found", 1, true) then
    error(why, 0)
end

harness.run(arg and arg[1] or nil)
-- A server the run started is stopped however the run was narrowed: the corpus
-- tally stops it too, but a filter can leave that case out.
pcall(function() require("testserver").release() end)
os.exit(harness.report())
