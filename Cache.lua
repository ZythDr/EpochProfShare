-------------------------------------------------------------------------------
-- EpochProfShare – Cache.lua
-- Two caches:
--   1. LinkSender cache  – maps a raw |Htrade:…| link string → { sender, t }
--      so that when SetItemRef fires we can identify who sent the link.
--   2. RemoteProf cache  – stores decoded recipe lists received from remote
--      players, keyed by "<player>/<profession>".
--
-- Both caches expire stale entries automatically via Cache.Prune().
-------------------------------------------------------------------------------

local _, EPS = ...

-- ---------------------------------------------------------------------------
-- TTLs
-- ---------------------------------------------------------------------------
local LINK_TTL   = 20 * 60   -- 20 minutes: how long a link-sender entry lives
local REMOTE_TTL = 30 * 60   -- 30 minutes: how long a remote prof entry lives

-- ---------------------------------------------------------------------------
-- Internal tables
-- ---------------------------------------------------------------------------
local linkSenderCache = {}   -- [linkKey] = { sender=string, t=GetTime() }
local remoteProfCache = {}   -- ["name/profname"] = { spellIDs, rank, maxRank, hash, t }

-- ---------------------------------------------------------------------------
-- Helper: extract the stable inner |H…| key from a raw hyperlink
-- ---------------------------------------------------------------------------
local function LinkKey(rawLink)
    return rawLink:match("|H(trade:[^|]+)|h") or rawLink
end

local function ProfKey(playerName, profName)
    return (playerName or ""):lower() .. "/" .. (profName or ""):lower()
end

-- ---------------------------------------------------------------------------
-- EPS.Cache API
-- ---------------------------------------------------------------------------
EPS.Cache = {}

---Store that `sender` posted a chat message containing `rawLink`.
function EPS.Cache.StoreLinkSender(rawLink, sender)
    if not rawLink or not sender or sender == "" then return end
    linkSenderCache[LinkKey(rawLink)] = { sender = sender, t = GetTime() }
end

---Look up who sent a particular trade link.  Returns sender name or nil.
function EPS.Cache.GetLinkSender(rawLink)
    if not rawLink then return nil end
    local entry = linkSenderCache[LinkKey(rawLink)]
    if not entry then return nil end
    if GetTime() - entry.t > LINK_TTL then
        linkSenderCache[LinkKey(rawLink)] = nil
        return nil
    end
    return entry.sender
end

---Store a decoded remote profession result.
---data = { spellIDs={…}, rank=n, maxRank=n, hash="…" }
function EPS.Cache.StoreRemoteProf(playerName, profName, data)
    if not playerName or not profName or not data then return end
    remoteProfCache[ProfKey(playerName, profName)] = {
        spellIDs = data.spellIDs or {},
        rank     = data.rank     or 0,
        maxRank  = data.maxRank  or 0,
        hash     = data.hash     or "",
        t        = GetTime(),
    }
end

---Retrieve cached remote profession data.  Returns entry table or nil.
function EPS.Cache.GetRemoteProf(playerName, profName)
    if not playerName or not profName then return nil end
    local key   = ProfKey(playerName, profName)
    local entry = remoteProfCache[key]
    if not entry then return nil end
    if GetTime() - entry.t > REMOTE_TTL then
        remoteProfCache[key] = nil
        return nil
    end
    return entry
end

---Returns the hash string of cached data for player+profession, or nil.
function EPS.Cache.GetRemoteProfHash(playerName, profName)
    local entry = EPS.Cache.GetRemoteProf(playerName, profName)
    return entry and entry.hash or nil
end

---Expire stale entries from both caches.  Call every ~60 seconds.
function EPS.Cache.Prune()
    local now = GetTime()
    for k, v in pairs(linkSenderCache) do
        if now - v.t > LINK_TTL then linkSenderCache[k] = nil end
    end
    for k, v in pairs(remoteProfCache) do
        if now - v.t > REMOTE_TTL then remoteProfCache[k] = nil end
    end
end
