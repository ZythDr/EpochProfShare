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

-- virtualList[i] = { type="server"|"addon"|"header", serverIdx=n|nil,
--                    spellID=n|nil, name=string, skillType=string }
local virtualList    = {}
local addonSpellByVI = {}   -- [virtualIndex] = spellID  (addon entries only)

-- filteredList is a subset of virtualList matching the current search text.
-- It is lazily rebuilt whenever filteredDirty is true.
local filteredList  = {}
local filteredDirty = false
local filteredText  = ""
local _savedFilterBoxScript = nil



EPS.UI = EPS.UI or {}
EPS.UI.pendingRemoteView = nil   -- { sender=str, profName=str }  set by SetItemRef hook

-- ---------------------------------------------------------------------------
-- Internal: build the merged virtual list
-- ---------------------------------------------------------------------------
local function BuildVirtualList(data)
    virtualList    = {}
    addonSpellByVI = {}

    -- bd2: entries list with headers provided by sender
    if data.entries and #data.entries > 0 then
        -- Build a set of server spell IDs for server-entry reuse
        local serverCount    = _orig_GetNumTradeSkills()
        local serverBySpell  = {}
        for i = 1, serverCount do
            local name, skillType = _orig_GetTradeSkillInfo(i)
            if skillType ~= "header" then
                local link = _orig_GetTradeSkillRecipeLink(i)
                local spID = link and (tonumber(link:match("|Henchant:(%d+)|h"))
                                   or tonumber(link:match("|Hspell:(%d+)|h"))) or nil
                if spID then serverBySpell[spID] = i end
            end
        end

        local addonOnly = 0
        for _, e in ipairs(data.entries) do
            if e.type == "h" then
                virtualList[#virtualList + 1] = {
                    type      = "header",
                    name      = e.name,
                    skillType = "header",
                }
            elseif e.type == "s" then
                local si = serverBySpell[e.id]
                if si then
                    virtualList[#virtualList + 1] = {
                        type      = "server",
                        serverIdx = si,
                        spellID   = e.id,
                        name      = (_orig_GetTradeSkillInfo(si)),
                        skillType = select(2, _orig_GetTradeSkillInfo(si)) or "nodifficulty",
                    }
                else
                    local spellName = GetSpellInfo(e.id)
                    if spellName then
                        local vi = #virtualList + 1
                        virtualList[vi] = {
                            type      = "addon",
                            spellID   = e.id,
                            name      = spellName,
                            skillType = "nodifficulty",
                        }
                        addonSpellByVI[vi] = e.id
                        addonOnly = addonOnly + 1
                    end
                end
            end
        end
        EPS.Debug(string.format("Injection (bd2): %d entries (%d addon-only) for %s",
            #virtualList, addonOnly, data.profName or "?"))

    else
        -- bd1 fallback: flat sorted spell ID list, server entries first
        local serverCount    = _orig_GetNumTradeSkills()
        local serverSpellIDs = {}
        for i = 1, serverCount do
            local name, skillType = _orig_GetTradeSkillInfo(i)
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
        local addonOnly = 0
        for _, spID in ipairs(data.spellIDs or {}) do
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
                    addonOnly = addonOnly + 1
                end
            end
        end
        EPS.Debug(string.format("Injection (bd1): %d server + %d addon-only = %d total",
            serverCount, addonOnly, #virtualList))
    end

    filteredList  = virtualList
    filteredDirty = false
    filteredText  = ""
end

-- Rebuild filteredList from virtualList based on current search text.
local function RebuildFilter()
    local text = _currentFilterText
    if text == (SEARCH or "Search") then text = "" end
    filteredText  = text
    filteredDirty = false
    if text == "" then
        filteredList = virtualList
        return
    end
    local lower = text:lower()
    local out   = {}
    for _, e in ipairs(virtualList) do
        if e.type == "header" or (e.name or ""):lower():find(lower, 1, true) then
            out[#out + 1] = e
        end
    end
    filteredList = out
end

-- Return the active (possibly filtered) list, rebuilding if dirty.
local function ActiveList()
    if filteredDirty then RebuildFilter() end
    return filteredList
end

-- ---------------------------------------------------------------------------
-- Override installation
-- ---------------------------------------------------------------------------
local _orig_SetTradeSkillItemNameFilter = SetTradeSkillItemNameFilter
local _currentFilterText = ""

local function InstallOverrides()
    filteredDirty = false
    filteredText  = ""
    filteredList  = virtualList
    _currentFilterText = ""

    -- Hook the C filter function: fires whenever the search text changes,
    -- regardless of which UI widget triggered it.
    if SetTradeSkillItemNameFilter then
        SetTradeSkillItemNameFilter = function(text)
            _currentFilterText = text or ""
            filteredDirty      = true
            if _orig_SetTradeSkillItemNameFilter then
                _orig_SetTradeSkillItemNameFilter(text)
            end
        end
    end

    -- Also hook the filter box's OnTextChanged as a belt-and-suspenders
    if TradeSkillFilterBox then
        _savedFilterBoxScript = TradeSkillFilterBox:GetScript("OnTextChanged")
        TradeSkillFilterBox:SetScript("OnTextChanged", function(self, userInput)
            _currentFilterText = self:GetText() or ""
            filteredDirty = true
            if _savedFilterBoxScript then _savedFilterBoxScript(self, userInput) end
        end)
    end

    GetNumTradeSkills = function()
        if injectionActive then return #ActiveList() end
        return _orig_GetNumTradeSkills()
    end

    GetTradeSkillInfo = function(index)
        if injectionActive then
            local e = ActiveList()[index]
            if not e then return _orig_GetTradeSkillInfo(index) end
            if e.type == "server" then
                return _orig_GetTradeSkillInfo(e.serverIdx)
            else
                return e.name, e.skillType, 0, false, 0
            end
        end
        return _orig_GetTradeSkillInfo(index)
    end

    GetTradeSkillRecipeLink = function(index)
        if injectionActive then
            local e = ActiveList()[index]
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
            local e = ActiveList()[index]
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

local function RemoveOverrides()
    GetNumTradeSkills        = _orig_GetNumTradeSkills
    GetTradeSkillInfo        = _orig_GetTradeSkillInfo
    GetTradeSkillRecipeLink  = _orig_GetTradeSkillRecipeLink
    GetTradeSkillItemLink    = _orig_GetTradeSkillItemLink
    GetTradeSkillNumReagents = _orig_GetTradeSkillNumReagents
    GetTradeSkillReagentInfo = _orig_GetTradeSkillReagentInfo
    -- Restore SetTradeSkillItemNameFilter
    if _orig_SetTradeSkillItemNameFilter then
        SetTradeSkillItemNameFilter = _orig_SetTradeSkillItemNameFilter
    end
    -- Restore the original filter box script
    if TradeSkillFilterBox and _savedFilterBoxScript ~= nil then
        TradeSkillFilterBox:SetScript("OnTextChanged", _savedFilterBoxScript)
        _savedFilterBoxScript = nil
    end
    _currentFilterText = ""
end

-- Overrides are installed dynamically inside Inject() and removed in ClearInjection().
-- Do NOT call InstallOverrides() here at load time.

-- ---------------------------------------------------------------------------
-- EPS.UI.Inject(sender, profName, data)
-- Called when we have addon recipe data and the native frame is (or will be)
-- open.  data = { spellIDs={…}, rank=n, maxRank=n }
-- ---------------------------------------------------------------------------
function EPS.UI.Inject(sender, profName, data)
    if not data or not data.spellIDs or #data.spellIDs == 0 then
        EPS.Debug("Inject: no data, skipping")
        return
    end
    if not TradeSkillFrame then
        EPS.Debug("Inject: TradeSkillFrame does not exist")
        return
    end
    if not TradeSkillFrame:IsShown() then
        EPS.Debug("Inject: TradeSkillFrame not shown, skipping")
        return
    end

    BuildVirtualList(data)

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
    else
        EPS.Debug("Inject: no known update function found")
    end

    EPS.Debug(string.format("Inject: done – %d virtual entries for %s/%s",
        #virtualList, sender or "?", profName or "?"))
end

-- ---------------------------------------------------------------------------
-- EPS.UI.ClearInjection()
-- Restore clean state when the trade skill window closes.
-- ---------------------------------------------------------------------------
function EPS.UI.ClearInjection()
    if injectionActive then
        RemoveOverrides()
        injectionActive = false
        virtualList    = {}
        addonSpellByVI = {}
        EPS.Debug("Injection cleared.")
    end
end

-- ---------------------------------------------------------------------------
-- EPS.UI.ForceInject(sender, profName, data)
-- Used when the TradeSkillFrame never opened on its own (e.g. pfQuest
-- intercepted the click and showed a tooltip instead).  We open the frame
-- ourselves, install overrides, and populate it purely from addon data.
-- ---------------------------------------------------------------------------
function EPS.UI.ForceInject(sender, profName, data)
    if not data or not data.spellIDs or #data.spellIDs == 0 then return end
    if not TradeSkillFrame then
        EPS.Debug("ForceInject: TradeSkillFrame missing")
        return
    end

    -- Build virtual list.  Server sent nothing (frame was never opened
    -- properly), so _orig_GetNumTradeSkills() returns 0; all entries come
    -- from the addon payload.
    BuildVirtualList(data)

    injectionActive = true
    InstallOverrides()

    -- Open the frame (bypasses whatever intercepted the original click)
    if ShowUIPanel then
        ShowUIPanel(TradeSkillFrame)
    else
        TradeSkillFrame:Show()
    end

    -- Patch the title text so it says the right name
    if TradeSkillFrameTitleText then
        TradeSkillFrameTitleText:SetText((sender or "?") .. "'s " .. (profName or "?"))
    end

    if TradeSkillList_Update then
        TradeSkillList_Update()
    elseif TradeSkillFrame_Update then
        TradeSkillFrame_Update()
    end

    EPS.Debug(string.format("ForceInject: %d addon-only entries for %s/%s",
        #virtualList, sender or "?", profName or "?"))
end

-- ---------------------------------------------------------------------------
-- EPS.UI.ShowRemoteProf(sender, profName, data)
-- Called by Comm.lua when a complete transfer arrives (or SAME + cache hit).
-- If the native frame is already open, inject immediately.
-- ---------------------------------------------------------------------------
function EPS.UI.ShowRemoteProf(sender, profName, data)
    if not data then return end

    if EPS.UI.pendingRemoteView
        and EPS.UI.pendingRemoteView.sender == sender
        and EPS.UI.pendingRemoteView.profName == profName then
        EPS.UI.pendingRemoteView.data = data
    end

    if TradeSkillFrame and TradeSkillFrame:IsShown() then
        EPS.UI.Inject(sender, profName, data)
        return
    end

    -- Frame not open yet.  Poll:
    --   < 1s  : wait for it to open normally (server response)
    --   >= 1s : assume another addon (e.g. pfQuest) intercepted the click;
    --           force-open the frame ourselves with our data.
    EPS.Debug("ShowRemoteProf: frame not shown, polling")
    local elapsed = 0
    local poller  = CreateFrame("Frame")
    poller:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if TradeSkillFrame and TradeSkillFrame:IsShown() then
            self:SetScript("OnUpdate", nil)
            EPS.UI.Inject(sender, profName, data)
        elseif elapsed >= 1.0 then
            self:SetScript("OnUpdate", nil)
            EPS.Debug("ShowRemoteProf: frame never opened, using ForceInject")
            EPS.UI.ForceInject(sender, profName, data)
        end
    end)
end

-- Compatibility stubs so other modules that imported EPS.UI early don't error
EPS.UI.HideRemoteProf = EPS.UI.ClearInjection
EPS.UI.IsShown        = function() return injectionActive end
