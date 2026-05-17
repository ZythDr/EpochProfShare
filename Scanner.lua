-------------------------------------------------------------------------------
-- EpochProfShare – Scanner.lua
-- Scans the currently open trade-skill window and returns a structured table.
--
-- Uses only 3.3.5-compatible APIs:
--   GetTradeSkillLine()        → profName, type, rank, modRank, maxRank
--   GetNumTradeSkills()        → number of visible entries
--   GetTradeSkillInfo(index)   → name, type ("header"|other), …
--   GetTradeSkillRecipeLink(i) → hyperlink string  (|Henchant:ID|h…)
-------------------------------------------------------------------------------

local _, EPS = ...

-- ---------------------------------------------------------------------------
-- Internal: extract spell ID from a recipe link returned by the trade skill API
-- Recipe links in 3.3.5 look like:
--   |cff…|Henchant:12345|h[Enchant Boots - …]|h|r
-- Some professions (Inscription, etc.) may use:
--   |cff…|Hspell:12345|h[…]|h|r
-- ---------------------------------------------------------------------------
local function SpellIDFromLink(link)
    if not link then return nil end
    local id = link:match("|Henchant:(%d+)|h")
    if id then return tonumber(id) end
    id = link:match("|Hspell:(%d+)|h")
    if id then return tonumber(id) end
    return nil
end

-- Capture the real C functions once at load time.
-- UI.lua may later replace the globals temporarily during injection;
-- using these locals guarantees the scanner always reads real server data.
local _GetNumTradeSkills     = GetNumTradeSkills
local _GetTradeSkillLine     = GetTradeSkillLine
local _GetTradeSkillInfo     = GetTradeSkillInfo
local _GetTradeSkillRecipeLink = GetTradeSkillRecipeLink

-- ---------------------------------------------------------------------------
-- EPS.Scanner
-- ---------------------------------------------------------------------------
EPS.Scanner = {}

---Scan the currently open profession window.
---Returns { profName, rank, maxRank, spellIDs, entries } or nil.
function EPS.Scanner.ScanCurrentProfession()
    local numSkills = _GetNumTradeSkills()
    if not numSkills or numSkills == 0 then return nil end

    local profName, _, rank, _, maxRank = _GetTradeSkillLine()
    if not profName or profName == "UNKNOWN" then return nil end

    local spellIDs = {}   -- sorted, for hashing / SAME detection
    local entries  = {}   -- ordered {type="h"|"s", name/id}, preserves categories

    for i = 1, numSkills do
        local skillName, skillType = _GetTradeSkillInfo(i)
        if skillType == "header" then
            entries[#entries + 1] = { type = "h", name = skillName or "Unknown" }
        elseif skillName then
            local id = SpellIDFromLink(_GetTradeSkillRecipeLink(i))
            if id and id > 0 then
                entries[#entries + 1]  = { type = "s", id = id }
                spellIDs[#spellIDs + 1] = id
            end
        end
    end

    if #spellIDs == 0 then return nil end

    table.sort(spellIDs)

    return {
        profName = profName,
        rank     = rank    or 0,
        maxRank  = maxRank or 0,
        spellIDs = spellIDs,
        entries  = entries,
    }
end

---Build a short djb2-style hash of a sorted spell ID list, returned as base36.
function EPS.Scanner.BuildHash(spellIDTable)
    if not spellIDTable or #spellIDTable == 0 then return "0" end
    local h = 5381
    for _, id in ipairs(spellIDTable) do
        h = ((h * 33) + id) % 2147483647
    end
    return EPS.Encode.ToBase36(h)
end
