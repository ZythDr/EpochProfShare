local _, EPS = ...
EPS.Comm = {}

local PREFIX = "EPS"
if RegisterAddonMessagePrefix then 
    RegisterAddonMessagePrefix(PREFIX) 
end

EPS.Comm.IncomingChunks = {}

function EPS.Comm.SendChunked(target, reqId, tradeName, rank, maxRank, hash, payload)
    local len = string.len(payload)
    local maxChunkLen = 200
    local chunks = {}
    for i = 1, len, maxChunkLen do
        table.insert(chunks, string.sub(payload, i, i + maxChunkLen - 1))
    end
    
    local header = string.format("S:%s:%s:%d:%d:bd1:%d:%s", reqId, tradeName, rank, maxRank, #chunks, hash)
    SendAddonMessage(PREFIX, header, "WHISPER", target)
    
    for i, chunk in ipairs(chunks) do
        SendAddonMessage(PREFIX, string.format("D:%s:%d:%s", reqId, i, chunk), "WHISPER", target)
    end
    SendAddonMessage(PREFIX, string.format("E:%s", reqId), "WHISPER", target)
end

function EPS.Comm.Request(target, tradeName, reqId, knownHash)
    knownHash = knownHash or "none"
    SendAddonMessage(PREFIX, string.format("REQ:%s:%s:%s", reqId, tradeName, knownHash), "WHISPER", target)
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if prefix ~= PREFIX then return end
    
    local parts = {strsplit(":", msg)}
    local cmd = parts[1]
    
    if cmd == "REQ" then
        local reqId = parts[2]
        local tradeName = parts[3]
        local knownHash = parts[4]
        
        if EpochProfShareDB and EpochProfShareDB.MyProfessions and EpochProfShareDB.MyProfessions[tradeName] then
            local data = EpochProfShareDB.MyProfessions[tradeName]
            if data.hash == knownHash then
                SendAddonMessage(PREFIX, string.format("SAME:%s:%s", reqId, data.hash), "WHISPER", sender)
            else
                local payload = EPS.Encoder.EncodeRecipeList(data.recipes)
                EPS.Comm.SendChunked(sender, reqId, tradeName, data.level, data.maxLevel, data.hash, payload)
            end
        else
            SendAddonMessage(PREFIX, string.format("ERR:%s:not_found", reqId), "WHISPER", sender)
        end
    elseif cmd == "S" then
        local reqId = parts[2]
        local tradeName = parts[3]
        local rank = tonumber(parts[4])
        local maxRank = tonumber(parts[5])
        local encoding = parts[6]
        local numChunks = tonumber(parts[7])
        local hash = parts[8]
        
        EPS.Comm.IncomingChunks[reqId] = {
            tradeName = tradeName,
            rank = rank,
            maxRank = maxRank,
            numChunks = numChunks,
            hash = hash,
            sender = sender,
            chunks = {},
            receivedCount = 0
        }
    elseif cmd == "D" then
        local reqId = parts[2]
        local chunkIdx = tonumber(parts[3])
        local payload = string.sub(msg, string.len("D:" .. reqId .. ":" .. chunkIdx .. ":") + 1)
        
        local info = EPS.Comm.IncomingChunks[reqId]
        if info then
            info.chunks[chunkIdx] = payload
            info.receivedCount = info.receivedCount + 1
        end
    elseif cmd == "E" then
        local reqId = parts[2]
        local info = EPS.Comm.IncomingChunks[reqId]
        if info then
            if info.receivedCount == info.numChunks then
                local fullPayload = ""
                for i = 1, info.numChunks do
                    fullPayload = fullPayload .. (info.chunks[i] or "")
                end
                local recipes = EPS.Encoder.DecodeRecipeList(fullPayload)
                EPS.EpochProfShare.SaveRemoteProfession(info.sender, info.tradeName, info.rank, info.maxRank, info.hash, recipes)
                EPS.UI.ShowProfession(info.sender, info.tradeName)
            end
            EPS.Comm.IncomingChunks[reqId] = nil
        end
    elseif cmd == "SAME" then
        local reqId = parts[2]
        local hash = parts[3]
        EPS.UI.ShowProfessionByReqId(reqId)
    elseif cmd == "ERR" then
        -- silently fail, fallback to native window 
    end
end)
