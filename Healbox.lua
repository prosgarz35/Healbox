local Healbox = LibStub("AceAddon-3.0"):NewAddon("Healbox", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")

-- Локальное кэширование API для OnUpdate (оптимизация CPU)
local IsUsableSpell = IsUsableSpell
local IsSpellInRange = IsSpellInRange
local UnitIsVisible = UnitIsVisible
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitBuff = UnitBuff
local UnitDebuff = UnitDebuff
local UnitName = UnitName
local UnitExists = UnitExists

local defaults = {
	profile = {
		buttonCount = 5, spells = {}, icons = {}, positions = {},
		showParty = true, showGroups = { false, false, false, false, false, false, false, false },
		scale = 1.0, showTooltips = true, showMana = true, showHealthText = true, showNameText = true,
	}
}

local CuresConfig = {
	[2782] = { Curse = true }, [2893] = { Poison = true }, [8946] = { Poison = true },
	[552] = { Disease = true }, [528] = { Disease = true }, [527] = { Magic = true },
	[526] = { Poison = true, Disease = true }, [51886] = { Poison = true, Disease = true, Curse = true },
	[1152] = { Poison = true, Disease = true }, [4987] = { Poison = true, Disease = true, Magic = true },
	[475] = { Curse = true }, [520869] = { Poison = true, Disease = true },
}
local CuresByName = {}
local DEBUFF_PRIORITY = { "Curse", "Disease", "Magic", "Poison" }
local activeDebuffsCache = {}

-- ==========================================
-- UI Templates & Frame Creation
-- ==========================================

local function CreateBuffFrame(parent, index)
	local name = parent:GetName() .. "_Buff" .. index
	local buff = CreateFrame("Frame", name, parent)
	buff:SetSize(20, 20)
	
	if index == 1 then
		buff:SetPoint("RIGHT", parent, "LEFT", -2, 0)
	else
		buff:SetPoint("RIGHT", parent["buff" .. (index-1)], "LEFT", -2, 0)
	end
	
	buff.icon = buff:CreateTexture(nil, "ARTWORK")
	buff.icon:SetAllPoints()
	
	buff.count = buff:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	buff.count:SetPoint("BOTTOMRIGHT", 2, -2)
	
	buff.cooldown = CreateFrame("Cooldown", name.."Cooldown", buff, "CooldownFrameTemplate")
	buff.cooldown:SetAllPoints()
	buff.cooldown:SetReverse(true)
	
	parent["buff"..index] = buff
	buff:Hide()
	return buff
end

local function CreateSpellButton(parent, index)
	local name = parent:GetName() .. "_Spell" .. index
	local btn = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
	btn:SetSize(28, 28)
	btn.index = index
	
	btn:SetPoint("LEFT", parent, "RIGHT", 4 + (index - 1) * 32, 0)
	btn:SetAttribute("type1", "spell")
	btn:SetAttribute("useparent-unit", "true")
	
	btn.icon = btn:CreateTexture(name.."Icon", "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
	btn.icon:SetVertexColor(0.5, 0.5, 0.5)

	btn.debuffHighlight = btn:CreateTexture(nil, "OVERLAY")
	btn.debuffHighlight:SetAllPoints()
	btn.debuffHighlight:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	btn.debuffHighlight:SetBlendMode("ADD")
	btn.debuffHighlight:Hide()
	
	btn:RegisterForClicks("AnyUp")
	btn:RegisterForDrag("LeftButton")
	
	btn:SetScript("OnEnter", function(self) Healbox:OnSpellButtonEnter(self) end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	btn:SetScript("OnReceiveDrag", function(self) Healbox:OnSpellButtonReceiveDrag(self) end)
	btn:SetScript("OnDragStart", function(self) Healbox:OnSpellButtonDragStart(self) end)
	
	return btn
end

local function InitialConfigFunction(self)
	self:SetSize(120, 32)
	self:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 8, edgeSize = 8,
		insets = { left = 2, right = 2, top = 2, bottom = 2 }
	})
	self:SetBackdropColor(0, 0, 0, 0.8)

	self:RegisterForClicks("AnyUp")
	self:SetScript("OnShow", function(self) Healbox:OnUnitFrameShow(self) end)
	self:SetScript("OnHide", function(self) Healbox:OnUnitFrameHide(self) end)
	self:SetScript("OnAttributeChanged", function(self, name, value) Healbox:OnUnitFrameAttributeChanged(self, name, value) end)

	local hb = CreateFrame("StatusBar", self:GetName().."HealthBar", self)
	hb:SetSize(116, 24)
	hb:SetPoint("TOPLEFT", 2, -2)
	hb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	hb:SetStatusBarColor(0, 1, 0)
	self.healthBar = hb

	hb.name = hb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hb.name:SetPoint("LEFT", 6, 0)
	hb.name:SetJustifyH("LEFT")

	hb.hpText = hb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hb.hpText:SetPoint("RIGHT", -6, 0)
	hb.hpText:SetJustifyH("RIGHT")

	local mb = CreateFrame("StatusBar", self:GetName().."ManaBar", self)
	mb:SetSize(116, 4)
	mb:SetPoint("TOPLEFT", hb, "BOTTOMLEFT")
	mb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	mb:SetStatusBarColor(0, 0, 1)
	self.manaBar = mb

	self.spellButtons = {}
	self.debuffHighlight = self:CreateTexture(nil, "OVERLAY")
	self.debuffHighlight:SetAllPoints(self.healthBar)
	self.debuffHighlight:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
	self.debuffHighlight:SetBlendMode("ADD")
	self.debuffHighlight:Hide()

	for i = 1, 4 do CreateBuffFrame(self, i) end
	for i = 1, 15 do self.spellButtons[i] = CreateSpellButton(self, i) end

	Healbox.activeFrames = Healbox.activeFrames or {}
	Healbox.activeFrames[self] = true
	Healbox:UpdateButtons()
end

local function SetupHeader(header, groupFilter, isParty)
	header:SetAttribute("template", "SecureUnitButtonTemplate")
	header.initialConfigFunction = InitialConfigFunction
	header:SetAttribute("showPlayer", true)
	header:SetAttribute("yOffset", -1)
	
	if isParty then
		header:SetAttribute("showParty", true)
		header:SetAttribute("showSolo", true)
		header:SetAttribute("showRaid", true)
	else
		header:SetAttribute("showRaid", true)
		header:SetAttribute("groupFilter", tostring(groupFilter))
	end
	header:Show()
end

function Healbox:CreateGroupHeaders()
	self.activeFrames = {}
	self.headers = {}
	self.containers = {}
	
	local function CreateContainer(name, titleText)
		local container = CreateFrame("Frame", name.."Container", UIParent)
		container:SetSize(120, 16)
		container:EnableMouse(true)
		container:SetMovable(true)
		container:SetClampedToScreen(true)
		container:RegisterForDrag("LeftButton")
		container:SetScript("OnDragStart", container.StartMoving)
		container:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			local point, _, relativePoint, x, y = self:GetPoint()
			Healbox.db.profile.positions[name] = { point = point, relativePoint = relativePoint, x = x, y = y }
		end)
		
		local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		title:SetPoint("TOPLEFT", 5, -2)
		title:SetText(titleText)
		
		local bg = container:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetTexture(0, 0, 0, 0.5)
		
		local header = CreateFrame("Frame", name, container, "SecureGroupHeaderTemplate")
		header:SetPoint("TOPLEFT", container, "BOTTOMLEFT", 0, -2)
		container.header = header
		table.insert(self.containers, container)
		
		return container, header
	end

	local partyContainer, partyHeader = CreateContainer("HealboxPartyHeader", "Party")
	local partyPos = self.db.profile.positions["HealboxPartyHeader"]
	if partyPos then
		partyContainer:SetPoint(partyPos.point, UIParent, partyPos.relativePoint, partyPos.x, partyPos.y)
	else
		partyContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -200)
	end
	SetupHeader(partyHeader, nil, true)
	self.partyContainer = partyContainer
	
	local lastContainer = partyContainer
	for i = 1, 8 do
		local name = "HealboxGroupHeader"..i
		local container, header = CreateContainer(name, "Group " .. i)
		local pos = self.db.profile.positions[name]
		if pos then
			container:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
		else
			container:SetPoint("TOPLEFT", lastContainer, "BOTTOMLEFT", 0, -20)
		end
		SetupHeader(header, i, false)
		container.isGroup = i
		lastContainer = container
	end
