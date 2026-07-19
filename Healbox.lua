---@type string, any
local addonName, addonTable = ...
local Healbox = {}

---@type table<any, any>
Healbox.activeFrames = {}
---@type table<any, any>
Healbox.unitFrames = {}
---@type table<any, any>
Healbox.activeSpellsHash = {}
---@type table<any, any>
Healbox.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
---@type any
Healbox.pendingButtonUpdate = false
---@type any
Healbox.pendingRosterUpdate = false

local _G = _G
local wipe, unpack, pairs, ipairs = wipe, unpack, pairs, ipairs
local math_max, math_floor = math.max, math.floor
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local IsUsableSpell, IsSpellInRange = IsUsableSpell, IsSpellInRange
local UnitIsVisible, UnitIsDeadOrGhost, UnitExists, UnitName = UnitIsVisible, UnitIsDeadOrGhost, UnitExists, UnitName
local UnitHealth, UnitHealthMax, UnitPower, UnitPowerMax, UnitPowerType = UnitHealth, UnitHealthMax, UnitPower, UnitPowerMax, UnitPowerType
local UnitBuff, UnitDebuff = UnitBuff, UnitDebuff
local PickupSpell, ClearCursor, InCombatLockdown, IsShiftKeyDown = PickupSpell, ClearCursor, InCombatLockdown, IsShiftKeyDown

---@type any
local GetSpellInfo = GetSpellInfo
---@type any
local GetSpellLink = GetSpellLink
---@type any
local GetCursorInfo = GetCursorInfo
---@type any
local GetMacroSpell = GetMacroSpell
---@type any
local IsPassiveSpell = IsPassiveSpell

local EventFrame = CreateFrame("Frame")

---@type any
local DB = {
	buttonCount = 5, scale = 1.0,
	spells = {}, icons = {}, positions = {}
}

---@type any
local CuresByName = {}
local SPELL_LIST = {
	{ 2782, { Curse = true } }, { 2893, { Poison = true } }, { 8946, { Poison = true } },
	{ 552, { Disease = true } }, { 528, { Disease = true } }, { 527, { Magic = true } },
	{ 526, { Poison = true, Disease = true } }, { 51886, { Poison = true, Disease = true, Curse = true } },
	{ 1152, { Poison = true, Disease = true } }, { 4987, { Poison = true, Disease = true, Magic = true } },
	{ 475, { Curse = true } }, { 32375, { Magic = true } }
}

local DEBUFF_PRIORITY = { Curse = 1, Disease = 2, Magic = 3, Poison = 4 }
local DEBUFF_COLOR = {
	Magic   = { 0.20, 0.60, 1.00 }, Curse   = { 0.60, 0.00, 1.00 },
	Disease = { 0.60, 0.40, 0.00 }, Poison  = { 0.00, 0.60, 0.00 }
}
local BACKDROP_TPL = {
	bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
	tile = true, tileSize = 8, edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 }
}

---@type any
local usableCache = {}
---@type any
local manaCache = {}

local function CreateBar(parent, name, height, color, anchor)
	local bar = CreateFrame("StatusBar", parent:GetName()..name, parent)
	bar:SetSize(116, height)
	bar:SetPoint("TOPLEFT", anchor or parent, anchor and "BOTTOMLEFT" or "TOPLEFT", anchor and 0 or 2, anchor and 0 or -2)
	bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
	bar:SetStatusBarColor(unpack(color))
	local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	return bar, text
end

