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
-- EPS.Encode.EncodeEntries(entries) → string   (bd2 format)
-- entries = { {type="h", name="…"}, {type="s", id=N}, … }
-- Headers are encoded as  !SafeName  (spaces→_).
-- Spell ID deltas reset to 0 after each header so all deltas are positive.
-- Tokens are separated by "." (same as bd1 so ChunkPayload still works).
-- ---------------------------------------------------------------------------
local function EncodeEntries(entries)
    if not entries or #entries == 0 then return "" end
    local parts = {}
    local prev  = 0
    for _, e in ipairs(entries) do
        if e.type == "h" then
            -- Encode header: replace . and space (reserved chars) with _
            local safe = (e.name or "unknown"):gsub("[%. ]", "_")
            parts[#parts + 1] = "!" .. safe
            prev = 0   -- reset delta base for new category
        elseif e.type == "s" then
            local delta = e.id - prev
            if delta > 0 then
                parts[#parts + 1] = ToBase36(delta)
                prev = e.id
            end
        end
    end
    return table.concat(parts, ".")
end

-- ---------------------------------------------------------------------------
-- EPS.Encode.DecodeEntries(payload) → entries, spellIDs
-- Inverse of EncodeEntries.  Also returns a sorted spellIDs array for
-- hash verification.
-- ---------------------------------------------------------------------------
local function DecodeEntries(payload)
    local entries  = {}
    local spellIDs = {}
    if not payload or payload == "" then return entries, spellIDs end

    local prev = 0
    for token in (payload .. "."):gmatch("([^%.]+)%.") do
        if token:sub(1, 1) == "!" then
            -- Header token
            local name = token:sub(2):gsub("_", " ")
            entries[#entries + 1] = { type = "h", name = name }
            prev = 0
        else
            local delta = FromBase36(token)
            if delta and delta > 0 then
                local id = prev + delta
                entries[#entries + 1] = { type = "s", id = id }
                spellIDs[#spellIDs + 1] = id
                prev = id
            end
        end
    end
    table.sort(spellIDs)
    return entries, spellIDs
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
EPS.Encode = {
    ToBase36      = ToBase36,
    FromBase36    = FromBase36,
    CompressIDs   = CompressIDs,
    DecompressIDs = DecompressIDs,
    EncodeEntries = EncodeEntries,
    DecodeEntries = DecodeEntries,
    ChunkPayload  = ChunkPayload,
}