end

-- ==========================================
-- Core Addon Logic & Config Table
-- ==========================================

function Healbox:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("HealboxCharacterDB", defaults)
	
	for spellID, cureData in pairs(CuresConfig) do
		local name = GetSpellInfo(spellID)
		if name then CuresByName[name] = cureData end
	end
	
	-- Построение макета меню настроек
	local options = {
		name = "Healbox", type = "group", handler = Healbox,
		args = {
			-- Блок 1: Основные настройки (кнопки и масштаб)
			generalHeader = { type = "header", name = "General Settings", order = 1 },
			buttonCount = { type = "range", name = "Number of Buttons", width = "normal", min = 1, max = 15, step = 1, get = "GetButtonCount", set = "SetButtonCount", order = 2 },
			scale = { type = "range", name = "Scale", width = "normal", min = 0.5, max = 2.0, step = 0.05,
				get = function() return self.db.profile.scale end,
				set = function(_, val) self.db.profile.scale = val; self:UpdateScale() end, order = 3 },
			
			-- Блок 2: Группы (2 горизонтальные линии)
			groupsHeader = { type = "header", name = "Raid Groups", order = 10 },
			-- Кнопки групп добавляются циклом ниже с order от 11 до 18

			-- Блок 3: Видимость (остальные 4 пункта в одну линию)
			visibilityHeader = { type = "header", name = "Visibility Options", order = 20 },
			showParty = { type = "toggle", name = "Show Party", width = 0.75,
				get = function() return self.db.profile.showParty end,
				set = function(_, val) self.db.profile.showParty = val; self:UpdateVisibility() end, order = 21 },
			showMana = { type = "toggle", name = "Show Main Resource", width = 0.75,
				set = function(_, val) self.db.profile.showMana = val; self:UpdateManaBarVisibility() end,
				get = function() return self.db.profile.showMana end, order = 22 },
			showHealthText = { type = "toggle", name = "Show Health Percent", width = 0.75,
				set = function(_, val) self.db.profile.showHealthText = val; self:RefreshAllFrames() end,
				get = function() return self.db.profile.showHealthText end, order = 23 },
			showNameText = { type = "toggle", name = "Show Names", width = 0.75,
				set = function(_, val) self.db.profile.showNameText = val; self:RefreshAllFrames() end,
				get = function() return self.db.profile.showNameText end, order = 24 },
		}
	}
	
	-- Добавляем чекбоксы групп. width = 0.75 позволяет уместить ровно 4 группы в одной строке
	for i = 1, 8 do
		options.args["showGroup"..i] = {
			type = "toggle", name = "Show Group "..i, width = 0.75,
			get = function() return self.db.profile.showGroups[i] end,
			set = function(_, val) self.db.profile.showGroups[i] = val; self:UpdateVisibility() end,
			order = 10 + i,
		}
	end

	LibStub("AceConfig-3.0"):RegisterOptionsTable("Healbox", options)
	self.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Healbox", "Healbox")
	self:RegisterChatCommand("healbox", "ChatCommand")
	self:RegisterChatCommand("hb", "ChatCommand")
