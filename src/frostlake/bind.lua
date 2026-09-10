-- Client-side parameter binding.
--
-- The HTTP protocol has no server-side binding, so parameters are inlined here
-- with the same rules Frostlake's JDBC driver uses. The scan that finds bind
-- sites is shared by counting and substitution, so the two cannot disagree
-- about what is a placeholder.
--
-- Which style a statement uses is decided by the STATEMENT, not by the shape of
-- the argument table: `?` markers take a list, `:name` markers take a table
-- keyed by name. Names match case-insensitively.

local sql = require("frostlake.sql")
local value = require("frostlake.value")
local errors = require("frostlake.errors")

local M = {}

-- Every bind site in a statement, as a list of `{start, stop, name}`: `start`
-- is the index of the marker's first byte, `stop` the index just past it, and
-- `name` the parameter's name upper-cased -- nil for a positional `?`, which no
-- name can be.
--
-- String literals, quoted identifiers, dollar-quoted bodies and comments are
-- stepped over.
function M.sites(statement)
    local out = {}
    local n = #statement
    local i = 1
    while i <= n do
        local skip = sql.skipenclosure(statement, i)
        if skip then
            i = skip
        else
            local c = statement:sub(i, i)
            if c == "?" then
                out[#out + 1] = { i, i + 1, nil }
                i = i + 1
            elseif c ~= ":" then
                i = i + 1
            else
                local next = statement:sub(i + 1, i + 1)
                if next == ":" or next == "=" then
                    -- `::` is a cast and `:=` an assignment; neither introduces
                    -- a parameter.
                    i = i + 2
                else
                    -- A colon ADJACENT to the end of an expression -- an
                    -- identifier character, a closing paren, bracket or brace,
                    -- a double or single quote, or a positional marker -- is
                    -- VARIANT path access (v:field, PARSE_JSON('...'):k,
                    -- OBJECT_CONSTRUCT(...):a, "V":k, ?:k), not a parameter: a
                    -- bind marker follows an operator, comma or keyword
                    -- boundary instead.
                    local adjacent = i > 1
                        and statement:sub(i - 1, i - 1):match('[%w_%$%)%]}"\'?]') ~= nil
                    if adjacent then
                        i = i + 1
                    else
                        local j = i + 1
                        while j <= n and statement:sub(j, j):match("[%w_%$]") do
                            j = j + 1
                        end
                        -- A leading digit means a positional reference (`:1`),
                        -- not a name.
                        if j > i + 1 and not statement:sub(i + 1, i + 1):match("%d") then
                            out[#out + 1] = { i, j, statement:sub(i + 1, j - 1):upper() }
                            i = j
                        else
                            i = i + 1
                        end
                    end
                end
            end
        end
    end
    return out
end

-- The parameter names a statement carries, upper-cased, in order of first
-- appearance.
function M.names(statement)
    local out, seen = {}, {}
    for _, site in ipairs(M.sites(statement)) do
        local name = site[3]
        if name and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

-- How many arguments a statement expects. Named placeholders count once each
-- however often they appear. A statement mixing the two styles reports -1, so a
-- caller checking the count leaves the real complaint to the substitution.
function M.count(statement)
    local positional, named = 0, 0
    local seen = {}
    for _, site in ipairs(M.sites(statement)) do
        local name = site[3]
        if not name then
            positional = positional + 1
        elseif not seen[name] then
            seen[name] = true
            named = named + 1
        end
    end
    if positional > 0 and named > 0 then return -1 end
    if named > 0 then return named end
    return positional
end

-- Splices the rendered literals in at their sites. Built back to front would
-- work too; front to back with a piece table is one pass and no index
-- arithmetic to get wrong.
local function render(statement, sites, literals)
    local pieces, n = {}, 0
    local cursor = 1
    for index, site in ipairs(sites) do
        n = n + 1
        pieces[n] = statement:sub(cursor, site[1] - 1)
        n = n + 1
        pieces[n] = literals[index]
        cursor = site[2]
    end
    n = n + 1
    pieces[n] = statement:sub(cursor)
    return table.concat(pieces)
end

-- How many placeholders of each style a statement carries, and a complaint if
-- it carries both -- `SELECT ?, :name` has no reading that is not a guess about
-- which argument goes where.
local function tally(sites)
    local positional, named = 0, 0
    for _, site in ipairs(sites) do
        if site[3] then named = named + 1 else positional = positional + 1 end
    end
    if positional > 0 and named > 0 then
        errors.usage("a statement may use ? or :name placeholders, not both")
    end
    return positional, named
end

-- Spreads a `types` option over `n` bind sites: nothing means every one is
-- decided by its Lua type, a single name applies to them all, and a list lines
-- up one to one.
local function spread(types, n)
    if types == nil then return {} end
    if type(types) == "string" then
        local out = {}
        for i = 1, n do out[i] = types end
        return out
    end
    if type(types) ~= "table" then
        errors.usage("the types option must be a type name or a list of them, got "
            .. type(types))
    end
    if #types == 0 then return {} end
    if #types ~= n then
        errors.usage(string.format(
            "the types option has %d entr%s for %d placeholder(s)",
            #types, #types == 1 and "y" or "ies", n))
    end
    return types
end

-- Inlines positional `?` placeholders. The argument count has to match in both
-- directions: a placeholder left without an argument is an error, never a
-- silently bound NULL.
function M.positional(statement, params, types, null)
    local sites = M.sites(statement)
    local _, named = tally(sites)
    if named > 0 then
        -- With no arguments at all the colon references are the SERVER's --
        -- Scripting variables (`EXECUTE IMMEDIATE :v`, `IFF(:flag, ...)`) --
        -- and the statement passes through verbatim.
        if params == nil or #params == 0 then return statement end
        errors.usage("the statement uses :name placeholders; pass a table of named"
            .. " parameters instead of a list")
    end
    -- Symmetrically, with no arguments at all the `?` marks are the SERVER's --
    -- a Scripting cursor placeholder bound by `OPEN c USING (...)`.
    local count = params and #params or 0
    if count == 0 then return statement end
    if #sites ~= count then
        errors.usage(string.format("the statement has %d placeholder(s), got %d argument(s)",
                                   #sites, count))
    end
    local kinds = spread(types, count)
    local literals = {}
    for i = 1, count do
        literals[i] = value.literal(params[i], kinds[i], null)
    end
    return render(statement, sites, literals)
end

-- Inlines `:name` placeholders. Names match case-insensitively and their order
-- does not matter. An argument that no placeholder mentions is an error rather
-- than a silent no-op -- it almost always means the name was misspelled on one
-- side or the other.
function M.named(statement, params, types, null)
    local sites = M.sites(statement)
    local positional = tally(sites)
    if positional > 0 then
        errors.usage("the statement uses positional ? placeholders; pass a list of"
            .. " parameters instead of a table of names")
    end

    local values, size = {}, 0
    for key, item in pairs(params) do
        if type(key) ~= "string" then
            errors.usage("a named parameter's key must be a string, got " .. type(key))
        end
        local folded = key:upper()
        if values[folded] ~= nil then
            -- `pairs` order is unspecified, so whichever spelling won would be a
            -- coin toss; two names that fold to one are refused instead.
            errors.usage("named parameters '" .. key .. "' and another spelling of it both name :"
                .. folded .. "; a name is matched case-insensitively")
        end
        size = size + 1
        values[folded] = item
    end

    if #sites == 0 then
        if size == 0 then return statement end
        errors.usage(string.format("the statement has no placeholders, got %d named argument(s)",
                                   size))
    end

    -- A single bare word applies to every name; otherwise `types` is a table
    -- keyed the same way the parameters are.
    local bytype = {}
    if type(types) == "string" then
        for key in pairs(values) do bytype[key] = types end
    elseif type(types) == "table" then
        for key, kind in pairs(types) do
            if type(key) ~= "string" then
                errors.usage("with :name placeholders the types option is keyed by name")
            end
            bytype[key:upper()] = kind
        end
    elseif types ~= nil then
        errors.usage("the types option must be a type name or a table of them, got "
            .. type(types))
    end

    local used, literals = {}, {}
    for index, site in ipairs(sites) do
        local name = site[3]
        -- `rawequal(nil)` rather than a truth test: an argument bound to `false`
        -- is bound, and must render as FALSE rather than be reported missing.
        if values[name] == nil then
            errors.usage("no argument bound for :" .. name:lower())
        end
        used[name] = true
        literals[index] = value.literal(values[name], bytype[name], null)
    end

    local unused = {}
    for key in pairs(values) do
        if not used[key] then unused[#unused + 1] = ":" .. key:lower() end
    end
    if #unused > 0 then
        table.sort(unused)
        errors.usage("argument(s) " .. table.concat(unused, ", ")
            .. " do not appear in the statement")
    end
    return render(statement, sites, literals)
end

-- Renders a statement with its parameters inlined.
--
-- Rendered even with no parameters, so a `?` left without an argument is
-- reported rather than sent to the engine as a literal question mark.
function M.render(statement, params, types, null)
    if params == nil then
        return M.positional(statement, nil, types, null)
    end
    if value.iswrapped(params) then
        -- A wrapper is a table, so it would otherwise be read as a parameter
        -- table whose keys are `type` and `value`.
        errors.usage("a single bound value still goes in a list: {"
            .. tostring(params) .. "}")
    end
    if type(params) ~= "table" then
        errors.usage("parameters must be a table -- a list for ? placeholders, or"
            .. " keyed by name for :name ones -- got " .. type(params))
    end
    -- A list binds positionally and a keyed table binds by name; an empty table
    -- is both, and falls to the positional path, which passes the statement
    -- through untouched.
    if #params == 0 and next(params) ~= nil then
        return M.named(statement, params, types, null)
    end
    -- A table carrying both -- `{1, 2, name = "x"}` -- would bind the list and
    -- drop the rest without a word, which is the same silent-typo failure the
    -- unused-argument check exists to prevent. Neither reading is safe to
    -- guess, so neither is guessed.
    if #params > 0 then
        local stray = {}
        for key in pairs(params) do
            if type(key) ~= "number" or key < 1 or key > #params
                or key ~= math.floor(key) then
                stray[#stray + 1] = tostring(key)
            end
        end
        if #stray > 0 then
            table.sort(stray)
            errors.usage("a parameter table is either a list, for ? placeholders, or"
                .. " keyed by name, for :name ones -- this one is a list of "
                .. #params .. " and also carries " .. table.concat(stray, ", "))
        end
    end
    -- A list, so the positional path -- which reports both a statement that
    -- wanted names and one that mixed the two styles. Deciding either of those
    -- here instead would answer "you passed a list" to a statement whose real
    -- problem is that no argument shape could satisfy it.
    return M.positional(statement, params, types, null)
end

return M
