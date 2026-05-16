-------------------------------------------------------------------------------
-- EpochProfShare – Comm.lua
-- Handles all addon message traffic over the "WHISPER" channel.
--
-- Prefix: "EpsProfShare" (max 16 chars)
--
-- Packet types (sender → receiver):
--   EPS:REQ:<reqId>:<profName>:<knownHash>
--       Receiver asks sender for their profession data.
--       knownHash is the hash of any already-cached data, or "" if none.
--
--   EPS:S:<reqId>:<profName>:<rank>:<maxRank>:bd1:<chunkCount>:<hash>
--       Sender starts a data transfer (Start packet).
--       encoding = "bd1" (base36 positive-delta v1)
--
--   EPS:D:<reqId>:<chunkIndex>:<payload>
--       Data chunk.  chunkIndex is 1-based.
--
--   EPS:E:<reqId>
--       End of transfer (all chunks sent).
--
--   EPS:SAME:<reqId>:<hash>
--       Sender's data hasn't changed; receiver may use its cached copy.
--
--   EPS:ERR:<reqId>:<reason>
--       Sender cannot fulfil the request (unknown profession, etc.).
--
-- Chunking: MAX_CHUNK_PAYLOAD bytes of raw delta-encoded payload per D packet.
-- Safe limit for addon messages is 255 bytes; after the D:<reqId>:<idx>:
-- header (~12 bytes overhead) we use 200 bytes of payload per chunk.
-------------------------------------------------------------------------------

local _, EPS = ...

local PREFIX          = "EpsProfShare"
local MAX_CHUNK_PAYLOAD = 200           -- bytes of encoded payload per chunk
local REQUEST_TIMEOUT   = 30            -- seconds to wait for a complete transfer
local MAX_PENDING       = 10            -- max simultaneous inbound transfers

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local pendingOutbound = {}    -- [reqId] = { target, profName, chunks, sent, acked }
local pendingInbound  = {}    -- [reqId] = { sender, profName, rank, maxRank,
                              --             hash, chunkCount, chunks={}, startT }

local reqCounter = 0
local function NextReqId()
    reqCounter = reqCounter + 1
    -- Include time to reduce collision chance across sessions
    return string.format("%x%x", math.floor(GetTime()) % 65536, reqCounter % 65536)
end

-- Active request tracking to prevent duplicate in-flight requests
local activeRequests = {}     -- ["sender/profName"] = reqId