end

function Healbox:OnEnable()
	self:RegisterEvent("UNIT_HEALTH")
	self:RegisterEvent("UNIT_MAXHEALTH", "UNIT_HEALTH")
	local powerEvents = {"UNIT_MANA", "UNIT_RAGE", "UNIT_FOCUS", "UNIT_ENERGY", "UNIT_RUNIC_POWER", "UNIT_DISPLAYPOWER"}
	for _, ev in ipairs(powerEvents) do self:RegisterEvent(ev, "UNIT_POWER_UPDATE") end
	
	self:RegisterEvent("UNIT_AURA")
	self:RegisterEvent("SPELLS_CHANGED", "UpdateSpells")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	
	self.activeSpellsHash = {}
	self.unitFrames = {}
	self.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
	
	self:CreateGroupHeaders()
	self:UpdateSpells()
	self:UpdateButtons()
	self:UpdateScale()
	self:UpdateVisibility()
	self:UpdateManaBarVisibility()
	
	self.updateTimer = self:ScheduleRepeatingTimer("OnUpdateTimer", 0.15)
end

function Healbox:ChatCommand() InterfaceOptionsFrame_OpenToCategory(self.optionsFrame) end
function Healbox:GetButtonCount() return self.db.profile.buttonCount end
function Healbox:SetButtonCount(_, val) self.db.profile.buttonCount = val; self:UpdateButtons() end

