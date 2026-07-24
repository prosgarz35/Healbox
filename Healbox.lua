---@diagnostic disable: unnecessary-if, assign-type-mismatch, param-type-mismatch
---@type string
local addonName = ...

---@class HealboxDB
---@field buttonCount number
---@field scale number
---@field spells table<number, string|nil>
---@field icons table<number, string|nil>
---@field positions table<string, any>

---@class Healbox
---@field activeFrames table<any, boolean>
---@field unitFrames table<string, table<any, boolean>>
---@field activeSpellsHash table<string, boolean>
---@field canCure table<string, boolean>
---@field pendingButtonUpdate boolean
---@field pendingRosterUpdate boolean
---@field partyContainer any
local Healbox = {}

local MAX_BUTTONS = 15

Healbox.activeFrames = {}
Healbox.unitFrames = {}
Healbox.activeSpellsHash = {}
Healbox.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
Healbox.pendingButtonUpdate = false
Healbox.pendingRosterUpdate = false

local _G = _G
local wipe, unpack, pairs, ipairs, type = wipe, unpack, pairs, ipairs, type
local math_max, math_floor = math.max, math.floor
local string_format = string.format

local CreateFrame, UIParent, GameTooltip = _G.CreateFrame, _G.UIParent, _G.GameTooltip
local IsUsableSpell, IsSpellInRange = _G.IsUsableSpell, _G.IsSpellInRange
local UnitIsVisible, UnitIsDeadOrGhost, UnitExists, UnitName = _G.UnitIsVisible, _G.UnitIsDeadOrGhost, _G.UnitExists, _G.UnitName
local UnitHealth, UnitHealthMax, UnitPower, UnitPowerMax, UnitPowerType = _G.UnitHealth, _G.UnitHealthMax, _G.UnitPower, _G.UnitPowerMax, _G.UnitPowerType
local UnitBuff, UnitDebuff = _G.UnitBuff, _G.UnitDebuff
local PickupSpell, ClearCursor = _G.PickupSpell, _G.ClearCursor
local PowerBarColor = _G.PowerBarColor

---@type fun(): boolean
local InCombatLockdown = _G.InCombatLockdown

---@type fun(): boolean
local IsShiftKeyDown = _G.IsShiftKeyDown

---@type fun(id: number|string, bookType?: string): string|nil, string|nil, string|nil
local GetSpellInfo = _G.GetSpellInfo

---@type fun(spellName: string): string|nil
local GetSpellLink = _G.GetSpellLink

---@type fun(): string|nil, number|nil, number|nil
local GetCursorInfo = _G.GetCursorInfo

---@type fun(index: number): string|nil
local GetMacroSpell = _G.GetMacroSpell

---@type fun(index: number, bookType: string): boolean
local IsPassiveSpell = _G.IsPassiveSpell

local EventFrame = CreateFrame("Frame")

---@type HealboxDB
local DB = {
	buttonCount = 5, scale = 1.0,
	spells = {}, icons = {}, positions = {}
}

---@type table<string, boolean|nil>
local unitPowerEvents = {
	UNIT_MANA = true, UNIT_RAGE = true, UNIT_FOCUS = true, UNIT_ENERGY = true, UNIT_RUNIC_POWER = true,
	UNIT_MAXMANA = true, UNIT_MAXRAGE = true, UNIT_MAXFOCUS = true, UNIT_MAXENERGY = true, UNIT_MAXRUNIC_POWER = true,
	UNIT_DISPLAYPOWER = true
}

---@type table<string, table<string, boolean>|nil>
local CuresByName = {}

---@type { [1]: number, [2]: table<string, boolean> }[]
local SPELL_LIST = {
	{ 2782, { Curse = true, Magic = true } },
	{ 2893, { Poison = true } },
	{ 8946, { Poison = true } },
	{ 552, { Disease = true } },
	{ 528, { Disease = true } },
	{ 527, { Magic = true } },
	{ 32375, { Magic = true } },
	{ 526, { Poison = true, Disease = true } },
	{ 51886, { Poison = true, Disease = true, Curse = true } },
	{ 523, { Poison = true } },
	{ 8170, { Disease = true } },
	{ 1152, { Poison = true, Disease = true } },
	{ 4987, { Poison = true, Disease = true, Magic = true } },
	{ 475, { Curse = true } },
	{ 520869, { Poison = true, Disease = true } }
}

