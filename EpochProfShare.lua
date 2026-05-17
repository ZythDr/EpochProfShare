-------------------------------------------------------------------------------
-- EpochProfShare – EpochProfShare.lua
-- Main entry point.
--
-- Flow (receiver side):
--   1. Player clicks a |Htrade:spellID:rank:maxRank:playerGUID| link.
--   2. SetItemRef hook fires → extracts GUID → resolves player name via
--      GetPlayerInfoByGUID (or falls back to the chat-sender cache).
--   3. Sends an addon-message REQUEST whisper to that player.
--   4. Native TradeSkillFrame opens normally (shows the broken partial list).
--   5. When the sender's reply arrives, Comm.lua calls EPS.UI.ShowRemoteProf.
--   6. UI.lua overrides the global trade-skill API functions and refreshes
--      the native TradeSkillFrame in-place with the full recipe list.
--   7. On TRADE_SKILL_CLOSE, overrides are removed.
--   If the sender has no addon, no reply arrives and the native (broken)
--   behaviour is unchanged.
--
-- Flow (sender side):
--   1. Player opens their own profession window.
--   2. TRADE_SKILL_SHOW fires → addon scans and saves recipes to SavedVariables.
--   3. When an EPS:REQ whisper arrives, Comm.lua serves the recipe list.
-------------------------------------------------------------------------------

local addonName, EPS = ...

EPS.Encode  = EPS.Encode  or {}
EPS.Cache   = EPS.Cache   or {}
EPS.Scanner = EPS.Scanner or {}
EPS.Comm    = EPS.Comm    or {}
EPS.UI      = EPS.UI      or {}

-- ---------------------------------------------------------------------------
-- SavedVariables defaults
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    debug    = false,
    autoScan = true,
}

-- ---------------------------------------------------------------------------
-- Debug printer (used by all modules via EPS.Debug)
-- ---------------------------------------------------------------------------
function EPS.Debug(msg)
    if EPS_SavedVars and EPS_SavedVars.settings and EPS_SavedVars.settings.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6[EPS]|r " .. (msg or ""))
    end
end

-- ---------------------------------------------------------------------------
-- Chat events we listen to for the fallback link-sender cache
-- ---------------------------------------------------------------------------
local CHAT_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",  "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
}

-- ---------------------------------------------------------------------------
-- SetItemRef hook
-- Primary: parse GUID from |Htrade:spellID:rank:maxRank:playerGUID| directly.
-- Fallback: consult the chat-sender cache if GUID lookup fails.
-- ---------------------------------------------------------------------------
local _OrigSetItemRef = SetItemRef