function Healbox:UNIT_HEALTH(_, unit)
	if not self.unitFrames[unit] then return end
	for frame in pairs(self.unitFrames[unit]) do self:UpdateUnitHealth(frame, unit) end
end

function Healbox:UNIT_POWER_UPDATE(_, unit)
	if not self.unitFrames[unit] then return end
	for frame in pairs(self.unitFrames[unit]) do self:UpdateUnitMana(frame, unit) end
end

function Healbox:UNIT_AURA(_, unit)
	if not self.unitFrames[unit] then return end
	for frame in pairs(self.unitFrames[unit]) do
		self:UpdateUnitBuffs(frame, unit)
		self:UpdateUnitDebuffs(frame, unit)
	end
end

function Healbox:PLAYER_REGEN_ENABLED()
	if self.pendingButtonUpdate then
		self.pendingButtonUpdate = false
		self:UpdateButtons()
	end
end

function Healbox:UpdateSpells()
	wipe(self.activeSpellsHash)
	for i = 1, 15 do
		local spellName = self.db.profile.spells[i]
		if spellName and spellName ~= "" then
			self.activeSpellsHash[spellName] = true
			local _, _, icon = GetSpellInfo(spellName)
			if not self.db.profile.icons[i] and icon then
				self.db.profile.icons[i] = icon
			end
		end
	end
	self:UpdateCures()
	self:UpdateButtons()
end

function Healbox:UpdateCures()
	self.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
	for i = 1, self.db.profile.buttonCount do
		local cure = CuresByName[self.db.profile.spells[i] or ""]
		if cure then
			for k, v in pairs(cure) do if v then self.canCure[k] = true end end
		end
	end
	
	if self.activeFrames then
		for frame in pairs(self.activeFrames) do
			if frame.TargetUnit then self:UpdateUnitDebuffs(frame, frame.TargetUnit) end
		end
	end
end

function Healbox:UpdateButtons()
	if InCombatLockdown() then self.pendingButtonUpdate = true; return end
	
	local count = self.db.profile.buttonCount
	for frame in pairs(self.activeFrames or {}) do
		for i = 1, 15 do
			local btn = frame.spellButtons[i]
			if btn then
				if i <= count then
					btn:Show()
					local spell = self.db.profile.spells[i]
					if spell and spell ~= "" then
						btn:SetAttribute("spell", spell)
						btn.icon:SetTexture(self.db.profile.icons[i])
						btn.icon:SetVertexColor(1, 1, 1)
					else
						btn:SetAttribute("spell", nil)
						btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
						btn.icon:SetVertexColor(0.5, 0.5, 0.5)
					end
				else
					btn:Hide()
				end
			end
		end
	end
end

function Healbox:UpdateVisibility()
	if InCombatLockdown() then return end
	if self.db.profile.showParty then self.partyContainer:Show() else self.partyContainer:Hide() end
	for _, container in ipairs(self.containers) do
		if container.isGroup then
			if self.db.profile.showGroups[container.isGroup] then container:Show() else container:Hide() end
		end
	end
end

function Healbox:UpdateScale()
	for _, container in ipairs(self.containers) do container:SetScale(self.db.profile.scale) end
end

