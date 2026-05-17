-------------------------------------------------------------------------------
-- EpochProfShare – UI.lua
-- Injects received remote recipe data directly into the native TradeSkillFrame.
--
-- Strategy:
--   After TRADE_SKILL_SHOW, if we have addon recipe data for the sender, we:
--     1. Read the server's (partial) recipe list via the real C functions.
--     2. Build a merged virtual list: server entries first, then addon-only
--        entries that the server failed to send.
--     3. Temporarily replace the global GetNumTradeSkills / GetTradeSkillInfo
--        / GetTradeSkillRecipeLink / GetTradeSkillItemLink /
--        GetTradeSkillNumReagents with our wrappers.
--     4. Call TradeSkillList_Update() so the native frame redraws itself using
--        our wrappers — the user sees the full recipe list with no new window.
--     5. On TRADE_SKILL_CLOSE (or when injection is cleared), restore originals.
--
-- Limitation: clicking an addon-injected recipe shows an empty detail panel
-- (no crafted item icon, no reagents) because we only transmit spell IDs.
-- The recipe NAME and icon are derived client-side from GetSpellInfo().
-------------------------------------------------------------------------------

local _, EPS = ...

-- ---------------------------------------------------------------------------
-- Saved original C functions (captured once at load time)
-- ---------------------------------------------------------------------------
local _orig_GetNumTradeSkills      = GetNumTradeSkills
local _orig_GetTradeSkillInfo      = GetTradeSkillInfo
local _orig_GetTradeSkillRecipeLink = GetTradeSkillRecipeLink
local _orig_GetTradeSkillItemLink   = GetTradeSkillItemLink
local _orig_GetTradeSkillNumReagents = GetTradeSkillNumReagents
local _orig_GetTradeSkillReagentInfo = GetTradeSkillReagentInfo

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local injectionActive = false

-- virtualList[i] = { type="server"|"addon", serverIdx=n|nil, spellID=n|nil,
--                    name=string, skillType=string }
local virtualList    = {}
local addonSpellByVI = {}   -- [virtualIndex] = spellID  (addon entries only)

EPS.UI = EPS.UI or {}
EPS.UI.pendingRemoteView = nil   -- { sender=str, profName=str }  set by SetItemRef hook

