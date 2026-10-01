-- A real DatabaseHttpServer, booted from an engine classpath for the tests that
-- need one.
--
-- Nothing here is mocked: every statement the integration tests run travels the
-- driver's own HTTP path to a live engine. Without FROSTLAKE_CLASSPATH there is
-- no server, and the tests that need one skip themselves rather than passing on
-- a stub -- a green suite that never reached an engine would be worse than a
-- skipped one.
--
-- Lua has no way to spawn a background process and keep its handle, so the JVM
-- is started by a one-shot script that writes the child's pid to a file. That
-- pid is what makes the server stoppable; `io.popen` alone would leave a JVM
-- running after the suite ended, and the next run would find its port taken and
-- its catalog full of the last run's objects.

local M = {}

local WINDOWS = package.config:sub(1, 1) == "\\"

local running = nil

function M.classpath()
    return os.getenv("FROSTLAKE_CLASSPATH")
end

-- An engine someone else is running, from FROSTLAKE_URL. Nothing is started or
-- stopped in that case: the tests point at what is already there, which is what
-- makes it possible to watch a server's own output while the corpus runs
-- against it.
function M.external()
    local url = os.getenv("FROSTLAKE_URL")
    if url and url ~= "" then return url end
    return nil
end

-- Why the engine-backed tests cannot run, or nil when they can.
function M.skipreason()
    if not M.external() and (not M.classpath() or M.classpath() == "") then
        return "neither FROSTLAKE_URL nor FROSTLAKE_CLASSPATH is set, so there is no engine"
    end
    local ok = require("frostlake.transport").detect()
    if not ok then return "no socket backend; install LuaSocket" end
    return nil
end

function M.available()
    return M.skipreason() == nil
end

local function java()
    local home = os.getenv("JAVA_HOME")
    if home and home ~= "" then
        return home .. (WINDOWS and "\\bin\\java.exe" or "/bin/java")
    end
    return "java"
end