---@type table<string, number>
local DEBUFF_PRIORITY = { Curse = 1, Disease = 2, Magic = 3, Poison = 4 }

---@type table<string, number[]>
local DEBUFF_COLOR = {
	Magic   = { 0.00, 0.80, 1.00 }, Curse   = { 0.90, 0.00, 1.00 },
	Disease = { 0.90, 0.50, 0.00 }, Poison  = { 0.00, 1.00, 0.00 }
}

local BACKDROP_TPL = {
	bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
	tile = true, tileSize = 8, edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 }
}

---@type table<string, boolean>
local usableCache = {}
---@type table<string, boolean>
local manaCache = {}

local function CreateBar(parent, height, color, anchor)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetSize(116, height)
	bar:SetPoint("TOPLEFT", anchor or parent, anchor and "BOTTOMLEFT" or "TOPLEFT", anchor and 0 or 2, anchor and 0 or -2)
	bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
	bar:SetStatusBarColor(unpack(color))
	bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	return bar
end

local function CreateBuffFrame(parent, index)
	local buff = CreateFrame("Frame", nil, parent)
	buff:SetSize(20, 20)
	buff:SetPoint("RIGHT", index == 1 and parent or parent["buff"..(index-1)], "LEFT", -2, 0)
	
	buff.icon = buff:CreateTexture(nil, "ARTWORK")
	buff.icon:SetAllPoints()
	
	buff.count = buff:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	buff.count:SetPoint("BOTTOMRIGHT", 2, -2)
	
	buff.cooldown = CreateFrame("Cooldown", nil, buff, "CooldownFrameTemplate")
	buff.cooldown:SetAllPoints()
	buff.cooldown:SetReverse(true)
	
	parent["buff"..index] = buff
	buff:Hide()
	return buff
end