function Healbox:UpdateManaBarVisibility()
	local showMana = self.db.profile.showMana
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
	local count = self.db.profile.buttonCount
	
	for frame in pairs(self.activeFrames) do
		local unit = frame.TargetUnit
		if unit and UnitIsVisible(unit) and not UnitIsDeadOrGhost(unit) then
			for i = 1, count do
				local btn = frame.spellButtons[i]
				if btn and btn:IsShown() then
					local spellName = self.db.profile.spells[i]
					if spellName and spellName ~= "" then
						local isUsable, notEnoughMana = IsUsableSpell(spellName)
						if isUsable then
							btn.icon:SetVertexColor(1, 1, 1)
						elseif notEnoughMana then
							btn.icon:SetVertexColor(0.5, 0.5, 1)
						else
							btn.icon:SetVertexColor(0.3, 0.3, 0.3)
						end
						
						if (isUsable or notEnoughMana) and IsSpellInRange(spellName, unit) == 0 then
							btn.icon:SetVertexColor(1, 0.3, 0.3)
						end
					end
				end
			end
		end
	end
end

function Healbox:UpdateUnitHealth(frame, unit)
	if not UnitExists(unit) then return end
	local hp, maxHp = UnitHealth(unit), math.max(1, UnitHealthMax(unit))
	local isDead = UnitIsDeadOrGhost(unit)
	if isDead then hp = 0 end
	
	frame.healthBar:SetMinMaxValues(0, maxHp)
	frame.healthBar:SetValue(hp)
	
	local percent = hp / maxHp
	frame.healthBar.hpText:SetText(self.db.profile.showHealthText and (isDead and "Dead" or math.floor(percent * 100) .. "%") or "")
	
	if percent < 0.3 then frame.healthBar:SetStatusBarColor(1, 0, 0)
	elseif percent < 0.6 then frame.healthBar:SetStatusBarColor(1, 0.9, 0)
	else frame.healthBar:SetStatusBarColor(0, 1, 0) end
end

function Healbox:UpdateUnitMana(frame, unit)
	if not UnitExists(unit) then return end
	local isDead = UnitIsDeadOrGhost(unit)
	frame.manaBar:SetMinMaxValues(0, math.max(1, UnitPowerMax(unit)))
	frame.manaBar:SetValue(isDead and 0 or UnitPower(unit))
	
	local pType, pToken = UnitPowerType(unit)
	local info = PowerBarColor[pToken] or PowerBarColor[pType]
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
	for i = buffIndex, 4 do if frame["buff"..i] then frame["buff"..i]:Hide() end end
end

function Healbox:UpdateUnitDebuffs(frame, unit)
	wipe(activeDebuffsCache)
	for i = 1, 40 do
		local name, _, _, _, debuffType = UnitDebuff(unit, i)
		if not name then break end
		if debuffType then activeDebuffsCache[debuffType] = true end
	end
	
	local highestDebuff
	for _, dtype in ipairs(DEBUFF_PRIORITY) do
		if activeDebuffsCache[dtype] and self.canCure[dtype] then highestDebuff = dtype; break end
	end
	
	if highestDebuff then
		local c = DebuffTypeColor[highestDebuff]
		frame.debuffHighlight:SetVertexColor(c.r, c.g, c.b, 0.4)
		frame.debuffHighlight:Show()
	else
		frame.debuffHighlight:Hide()
	end
	
	for i = 1, self.db.profile.buttonCount do
		local btn = frame.spellButtons[i]
		if btn and btn:IsShown() then
			local cure = CuresByName[self.db.profile.spells[i] or ""]
			local highlight = false
			if cure then
				for _, dtype in ipairs(DEBUFF_PRIORITY) do
					if activeDebuffsCache[dtype] and cure[dtype] then
						highlight = true
						local c = DebuffTypeColor[dtype]
						btn.debuffHighlight:SetVertexColor(c.r, c.g, c.b)
						break
					end
				end
			end
			if highlight then btn.debuffHighlight:Show() else btn.debuffHighlight:Hide() end
		end
	end
end

-- ==========================================
-- UI Event Handlers
-- ==========================================

