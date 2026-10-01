-- Runs the engine-owned, language-neutral JSON test suites through THIS driver.
--
-- The definitions live in the frostlake repo
-- (`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` next
-- to them); every statement travels connect -> HTTP -> DatabaseHttpServer. The
-- engine owns the definitions and this file is only the Lua driver's runner, so
-- suites added on the engine side are picked up here with no driver change.
--
--     FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
--     JAVA_HOME=... FROSTLAKE_CLASSPATH=... lua tests/all.lua
--
-- FL_CORPUS names that testkit directory; the suites are read from its
-- `suites`. Without FL_CORPUS the corpus skips, and without FROSTLAKE_CLASSPATH
-- every case skips -- never falsely green. FL_CORPUS naming a directory with no
-- suites fails the run. FROSTLAKE_TESTKIT_FILTER narrows the run to the suites
-- whose file name contains it.
--
-- FROSTLAKE_TESTKIT_FROM and FROSTLAKE_TESTKIT_TO run a SLICE of the corpus,
-- each a suite position, an exact suite name, or a name prefix:
--
--     FROSTLAKE_TESTKIT_FROM=query-connect-by lua tests/all.lua
--     FROSTLAKE_TESTKIT_FROM=471 FROSTLAKE_TESTKIT_TO=685 lua tests/all.lua
--
-- That exists because a run can lose its engine partway: the slice picks up
-- where the last one stopped. It is not equivalent to one continuous run --
-- the corpus is order-sensitive, so a suite whose fixture depends on an
-- account-level object an earlier suite created will fail on a fresh engine.
-- Read a slice's failures with that in mind rather than as driver defects.
--
-- Semantics (mirrors SCHEMA.md and the Go, Ruby, dotnet, Julia, Dart and Tcl
-- runners):
--
--  * backend name for a suite's skip clause: `lua`; `http` entries are honoured
--    too, because this driver rides the HTTP transport and the same engine.
--  * per-test isolation: CREATE OR REPLACE DATABASE test_db -> USE ->
--    CREATE OR REPLACE SCHEMA test_schema -> USE, then the steps, in order, on
--    ONE connection -- which is what keeps USE, variables and transactions on a
--    single session.
--  * capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT. No ERROR_CODE -- the
--    HTTP protocol carries a message only, so expected-error code/sqlState
--    checks are recorded as missing-API notes instead of failing.
--  * suite files run in name order, because the corpus is order-sensitive by
--    design: account-level objects outlive the per-test reset, so a suite whose
--    fixture does a bare CREATE WAREHOUSE has to run before the ones that
--    create the same name with IF NOT EXISTS.
--
-- FROSTLAKE_TESTKIT_SESSION picks how much session a connection spans: `suite`
-- (the default, one connection per file), `test` (one per case, the strictest
-- isolation) or `run` (one for the whole corpus, which is the harshest on
-- session leaks and the kindest to the machine's TCP ports).

local t = require("harness")
local frostlake = require("frostlake")
local json = require("frostlake.json")
local testserver = require("testserver")

local BACKEND = "lua"
local WINDOWS = package.config:sub(1, 1) == "\\"
local SEP = WINDOWS and "\\" or "/"

local kit = {
    notes = {},
    noteseen = {},
    records = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    sessionmode = os.getenv("FROSTLAKE_TESTKIT_SESSION") or "suite",
    conn = nil,
    server = nil,
}

-- ----------------------------------------------------------- locating things

-- Resolves FROSTLAKE_TESTKIT_FROM / _TO to a position in the sorted corpus. A
-- bound is a 1-based index, an exact suite name, or a name prefix -- so a run
-- can be resumed with the name of the suite it stopped on, without anyone
-- having to count files.
--
-- Answers `position` or `nil, reason`.
local function resolvebound(value, names, fallback)
    if not value or value == "" then return fallback end
    local index = tonumber(value)
    if index then
        if index ~= math.floor(index) or index < 1 or index > #names then
            return nil, string.format(
                "%s is not a suite position; the corpus has %d files", value, #names)
        end
        return index
    end
    local wanted = value:gsub("%.json$", "")
    for i, name in ipairs(names) do
        if name:gsub("%.json$", "") == wanted then return i end
    end
    for i, name in ipairs(names) do
        if name:find(wanted, 1, true) == 1 then return i end
    end
    return nil, string.format("no suite file is named or starts with %q", value)
end

-- The suite files to run, in corpus order, each carrying its position in the
-- WHOLE corpus rather than in the selection -- so `[470/685]` means the same
-- thing whether the run covers everything or a slice of it.
--
-- Answers `files, corpussize` or `nil, reason`.
local function suitefiles(directory)
    if not directory then return {}, 0 end
    local pipe = io.popen(WINDOWS
        and string.format('dir /b "%s\\*.json" 2>nul', directory:gsub("/", "\\"))
        or string.format("ls -1 '%s' 2>/dev/null", directory))
    if not pipe then return {}, 0 end
    local names = {}
    for line in pipe:lines() do
        if line:match("%.json$") then names[#names + 1] = line end
    end
    pipe:close()
    table.sort(names)
    -- No suites at all: a range has nothing to be resolved against.
    if #names == 0 then return {}, 0 end

    -- The range is resolved against the full corpus BEFORE any filtering, so
    -- the two options compose without either changing what the other means.
    local first, why = resolvebound(os.getenv("FROSTLAKE_TESTKIT_FROM"), names, 1)
    if not first then return nil, "FROSTLAKE_TESTKIT_FROM: " .. why end
    local last
    last, why = resolvebound(os.getenv("FROSTLAKE_TESTKIT_TO"), names, #names)
    if not last then return nil, "FROSTLAKE_TESTKIT_TO: " .. why end
    if first > last then
        return nil, string.format(
            "FROSTLAKE_TESTKIT_FROM (%d) is past FROSTLAKE_TESTKIT_TO (%d)", first, last)
    end

    local filter = os.getenv("FROSTLAKE_TESTKIT_FILTER")
    local out = {}
    for i = first, last do
        local name = names[i]
        if not filter or filter == "" or name:find(filter, 1, true) then
            out[#out + 1] = { path = directory .. SEP .. name,
                              name = name:gsub("%.json$", ""), index = i }
        end
    end
    return out, #names
end

-- ------------------------------------------------------------------ notes

local function note(text)
    text = text:gsub("%s+", " ")
    local line = string.format("missing-API [%s] %s", BACKEND, text)
    if not kit.noteseen[line] then
        kit.noteseen[line] = true
        kit.notes[#kit.notes + 1] = line
    end
end

-- --------------------------------------------------------------- connections

local function newconnection()
    local conn = frostlake.connect(kit.server.dsn)
    -- A case whose step holds several statements is a pack, which the engine refuses unless the
    -- session asks for one; the corpus asks for any number.
    pcall(conn.execute, conn, "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
    return conn
end

-- The connection a case runs on, per the session mode.
local function acquire()
    if kit.sessionmode == "test" then return newconnection() end
    if not kit.conn then kit.conn = newconnection() end
    return kit.conn
end

local function releasecase(conn)
    if kit.sessionmode == "test" then pcall(conn.close, conn) end
end

local function releasesuite()
    if kit.sessionmode ~= "run" and kit.conn then
        pcall(kit.conn.close, kit.conn)
        kit.conn = nil
    end
end

local function releaseall()
    if kit.conn then
        pcall(kit.conn.close, kit.conn)
        kit.conn = nil
    end
end

-- ------------------------------------------------------------------ one step

-- A client is handed a VARIANT, OBJECT or ARRAY cell as its JSON TEXT -- a
-- string's own quotes included -- which is what the account's own drivers do
-- and what a real caller should see. The suites record the VALUE instead: `a`
-- rather than `"a"`, and an object as its own text rather than as a string
-- holding that text. So a cell on one of those columns is decoded once before
-- it is compared, or the same case passes on the engine's own runner and fails
-- here over a difference nobody cares about.
local SEMISTRUCTURED = { VARIANT = true, OBJECT = true, ARRAY = true }

-- Whether a column carries semi-structured values, read from the type the
-- engine declared -- not from the cell's shape, so a VARCHAR whose content
-- happens to look like `"quoted"` keeps its quotes.
local function issemistructured(column)
    return column ~= nil and SEMISTRUCTURED[tostring(column.datatype or ""):upper()] == true
end

-- One level, and nothing else: a cell that IS a JSON string becomes that
-- string's content, which for a whole object or array is the object's own
-- text. Anything else -- a number, a boolean, text that is not JSON at all --
-- is left exactly as it came.
local function semistructuredvalue(cell)
    if type(cell) ~= "string" then return cell end
    local ok, node = pcall(json.parse, cell)
    if not ok or json.kind(node) ~= "string" then return cell end
    return json.text(node, cell)
end

-- A result's grid, with every semi-structured cell read as its value.
local function grid(outcome)
    local rows = {}
    for i, cells in ipairs(outcome.rows) do
        local row = {}
        for j = 1, #cells do
            if issemistructured(outcome.columns[j]) then
                row[j] = semistructuredvalue(cells[j])
            else
                row[j] = cells[j]
            end
        end
        rows[i] = row
    end
    return rows
end

-- What one step produced: a grid, an update count, or a failure. A transport
-- failure is distinguished from a refused statement, because SCHEMA.md's ERROR
-- status means "infrastructure", not "the engine said no".
local function runstep(conn, statement)
    local ok, outcome = pcall(conn.execute, conn, statement)
    if ok then
        return { columns = outcome:names(), rows = grid(outcome),
                 updatecount = outcome.updatecount, error = nil, broken = false }
    end
    if frostlake.iskind(outcome, "connection") then
        return { columns = {}, rows = {}, updatecount = -1,
                 error = outcome.message, broken = true }
    end
    if frostlake.iserror(outcome) then
        return { columns = {}, rows = {}, updatecount = -1,
                 error = outcome.message, broken = false }
    end
    -- Not one of the driver's errors at all: a bug in the runner or in the
    -- driver. Infrastructure, and reported as such rather than as a refusal.
    return { columns = {}, rows = {}, updatecount = -1,
             error = tostring(outcome), broken = true }
end

local RESET = {
    "CREATE OR REPLACE DATABASE test_db",
    "USE DATABASE test_db",
    "CREATE OR REPLACE SCHEMA test_schema",
    "USE SCHEMA test_schema",
}

-- The reset sequence SCHEMA.md prescribes: every case starts in an empty
-- test_db.test_schema.
local function resetcontext(conn)
    for _, statement in ipairs(RESET) do
        local outcome = runstep(conn, statement)
        if outcome.error then
            return string.format('resetContext failed on "%s": %s', statement, outcome.error),
                   outcome.broken
        end
    end
    return nil, false
end

-- ---------------------------------------------------------------- comparison

local function trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- SCHEMA.md value normalization, applied to both sides before comparing:
-- null/empty becomes NULL, booleans compare case-insensitively, anything
-- numeric compares as a number rounded to 10 significant digits, and everything
-- else is an exact trimmed string.
local function normalize(value)
    local text = trim(value)
    if text == "" then return "NULL" end
    local folded = text:lower()
    if folded == "null" then return "NULL" end
    if folded == "true" then return "TRUE" end
    if folded == "false" then return "FALSE" end
    -- Deliberately not `tonumber` alone: it reads "0x10" as 16 and "1e400" as
    -- infinity, and neither is what the engine wrote.
    if text:match("^[-+]?%d+$")
        or text:match("^[-+]?%d*%.%d+$")
        or text:match("^[-+]?%d+%.%d*$")
        or text:match("^[-+]?%d*%.?%d+[eE][-+]?%d+$") then
        local number = tonumber(text)
        -- The infinities and NaN are not numbers to round; compare them as the
        -- text they arrived as.
        if number and number == number
            and number ~= math.huge and number ~= -math.huge then
            if number == 0 then return "0" end
            return string.format("%.10g", number)
        end
    end
    return text
end

-- An expectation's scalar as text. A JSON null becomes "", which normalizes to
-- NULL -- the same place a NULL cell lands.
local function scalar(node)
    return json.text(node, "")
end

local function asinteger(node)
    local text = json.text(node, "")
    if text:match("^%-?%d+$") then return tonumber(text) end
    return nil
end

local function joinrow(cells)
    local parts = {}
    for i = 1, #cells do parts[i] = normalize(cells[i]) end
    return table.concat(parts, " | ")
end

-- Checks one step's outcome against its expectation. Answers nil when it
-- passed, or the problem.
local function check(expectation, outcome, statement)
    if json.kind(expectation) ~= "object" then
        if not outcome.error then return nil end
        return "unexpected error: " .. outcome.error
    end

    if json.exists(expectation, "error") then
        if not outcome.error then
            return "expected an error, the statement succeeded"
        end
        local expected = json.at(expectation, "error")
        if json.kind(expected) == "object" then
            if json.exists(expected, "messageContains") then
                local wanted = scalar(json.at(expected, "messageContains"))
                if not outcome.error:lower():find(wanted:lower(), 1, true) then
                    -- A blank statement is refused by the HTTP endpoint itself
                    -- -- 400, "SQL is required" -- so the engine never runs it
                    -- and never produces its own wording. No driver over this
                    -- transport can, which makes it a capability gap rather
                    -- than a mismatch. The statement did still fail.
                    if trim(statement) == "" then
                        note("EMPTY_STATEMENT: the HTTP API refuses a blank statement"
                            .. ' itself (HTTP 400 "SQL is required"), so the engine\'s'
                            .. ' own "Empty SQL statement." error cannot be observed'
                            .. " over this transport")
                        return nil
                    end
                    return string.format("the error [%s] does not contain [%s]",
                                         outcome.error, wanted)
                end
            end
            if json.exists(expected, "code") or json.exists(expected, "sqlState") then
                note("ERROR_CODE: failures carry a message only, so an error code or"
                    .. " SQLSTATE cannot be checked")
            end
        end
        return nil
    end

    if outcome.error then
        return "unexpected error: " .. outcome.error
    end

    if json.exists(expectation, "value") then
        local first = outcome.rows[1]
        local actual = first and first[1] or ""
        local wanted = scalar(json.at(expectation, "value"))
        if normalize(wanted) ~= normalize(actual) then
            return string.format("value [%s] != expected [%s]", tostring(actual), wanted)
        end
    end

    local wantedrows = json.at(expectation, "rows")
    if json.kind(wantedrows) == "array" then
        local want = {}
        for _, row in ipairs(json.items(wantedrows)) do
            if json.kind(row) == "array" then
                local cells = {}
                for i, cell in ipairs(json.items(row)) do cells[i] = scalar(cell) end
                want[#want + 1] = joinrow(cells)
            end
        end
        local got = {}
        for i, cells in ipairs(outcome.rows) do got[i] = joinrow(cells) end
        local ordered = json.boolean(json.at(expectation, "ordered")) == true
        if not ordered then
            table.sort(want)
            table.sort(got)
        end
        if #want ~= #got then
            return string.format("rows differ:\n    expected %d row(s): %s\n    got      %d row(s): %s",
                #want, table.concat(want, " / "), #got, table.concat(got, " / "))
        end
        for i = 1, #want do
            if want[i] ~= got[i] then
                return string.format("rows differ:\n    expected %s\n    got      %s",
                    table.concat(want, " / "), table.concat(got, " / "))
            end
        end
    end

    if json.exists(expectation, "rowCount") then
        local want = asinteger(json.at(expectation, "rowCount"))
        if want and #outcome.rows ~= want then
            return string.format("rowCount %d != expected %d", #outcome.rows, want)
        end
    end

    local wantedcolumns = json.at(expectation, "columns")
    if json.kind(wantedcolumns) == "array" then
        local want = {}
        for i, column in ipairs(json.items(wantedcolumns)) do
            want[i] = scalar(column):upper()
        end
        local got = {}
        for i, name in ipairs(outcome.columns) do got[i] = tostring(name):upper() end
        local same = #want == #got
        if same then
            for i = 1, #want do
                if want[i] ~= got[i] then same = false break end
            end
        end
        if not same then
            return string.format("columns [%s] != expected [%s]",
                table.concat(got, ", "), table.concat(want, ", "))
        end
    end

    if json.exists(expectation, "updateCount") then
        local want = asinteger(json.at(expectation, "updateCount"))
        if want and outcome.updatecount ~= want then
            return string.format("updateCount %d != expected %d",
                                 outcome.updatecount, want)
        end
    end

    return nil
end

-- ------------------------------------------------------------------ one case

-- A suite may declare that a backend cannot run a case.
local function skipreason(entry)
    local skip = json.at(entry, "skip")
    if json.kind(skip) ~= "object" then return nil end
    local backends = json.at(skip, "backends")
    if json.kind(backends) ~= "array" then return nil end
    local named = false
    for _, item in ipairs(json.items(backends)) do
        local name = scalar(item):lower()
        if name == BACKEND or name == "http" then named = true end
    end
    if not named then return nil end
    local reason = json.at(skip, "reason")
    local text = json.kind(reason) == "string" and reason.text or "no reason given"
    return "declared in the suite: " .. text
end

-- Runs one case. Answers `problem, broken`: a nil problem means it passed.
local function runcase(entry)
    local conn = acquire()
    local problem, broken = resetcontext(conn)
    if problem then
        releasecase(conn)
        return problem, broken
    end
    local steps = json.at(entry, "steps")
    if json.kind(steps) ~= "array" then
        releasecase(conn)
        return nil, false
    end
    for n, step in ipairs(json.items(steps)) do
        if json.kind(step) == "object" then
            local statement = json.textat(step, "sql", "")
            local outcome = runstep(conn, statement)
            if outcome.broken then
                releasecase(conn)
                return string.format("step %d: %s\n  [sql: %s]", n, outcome.error, statement),
                       true
            end
            problem = check(json.at(step, "expect"), outcome, statement)
            if problem then
                releasecase(conn)
                return string.format("step %d: %s\n  [sql: %s]", n, problem, statement), false
            end
        end
    end
    releasecase(conn)
    return nil, false
end

local function record(suite, name, status, step, detail, ms)
    kit.records[#kit.records + 1] = table.concat({
        suite, name, status, step or "",
        (detail or ""):gsub("[\n\t]", " "):gsub("\r", ""),
        tostring(ms),
    }, "\t")
end

-- ------------------------------------------------------------------ one file

-- Runs every case in one suite file, answering the list of failures.
local function runfile(file)
    local handle = assert(io.open(file.path, "rb"))
    local text = handle:read("*a")
    handle:close()

    local suite = json.parse(text)
    local cases = json.at(suite, "tests")
    if json.kind(cases) ~= "array" then return {} end

    local socket = require("socket")
    local failures = {}
    for _, entry in ipairs(json.items(cases)) do
        if json.kind(entry) == "object" then
            local casename = json.textat(entry, "name", "(unnamed)")
            local reason = skipreason(entry)
            if reason then
                kit.skipped = kit.skipped + 1
                record(file.name, casename, "SKIP", nil, reason, 0)
            else
                local started = socket.gettime()
                local ok, problem, broken = pcall(runcase, entry)
                if not ok then
                    problem, broken = "ERROR: " .. tostring(problem), true
                end
                local ms = math.floor((socket.gettime() - started) * 1000)
                if not problem then
                    kit.passed = kit.passed + 1
                    record(file.name, casename, "PASS", nil, nil, ms)
                else
                    kit.failed = kit.failed + 1
                    failures[#failures + 1] = casename .. ": " .. problem
                    record(file.name, casename, broken and "ERROR" or "FAIL",
                           problem:match("^step (%d+):"), problem, ms)
                end
            end
        end
    end
    releasesuite()
    return failures
end

local function writeresults(root)
    local directory = root .. SEP .. "results"
    if WINDOWS then
        os.execute(string.format('mkdir "%s" 2>nul', directory:gsub("/", "\\")))
    else
        os.execute(string.format("mkdir -p '%s'", directory))
    end

    local handle = io.open(directory .. SEP .. "testkit-" .. BACKEND .. ".tsv", "wb")
    if handle then
        handle:write("suite\ttest\tstatus\tfailedStep\tdetail\tms\n")
        for _, line in ipairs(kit.records) do handle:write(line, "\n") end
        handle:close()
    end

    if #kit.notes > 0 then
        handle = io.open(directory .. SEP .. "missing-apis-" .. BACKEND .. ".md", "wb")
        if handle then
            handle:write("# Missing APIs -- ", BACKEND, " backend\n\n")
            table.sort(kit.notes)
            for _, line in ipairs(kit.notes) do handle:write("- ", line, "\n") end
            handle:close()
        end
    end
end

-- ------------------------------------------------------------------- the run

t.describe("testkit suites")

-- FL_CORPUS is read first: without it nothing looks for suites or an engine.
local testkit = os.getenv("FL_CORPUS")
if not testkit or testkit == "" then
    t.skip("the canonical corpus", "set FL_CORPUS to frostlake's"
        .. " engine/src/test/resources/testkit to replay the testkit corpus")
    return
end

local directory = testkit .. SEP .. "suites"
local files, corpus = suitefiles(directory)
if corpus == 0 then
    -- Asked for and not there: a failure rather than a skip.
    t.it("the canonical corpus", function()
        t.fail("FL_CORPUS=" .. testkit .. " holds no suites/*.json; point it at"
            .. " frostlake's engine/src/test/resources/testkit")
    end)
    return
end

local reason = testserver.skipreason()

if reason then
    t.skip("the canonical corpus", reason)
elseif kit.sessionmode ~= "run" and kit.sessionmode ~= "suite"
       and kit.sessionmode ~= "test" then
    t.skip("the canonical corpus",
        "FROSTLAKE_TESTKIT_SESSION must be run, suite or test, got " .. kit.sessionmode)
else
    local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+[/\\][^/\\]+$")) or "."
    if not files then
        -- `corpus` carries the complaint when the selection could not be made.
        t.skip("the canonical corpus", corpus)
        return
    end
    io.write(string.format(
        "  running %d of %d testkit suite file(s) from %s (session per %s)\n",
        #files, corpus, directory, kit.sessionmode))
    kit.server = testserver.shared()

    -- A run that has lost its engine produces one ERROR per case for every
    -- suite left, which buries the one line that says what actually happened
    -- under thousands that do not. Past this many consecutive infrastructure
    -- failures the corpus stops and says so.
    local BROKEN_LIMIT = 3
    local broken = 0

    for _, file in ipairs(files) do
        t.it("suite " .. file.name, function()
            if broken >= BROKEN_LIMIT then
                t.fail("skipped: the engine stopped answering earlier in this run")
            end
            local failures = runfile(file)
            -- Progress, so a run of several hundred files is visibly moving.
            -- Numbered against the whole corpus, so a resumed run's positions
            -- line up with the run it is continuing.
            io.write(string.format("    [%d/%d] %-46s %s\n", file.index, corpus, file.name,
                #failures == 0 and "ok" or (#failures .. " failed")))
            if #failures > 0 then
                -- Every case in the file failing on the transport is the engine
                -- going away, not the suite being wrong.
                local infrastructure = true
                for _, failure in ipairs(failures) do
                    if not failure:find("cannot reach", 1, true)
                        and not failure:find("closed the connection", 1, true) then
                        infrastructure = false
                        break
                    end
                end
                broken = infrastructure and (broken + 1) or 0
                t.fail(table.concat(failures, "\n      "))
            else
                broken = 0
            end
        end)
    end

    -- Registered last, so it runs after every suite file above: the tally and
    -- the TSV describe the whole run rather than whatever had finished when the
    -- file was loaded.
    t.it("(tally)", function()
        releaseall()
        testserver.release()
        writeresults(root)
        io.write(string.format("  testkit: %d passed, %d failed, %d skipped\n",
                               kit.passed, kit.failed, kit.skipped))
        if #kit.notes > 0 then
            io.write(string.format("  %d missing-API note(s) recorded\n", #kit.notes))
        end
    end)
end
