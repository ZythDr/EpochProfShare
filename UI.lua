local _, EPS = ...
EPS.UI = EPS.UI or {}

local mainFrame = nil

local function CreateUI()
    if mainFrame then return end
    
    mainFrame = CreateFrame("Frame", "EpochProfShareFrame", UIParent, "UIPanelDialogTemplate")
    mainFrame:SetSize(384, 512)
    mainFrame:SetPoint("CENTER")
    mainFrame:Hide()
    mainFrame:EnableMouse(true)
    mainFrame:SetMovable(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    
    mainFrame.Title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mainFrame.Title:SetPoint("TOP", 0, -14)
    mainFrame.Title:SetText("Remote Profession")
    
    mainFrame.Rank = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.Rank:SetPoint("TOP", 0, -32)
    
    local scrollFrame = CreateFrame("ScrollFrame", "EpochProfShareScrollFrame", mainFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 22, -75)
    scrollFrame:SetPoint("BOTTOMRIGHT", -44, 40)
    
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(318, 400)
    scrollFrame:SetScrollChild(content)
    mainFrame.Content = content
    mainFrame.ScrollFrame = scrollFrame
    
    mainFrame.Buttons = {}
end

local function GetRecipeLink(spellID)
    local name, rank, icon, castTime, minRange, maxRange, spellId = GetSpellInfo(spellID)
    return name, icon
end

function EPS.UI.ShowProfession(sender, tradeName)
    CreateUI()
    
    local data = EpochProfShareDB.RemoteProfessions and EpochProfShareDB.RemoteProfessions[sender] and EpochProfShareDB.RemoteProfessions[sender][tradeName]
    if not data then return end
    
    mainFrame.Title:SetText(sender .. "'s " .. tradeName)
    mainFrame.Rank:SetText("Skill: " .. data.rank .. " / " .. data.maxRank)
    
    -- Clear old buttons
    for _, btn in ipairs(mainFrame.Buttons) do
        btn:Hide()
    end
    
    local recipes = data.recipes or {}
    local yOffset = 0
    
    for i, spellID in ipairs(recipes) do
        local btn = mainFrame.Buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, mainFrame.Content)
            btn:SetSize(300, 20)
            
            local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            text:SetPoint("LEFT", 20, 0)
            btn.Text = text
            
            local icon = btn:CreateTexture(nil, "OVERLAY")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", 0, 0)
            btn.Icon = icon
            
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            
            btn:SetScript("OnEnter", function(self)
                if self.spellID then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetSpellByID(self.spellID)
                    GameTooltip:Show()
                end
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            
            table.insert(mainFrame.Buttons, btn)
        end
        
        local name, iconTex = GetRecipeLink(spellID)
        btn.Text:SetText(name or ("Unknown Recipe ("..spellID..")"))
        if iconTex then
            btn.Icon:SetTexture(iconTex)
        else
            btn.Icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
        
        btn.spellID = spellID
        btn:SetPoint("TOPLEFT", 0, -yOffset)
        btn:Show()
        
        yOffset = yOffset + 20
    end
    
    mainFrame.Content:SetHeight(math.max(1, yOffset))
    mainFrame:Show()
end