local function CreateBuffFrame(parent, index)
	local buff = CreateFrame("Frame", parent:GetName().."_Buff"..index, parent)
	buff:SetSize(20, 20)
	buff:SetPoint("RIGHT", index == 1 and parent or parent["buff"..(index-1)], "LEFT", -2, 0)
	
	buff.icon = buff:CreateTexture(nil, "ARTWORK")
	buff.icon:SetAllPoints()
	
	buff.count = buff:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	buff.count:SetPoint("BOTTOMRIGHT", 2, -2)
	
	buff.cooldown = CreateFrame("Cooldown", buff:GetName().."CD", buff, "CooldownFrameTemplate")
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
	local btn = CreateFrame("Button", parent:GetName().."_Spell"..index, parent, "SecureActionButtonTemplate")
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

	local hb, hbName = CreateBar(self, "HealthBar", 24, {0, 1, 0})
	self.healthBar = hb
	self.healthBar.name = hbName
	self.healthBar.name:SetPoint("LEFT", 6, 0)
	self.healthBar.name:SetJustifyH("LEFT")
	
	self.healthBar.hpText = self.healthBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.healthBar.hpText:SetPoint("RIGHT", -6, 0)

	self.manaBar = CreateBar(self, "ManaBar", 4, {0, 0, 1}, self.healthBar)
	self.CurseBar = CreateCurseBar(self, 124, 32, 24, "MEDIUM")

	self.spellButtons = {}
	for i = 1, 4 do CreateBuffFrame(self, i) end
	for i = 1, 15 do self.spellButtons[i] = CreateSpellButton(self, i) end

	Healbox.activeFrames[self] = true
	Healbox:UpdateButtons()

	self:SetScript("OnShow", function(f) Healbox:OnUnitFrameEvent(f, "SHOW") end)
	self:SetScript("OnHide", function(f) Healbox:OnUnitFrameEvent(f, "HIDE") end)
	self:SetScript("OnAttributeChanged", function(f, name, value) 
		if name == "unit" then Healbox:OnUnitFrameEvent(f, "UPDATE_UNIT", value) end 
	end)
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
		p = pos.point or p
		rp = pos.relativePoint or rp
		x = pos.x or x
		y = pos.y or y
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
		
		slider:SetScript("OnValueChanged", function(self, val)
			if step >= 1 then val = math_floor(val) end
			label:SetText(text .. ": " .. string.format(formatStr, val))
			DB[dbKey] = val
			if updateFunc then updateFunc() end
		end)
		
		slider:SetValue(DB[dbKey] or minVal)
		return slider
	end

	CreateSlider("ButtonCount", "Number of Buttons", 1, 15, 1, -60, "%.0f", "buttonCount", function() Healbox:UpdateButtons() end)
	CreateSlider("Scale", "Scale", 0.5, 2.0, 0.05, -110, "%.2f", "scale", function() Healbox:UpdateScale() end)

	InterfaceOptions_AddCategory(panel)
end

---@param name string
function Healbox:ADDON_LOADED(name)
	if name ~= addonName then return end
	
	local db = rawget(_G, "HealboxDB") or {}
	rawset(_G, "HealboxDB", db)
	
	for k, v in pairs(DB) do
		if db[k] == nil then db[k] = v end
	end
	DB = db
	
	self:CreateOptionsUI()
	
	rawset(_G, "SLASH_HEALBOX1", "/healbox")
	rawset(_G, "SLASH_HEALBOX2", "/hb")
	
	local scl = rawget(_G, "SlashCmdList")
	if scl then
		scl["HEALBOX"] = function() InterfaceOptionsFrame_OpenToCategory("Healbox") end
	end
end

function Healbox:PLAYER_LOGIN()
	self:CreatePartyHeader()
	self:UpdateSpells()
	self:UpdateScale()
	
	EventFrame:RegisterEvent("UNIT_HEALTH")
	EventFrame:RegisterEvent("UNIT_MAXHEALTH")
	EventFrame:RegisterEvent("UNIT_AURA")
	
	local powerEvents = { "UNIT_MANA", "UNIT_RAGE", "UNIT_FOCUS", "UNIT_ENERGY", "UNIT_RUNIC_POWER", "UNIT_MAXMANA", "UNIT_MAXRAGE", "UNIT_MAXFOCUS", "UNIT_MAXENERGY", "UNIT_MAXRUNIC_POWER", "UNIT_DISPLAYPOWER" }
	for _, ev in ipairs(powerEvents) do EventFrame:RegisterEvent(ev) end

	EventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
	EventFrame:RegisterEvent("SPELLS_CHANGED")
	EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