SetItemRef = function(link, text, button, chatFrame)
    if link and link:sub(1, 6) == "trade:" then
        -- trade:spellID:rank:maxRank:playerGUID
        local spellID, rank, maxRank, guid =
            link:match("^trade:(%d+):(%d+):(%d+):(.+)$")

        local sender = nil

        -- Primary: resolve name from the GUID embedded in the link
        if guid and guid ~= "" and guid ~= "0x0000000000000000" then
            local _, _, _, _, _, name, realm = GetPlayerInfoByGUID(guid)
            if name and name ~= "" then
                sender = name
                EPS.Debug("GUID resolved: " .. guid .. " → " .. name)
            end
        end

        -- Fallback: the link string itself IS the cache key
        if not sender then
            sender = EPS.Cache.GetLinkSender(link)
            if sender then
                EPS.Debug("Cache fallback: sender=" .. sender)
            end
        end

        -- Own trade link: skip all addon logic completely, let native handle it
        local myName = UnitName("player")
        if sender and myName and sender:lower() == myName:lower() then
            EPS.Debug("Own trade link – skipping addon logic")
            return _OrigSetItemRef(link, text, button, chatFrame)
        end

        if sender and sender ~= "" then
            -- Extract profession name from the link text, e.g. "[Enchanting]"
            local profName = (text or ""):match("%[(.-)%]") or ""
            profName = profName:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|h", "")

            if profName ~= "" then
                EPS.Debug("Trade link clicked: " .. sender .. " / " .. profName)

                -- Record what we're expecting so TRADE_SKILL_SHOW can inject
                EPS.UI.pendingRemoteView = {
                    sender   = sender,
                    profName = profName,
                }

                -- Serve from cache immediately while a background refresh runs
                local cached = EPS.Cache.GetRemoteProf(sender, profName)
                if cached then
                    EPS.Debug("Cache hit – will inject when frame opens")
                    -- Injection happens in TRADE_SKILL_SHOW once the frame is ready
                end

                -- Always request (sender replies SAME if nothing changed)
                if EPS.Comm and EPS.Comm.Request then
                    EPS.Comm.Request(sender, profName)
                end

                -- Safety: if TradeSkillFrame never opens (server bug), clear
                -- pendingRemoteView after 15s so the next own-profession open
                -- isn't mistaken for a remote view.
                local clearTimer = CreateFrame("Frame")
                local clearT = 0
                clearTimer:SetScript("OnUpdate", function(self, elapsed)
                    clearT = clearT + elapsed
                    if clearT >= 15 then
                        self:SetScript("OnUpdate", nil)
                        if EPS.UI.pendingRemoteView
                            and EPS.UI.pendingRemoteView.sender == sender
                            and EPS.UI.pendingRemoteView.profName == profName then
                            EPS.UI.pendingRemoteView = nil
                            EPS.Debug("pendingRemoteView auto-expired (frame never opened)")
                        end
                    end
                end)
            end
        else
            EPS.Debug("Trade link clicked but sender unknown – native fallback")
        end
    end

    return _OrigSetItemRef(link, text, button, chatFrame)
end

-- ---------------------------------------------------------------------------
-- Main event frame
-- ---------------------------------------------------------------------------
local mainFrame = CreateFrame("Frame", "EPSMainFrame", UIParent)

-- RegisterAddonMessagePrefix was not available on all 3.3.5 private servers
if RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix("EpsProfShare")
end

mainFrame:RegisterEvent("ADDON_LOADED")
mainFrame:RegisterEvent("TRADE_SKILL_SHOW")
mainFrame:RegisterEvent("TRADE_SKILL_CLOSE")
mainFrame:RegisterEvent("CHAT_MSG_ADDON")
for _, ev in ipairs(CHAT_EVENTS) do mainFrame:RegisterEvent(ev) end