function Healbox:OnSpellButtonEnter(btn)
	if not self.db.profile.showTooltips then return end
	local spellName = self.db.profile.spells[btn.index]
	GameTooltip_SetDefaultAnchor(GameTooltip, btn)
	if spellName then
		local link = GetSpellLink(spellName)
		if link then GameTooltip:SetHyperlink(link) end
		local unit = btn:GetParent().TargetUnit
		if unit and UnitExists(unit) then GameTooltip:AddLine("Target: |cFF00FF00" .. (UnitName(unit) or ""), 1, 1, 1) end
	else
		GameTooltip:SetText("|cFFFFFFFFNo Spell|n|cFF00FF00Drag and drop a spell|nhere from your spellbook.")
	end
	GameTooltip:Show()
end

function Healbox:OnSpellButtonReceiveDrag(btn)
	if InCombatLockdown() then print("|cFFFF0000Healbox:|r Cannot change spells in combat."); return end
	local infoType, index, bookType = GetCursorInfo()
	if infoType == "spell" then
		if IsPassiveSpell(index, bookType) then print("|cFFFF0000Healbox:|r Cannot assign passive spells."); return end
		local name, _, icon = GetSpellInfo(GetSpellBookItemName(index, bookType))
		local oldSpell = self.db.profile.spells[btn.index]
		self.db.profile.spells[btn.index] = name
		self.db.profile.icons[btn.index] = icon
		self:UpdateSpells()
		ClearCursor()
		if IsShiftKeyDown() and oldSpell then PickupSpell(oldSpell) end
	end
end

function Healbox:OnSpellButtonDragStart(btn)
	if InCombatLockdown() or not IsShiftKeyDown() then return end
	local spellName = self.db.profile.spells[btn.index]
	if spellName then
		self.db.profile.spells[btn.index] = nil
		self.db.profile.icons[btn.index] = nil
		self:UpdateSpells()
		PickupSpell(spellName)
	end
end

function Healbox:RefreshAllFrames()
	if not self.activeFrames then return end
	for frame in pairs(self.activeFrames) do
		if frame.TargetUnit then
			frame.healthBar.name:SetText(self.db.profile.showNameText and (UnitName(frame.TargetUnit) or "Unknown") or "")
			self:UpdateUnitHealth(frame, frame.TargetUnit)
		end
	end
end

function Healbox:OnUnitFrameShow(frame)
	local unit = frame:GetAttribute("unit")
	if unit then
		frame.TargetUnit = unit
		self.unitFrames[unit] = self.unitFrames[unit] or {}
		self.unitFrames[unit][frame] = true
		frame.healthBar.name:SetText(self.db.profile.showNameText and (UnitName(unit) or "Unknown") or "")
		self:UpdateUnitHealth(frame, unit)
		self:UpdateUnitMana(frame, unit)
		self:UpdateUnitBuffs(frame, unit)
		self:UpdateUnitDebuffs(frame, unit)
	end
	self:UpdateManaBarVisibility()
	self:UpdateButtons()
end

function Healbox:OnUnitFrameHide(frame)
	local unit = frame.TargetUnit
	if unit and self.unitFrames[unit] then self.unitFrames[unit][frame] = nil end
	frame.TargetUnit = nil
end

function Healbox:OnUnitFrameAttributeChanged(frame, name, value)
	if name == "unit" then
		if frame.TargetUnit and self.unitFrames[frame.TargetUnit] then self.unitFrames[frame.TargetUnit][frame] = nil end
		if value and frame:IsShown() then
			frame.TargetUnit = value
			self.unitFrames[value] = self.unitFrames[value] or {}
			self.unitFrames[value][frame] = true
			frame.healthBar.name:SetText(self.db.profile.showNameText and (UnitName(value) or "Unknown") or "")
			self:UpdateUnitHealth(frame, value)
			self:UpdateUnitMana(frame, value)
			self:UpdateUnitBuffs(frame, value)
			self:UpdateUnitDebuffs(frame, value)
		else
			frame.TargetUnit = nil
		end
	end
end