-- ---------------------------------------------------------------------------
-- Internal: Send a raw addon message to a single player (whisper)
-- ---------------------------------------------------------------------------
local function SendToPlayer(target, msg)
    if not target or target == "" then return end
    -- Clamp to 255 bytes just in case
    if #msg > 255 then
        EPS.Debug("COMM: Message too long (" .. #msg .. " bytes), truncating.")
        msg = msg:sub(1, 255)
    end
    SendAddonMessage(PREFIX, msg, "WHISPER", target)
end

-- ---------------------------------------------------------------------------
-- Internal: Debug log helper
-- ---------------------------------------------------------------------------
local function Dbg(msg)
    EPS.Debug("[COMM] " .. msg)
end

-- ---------------------------------------------------------------------------
-- Timeout checker – called from the main OnUpdate ticker
-- ---------------------------------------------------------------------------
function EPS.Comm.PruneTimedOut()
    local now = GetTime()
    for reqId, state in pairs(pendingInbound) do
        if now - state.startT > REQUEST_TIMEOUT then
            Dbg("Transfer " .. reqId .. " from " .. state.sender .. " timed out, discarding.")
            pendingInbound[reqId] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- PUBLIC: EPS.Comm.Request(target, profName)
-- Send a recipe request to `target`.  Returns the reqId.
-- ---------------------------------------------------------------------------
function EPS.Comm.Request(target, profName)
    if not target or not profName then return nil end

    -- Prevent duplicate in-flight requests
    local key = (target:lower()) .. "/" .. (profName:lower())
    if activeRequests[key] then
        Dbg("Duplicate request for " .. key .. " suppressed.")
        return activeRequests[key]
    end

    local reqId     = NextReqId()
    local knownHash = EPS.Cache.GetRemoteProfHash(target, profName) or ""

    local msg = string.format("EPS:REQ:%s:%s:%s", reqId, profName, knownHash)
    Dbg("Sending REQ to " .. target .. " – " .. msg)
    SendToPlayer(target, msg)

    activeRequests[key] = reqId
    -- Clean up the active-request lock after the timeout window
    C_Timer and C_Timer.After and C_Timer.After(REQUEST_TIMEOUT + 5, function()
        if activeRequests[key] == reqId then activeRequests[key] = nil end
    end)

    return reqId
end

-- ---------------------------------------------------------------------------
-- Internal: Handle an inbound REQ – we are the sender
-- ---------------------------------------------------------------------------
local function HandleREQ(sender, reqId, profName, knownHash)
    Dbg("Got REQ from " .. sender .. " for " .. profName .. " (known=" .. knownHash .. ")")

    -- Fetch our locally scanned data from SavedVariables
    local saved = EPS_SavedVars and EPS_SavedVars.localProfs and EPS_SavedVars.localProfs[profName:lower()]
    if not saved or not saved.spellIDs or #saved.spellIDs == 0 then
        SendToPlayer(sender, string.format("EPS:ERR:%s:noprof", reqId))
        Dbg("No data for " .. profName .. ", sent ERR to " .. sender)
        return
    end

    -- If the requester already has the current data, send SAME
    local currentHash = EPS.Scanner.BuildHash(saved.spellIDs)
    if knownHash ~= "" and knownHash == currentHash then
        SendToPlayer(sender, string.format("EPS:SAME:%s:%s", reqId, currentHash))
        Dbg("Data unchanged, sent SAME to " .. sender)
        return
    end

    -- Encode and chunk
    local encoded    = EPS.Encode.CompressIDs(saved.spellIDs)
    local chunks     = EPS.Encode.ChunkPayload(encoded, MAX_CHUNK_PAYLOAD)
    local chunkCount = #chunks

    -- Start packet
    local startMsg = string.format("EPS:S:%s:%s:%d:%d:bd1:%d:%s",
        reqId, profName, saved.rank or 0, saved.maxRank or 0, chunkCount, currentHash)
    SendToPlayer(sender, startMsg)
    Dbg("Sent S to " .. sender .. " – " .. chunkCount .. " chunks")

    -- Data chunks  (small inter-chunk delay to avoid flooding)
    for i, chunk in ipairs(chunks) do
        local dataMsg = string.format("EPS:D:%s:%d:%s", reqId, i, chunk)
        SendToPlayer(sender, dataMsg)
    end

    -- End packet
    SendToPlayer(sender, string.format("EPS:E:%s", reqId))
    Dbg("Sent E to " .. sender)
end

-- ---------------------------------------------------------------------------
-- Internal: Handle S (Start) packet – we are the receiver
-- ---------------------------------------------------------------------------
local function HandleS(sender, reqId, profName, rank, maxRank, encoding, chunkCount, hash)
    if encoding ~= "bd1" then
        Dbg("Unknown encoding '" .. (encoding or "?") .. "' from " .. sender)
        return
    end
    if #pendingInbound >= MAX_PENDING then
        Dbg("Too many pending transfers, dropping from " .. sender)
        return
    end
    pendingInbound[reqId] = {
        sender     = sender,
        profName   = profName,
        rank       = tonumber(rank)       or 0,
        maxRank    = tonumber(maxRank)    or 0,
        chunkCount = tonumber(chunkCount) or 0,
        hash       = hash,
        chunks     = {},
        startT     = GetTime(),
    }
    Dbg("Transfer " .. reqId .. " started from " .. sender ..
        " – " .. (chunkCount or "?") .. " chunks for " .. profName)
end

-- ---------------------------------------------------------------------------
-- Internal: Handle D (Data) packet – we are the receiver
-- ---------------------------------------------------------------------------
local function HandleD(sender, reqId, chunkIndex, payload)
    local state = pendingInbound[reqId]
    if not state then
        Dbg("Got orphan D packet (reqId=" .. reqId .. ") from " .. sender)
        return
    end
    -- Sanity-check sender identity
    if state.sender:lower() ~= sender:lower() then return end

    local idx = tonumber(chunkIndex)
    if idx and idx >= 1 then
        state.chunks[idx] = payload or ""
    end
end

-- ---------------------------------------------------------------------------
-- Internal: Handle E (End) packet – we are the receiver
-- ---------------------------------------------------------------------------
local function HandleE(sender, reqId)
    local state = pendingInbound[reqId]
    if not state then return end
    if state.sender:lower() ~= sender:lower() then return end

    -- Verify all chunks arrived
    for i = 1, state.chunkCount do
        if not state.chunks[i] then
            Dbg("Transfer " .. reqId .. " incomplete (missing chunk " .. i .. "), discarding.")
            pendingInbound[reqId] = nil
            return
        end
    end

    -- Reassemble
    local full    = table.concat(state.chunks)
    local ids     = EPS.Encode.DecompressIDs(full)
    local hash    = EPS.Scanner.BuildHash(ids)

    -- Validate hash
    if state.hash ~= "" and hash ~= state.hash then
        Dbg("Hash mismatch for " .. reqId .. " – got " .. hash .. " expected " .. state.hash)
        pendingInbound[reqId] = nil
        return
    end

    Dbg("Transfer " .. reqId .. " complete – " .. #ids .. " recipes from " .. state.sender)

    -- Store in cache
    EPS.Cache.StoreRemoteProf(state.sender, state.profName, {
        spellIDs = ids,
        rank     = state.rank,
        maxRank  = state.maxRank,
        hash     = hash,
    })

    -- Clear active request lock
    local key = state.sender:lower() .. "/" .. state.profName:lower()
    activeRequests[key] = nil

    pendingInbound[reqId] = nil

    -- Notify UI
    if EPS.UI and EPS.UI.ShowRemoteProf then
        EPS.UI.ShowRemoteProf(state.sender, state.profName, {
            spellIDs = ids,
            rank     = state.rank,
            maxRank  = state.maxRank,
            hash     = hash,
        })
    end
end

-- ---------------------------------------------------------------------------
-- Internal: Handle SAME – receiver can use cached copy
-- ---------------------------------------------------------------------------
local function HandleSAME(sender, reqId, hash)
    Dbg("SAME from " .. sender .. " (hash=" .. hash .. ")")

    -- Find which profession this reqId was for
    -- We stored it in activeRequests with "sender/profName"
    local profName
    for k, v in pairs(activeRequests) do
        if v == reqId then
            profName = k:match("/(.+)$")
            activeRequests[k] = nil
            break
        end
    end
    if not profName then return end

    local cached = EPS.Cache.GetRemoteProf(sender, profName)
    if cached then
        Dbg("Using cached data for " .. sender .. "/" .. profName)
        if EPS.UI and EPS.UI.ShowRemoteProf then
            EPS.UI.ShowRemoteProf(sender, profName, cached)
        end
    else
        Dbg("SAME but no cache for " .. sender .. "/" .. profName)
    end
end

-- ---------------------------------------------------------------------------
-- Internal: Handle ERR
-- ---------------------------------------------------------------------------
local function HandleERR(sender, reqId, reason)
    Dbg("ERR from " .. sender .. " (reqId=" .. reqId .. "): " .. (reason or "?"))
    -- Clean up active request lock
    for k, v in pairs(activeRequests) do
        if v == reqId then activeRequests[k] = nil; break end
    end
    -- Silent failure – do nothing else; native window remains open
end

-- ---------------------------------------------------------------------------
-- Main dispatch: called from the CHAT_MSG_ADDON event
-- ---------------------------------------------------------------------------
function EPS.Comm.OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX then return end
    if not msg or msg == "" then return end

    -- Remove server suffix (Name-Realm → Name)
    local cleanSender = sender and sender:match("^([^-]+)") or sender

    -- Route by packet type
    -- EPS:REQ:<reqId>:<profName>:<knownHash>
    local reqId, rest = msg:match("^EPS:REQ:([^:]+):(.+)$")
    if reqId then
        local profName, knownHash = rest:match("^([^:]+):(.*)$")
        HandleREQ(cleanSender, reqId, profName or rest, knownHash or "")
        return
    end

    -- EPS:S:<reqId>:<profName>:<rank>:<maxRank>:<encoding>:<chunkCount>:<hash>
    local s_reqId, s_profName, s_rank, s_maxRank, s_enc, s_cnt, s_hash =
        msg:match("^EPS:S:([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)$")
    if s_reqId then
        HandleS(cleanSender, s_reqId, s_profName, s_rank, s_maxRank, s_enc, s_cnt, s_hash)
        return
    end

    -- EPS:D:<reqId>:<chunkIndex>:<payload>
    -- payload may contain no colons
    local d_reqId, d_idx, d_payload = msg:match("^EPS:D:([^:]+):([^:]+):(.*)$")
    if d_reqId then
        HandleD(cleanSender, d_reqId, d_idx, d_payload)
        return
    end

    -- EPS:E:<reqId>
    local e_reqId = msg:match("^EPS:E:([^:]+)$")
    if e_reqId then
        HandleE(cleanSender, e_reqId)
        return
    end

    -- EPS:SAME:<reqId>:<hash>
    local sm_reqId, sm_hash = msg:match("^EPS:SAME:([^:]+):(.+)$")
    if sm_reqId then
        HandleSAME(cleanSender, sm_reqId, sm_hash)
        return
    end

    -- EPS:ERR:<reqId>:<reason>
    local er_reqId, er_reason = msg:match("^EPS:ERR:([^:]+):(.+)$")
    if er_reqId then
        HandleERR(cleanSender, er_reqId, er_reason)
        return
    end

    Dbg("Unrecognised packet from " .. (cleanSender or "?") .. ": " .. msg:sub(1, 60))
end

-- ---------------------------------------------------------------------------
-- Namespace guard / init
-- ---------------------------------------------------------------------------
EPS.Comm = EPS.Comm or {}
EPS.Comm.Request        = EPS.Comm.Request        or function() end
EPS.Comm.OnAddonMessage = EPS.Comm.OnAddonMessage or function() end
EPS.Comm.PruneTimedOut  = EPS.Comm.PruneTimedOut  or function() end
