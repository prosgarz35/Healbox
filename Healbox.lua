local Healbox = LibStub("AceAddon-3.0"):NewAddon("Healbox", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")

local wipe, unpack, pairs, ipairs, math_max, math_floor, tostring = wipe, unpack, pairs, ipairs, math.max, math.floor, tostring
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local IsUsableSpell, IsSpellInRange = IsUsableSpell, IsSpellInRange
local UnitIsVisible, UnitIsDeadOrGhost, UnitExists, UnitName = UnitIsVisible, UnitIsDeadOrGhost, UnitExists, UnitName
local UnitHealth, UnitHealthMax, UnitPower, UnitPowerMax, UnitPowerType = UnitHealth, UnitHealthMax, UnitPower, UnitPowerMax, UnitPowerType
local UnitBuff, UnitDebuff = UnitBuff, UnitDebuff
local GetSpellInfo, GetSpellLink, GetCursorInfo, GetMacroSpell = GetSpellInfo, GetSpellLink, GetCursorInfo, GetMacroSpell
local IsPassiveSpell, PickupSpell, ClearCursor, InCombatLockdown = IsPassiveSpell, PickupSpell, ClearCursor, InCombatLockdown
local IsShiftKeyDown = IsShiftKeyDown

local defaults = {
	profile = {
		buttonCount = 5, spells = {}, icons = {}, positions = {},
		showParty = true, showGroups = { false, false, false, false, false, false, false, false },
		scale = 1.0, showTooltips = true, showMana = true, showHealthText = true, showNameText = true,
	}
}

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

local usableCache, manaCache = {}, {}

local function CreateBar(parent, name, height, color, anchor)
	local bar = CreateFrame("StatusBar", parent:GetName()..name, parent)
	bar:SetSize(116, height)
	bar:SetPoint("TOPLEFT", anchor or parent, anchor and "BOTTOMLEFT" or "TOPLEFT", anchor and 0 or 2, anchor and 0 or -2)
	bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
	bar:SetStatusBarColor(unpack(color))
	return bar, bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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

	btn.debuffHighlight = btn:CreateTexture(nil, "OVERLAY")
	btn.debuffHighlight:SetTexture("Interface/Buttons/UI-ActionButton-Border")
	btn.debuffHighlight:SetBlendMode("ADD")
	btn.debuffHighlight:SetPoint("CENTER")
	btn.debuffHighlight:SetSize(42, 42)
	btn.debuffHighlight:Hide()
	
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
	self:RegisterForClicks("AnyUp")

	local hb, hbName = CreateBar(self, "HealthBar", 24, {0, 1, 0})
	self.healthBar = hb
	self.healthBar.name = hbName
	self.healthBar.name:SetPoint("LEFT", 6, 0)
	self.healthBar.name:SetJustifyH("LEFT")
	
	self.healthBar.hpText = self.healthBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.healthBar.hpText:SetPoint("RIGHT", -6, 0)

	self.manaBar = CreateBar(self, "ManaBar", 4, {0, 0, 1}, self.healthBar)

	self.debuffHighlight = self:CreateTexture(nil, "OVERLAY")
	self.debuffHighlight:SetAllPoints(self.healthBar)
	self.debuffHighlight:SetTexture("Interface/ChatFrame/ChatFrameBackground")
	self.debuffHighlight:SetBlendMode("ADD")
	self.debuffHighlight:Hide()

	self.spellButtons = {}
	for i = 1, 4 do CreateBuffFrame(self, i) end
	for i = 1, 15 do self.spellButtons[i] = CreateSpellButton(self, i) end

	Healbox.activeFrames = Healbox.activeFrames or {}
	Healbox.activeFrames[self] = true
	Healbox:UpdateButtons()

	self:SetScript("OnShow", function(f) Healbox:OnUnitFrameEvent(f, "SHOW") end)
	self:SetScript("OnHide", function(f) Healbox:OnUnitFrameEvent(f, "HIDE") end)
	self:SetScript("OnAttributeChanged", function(f, name, value) 
		if name == "unit" then Healbox:OnUnitFrameEvent(f, "UPDATE_UNIT", value) end 
	end)
end

function Healbox:CreateGroupHeaders()
	self.activeFrames, self.containers = {}, {}
	
	local function CreateContainer(name, titleText, relativeTo, isGroup)
		local container = CreateFrame("Frame", name.."Container", UIParent)
		container:SetSize(120, 16)
		container:EnableMouse(true)
		container:SetMovable(true)
		container:SetClampedToScreen(true)
		container:RegisterForDrag("LeftButton")
		container:SetScript("OnDragStart", container.StartMoving)
		container:SetScript("OnDragStop", function(f)
			f:StopMovingOrSizing()
			local p, _, rp, x, y = f:GetPoint()
			self.profile.positions[name] = { point = p, relativePoint = rp, x = x, y = y }
		end)
		
		local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		title:SetPoint("TOPLEFT", 5, -2)
		title:SetText(titleText)
		
		local bg = container:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetTexture(0, 0, 0, 0.5)
		
		local header = CreateFrame("Frame", name, container, "SecureGroupHeaderTemplate")
		header:SetPoint("TOPLEFT", container, "BOTTOMLEFT", 0, -2)
		header:SetAttribute("template", "SecureUnitButtonTemplate")
		header.initialConfigFunction = InitialConfigFunction
		header:SetAttribute("showPlayer", true)
		header:SetAttribute("yOffset", -1)

		if isGroup then
			header:SetAttribute("showRaid", true)
			header:SetAttribute("groupFilter", tostring(isGroup))
		else
			header:SetAttribute("showParty", true)
			header:SetAttribute("showSolo", true)
		end
		
		local pos = self.profile.positions[name]
		container:SetPoint(pos and pos.point or "TOPLEFT", pos and UIParent or relativeTo, pos and pos.relativePoint or (isGroup and "BOTTOMLEFT" or "TOPLEFT"), pos and pos.x or (isGroup and 0 or 100), pos and pos.y or (isGroup and -20 or -200))
		
		if (not isGroup and self.profile.showParty) or (isGroup and self.profile.showGroups[isGroup]) then header:Show() else header:Hide() end

		container.header, container.isGroup = header, isGroup
		table.insert(self.containers, container)
		return container
	end

	self.partyContainer = CreateContainer("HealboxPartyHeader", "Party", UIParent, false)
	local lastContainer = self.partyContainer
	for i = 1, 8 do lastContainer = CreateContainer("HealboxGroupHeader"..i, "Group "..i, lastContainer, i) end
end

function Healbox:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("HealboxCharacterDB", defaults)
	self.profile = self.db.profile
	
	local options = {
		name = "Settings", type = "group", handler = Healbox,
		get = function(info) return self.profile[info[#info]] end,
		set = function(info, val) self.profile[info[#info]] = val; self:RefreshAllFrames() end,
		args = {
			buttonCount = { type = "range", name = "Number of Buttons", width = "full", min = 1, max = 15, step = 1, set = function(_, val) self.profile.buttonCount = val; self:UpdateButtons() end, order = 1 },
			scale = { type = "range", name = "Scale", width = "full", min = 0.5, max = 2.0, step = 0.05, set = function(_, val) self.profile.scale = val; self:UpdateScale() end, order = 2 },
			groupsHeader = { type = "header", name = "Raid Groups", order = 10 },
			visibilityHeader = { type = "header", name = "Visibility Options", order = 20 },
			showParty = { type = "toggle", name = "Show Party", width = "normal", set = function(_, val) self.profile.showParty = val; self:UpdateVisibility() end, order = 21 },
			showNameText = { type = "toggle", name = "Show Names", width = "normal", order = 22 },
			showMana = { type = "toggle", name = "Show Main Resource", width = "normal", set = function(_, val) self.profile.showMana = val; self:UpdateManaBarVisibility() end, order = 23 },
			showHealthText = { type = "toggle", name = "Show Health Percent", width = "normal", order = 24 },
		}
	}

	for i = 1, 8 do
		options.args["showGroup"..i] = {
			type = "toggle", name = "Group "..i, width = "half",
			get = function() return self.profile.showGroups[i] end,
			set = function(_, val) self.profile.showGroups[i] = val; self:UpdateVisibility() end,
			order = 10 + i
		}
	end

	LibStub("AceConfig-3.0"):RegisterOptionsTable("Healbox", options)
	self.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Healbox", "Healbox")
	self:RegisterChatCommand("healbox", "ChatCommand")
	self:RegisterChatCommand("hb", "ChatCommand")
end

function Healbox:OnEnable()
	self:RegisterEvent("UNIT_HEALTH", "OnUnitEvent")
	self:RegisterEvent("UNIT_MAXHEALTH", "OnUnitEvent")
	self:RegisterEvent("UNIT_AURA", "OnUnitEvent")
	self:RegisterEvent("UNIT_POWER", "OnUnitEvent")
	self:RegisterEvent("UNIT_MAXPOWER", "OnUnitEvent")
	self:RegisterEvent("UNIT_DISPLAYPOWER", "OnUnitEvent")
	self:RegisterEvent("SPELLS_CHANGED", "UpdateSpells")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("PARTY_MEMBERS_CHANGED", "UpdateRoster")
	self:RegisterEvent("RAID_ROSTER_UPDATE", "UpdateRoster")
	
	self.activeSpellsHash, self.unitFrames = {}, {}
	self.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
	
	self:CreateGroupHeaders()
	self:UpdateSpells()
	self:UpdateScale()
	self:UpdateVisibility()
	self:UpdateManaBarVisibility()
	
	self.updateTimer = self:ScheduleRepeatingTimer("OnUpdateTimer", 0.15)
end

function Healbox:ChatCommand() InterfaceOptionsFrame_OpenToCategory(self.optionsFrame) end

function Healbox:OnUnitEvent(event, unit)
	if not self.unitFrames[unit] then return end
	local isHealth = (event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH")
	local isAura = (event == "UNIT_AURA")
	
	for frame in pairs(self.unitFrames[unit]) do 
		if isHealth then self:UpdateUnitHealth(frame, unit)
		elseif isAura then self:UpdateUnitBuffs(frame, unit); self:UpdateUnitDebuffs(frame, unit)
		else self:UpdateUnitMana(frame, unit) end
	end
end

function Healbox:UpdateRoster()
	if InCombatLockdown() then self.pendingRosterUpdate = true; return end
	if self.profile.showParty and self.partyContainer and self.partyContainer.header then
		self.partyContainer.header:Hide()
		self.partyContainer.header:Show()
	end
end

function Healbox:PLAYER_REGEN_ENABLED()
	if self.pendingButtonUpdate then self.pendingButtonUpdate = false; self:UpdateButtons() end
	if self.pendingRosterUpdate then self.pendingRosterUpdate = false; self:UpdateRoster() end
end

function Healbox:UpdateSpells()
	wipe(self.activeSpellsHash)
	for _, data in ipairs(SPELL_LIST) do
		local name = GetSpellInfo(data[1])
		if name then CuresByName[name] = data[2] end
	end

	local count = self.profile.buttonCount or 5
	for i = 1, 15 do
		local spellName = self.profile.spells[i]
		if spellName and spellName ~= "" then
			self.activeSpellsHash[spellName] = true
			if not self.profile.icons[i] then _, _, self.profile.icons[i] = GetSpellInfo(spellName) end
		end
	end
	
	for k in pairs(self.canCure) do self.canCure[k] = false end
	for i = 1, count do
		local cure = CuresByName[self.profile.spells[i] or ""]
		if cure then 
			for k, v in pairs(cure) do if v then self.canCure[k] = true end end 
		end
	end
	
	for frame in pairs(self.activeFrames or {}) do
		if frame.TargetUnit then self:UpdateUnitDebuffs(frame, frame.TargetUnit) end
	end
	self:UpdateButtons()
end

function Healbox:UpdateButtons()
	if InCombatLockdown() then self.pendingButtonUpdate = true; return end
	
	local count = self.profile.buttonCount or 5
	for frame in pairs(self.activeFrames or {}) do
		for i = 1, 15 do
			local btn = frame.spellButtons[i]
			if i <= count then
				btn:Show()
				local spell = self.profile.spells[i]
				local hasSpell = spell and spell ~= ""
				btn:SetAttribute("spell", hasSpell and spell or nil)
				btn.icon:SetTexture(hasSpell and self.profile.icons[i] or "Interface/Icons/INV_Misc_QuestionMark")
				btn.icon:SetVertexColor(hasSpell and 1 or 0.5, hasSpell and 1 or 0.5, hasSpell and 1 or 0.5)
			else
				btn:Hide()
			end
		end
	end
end

function Healbox:UpdateVisibility()
	if InCombatLockdown() then return end
	if self.profile.showParty then self.partyContainer:Show() else self.partyContainer:Hide() end
	for _, container in ipairs(self.containers) do
		if container.isGroup then
			if self.profile.showGroups[container.isGroup] then container:Show() else container:Hide() end
		end
	end
end

function Healbox:UpdateScale()
	for _, container in ipairs(self.containers) do container:SetScale(self.profile.scale) end
end

function Healbox:UpdateManaBarVisibility()
	local showMana = self.profile.showMana
	for frame in pairs(self.activeFrames or {}) do
		if showMana then
			frame.manaBar:Show()
			frame.healthBar:SetHeight(24)
		else
			frame.manaBar:Hide()
			frame.healthBar:SetHeight(28)
		end
	end
end

function Healbox:OnUpdateTimer()
	if not self.activeFrames then return end
	local count = self.profile.buttonCount or 5
	local spells = self.profile.spells
	
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
		if frame:IsVisible() and unit and UnitIsVisible(unit) and not UnitIsDeadOrGhost(unit) then
			for i = 1, count do
				local btn = frame.spellButtons[i]
				local spellName = spells[i]
				if spellName and spellName ~= "" then
					local isUsable, notEnoughMana = usableCache[spellName], manaCache[spellName]
					local inRange = IsSpellInRange(spellName, unit)
					
					if (isUsable or notEnoughMana) and inRange == 0 then
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
	frame.healthBar.name:SetText(self.profile.showNameText and (UnitName(unit) or "Unknown") or "")
	self:UpdateUnitHealth(frame, unit)
	self:UpdateUnitMana(frame, unit)
	self:UpdateUnitBuffs(frame, unit)
	self:UpdateUnitDebuffs(frame, unit)
end

function Healbox:RefreshAllFrames()
	for frame in pairs(self.activeFrames or {}) do
		if frame.TargetUnit then
			self:RefreshFrameData(frame, frame.TargetUnit)
			self:UpdateManaBarVisibility()
		end
	end
end

function Healbox:UpdateUnitHealth(frame, unit)
	if not UnitExists(unit) then return end
	local maxHp = math_max(1, UnitHealthMax(unit))
	local hp = UnitIsDeadOrGhost(unit) and 0 or UnitHealth(unit)
	local percent = hp / maxHp
	
	frame.healthBar:SetMinMaxValues(0, maxHp)
	frame.healthBar:SetValue(hp)
	frame.healthBar.hpText:SetText(self.profile.showHealthText and (hp == 0 and "Dead" or math_floor(percent * 100) .. "%") or "")
	
	if percent < 0.3 then frame.healthBar:SetStatusBarColor(1, 0, 0)
	elseif percent < 0.6 then frame.healthBar:SetStatusBarColor(1, 0.9, 0)
	else frame.healthBar:SetStatusBarColor(0, 1, 0) end
end

function Healbox:UpdateUnitMana(frame, unit)
	if not UnitExists(unit) then return end
	frame.manaBar:SetMinMaxValues(0, math_max(1, UnitPowerMax(unit)))
	frame.manaBar:SetValue(UnitIsDeadOrGhost(unit) and 0 or UnitPower(unit))
	
	local pType, pToken = UnitPowerType(unit)
	local info = PowerBarColor[pToken] or PowerBarColor[pType]
	if info then 
		frame.manaBar:SetStatusBarColor(info.r, info.g, info.b) 
	end
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
		frame.debuffHighlight:SetVertexColor(unpack(DEBUFF_COLOR[highestType]))
		frame.debuffHighlight:SetAlpha(0.4)
		frame.debuffHighlight:Show()
	else
		frame.debuffHighlight:Hide()
	end
	
	local count = self.profile.buttonCount or 5
	for i = 1, count do
		local btn = frame.spellButtons[i]
		local cure, btnHighlight = CuresByName[self.profile.spells[i] or ""], nil
		if cure then
			local btnWeight = 10
			if cure.Curse and hasCurse and DEBUFF_PRIORITY.Curse < btnWeight then btnWeight = DEBUFF_PRIORITY.Curse; btnHighlight = "Curse" end
			if cure.Disease and hasDisease and DEBUFF_PRIORITY.Disease < btnWeight then btnWeight = DEBUFF_PRIORITY.Disease; btnHighlight = "Disease" end
			if cure.Magic and hasMagic and DEBUFF_PRIORITY.Magic < btnWeight then btnWeight = DEBUFF_PRIORITY.Magic; btnHighlight = "Magic" end
			if cure.Poison and hasPoison and DEBUFF_PRIORITY.Poison < btnWeight then btnWeight = DEBUFF_PRIORITY.Poison; btnHighlight = "Poison" end
		end
		
		if btnHighlight then 
			btn.debuffHighlight:SetVertexColor(unpack(DEBUFF_COLOR[btnHighlight]))
			btn.debuffHighlight:SetAlpha(1)
			btn.debuffHighlight:Show() 
		else 
			btn.debuffHighlight:Hide()
		end
	end
end

function Healbox:OnSpellButtonEnter(btn)
	if not self.profile.showTooltips then return end
	local spellName = self.profile.spells[btn.index]
	GameTooltip:SetOwner(btn, "ANCHOR_TOPLEFT")
	if spellName then
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
	local infoType, index, bookType = GetCursorInfo()
	local spellName, icon
	
	if infoType == "spell" then
		if IsPassiveSpell(index, bookType) then print("|cFFFF0000Healbox:|r Cannot assign passive spells."); return end
		local sName = GetSpellInfo(index, bookType)
		if sName then spellName, _, icon = GetSpellInfo(sName) end
	elseif infoType == "macro" then
		spellName = GetMacroSpell(index)
		if spellName then _, _, icon = GetSpellInfo(spellName)
		else print("|cFFFF0000Healbox:|r This macro does not cast a recognized spell."); return end
	else return end

	if spellName then
		local oldSpell = self.profile.spells[btn.index]
		self.profile.spells[btn.index] = spellName
		self.profile.icons[btn.index] = icon
		self:UpdateSpells()
		ClearCursor()
		if IsShiftKeyDown() and oldSpell then PickupSpell(oldSpell) end
	end
end

function Healbox:OnSpellButtonDragStart(btn)
	if InCombatLockdown() or not IsShiftKeyDown() then return end
	local spellName = self.profile.spells[btn.index]
	if spellName then
		self.profile.spells[btn.index] = nil
		self.profile.icons[btn.index] = nil
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
		self:UpdateManaBarVisibility()
		self:UpdateButtons()
	elseif action == "HIDE" then
		local unit = frame.TargetUnit
		if unit and self.unitFrames[unit] then self.unitFrames[unit][frame] = nil end
		frame.TargetUnit = nil
	elseif action == "UPDATE_UNIT" then
		if frame.TargetUnit and self.unitFrames[frame.TargetUnit] then self.unitFrames[frame.TargetUnit][frame] = nil end
		if value and frame:IsVisible() then
			frame.TargetUnit = value
			self.unitFrames[value] = self.unitFrames[value] or {}
			self.unitFrames[value][frame] = true
			self:RefreshFrameData(frame, value)
		else
			frame.TargetUnit = nil
		end
	end
end