-- ---------------------------------------------------------------------------
-- Periodic pruning
-- ---------------------------------------------------------------------------
local pruneTimer = 0
mainFrame:SetScript("OnUpdate", function(self, elapsed)
    pruneTimer = pruneTimer + elapsed
    if pruneTimer >= 60 then
        pruneTimer = 0
        EPS.Cache.Prune()
        if EPS.Comm.PruneTimedOut then EPS.Comm.PruneTimedOut() end
    end
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
mainFrame:SetScript("OnEvent", function(self, event, ...)
    -- -----------------------------------------------------------------------
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= addonName then return end

        EPS_SavedVars                = EPS_SavedVars or {}
        EPS_SavedVars.settings       = EPS_SavedVars.settings  or {}
        EPS_SavedVars.localProfs     = EPS_SavedVars.localProfs or {}

        for k, v in pairs(DEFAULTS) do
            if EPS_SavedVars.settings[k] == nil then
                EPS_SavedVars.settings[k] = v
            end
        end

        local ver = GetAddOnMetadata(addonName, "Version") or "?"
        EPS.Debug("EpochProfShare v" .. ver .. " loaded.")

    -- -----------------------------------------------------------------------
    elseif event == "TRADE_SKILL_SHOW" then
        -- If we have no pending remote view, this is the player's OWN profession.
        -- Scan and save it, then return – no injection should happen.
        if not EPS.UI.pendingRemoteView then
            if EPS_SavedVars and EPS_SavedVars.settings and EPS_SavedVars.settings.autoScan then
                local result = EPS.Scanner.ScanCurrentProfession()
                if result then
                    EPS_SavedVars.localProfs[result.profName:lower()] = {
                        profName  = result.profName,
                        rank      = result.rank,
                        maxRank   = result.maxRank,
                        spellIDs  = result.spellIDs,
                        scannedAt = time(),
                    }
                    EPS.Debug("Scanned " .. result.profName .. " – " .. #result.spellIDs .. " recipes")
                end
            end
            return   -- never inject into own-profession window
        end

        -- Remote view: inject cached data (if available) once the frame has drawn.
        local pv = EPS.UI.pendingRemoteView
        local cached = EPS.Cache.GetRemoteProf(pv.sender, pv.profName)
        if cached then
            local f = CreateFrame("Frame")
            local t = 0
            f:SetScript("OnUpdate", function(self, elapsed)
                t = t + elapsed
                if t >= 0.15 then
                    self:SetScript("OnUpdate", nil)
                    EPS.UI.Inject(pv.sender, pv.profName, cached)
                end
            end)
        end
        -- No cached data: wait for Comm → ShowRemoteProf to call Inject

    -- -----------------------------------------------------------------------
    elseif event == "TRADE_SKILL_CLOSE" then
        EPS.UI.ClearInjection()
        EPS.UI.pendingRemoteView = nil

    -- -----------------------------------------------------------------------
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        EPS.Comm.OnAddonMessage(prefix, msg, channel, sender)

    -- -----------------------------------------------------------------------
    else
        -- All CHAT_MSG_* events: cache trade links → sender for fallback
        local msg    = select(1, ...)
        local sender = select(2, ...)
        if type(msg) == "string" and type(sender) == "string" and msg:find("|Htrade:", 1, true) then
            local cleanSender = sender:match("^([^-]+)") or sender
            for rawLink in msg:gmatch("|Htrade:[^|]+|h%[[^%]]*%]|h") do
                EPS.Cache.StoreLinkSender(rawLink, cleanSender)
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_EPOCHPROFSHARE1 = "/eps"
SlashCmdList["EPOCHPROFSHARE"] = function(input)
    local cmd = (input or ""):lower():match("^%s*(%S*)")

    if cmd == "debug" then
        EPS_SavedVars.settings.debug = not EPS_SavedVars.settings.debug
        DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6EpochProfShare:|r Debug " ..
            (EPS_SavedVars.settings.debug and "|cff2ecc71ON|r" or "|cffe74c3cOFF|r"))

    elseif cmd == "scan" then
        local r = EPS.Scanner.ScanCurrentProfession()
        if r then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cff9b59b6EPS:|r %s – %d recipes (%d/%d)",
                r.profName, #r.spellIDs, r.rank, r.maxRank))
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6EPS:|r No profession window open.")
        end

    elseif cmd == "profs" then
        local count = 0
        for _, v in pairs(EPS_SavedVars.localProfs or {}) do
            count = count + 1
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cff9b59b6EPS:|r  %s  %d/%d  (%d recipes)",
                v.profName or "?", v.rank or 0, v.maxRank or 0,
                v.spellIDs and #v.spellIDs or 0))
        end
        if count == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6EPS:|r No professions scanned yet.")
        end

    elseif cmd == "autoscan" then
        EPS_SavedVars.settings.autoScan = not EPS_SavedVars.settings.autoScan
        DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6EPS:|r Auto-scan " ..
            (EPS_SavedVars.settings.autoScan and "|cff2ecc71ON|r" or "|cffe74c3cOFF|r"))

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff9b59b6EpochProfShare|r – /eps <command>")
        DEFAULT_CHAT_FRAME:AddMessage("  debug · scan · profs · autoscan")
    end
end
