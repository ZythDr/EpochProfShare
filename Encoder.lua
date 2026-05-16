local _, EPS = ...

EPS.Encoder = {}

local BASE36_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
local charToBase36 = {}
for i = 1, 36 do
    charToBase36[BASE36_CHARS:sub(i, i)] = i - 1
end

function EPS.Encoder.ToBase36(num)
    if num == 0 then return "0" end
    local res = ""
    while num > 0 do
        local rem = num % 36
        res = BASE36_CHARS:sub(rem + 1, rem + 1) .. res
        num = math.floor(num / 36)
    end
    return res
end

function EPS.Encoder.FromBase36(str)
    local num = 0
    for i = 1, #str do
        local char = str:sub(i, i)
        if not charToBase36[char] then return 0 end -- Safe fallback
        num = num * 36 + charToBase36[char]
    end
    return num
end

function EPS.Encoder.EncodeRecipeList(recipeIDs)
    if not recipeIDs or #recipeIDs == 0 then return "" end
    
    -- Ensure array is sorted
    table.sort(recipeIDs)
    
    local encoded = {}
    table.insert(encoded, EPS.Encoder.ToBase36(recipeIDs[1]))
    
    for i = 2, #recipeIDs do
        local delta = recipeIDs[i] - recipeIDs[i - 1]
        table.insert(encoded, EPS.Encoder.ToBase36(delta))
    end
    
    return table.concat(encoded, ".")
end

function EPS.Encoder.DecodeRecipeList(encodedStr)
    if not encodedStr or encodedStr == "" then return {} end
    
    local parts = {strsplit(".", encodedStr)}
    local recipeIDs = {}
    
    if #parts > 0 then
        local currentID = EPS.Encoder.FromBase36(parts[1])
        table.insert(recipeIDs, currentID)
        
        for i = 2, #parts do
            currentID = currentID + EPS.Encoder.FromBase36(parts[i])
            table.insert(recipeIDs, currentID)
        end
    end
    
    return recipeIDs
end