-- Extra JVM options, space-separated, from FROSTLAKE_JAVA_OPTS. A corpus run is
-- long and creates a great many objects, so a machine that needs `-Xmx` or a
-- different collector can say so without editing this file.
local function javaoptions()
    local out = {}
    for word in (os.getenv("FROSTLAKE_JAVA_OPTS") or ""):gmatch("%S+") do
        out[#out + 1] = word
    end
    return out
end

local function tempdir()
    for _, name in ipairs({ "TMPDIR", "TEMP", "TMP" }) do
        local value = os.getenv(name)
        if value and value ~= "" then return value end
    end
    return WINDOWS and "." or "/tmp"
end

-- Binds port 0 to have the OS name a free one, then hands it straight to the
-- engine. A race is possible in principle and has never been the problem in
-- practice; a fixed port collides with a developer's own server.
local function freeport()
    local socket = require("socket")
    local probe = assert(socket.bind("127.0.0.1", 0))
    local _, port = probe:getsockname()
    probe:close()
    return tonumber(port)
end

local function writefile(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

local function readfile(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

local function mkdir(path)
    if WINDOWS then
        os.execute(string.format('mkdir "%s" 2>nul', path:gsub("/", "\\")))
    else
        os.execute(string.format("mkdir -p '%s'", path))
    end
end

-- Boots a server on a free port and waits for it to answer.
--
-- The engine keeps its catalog under ~/.frostlake_engine and its internal
-- stages under ~/.frostlake_stages, so consecutive runs would otherwise inherit
-- each other's warehouses and stages. Both are pointed at a directory of this
-- run's own, which is what makes a run repeatable -- and what keeps a corpus
-- run from colliding with account-level objects a previous one left behind.
--
-- The server is started IN that directory too. It writes its real log to
-- `db-engine.log` in whatever its working directory happens to be, and
-- inheriting the runner's would drop tens of megabytes of it into the repo --
-- and put the one file that explains a failed boot somewhere other than beside
-- the rest of that run's evidence.
function M.start()
    local classpath = M.classpath()
    if not classpath or classpath == "" then
        error("FROSTLAKE_CLASSPATH is not set", 0)
    end

    local port = freeport()
    local home = tempdir() .. (WINDOWS and "\\" or "/") .. "frostlake-lua-" .. port
    local data = home .. (WINDOWS and "\\data" or "/data")
    mkdir(data)
    local log = home .. (WINDOWS and "\\server.log" or "/server.log")
    local pidfile = home .. (WINDOWS and "\\server.pid" or "/server.pid")

    local options = javaoptions()
    local script, command
    if WINDOWS then
        local arguments = { "'-Duser.home=" .. home .. "'" }
        for _, option in ipairs(options) do
            arguments[#arguments + 1] = "'" .. option .. "'"
        end
        arguments[#arguments + 1] = "'-cp'"
        arguments[#arguments + 1] = "'" .. classpath .. "'"
        arguments[#arguments + 1] = "'dev.frostlake.http.DatabaseHttpServer'"
        arguments[#arguments + 1] = "'" .. port .. "'"

        script = home .. "\\start.ps1"
        writefile(script, table.concat({
            "$ErrorActionPreference = 'Stop'",
            "$env:SQL_ENGINE_DATA_DIR = '" .. data .. "'",
            "$p = Start-Process -FilePath '" .. java() .. "'"
                .. " -ArgumentList @(" .. table.concat(arguments, ", ") .. ")"
                .. " -WorkingDirectory '" .. home .. "'"
                .. " -RedirectStandardOutput '" .. log .. "'"
                .. " -RedirectStandardError '" .. log .. ".err'"
                .. " -PassThru -WindowStyle Hidden",
            "Set-Content -Path '" .. pidfile .. "' -Value $p.Id",
        }, "\n"))
        command = string.format(
            'powershell -NoProfile -ExecutionPolicy Bypass -File "%s" >nul 2>&1', script)
    else
        local arguments = { "'-Duser.home=" .. home .. "'" }
        for _, option in ipairs(options) do
            arguments[#arguments + 1] = "'" .. option .. "'"
        end
        script = home .. "/start.sh"
        writefile(script, table.concat({
            "#!/bin/sh",
            "cd '" .. home .. "' || exit 1",
            "SQL_ENGINE_DATA_DIR='" .. data .. "' \\",
            "  '" .. java() .. "' " .. table.concat(arguments, " ") .. " \\",
            "  -cp '" .. classpath .. "' dev.frostlake.http.DatabaseHttpServer " .. port
                .. " > '" .. log .. "' 2>&1 &",
            "echo $! > '" .. pidfile .. "'",
        }, "\n"))
        command = string.format("sh '%s'", script)
    end

    -- A real log file, not a null sink: the log is what says why a boot failed.
    os.execute(command)

    local server = {
        port = port, home = home, log = log, pidfile = pidfile,
        dsn = "frostlake://127.0.0.1:" .. port,
    }
    if not M.waituntilhealthy(server) then
        M.stop(server)
        error(string.format("the engine did not answer /api/health within 60s; see %s\n%s",
            log, (readfile(log) or ""):sub(1, 2000)), 0)
    end
    return server
end

function M.waituntilhealthy(server, seconds)
    local frostlake = require("frostlake")
    local socket = require("socket")
    local deadline = socket.gettime() + (seconds or 60)
    while socket.gettime() < deadline do
        local ok, conn = pcall(frostlake.connect, server.dsn, { connecttimeout = "5s" })
        if ok then
            conn:close()
            return true
        end
        socket.sleep(0.2)
    end
    return false
end

function M.stop(server)
    if not server then return end
    local pid = (readfile(server.pidfile) or ""):match("(%d+)")
    if not pid then return end
    if WINDOWS then
        os.execute(string.format("taskkill /F /T /PID %s >nul 2>&1", pid))
    else
        os.execute(string.format("kill -9 %s >/dev/null 2>&1", pid))
    end
end

-- One server for the whole run, started on demand -- or the one FROSTLAKE_URL
-- names, which is used as it is found and left running afterwards.
function M.shared()
    if not running then
        local url = M.external()
        if url then
            running = { dsn = url, external = true }
        else
            running = M.start()
        end
    end
    return running
end

function M.release()
    if running then
        if not running.external then M.stop(running) end
        running = nil
    end
end

return M
