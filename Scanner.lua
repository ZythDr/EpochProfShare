local _, EPS = ...
EPS.Scanner = {}

local f = CreateFrame("Frame")
f:RegisterEvent("TRADE_SKILL_SHOW")
f:RegisterEvent("TRADE_SKILL_UPDATE")

function EPS.Scanner.ScanCurrent()
    local tradeName, currentLevel, maxLevel = GetTradeSkillLine()
    if not tradeName or tradeName == "UNKNOWN" then return end
    
    local numSkills = GetNumTradeSkills()
    if numSkills == 0 then return end
    
    local recipes = {}
    for i = 1, numSkills do
        local name, type, numAvailable, isExpanded, altVerb, numSkillUps = GetTradeSkillInfo(i)
        if type ~= "header" then
            local link = GetTradeSkillRecipeLink(i)
            if link then
                local spellID = link:match("enchant:(%d+)")
                if spellID then
                    table.insert(recipes, tonumber(spellID))
                end
            end
        end
    end
    
    if #recipes > 0 then
        if not EpochProfShareDB.MyProfessions then EpochProfShareDB.MyProfessions = {} end
        -- Use a robust hash (count of recipes for simplicity, combined with last recipe ID)
        table.sort(recipes)
        local hash = tostring(#recipes) .. "-" .. tostring(recipes[#recipes])
        EpochProfShareDB.MyProfessions[tradeName] = {
            level = currentLevel,
            maxLevel = maxLevel,
            recipes = recipes,
            hash = hash
        }
    end
end

f:SetScript("OnEvent", function(self, event)
    if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
        EPS.Scanner.ScanCurrent()
    end
end)