-- ---------------------------------------------------------------------------
-- Internal: build the merged virtual list
-- ---------------------------------------------------------------------------
local function BuildVirtualList(addonSpellIDs)
    virtualList    = {}
    addonSpellByVI = {}

    -- Collect everything the server sent
    local serverCount    = _orig_GetNumTradeSkills()
    local serverSpellIDs = {}

    for i = 1, serverCount do
        local name, skillType, numAvail, isExpanded = _orig_GetTradeSkillInfo(i)
        local link  = (skillType ~= "header") and _orig_GetTradeSkillRecipeLink(i) or nil
        local spID  = link and (tonumber(link:match("|Henchant:(%d+)|h"))
                             or tonumber(link:match("|Hspell:(%d+)|h"))) or nil
        if spID then serverSpellIDs[spID] = true end

        virtualList[#virtualList + 1] = {
            type      = "server",
            serverIdx = i,
            spellID   = spID,
            name      = name,
            skillType = skillType or "nodifficulty",
        }
    end

    -- Append addon-only entries (not already sent by server)
    for _, spID in ipairs(addonSpellIDs) do
        if not serverSpellIDs[spID] then
            local spellName = GetSpellInfo(spID)
            if spellName then
                local vi = #virtualList + 1
                virtualList[vi] = {
                    type      = "addon",
                    spellID   = spID,
                    name      = spellName,
                    skillType = "nodifficulty",
                }
                addonSpellByVI[vi] = spID
            end
        end
    end

    EPS.Debug(string.format("Injection: %d server + %d addon-only = %d total",
        serverCount, #virtualList - serverCount, #virtualList))
end

-- ---------------------------------------------------------------------------
-- Override installation
-- ---------------------------------------------------------------------------
local function InstallOverrides()
    GetNumTradeSkills = function()
        if injectionActive then return #virtualList end
        return _orig_GetNumTradeSkills()
    end

    GetTradeSkillInfo = function(index)
        if injectionActive then
            local e = virtualList[index]
            if not e then return _orig_GetTradeSkillInfo(index) end
            if e.type == "server" then
                return _orig_GetTradeSkillInfo(e.serverIdx)
            else
                -- Remote recipe: name from client spell DB, no difficulty color,
                -- numAvailable=0, isExpanded=false
                return e.name, e.skillType, 0, false, 0
            end
        end
        return _orig_GetTradeSkillInfo(index)
    end

    GetTradeSkillRecipeLink = function(index)
        if injectionActive then
            local e = virtualList[index]
            if not e then return _orig_GetTradeSkillRecipeLink(index) end
            if e.type == "server" then
                return _orig_GetTradeSkillRecipeLink(e.serverIdx)
            else
                return GetSpellLink(e.spellID)
            end
        end
        return _orig_GetTradeSkillRecipeLink(index)
    end

    -- GetTradeSkillItemLink: for addon entries we don't know the crafted item
    GetTradeSkillItemLink = function(index)
        if injectionActive then
            local e = virtualList[index]
            if not e then return _orig_GetTradeSkillItemLink(index) end
            if e.type == "server" then
                return _orig_GetTradeSkillItemLink(e.serverIdx)
            else
                return nil   -- no crafted-item data available
            end
        end
        return _orig_GetTradeSkillItemLink(index)
    end

    -- GetTradeSkillNumReagents: return 0 for addon entries so the detail panel
    -- doesn't try to iterate reagents with an out-of-range server index
    GetTradeSkillNumReagents = function(index)
        if injectionActive then
            local e = virtualList[index]
            if not e then return _orig_GetTradeSkillNumReagents(index) end
            if e.type == "server" then
                return _orig_GetTradeSkillNumReagents(e.serverIdx)
            else
                return 0
            end
        end
        return _orig_GetTradeSkillNumReagents(index)
    end

    GetTradeSkillReagentInfo = function(index, reagentIndex)
        if injectionActive then
            local e = virtualList[index]
            if not e then return _orig_GetTradeSkillReagentInfo(index, reagentIndex) end
            if e.type == "server" then
                return _orig_GetTradeSkillReagentInfo(e.serverIdx, reagentIndex)
            else
                return nil
            end
        end
        return _orig_GetTradeSkillReagentInfo(index, reagentIndex)
    end
end

-- ---------------------------------------------------------------------------
-- Override removal
-- ---------------------------------------------------------------------------
local function RemoveOverrides()
    GetNumTradeSkills        = _orig_GetNumTradeSkills
    GetTradeSkillInfo        = _orig_GetTradeSkillInfo
    GetTradeSkillRecipeLink  = _orig_GetTradeSkillRecipeLink
    GetTradeSkillItemLink    = _orig_GetTradeSkillItemLink
    GetTradeSkillNumReagents = _orig_GetTradeSkillNumReagents
    GetTradeSkillReagentInfo = _orig_GetTradeSkillReagentInfo
end

-- Overrides are installed dynamically inside Inject() and removed in ClearInjection().
-- Do NOT call InstallOverrides() here at load time.

-- ---------------------------------------------------------------------------
-- EPS.UI.Inject(sender, profName, data)
-- Called when we have addon recipe data and the native frame is (or will be)
-- open.  data = { spellIDs={…}, rank=n, maxRank=n }
-- ---------------------------------------------------------------------------
function EPS.UI.Inject(sender, profName, data)
    if not data or not data.spellIDs or #data.spellIDs == 0 then return end
    if not TradeSkillFrame or not TradeSkillFrame:IsShown() then return end

    BuildVirtualList(data.spellIDs)
    injectionActive = true
    InstallOverrides()   -- only active while frame is open with remote data

    -- Update the skill rank label if we have better info than the server sent
    if data.rank and data.maxRank and TradeSkillFrameSkillRankText then
        TradeSkillFrameSkillRankText:SetText(data.rank .. " / " .. data.maxRank)
    end

    -- Refresh the native list (our overrides are now in place)
    if TradeSkillList_Update then
        TradeSkillList_Update()
    elseif TradeSkillFrame_Update then
        TradeSkillFrame_Update()
    end

    EPS.Debug("Injection active for " .. (sender or "?") .. " / " .. (profName or "?"))
end

-- ---------------------------------------------------------------------------
-- EPS.UI.ClearInjection()
-- Restore clean state when the trade skill window closes.
-- ---------------------------------------------------------------------------
function EPS.UI.ClearInjection()
    if injectionActive then
        RemoveOverrides()   -- restore natives before clearing state
        injectionActive = false
        virtualList     = {}
        addonSpellByVI  = {}
        EPS.Debug("Injection cleared.")
    end
end

-- ---------------------------------------------------------------------------
-- EPS.UI.ShowRemoteProf(sender, profName, data)
-- Called by Comm.lua when a complete transfer arrives (or SAME + cache hit).
-- If the native frame is already open, inject immediately.
-- ---------------------------------------------------------------------------
function EPS.UI.ShowRemoteProf(sender, profName, data)
    if not data then return end
    EPS.UI.pendingRemoteView = { sender = sender, profName = profName, data = data }

    if TradeSkillFrame and TradeSkillFrame:IsShown() then
        EPS.UI.Inject(sender, profName, data)
    end
    -- If frame isn't open yet, injection will happen from TRADE_SKILL_SHOW
    -- (the handler is in EpochProfShare.lua)
end

-- Compatibility stubs so other modules that imported EPS.UI early don't error
EPS.UI.HideRemoteProf = EPS.UI.ClearInjection
EPS.UI.IsShown        = function() return injectionActive end