end

function Healbox:PARTY_MEMBERS_CHANGED() self:UpdateRoster() end

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

function Healbox:UNIT_HEALTH(unit) self:OnUnitEvent("UNIT_HEALTH", unit) end
function Healbox:UNIT_MAXHEALTH(unit) self:OnUnitEvent("UNIT_MAXHEALTH", unit) end
function Healbox:UNIT_AURA(unit) self:OnUnitEvent("UNIT_AURA", unit) end

function Healbox:UNIT_MANA(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_RAGE(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_FOCUS(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_ENERGY(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_RUNIC_POWER(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_MAXMANA(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_MAXRAGE(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_MAXFOCUS(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_MAXENERGY(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_MAXRUNIC_POWER(unit) self:OnUnitEvent("UNIT_POWER", unit) end
function Healbox:UNIT_DISPLAYPOWER(unit) self:OnUnitEvent("UNIT_DISPLAYPOWER", unit) end

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
	for _, data in ipairs(SPELL_LIST) do
		local name = GetSpellInfo(data[1])
		if name then CuresByName[name] = data[2] end
	end

	local count = DB.buttonCount
	local spells = DB.spells
	local icons = DB.icons
	
	for i = 1, 15 do
		local spellName = spells[i]
		if spellName and spellName ~= "" then
			self.activeSpellsHash[spellName] = true
			if not icons[i] then _, _, icons[i] = GetSpellInfo(spellName) end
		end
	end
	
	for k in pairs(self.canCure) do self.canCure[k] = false end
	for i = 1, count do
		local cure = CuresByName[spells[i] or ""]
		if cure then 
			for k, v in pairs(cure) do if v then self.canCure[k] = true end end 
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
		for i = 1, 15 do
			local btn = frame.spellButtons[i]
			if i <= count then
				btn:Show()
				local spell = spells[i]
				local hasSpell = (spell ~= nil and spell ~= "")
				btn:SetAttribute("spell", hasSpell and spell or nil)
				btn.icon:SetTexture(hasSpell and icons[i] or "Interface/Icons/INV_Misc_QuestionMark")
				btn.icon:SetVertexColor(hasSpell and 1 or 0.5, hasSpell and 1 or 0.5, hasSpell and 1 or 0.5)
			else
				btn:Hide()
			end
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
		if spellName and spellName ~= "" then
			usableCache[spellName], manaCache[spellName] = IsUsableSpell(spellName)
		end
	end

	for frame in pairs(self.activeFrames) do
		local unit = frame.TargetUnit
		if unit and UnitIsVisible(unit) and not UnitIsDeadOrGhost(unit) then
			for i = 1, count do
				local spellName = spells[i]
				if spellName and spellName ~= "" then
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

function Healbox:RefreshFrameData(frame, unit)
	if not unit then return end
	frame.healthBar.name:SetText(UnitName(unit) or "Unknown")
	self:UpdateUnitHealth(frame, unit)
	self:UpdateUnitMana(frame, unit)
	self:UpdateUnitBuffs(frame, unit)
	self:UpdateUnitDebuffs(frame, unit)
end

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
	elseif frame.hasDebuffColor then
		local c = frame.hasDebuffColor
		frame.healthBar:SetStatusBarColor(c[1], c[2], c[3])
	elseif percent < 0.3 then 
		frame.healthBar:SetStatusBarColor(1, 0, 0)
	elseif percent < 0.6 then 
		frame.healthBar:SetStatusBarColor(1, 0.9, 0)
	else 
		frame.healthBar:SetStatusBarColor(0, 1, 0) 
	end
end

function Healbox:UpdateUnitMana(frame, unit)
	if not UnitExists(unit) then return end
	frame.manaBar:SetMinMaxValues(0, math_max(1, UnitPowerMax(unit)))
	frame.manaBar:SetValue(UnitIsDeadOrGhost(unit) and 0 or UnitPower(unit))
	
	local pType = UnitPowerType(unit)
	local info = PowerBarColor[pType]
	if info then frame.manaBar:SetStatusBarColor(info.r, info.g, info.b) end
end

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

function Healbox:UpdateUnitDebuffs(frame, unit)
	local highestWeight, highestType = 10, nil
	local hasCurse, hasDisease, hasMagic, hasPoison = false, false, false, false

	for i = 1, 40 do
		local name, _, _, _, dType = UnitDebuff(unit, i)
		if not name then break end
		if dType then
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
	
	if highestType then
		local color = DEBUFF_COLOR[highestType]
		frame.hasDebuffColor = color
		frame.CurseBar:SetBackdropBorderColor(color[1], color[2], color[3])
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
		local btnHighlight
		
		if cure then
			local btnWeight = 10
			if cure.Curse and hasCurse and DEBUFF_PRIORITY.Curse < btnWeight then btnWeight = DEBUFF_PRIORITY.Curse; btnHighlight = "Curse" end
			if cure.Disease and hasDisease and DEBUFF_PRIORITY.Disease < btnWeight then btnWeight = DEBUFF_PRIORITY.Disease; btnHighlight = "Disease" end
			if cure.Magic and hasMagic and DEBUFF_PRIORITY.Magic < btnWeight then btnWeight = DEBUFF_PRIORITY.Magic; btnHighlight = "Magic" end
			if cure.Poison and hasPoison and DEBUFF_PRIORITY.Poison < btnWeight then btnWeight = DEBUFF_PRIORITY.Poison; btnHighlight = "Poison" end
		end
		
		if btnHighlight then 
			local color = DEBUFF_COLOR[btnHighlight]
			btn.CurseBar:SetBackdropBorderColor(color[1], color[2], color[3])
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
	if spellName and spellName ~= "" then
		local link = GetSpellLink(spellName)
		if link then GameTooltip:SetHyperlink(link) end
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
	
	---@type any, any, any
	local infoType, index, bookType = GetCursorInfo()
	local spellName, icon
	
	if infoType == "spell" then
		if IsPassiveSpell(index, bookType) then print("|cFFFF0000Healbox:|r Cannot assign passive spells."); return end
		local sName = GetSpellInfo(index, bookType)
		if sName then spellName, _, icon = GetSpellInfo(sName) end
	elseif infoType == "macro" then
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
	
	if IsShiftKeyDown() and oldSpell ~= nil then PickupSpell(oldSpell) end
end

function Healbox:OnSpellButtonDragStart(btn)
	if InCombatLockdown() or not IsShiftKeyDown() then return end
	local spells = DB.spells
	local icons = DB.icons
	local spellName = spells[btn.index]
	
	if spellName and spellName ~= "" then
		spells[btn.index] = nil
		icons[btn.index] = nil
		self:UpdateSpells()
		PickupSpell(spellName)
	end
end

function Healbox:OnUnitFrameEvent(frame, action, value)
	if action == "SHOW" then
		local unit = frame:GetAttribute("unit")
		if unit then
			frame.TargetUnit = unit
			self.unitFrames[unit] = self.unitFrames[unit] or {}
			self.unitFrames[unit][frame] = true
			self:RefreshFrameData(frame, unit)
		end
		self:UpdateButtons()
	elseif action == "HIDE" then
		local unit = frame.TargetUnit
		if unit and self.unitFrames[unit] then self.unitFrames[unit][frame] = nil end
		frame.TargetUnit = nil
	elseif action == "UPDATE_UNIT" then
		if frame.TargetUnit and self.unitFrames[frame.TargetUnit] then self.unitFrames[frame.TargetUnit][frame] = nil end
		if value then
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

EventFrame:SetScript("OnEvent", function(self, event, ...)
	if Healbox[event] then Healbox[event](Healbox, ...) end
end)

local updateTimer = 0
EventFrame:SetScript("OnUpdate", function(self, elapsed)
	updateTimer = updateTimer + elapsed
	if updateTimer >= 0.15 then
		updateTimer = 0
		Healbox:OnUpdateTimer()
	end
end)