local function CreateCurseBar(parent, sizeX, sizeY, edgeSize, strata)
	local cb = CreateFrame("Frame", nil, parent)
	cb:SetFrameStrata(strata)
	cb:SetSize(sizeX, sizeY)
	cb:SetPoint("CENTER")
	cb:SetBackdrop({ edgeFile = "Interface/Tooltips/UI-Tooltip-Border", edgeSize = edgeSize, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
	cb:SetAlpha(0)
	return cb
end

local function CreateSpellButton(parent, index)
	local btn = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
	btn:SetSize(28, 28)
	btn.index = index
	btn:SetPoint("LEFT", parent, "RIGHT", 4 + (index - 1) * 32, 0)
	
	btn:SetAttribute("type1", "spell")
	btn:SetAttribute("useparent-unit", "true")
	btn:RegisterForClicks("AnyUp")
	btn:RegisterForDrag("LeftButton")
	
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
	btn.icon:SetVertexColor(0.5, 0.5, 0.5)

	btn.CurseBar = CreateCurseBar(btn, 36, 36, 28, "HIGH")
	
	btn:SetScript("OnEnter", function(s) Healbox:OnSpellButtonEnter(s) end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	btn:SetScript("OnReceiveDrag", function(s) Healbox:OnSpellButtonReceiveDrag(s) end)
	btn:SetScript("OnDragStart", function(s) Healbox:OnSpellButtonDragStart(s) end)
	
	return btn
end

local function InitialConfigFunction(self)
	self:SetSize(120, 32)
	self:SetBackdrop(BACKDROP_TPL)
	self:SetBackdropColor(0, 0, 0, 0.8)
	self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	self:RegisterForClicks("AnyUp")

	self.healthBar = CreateBar(self, 24, {0, 1, 0})
	self.healthBar.text:SetPoint("LEFT", 6, 0)
	self.healthBar.text:SetJustifyH("LEFT")
	
	self.healthBar.hpText = self.healthBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.healthBar.hpText:SetPoint("RIGHT", -6, 0)

	self.manaBar = CreateBar(self, 4, {0, 0, 1}, self.healthBar)
	
	self.CurseBar = CreateCurseBar(self, 124, 32, 16, "MEDIUM")
	self.CurseBar:ClearAllPoints()
	self.CurseBar:SetPoint("TOPLEFT", self, "TOPLEFT", -4, 4)
	self.CurseBar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", -4, -4)

	self.spellButtons = {}
	for i = 1, 4 do CreateBuffFrame(self, i) end
	for i = 1, MAX_BUTTONS do self.spellButtons[i] = CreateSpellButton(self, i) end

	Healbox.activeFrames[self] = true
	Healbox:UpdateButtons()

	self:SetScript("OnShow", function(f) Healbox:OnFrameShow(f) end)
	self:SetScript("OnHide", function(f) Healbox:OnFrameHide(f) end)
	self:SetScript("OnAttributeChanged", function(f, name, value) Healbox:OnFrameAttributeChanged(f, name, value) end)
end

function Healbox:CreatePartyHeader()
	local container = CreateFrame("Frame", "HealboxPartyContainer", UIParent)
	container:SetSize(120, 16)
	container:EnableMouse(true)
	container:SetMovable(true)
	container:SetClampedToScreen(true)
	container:RegisterForDrag("LeftButton")
	container:SetScript("OnDragStart", container.StartMoving)
	container:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		local p, _, rp, x, y = f:GetPoint()
		DB.positions["Party"] = { point = p, relativePoint = rp, x = x, y = y }
	end)
	
	local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", 5, -2)
	title:SetText("Party")
	
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetTexture(0, 0, 0, 0.5)
	
	local header = CreateFrame("Frame", "HealboxPartyHeader", container, "SecureGroupHeaderTemplate")
	header:SetPoint("TOPLEFT", container, "BOTTOMLEFT", 0, -2)
	header:SetAttribute("template", "SecureUnitButtonTemplate")
	header.initialConfigFunction = InitialConfigFunction
	header:SetAttribute("showPlayer", true)
	header:SetAttribute("showParty", true)
	header:SetAttribute("showSolo", true)
	header:SetAttribute("yOffset", -1)
	
	local pos = DB.positions["Party"]
	local p, rp, x, y = "TOPLEFT", "TOPLEFT", 100, -200
	if pos then
		p, rp, x, y = pos.point or p, pos.relativePoint or rp, pos.x or x, pos.y or y
	end
	
	container:SetPoint(p, UIParent, rp, x, y)
	header:Show()
	container.header = header
	self.partyContainer = container
end

function Healbox:CreateOptionsUI()
	local panel = CreateFrame("Frame", "HealboxOptionsPanel", UIParent)
	panel.name = "Healbox"
	
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Healbox Settings")

	local function CreateSlider(name, text, minVal, maxVal, step, yOffset, formatStr, dbKey, updateFunc)
		local slider = CreateFrame("Slider", "HealboxSlider"..name, panel, "OptionsSliderTemplate")
		slider:SetPoint("TOPLEFT", 16, yOffset)
		slider:SetMinMaxValues(minVal, maxVal)
		slider:SetValueStep(step)
		
		local label = _G[slider:GetName().."Text"]
		_G[slider:GetName().."Low"]:SetText(minVal)
		_G[slider:GetName().."High"]:SetText(maxVal)
		
		slider:SetScript("OnValueChanged", function(_, val)
			if step >= 1 then val = math_floor(val + 0.5) end
			label:SetText(text .. ": " .. string_format(formatStr, val))
			DB[dbKey] = val
			if updateFunc then updateFunc() end
		end)
		
		slider:SetValue(DB[dbKey] or minVal)
		return slider
	end

	CreateSlider("ButtonCount", "Number of Buttons", 1, MAX_BUTTONS, 1, -60, "%.0f", "buttonCount", function() Healbox:UpdateButtons() end)
	CreateSlider("Scale", "Scale", 0.5, 2.0, 0.05, -110, "%.2f", "scale", function() Healbox:UpdateScale() end)

	InterfaceOptions_AddCategory(panel)
end

function Healbox:ADDON_LOADED(name)
	if name ~= addonName then return end
	
	EventFrame:UnregisterEvent("ADDON_LOADED")
	
	local savedDB = rawget(_G, "HealboxDB")
	if type(savedDB) ~= "table" then
		savedDB = {}
	end
	
	for k, v in pairs(DB) do
		if savedDB[k] == nil then savedDB[k] = v end
	end
	DB = savedDB ---@type HealboxDB
	rawset(_G, "HealboxDB", DB)
	
	self:CreateOptionsUI()
	
	rawset(_G, "SLASH_HEALBOX1", "/healbox")
	rawset(_G, "SLASH_HEALBOX2", "/hb")
	
	local scl = rawget(_G, "SlashCmdList")
	if scl then
		scl["HEALBOX"] = function() InterfaceOptionsFrame_OpenToCategory("Healbox") end
	end
end

function Healbox:PLAYER_LOGIN()
	for _, data in ipairs(SPELL_LIST) do
		local name = GetSpellInfo(data[1])
		if name then 
			if not CuresByName[name] then CuresByName[name] = {} end
			for k, v in pairs(data[2]) do
				if v then CuresByName[name][k] = true end
			end
		end
	end

	self:CreatePartyHeader()
	self:UpdateSpells()
	self:UpdateScale()
	
	EventFrame:RegisterEvent("UNIT_HEALTH")
	EventFrame:RegisterEvent("UNIT_MAXHEALTH")
	EventFrame:RegisterEvent("UNIT_AURA")
	
	for ev in pairs(unitPowerEvents) do EventFrame:RegisterEvent(ev) end

	EventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
	EventFrame:RegisterEvent("SPELLS_CHANGED")
	EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
end

function Healbox:UpdateRoster()
	if InCombatLockdown() then
		self.pendingRosterUpdate = true
		return
	end
	if self.partyContainer and self.partyContainer.header then
		self.partyContainer.header:Hide()
		self.partyContainer.header:Show()
	end
end

---@param event string
---@param unit string
function Healbox:OnUnitEvent(event, unit)
	if not self.unitFrames[unit] then return end
	local isHealth = (event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH")
	local isAura = (event == "UNIT_AURA")
	
	for frame in pairs(self.unitFrames[unit]) do 
		if isHealth then 
			self:UpdateUnitHealth(frame, unit)
		elseif isAura then 
			self:UpdateUnitBuffs(frame, unit)
			self:UpdateUnitDebuffs(frame, unit)
		else 
			self:UpdateUnitMana(frame, unit) 
		end
	end
end

function Healbox:PLAYER_REGEN_ENABLED()
	if self.pendingButtonUpdate then 
		self.pendingButtonUpdate = false
		self:UpdateButtons() 
	end
	if self.pendingRosterUpdate then
		self.pendingRosterUpdate = false
		self:UpdateRoster()
	end
end

function Healbox:SPELLS_CHANGED()
	self:UpdateSpells()
end

function Healbox:UpdateSpells()
	wipe(self.activeSpellsHash)
	for k in pairs(self.canCure) do self.canCure[k] = false end

	local count = DB.buttonCount
	local spells = DB.spells
	local icons = DB.icons
	
	for i = 1, MAX_BUTTONS do
		local spellName = spells[i]
		if type(spellName) == "string" and spellName ~= "" then
			self.activeSpellsHash[spellName] = true
			if not icons[i] then _, _, icons[i] = GetSpellInfo(spellName) end
			
			if i <= count then
				local cure = CuresByName[spellName]
				if cure then 
					for k, v in pairs(cure) do if v then self.canCure[k] = true end end 
				end
			end
		end
	end
	
	for frame in pairs(self.activeFrames) do
		if frame.TargetUnit then self:UpdateUnitDebuffs(frame, frame.TargetUnit) end
	end
	self:UpdateButtons()
end

function Healbox:UpdateButtons()
	if InCombatLockdown() then self.pendingButtonUpdate = true; return end
	
	local count = DB.buttonCount
	local spells = DB.spells
	local icons = DB.icons
	
	for frame in pairs(self.activeFrames) do
		local lastVisibleElement = frame 
		
		for i = 1, MAX_BUTTONS do
			local btn = frame.spellButtons[i]
			if i <= count then
				btn:Show()
				local spell = spells[i]
				local hasSpell = (type(spell) == "string" and spell ~= "")
				btn:SetAttribute("spell", hasSpell and spell or nil)
				btn.icon:SetTexture((hasSpell and icons[i]) and icons[i] or "Interface/Icons/INV_Misc_QuestionMark")
				btn.icon:SetVertexColor(hasSpell and 1 or 0.5, hasSpell and 1 or 0.5, hasSpell and 1 or 0.5)
				
				lastVisibleElement = btn 
			else
				btn:Hide()
			end
		end
		
		if frame.CurseBar then
			frame.CurseBar:SetPoint("RIGHT", lastVisibleElement, "RIGHT", 4, 0)
		end
	end
end

function Healbox:UpdateScale()
	if self.partyContainer then
		self.partyContainer:SetScale(DB.scale)
	end
end

function Healbox:OnUpdateTimer()
	local count = DB.buttonCount
	local spells = DB.spells
	
	wipe(usableCache)
	wipe(manaCache)

	for i = 1, count do
		local spellName = spells[i]
		if type(spellName) == "string" and spellName ~= "" then
			usableCache[spellName], manaCache[spellName] = IsUsableSpell(spellName)
		end
	end

	for frame in pairs(self.activeFrames) do
		local unit = frame.TargetUnit
		if type(unit) == "string" and UnitIsVisible(unit) and not UnitIsDeadOrGhost(unit) then
			for i = 1, count do
				local spellName = spells[i]
				if type(spellName) == "string" and spellName ~= "" then
					local btn = frame.spellButtons[i]
					local isUsable, notEnoughMana = usableCache[spellName], manaCache[spellName]
					local inRange = IsSpellInRange(spellName, unit)
					
					if (isUsable or notEnoughMana) and (inRange == 0) then
						btn.icon:SetVertexColor(1, 0.3, 0.3)
					elseif isUsable then
						btn.icon:SetVertexColor(1, 1, 1)
					elseif notEnoughMana then
						btn.icon:SetVertexColor(0.5, 0.5, 1)
					else
						btn.icon:SetVertexColor(0.3, 0.3, 0.3)
					end
				end
			end
		end
	end
end

---@param frame any
---@param unit string
function Healbox:RefreshFrameData(frame, unit)
	if not unit then return end
	frame.healthBar.text:SetText(UnitName(unit) or "Unknown")
	self:UpdateUnitHealth(frame, unit)
	self:UpdateUnitMana(frame, unit)
	self:UpdateUnitBuffs(frame, unit)
	self:UpdateUnitDebuffs(frame, unit)
end

---@param frame any
---@param unit string
function Healbox:UpdateUnitHealth(frame, unit)
	if not UnitExists(unit) then return end
	local maxHp = math_max(1, UnitHealthMax(unit))
	local isDead = UnitIsDeadOrGhost(unit)
	local hp = isDead and 0 or UnitHealth(unit)
	local percent = hp / maxHp
	
	frame.healthBar:SetMinMaxValues(0, maxHp)
	frame.healthBar:SetValue(hp)
	frame.healthBar.hpText:SetText(isDead and "Dead" or math_floor(percent * 100) .. "%")
	
	if isDead then
		frame.healthBar:SetStatusBarColor(0.5, 0.5, 0.5)
	elseif percent < 0.3 then 
		frame.healthBar:SetStatusBarColor(1, 0, 0)
	elseif percent < 0.6 then 
		frame.healthBar:SetStatusBarColor(1, 0.9, 0)
	else 
		frame.healthBar:SetStatusBarColor(0, 1, 0) 
	end
end

---@param frame any
---@param unit string
function Healbox:UpdateUnitMana(frame, unit)
	if not UnitExists(unit) then return end
	frame.manaBar:SetMinMaxValues(0, math_max(1, UnitPowerMax(unit)))
	frame.manaBar:SetValue(UnitIsDeadOrGhost(unit) and 0 or UnitPower(unit))
	
	local pType, pToken = UnitPowerType(unit)
	local info = PowerBarColor[pToken] or PowerBarColor[pType]
	if type(info) == "table" then 
		local r, g, b = info.r or 0, info.g or 0, info.b or 1
		frame.manaBar:SetStatusBarColor(r, g, b) 
	end
end

---@param frame any
---@param unit string
function Healbox:UpdateUnitBuffs(frame, unit)
	local buffIndex = 1
	for i = 1, 40 do
		local name, _, icon, count, _, duration, expirationTime, unitCaster = UnitBuff(unit, i)
		if not name then break end
		if unitCaster == "player" and self.activeSpellsHash[name] then
			local buffFrame = frame["buff"..buffIndex]
			if buffFrame then
				buffFrame.icon:SetTexture(icon)
				buffFrame.count:SetText(count > 1 and count or "")
				if duration and duration > 0 then
					buffFrame.cooldown:SetCooldown(expirationTime - duration, duration)
					buffFrame.cooldown:Show()
				else
					buffFrame.cooldown:Hide()
				end
				buffFrame:Show()
				buffIndex = buffIndex + 1
				if buffIndex > 4 then break end
			end
		end
	end
	for i = buffIndex, 4 do frame["buff"..i]:Hide() end
end

---@param frame any
---@param unit string
function Healbox:UpdateUnitDebuffs(frame, unit)
	---@type number
	local highestWeight = 10
	---@type string|nil
	local highestType
	local hasCurse, hasDisease, hasMagic, hasPoison = false, false, false, false

	for i = 1, 40 do
		local name, _, _, _, dType = UnitDebuff(unit, i)
		if not name then break end
		if type(dType) == "string" and dType ~= "" then
			if dType == "Curse" then hasCurse = true
			elseif dType == "Disease" then hasDisease = true
			elseif dType == "Magic" then hasMagic = true
			elseif dType == "Poison" then hasPoison = true end

			local w = DEBUFF_PRIORITY[dType]
			if w and self.canCure[dType] and w < highestWeight then
				highestWeight = w
				highestType = dType
			end
		end
	end
	
	if type(highestType) == "string" then
		local color = DEBUFF_COLOR[highestType]
		local r, g, b = color[1], color[2], color[3]
		frame.hasDebuffColor = color
		frame.CurseBar:SetBackdropBorderColor(r, g, b)
		frame.CurseBar:SetAlpha(1)
	else
		frame.hasDebuffColor = nil
		frame.CurseBar:SetAlpha(0)
	end
	
	self:UpdateUnitHealth(frame, unit)
	
	local count = DB.buttonCount
	local spells = DB.spells
	
	for i = 1, count do
		local btn = frame.spellButtons[i]
		local cure = CuresByName[spells[i] or ""]
		---@type string|nil
		local btnHighlight

		if cure then
			---@type number
			local btnWeight = 10
			if cure.Curse and hasCurse then btnWeight = 1; btnHighlight = "Curse" end
			if cure.Disease and hasDisease and btnWeight > 2 then btnWeight = 2; btnHighlight = "Disease" end
			if cure.Magic and hasMagic and btnWeight > 3 then btnWeight = 3; btnHighlight = "Magic" end
			if cure.Poison and hasPoison and btnWeight > 4 then btnWeight = 4; btnHighlight = "Poison" end
		end
		
		if type(btnHighlight) == "string" then 
			local color = DEBUFF_COLOR[btnHighlight]
			local r, g, b = color[1], color[2], color[3]
			btn.CurseBar:SetBackdropBorderColor(r, g, b)
			btn.CurseBar:SetAlpha(1)
		else 
			btn.CurseBar:SetAlpha(0)
		end
	end
end

function Healbox:OnSpellButtonEnter(btn)
	local spells = DB.spells
	local spellName = spells[btn.index]
	
	GameTooltip:SetOwner(btn, "ANCHOR_TOPLEFT")
	if type(spellName) == "string" and spellName ~= "" then
		local link = GetSpellLink(spellName)
		if type(link) == "string" then GameTooltip:SetHyperlink(link) end
		local unit = btn:GetParent().TargetUnit
		if unit and UnitExists(unit) then 
			GameTooltip:AddLine("Target: |cFF00FF00" .. (UnitName(unit) or ""), 1, 1, 1) 
		end
	else
		GameTooltip:SetText("|cFFFFFFFFNo Spell|n|cFF00FF00Drag and drop a spell|nhere from your spellbook.")
	end
	GameTooltip:Show()
end

function Healbox:OnSpellButtonReceiveDrag(btn)
	if InCombatLockdown() then print("|cFFFF0000Healbox:|r Cannot change spells in combat."); return end
	
	local infoType, index, bookType = GetCursorInfo()
	local spellName, icon
	
	if infoType == "spell" and index then
		if IsPassiveSpell(index, bookType) then print("|cFFFF0000Healbox:|r Cannot assign passive spells."); return end
		local sName = GetSpellInfo(index, bookType)
		if sName then spellName, _, icon = GetSpellInfo(sName) end
	elseif infoType == "macro" and index then
		spellName = GetMacroSpell(index)
		if spellName then 
			_, _, icon = GetSpellInfo(spellName)
		else 
			print("|cFFFF0000Healbox:|r This macro does not cast a recognized spell.")
			return 
		end
	else 
		return 
	end

	local spells = DB.spells
	local icons = DB.icons
	local oldSpell = spells[btn.index]
	
	spells[btn.index] = spellName
	icons[btn.index] = icon
	self:UpdateSpells()
	ClearCursor()
	
	if IsShiftKeyDown() and oldSpell then PickupSpell(oldSpell) end
end

function Healbox:OnSpellButtonDragStart(btn)
	if InCombatLockdown() then return end
	if not IsShiftKeyDown() then return end
	local spells = DB.spells
	local icons = DB.icons
	local spellName = spells[btn.index]
	
	if type(spellName) == "string" and spellName ~= "" then
		spells[btn.index] = nil
		icons[btn.index] = nil
		self:UpdateSpells()
		PickupSpell(spellName)
	end
end

---@param frame any
function Healbox:OnFrameShow(frame)
	local unit = frame:GetAttribute("unit")
	if type(unit) == "string" then
		frame.TargetUnit = unit
		self.unitFrames[unit] = self.unitFrames[unit] or {}
		self.unitFrames[unit][frame] = true
		self:RefreshFrameData(frame, unit)
	end
	self:UpdateButtons()
end

---@param frame any
function Healbox:OnFrameHide(frame)
	local unit = frame.TargetUnit
	if type(unit) == "string" and self.unitFrames[unit] then self.unitFrames[unit][frame] = nil end
	frame.TargetUnit = nil
end

---@param frame any
---@param name string
---@param value any
function Healbox:OnFrameAttributeChanged(frame, name, value)
	if name == "unit" then
		local currentUnit = frame.TargetUnit
		if type(currentUnit) == "string" and self.unitFrames[currentUnit] then self.unitFrames[currentUnit][frame] = nil end
		if type(value) == "string" then
			frame.TargetUnit = value
			self.unitFrames[value] = self.unitFrames[value] or {}
			self.unitFrames[value][frame] = true
			self:RefreshFrameData(frame, value)
		else
			frame.TargetUnit = nil
		end
	end
end

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_LOGIN")

-- Event Handlers table for O(1) dispatch
local EventHandlers = {
	UNIT_HEALTH = function(...) Healbox:OnUnitEvent("UNIT_HEALTH", ...) end,
	UNIT_MAXHEALTH = function(...) Healbox:OnUnitEvent("UNIT_MAXHEALTH", ...) end,
	UNIT_AURA = function(...) Healbox:OnUnitEvent("UNIT_AURA", ...) end,
}
for ev in pairs(unitPowerEvents) do
	EventHandlers[ev] = function(...) Healbox:OnUnitEvent("UNIT_POWER", ...) end
end
EventHandlers["PARTY_MEMBERS_CHANGED"] = function() Healbox:UpdateRoster() end

local function OnEvent(_, event, ...)
	local handler = EventHandlers[event]
	if handler then
		handler(...)
	else
		local method = rawget(Healbox, event)
		if method then 
			method(Healbox, ...) -- Явно передаем Healbox в качестве self
		end
	end
end

EventFrame:SetScript("OnEvent", OnEvent)

---@type number
local updateTimer = 0
EventFrame:SetScript("OnUpdate", function(_, elapsed)
	updateTimer = updateTimer + elapsed
	if updateTimer >= 0.15 then
		updateTimer = 0
		Healbox:OnUpdateTimer()
	end
end)