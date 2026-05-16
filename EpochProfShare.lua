local _, EPS = ...
EPS.EpochProfShare = {}

local LinkCache = {}
local CACHE_EXPIRY = 1800 -- 30 minutes

local function CleanCache()
    local now = time()
    for link, data in pairs(LinkCache) do
        if now - data.time > CACHE_EXPIRY then
            LinkCache[link] = nil
        end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("CHAT_MSG_SAY")
f:RegisterEvent("CHAT_MSG_YELL")
f:RegisterEvent("CHAT_MSG_GUILD")
f:RegisterEvent("CHAT_MSG_PARTY")
f:RegisterEvent("CHAT_MSG_RAID")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("CHAT_MSG_CHANNEL")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "EpochProfShare" then
            if not EpochProfShareDB then EpochProfShareDB = {} end
            if not EpochProfShareDB.MyProfessions then EpochProfShareDB.MyProfessions = {} end
            if not EpochProfShareDB.RemoteProfessions then EpochProfShareDB.RemoteProfessions = {} end
        end
    else
        local msg, sender = ...
        if msg and sender then
            -- Find all trade links
            for link in msg:gmatch("|c%x+|Htrade:.-|h.-|h|r") do
                LinkCache[link] = {
                    sender = sender,
                    time = time()
                }
            end
        end
        CleanCache()
    end
end)

function EPS.EpochProfShare.SaveRemoteProfession(sender, tradeName, rank, maxRank, hash, recipes)
    if not EpochProfShareDB.RemoteProfessions then EpochProfShareDB.RemoteProfessions = {} end
    if not EpochProfShareDB.RemoteProfessions[sender] then EpochProfShareDB.RemoteProfessions[sender] = {} end
    
    EpochProfShareDB.RemoteProfessions[sender][tradeName] = {
        rank = rank,
        maxRank = maxRank,
        hash = hash,
        recipes = recipes,
        time = time()
    }
end

function EPS.EpochProfShare.GetCachedSenderForLink(link)
    local data = LinkCache[link]
    if data and time() - data.time <= CACHE_EXPIRY then
        return data.sender
    end
    return nil
end

local ActiveRequests = {}

local originalSetItemRef = SetItemRef
SetItemRef = function(link, text, button, chatFrame)
    if link:sub(1, 5) == "trade" then
        -- Native trade link click
        local sender = EPS.EpochProfShare.GetCachedSenderForLink(text)
        if sender and sender ~= UnitName("player") then
            -- Extract trade name
            local tradeName = text:match("|h%[(.-)%]|h") or "Unknown"
            
            -- Request from sender
            local reqId = tostring(math.random(100000, 999999))
            
            local knownHash = "none"
            if EpochProfShareDB.RemoteProfessions and EpochProfShareDB.RemoteProfessions[sender] and EpochProfShareDB.RemoteProfessions[sender][tradeName] then
                knownHash = EpochProfShareDB.RemoteProfessions[sender][tradeName].hash
            end
            
            ActiveRequests[reqId] = {
                sender = sender,
                tradeName = tradeName
            }
            
            EPS.Comm.Request(sender, tradeName, reqId, knownHash)
            
            -- Show cached immediately if exists
            if knownHash ~= "none" then
                if not EPS.UI then EPS.UI = {} end
                if EPS.UI.ShowProfession then
                    EPS.UI.ShowProfession(sender, tradeName)
                end
            end
            
            -- Let the native UI open as a fallback. We will overlay our UI if data arrives or is cached.
            return originalSetItemRef(link, text, button, chatFrame)
        end
    end
    return originalSetItemRef(link, text, button, chatFrame)
end

if not EPS.UI then EPS.UI = {} end
function EPS.UI.ShowProfessionByReqId(reqId)
    local req = ActiveRequests[reqId]
    if req and EPS.UI.ShowProfession then
        EPS.UI.ShowProfession(req.sender, req.tradeName)
    end
end
