-------------------------------------------------------------------------------
-- EpochProfShare – Encode.lua
-- Base-36 encode/decode + sorted positive delta compress/decompress.
--
-- Protocol:   bd1 = base36 positive-delta v1
-- Separator:  "." between encoded numbers
-- Example:    {61225,61327,61330,61400} → "1b8p.2u.3.1y"
-------------------------------------------------------------------------------

local _, EPS = ...

-- ---------------------------------------------------------------------------
-- Internal base-36 alphabet
-- ---------------------------------------------------------------------------
local CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
local CHAR_TO_VAL = {}
for i = 1, #CHARS do
    CHAR_TO_VAL[CHARS:sub(i, i)] = i - 1
end

-- ---------------------------------------------------------------------------
-- EPS.Encode.ToBase36(n) → string
-- Encodes a non-negative integer as a base-36 lowercase string.
-- n == 0 returns "0".
-- ---------------------------------------------------------------------------
local function ToBase36(n)
    if n == 0 then return "0" end
    local result = ""
    while n > 0 do
        local rem = n % 36
        result = CHARS:sub(rem + 1, rem + 1) .. result
        n = math.floor(n / 36)
    end
    return result
end

-- ---------------------------------------------------------------------------
-- EPS.Encode.FromBase36(s) → number
-- Decodes a base-36 string to a non-negative integer.
-- Returns 0 on empty/invalid input.
-- ---------------------------------------------------------------------------
local function FromBase36(s)
    if not s or s == "" then return 0 end
    local value = 0
    for i = 1, #s do
        local c = s:sub(i, i):lower()
        local v = CHAR_TO_VAL[c]
        if not v then return 0 end   -- bad character → corrupt payload
        value = value * 36 + v
    end
    return value
end

-- ---------------------------------------------------------------------------
-- EPS.Encode.CompressIDs(spellIDTable) → string
-- Sorts the spell IDs ascending, then encodes as:
--   base36(id0) . base36(delta1) . base36(delta2) ...
-- Returns "" for an empty table.
-- ---------------------------------------------------------------------------
local function CompressIDs(spellIDTable)
    if not spellIDTable or #spellIDTable == 0 then return "" end

    -- Make a sorted copy (never mutate the original)
    local sorted = {}
    for _, id in ipairs(spellIDTable) do
        sorted[#sorted + 1] = id
    end
    table.sort(sorted)

    local parts = {}
    local prev = 0
    for i, id in ipairs(sorted) do
        local delta = (i == 1) and id or (id - prev)
        parts[#parts + 1] = ToBase36(delta)
        prev = id
    end
    return table.concat(parts, ".")
end

-- ---------------------------------------------------------------------------
-- EPS.Encode.DecompressIDs(payload) → spellIDTable
-- Inverse of CompressIDs.  Returns an empty table on empty/bad input.
-- ---------------------------------------------------------------------------
local function DecompressIDs(payload)
    local result = {}
    if not payload or payload == "" then return result end

    local prev = 0
    local isFirst = true
    for token in (payload .. "."):gmatch("([^%.]+)%.") do
        local n = FromBase36(token)
        if isFirst then
            prev = n
            isFirst = false
        else
            prev = prev + n
        end
        result[#result + 1] = prev
    end
    return result
end

-- ---------------------------------------------------------------------------
-- EPS.Encode.ChunkPayload(payload, chunkSize) → { chunk1, chunk2, … }
-- Splits a raw string into sequential chunks no larger than chunkSize bytes.
-- ---------------------------------------------------------------------------
local function ChunkPayload(payload, chunkSize)
    local chunks = {}
    local len = #payload
    local pos = 1
    while pos <= len do
        chunks[#chunks + 1] = payload:sub(pos, pos + chunkSize - 1)
        pos = pos + chunkSize
    end
    if #chunks == 0 then chunks[1] = "" end
    return chunks
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
EPS.Encode = {
    ToBase36     = ToBase36,
    FromBase36   = FromBase36,
    CompressIDs  = CompressIDs,
    DecompressIDs = DecompressIDs,
    ChunkPayload = ChunkPayload,
}
