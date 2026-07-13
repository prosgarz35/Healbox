Healbox = LibStub("AceAddon-3.0"):NewAddon("Healbox", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
local L = Healbox

local defaults = {
	profile = {
		buttonCount = 5,
		spells = {},
		icons = {},
		positions = {},
		showParty = true,
		showGroups = { false, false, false, false, false, false, false, false },
		scale = 1.0,
		showTooltips = true,
		showMana = true,
		showHealthText = true,
		showNameText = true,
	}
}

local CuresConfig = {
	[2782] = { Curse = true },
	[2893] = { Poison = true },
	[8946] = { Poison = true },
	[552] = { Disease = true },
	[528] = { Disease = true },
	[527] = { Magic = true },
	[526]   = { Poison = true, Disease = true },
	[51886] = { Poison = true, Disease = true, Curse = true },
	[1152] = { Poison = true, Disease = true },
	[4987] = { Poison = true, Disease = true, Magic = true },
	[475] = { Curse = true },
	[520869] = { Poison = true, Disease = true },
}
local CuresByName = {}
local DEBUFF_PRIORITY = { "Curse", "Disease", "Magic", "Poison" }

function Healbox:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("HealboxCharacterDB", defaults)
	
	local options = {
		name = "Healbox",
		handler = Healbox,
		type = "group",
		args = {
			buttonCount = {
				type = "range",
				name = "Number of Buttons",
				desc = "Number of healing buttons next to each frame",
				min = 1, max = 15, step = 1,
				get = "GetButtonCount",
				set = "SetButtonCount",
				order = 1,
			},
			scale = {
				type = "range",
				name = "Scale",
				desc = "Scale of the unit frames",
				min = 0.5, max = 2.0, step = 0.05,
				get = function(info) return self.db.profile.scale end,
				set = function(info, val) self.db.profile.scale = val; self:UpdateScale() end,
				order = 2,
			},
			showParty = {
				type = "toggle",
				name = "Show Party",
				get = function() return self.db.profile.showParty end,
				set = function(info, val) self.db.profile.showParty = val; self:UpdateVisibility() end,
				order = 3,
			},
			showMana = {
				type = "toggle",
				name = "Show Mana",
				desc = "Show mana bars",
				order = 13,
				set = function(info, val) self.db.profile.showMana = val; self:UpdateManaBarVisibility() end,
				get = function(info) return self.db.profile.showMana end,
			},
			showHealthText = {
				type = "toggle",
				name = "Show Health Percent",
				desc = "Show health percentages on the bar",
				order = 14,
				set = function(info, val) self.db.profile.showHealthText = val; self:RefreshAllFrames() end,
				get = function(info) return self.db.profile.showHealthText end,
			},
			showNameText = {
				type = "toggle",
				name = "Show Names",
				desc = "Show character names on the bar",
				order = 15,
				set = function(info, val) self.db.profile.showNameText = val; self:RefreshAllFrames() end,
				get = function(info) return self.db.profile.showNameText end,
			},
		},
	}
	for i = 1, 8 do
		options.args["showGroup"..i] = {
			type = "toggle",
			name = "Show Group "..i,
			get = function() return self.db.profile.showGroups[i] end,
			set = function(info, val) self.db.profile.showGroups[i] = val; self:UpdateVisibility() end,
			order = 4 + i,
		}
	end

	LibStub("AceConfig-3.0"):RegisterOptionsTable("Healbox", options)
	self.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Healbox", "Healbox")
	self:RegisterChatCommand("healbox", "ChatCommand")
	self:RegisterChatCommand("hb", "ChatCommand")
end

function Healbox:GetButtonCount(info)
	return self.db.profile.buttonCount
end

function Healbox:SetButtonCount(info, val)
	self.db.profile.buttonCount = val
	self:UpdateButtons()
end

function Healbox:ChatCommand(input)
	if not input or input:trim() == "" then
		InterfaceOptionsFrame_OpenToCategory(self.optionsFrame)
		InterfaceOptionsFrame_OpenToCategory(self.optionsFrame)
	end
end

function Healbox:OnEnable()
	self:RegisterEvent("UNIT_HEALTH")
	self:RegisterEvent("UNIT_MAXHEALTH", "UNIT_HEALTH")
	self:RegisterEvent("UNIT_MANA", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_RAGE", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_FOCUS", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_ENERGY", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_RUNIC_POWER", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_MAXMANA", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_MAXRAGE", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_MAXFOCUS", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_MAXENERGY", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_MAXRUNIC_POWER", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_DISPLAYPOWER", "UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_AURA")
	self:RegisterEvent("SPELLS_CHANGED")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("RAID_TARGET_UPDATE")
	
	self.spellIDs = {}
	self.activeSpellsHash = {}
	self.unitFrames = {}
	self.headers = {}
	self.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
	
	for spellID, cureData in pairs(CuresConfig) do
		local name = GetSpellInfo(spellID)
		if name then CuresByName[name] = cureData end
	end
	
	if self.CreateFrames then
		self:CreateFrames()
	end
	self:UpdateSpells()
	self:UpdateButtons()
	self:UpdateScale()
	self:UpdateVisibility()
	self:UpdateManaBarVisibility()
	
	self.updateTimer = self:ScheduleRepeatingTimer("OnUpdateTimer", 0.15)
end

function Healbox:OnDisable()
	self:CancelTimer(self.updateTimer)
end

function Healbox:UNIT_HEALTH(event, unit)
	if self.unitFrames[unit] then
		for frame in pairs(self.unitFrames[unit]) do
			self:UpdateUnitHealth(frame, unit)
		end
	end
end

function Healbox:UNIT_POWER_UPDATE(event, unit)
	if self.unitFrames[unit] then
		for frame in pairs(self.unitFrames[unit]) do
			self:UpdateUnitMana(frame, unit)
		end
	end
end

function Healbox:UNIT_AURA(event, unit)
	if self.unitFrames[unit] then
		for frame in pairs(self.unitFrames[unit]) do
			self:UpdateUnitBuffs(frame, unit)
			self:UpdateUnitDebuffs(frame, unit)
		end
	end
end

function Healbox:SPELLS_CHANGED()
	self:UpdateSpells()
end

function Healbox:PLAYER_REGEN_ENABLED()
	if self.pendingButtonUpdate then
		self.pendingButtonUpdate = false
		self:UpdateButtons()
	end
end

function Healbox:RAID_TARGET_UPDATE()
	-- implementation if needed
end

function Healbox:UpdateSpells()
	wipe(self.spellIDs)
	wipe(self.activeSpellsHash)
	
	for i = 1, 15 do
		local spellName = self.db.profile.spells[i]
		if spellName and spellName ~= "" then
			self.activeSpellsHash[spellName] = true
			
			local _, _, icon, _, _, _, spellID = GetSpellInfo(spellName)
			if spellID then
				self.spellIDs[i] = spellID
				if not self.db.profile.icons[i] then
					self.db.profile.icons[i] = icon
				end
			else
				local link = GetSpellLink(spellName)
				if link then
					spellID = tonumber(link:match("spell:(%d+)"))
					self.spellIDs[i] = spellID
				end
			end
		end
	end
	self:UpdateCures()
	self:UpdateButtons()
end

function Healbox:UpdateCures()
	self.canCure = { Curse = false, Disease = false, Magic = false, Poison = false }
	for i = 1, self.db.profile.buttonCount do
		local spellName = self.db.profile.spells[i]
		local cure = spellName and CuresByName[spellName]
		if cure then
			for k, v in pairs(cure) do
				if v then self.canCure[k] = true end
			end
		end
	end
	
	-- Refresh debuffs on all active frames
	if self.activeFrames then
		for frame in pairs(self.activeFrames) do
			if frame.TargetUnit then
				self:UpdateUnitDebuffs(frame, frame.TargetUnit)
			end
		end
	end
end

function Healbox:UpdateButtons()
	if InCombatLockdown() then
		self.pendingButtonUpdate = true
		return
	end
	
	local count = self.db.profile.buttonCount
	for frame in pairs(self.activeFrames or {}) do
		for i = 1, 15 do
			local btn = frame.spellButtons[i]
			if btn then
				if i <= count then
					btn:Show()
					local spell = self.db.profile.spells[i]
					btn:SetAttribute("type", "spell")
					if spell and spell ~= "" then
						btn:SetAttribute("spell", spell)
						btn.icon:SetTexture(self.db.profile.icons[i] or "Interface\\Icons\\INV_Misc_QuestionMark")
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

function Healbox:UpdateManaBarVisibility()
	local showMana = self.db.profile.showMana
	for frame in pairs(self.activeFrames or {}) do
		if showMana then
			frame.manaBar:Show()
			frame.healthBar:SetHeight(24)
			frame.healthBar:SetPoint("TOPLEFT", 2, -2)
		else
			frame.manaBar:Hide()
			frame.healthBar:SetHeight(28)
			frame.healthBar:SetPoint("TOPLEFT", 2, -2)
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
							btn.icon:SetVertexColor(1.0, 1.0, 1.0)
						elseif notEnoughMana then
							btn.icon:SetVertexColor(0.5, 0.5, 1.0)
						else
							btn.icon:SetVertexColor(0.3, 0.3, 0.3)
						end
						
						-- Only check range if not already unusable
						if isUsable or notEnoughMana then
							if SpellHasRange(spellName) then
								local inRange = IsSpellInRange(spellName, unit)
								if inRange == 0 then
									btn.icon:SetVertexColor(1.0, 0.3, 0.3)
								end
							end
						end
					end
				end
			end
		end
	end
end

function Healbox:UpdateUnitHealth(frame, unit)
	if not unit or not UnitExists(unit) then return end
	local hp = UnitHealth(unit)
	local maxHp = math.max(1, UnitHealthMax(unit))
	local isDead = UnitIsDeadOrGhost(unit)
	
	if isDead then hp = 0 end
	
	frame.healthBar:SetMinMaxValues(0, maxHp)
	frame.healthBar:SetValue(hp)
	
	local percent = hp / maxHp
	if self.db.profile.showHealthText then
		frame.healthBar.hpText:SetText(isDead and "Dead" or math.floor(percent * 100) .. "%")
	else
		frame.healthBar.hpText:SetText("")
	end
	
	if percent < 0.3 then
		frame.healthBar:SetStatusBarColor(1, 0, 0)
	elseif percent < 0.6 then
		frame.healthBar:SetStatusBarColor(1, 0.9, 0)
	else
		frame.healthBar:SetStatusBarColor(0, 1, 0)
	end
end

function Healbox:UpdateUnitMana(frame, unit)
	if not unit or not UnitExists(unit) then return end
	local mana = UnitPower(unit)
	local maxMana = math.max(1, UnitPowerMax(unit))
	local isDead = UnitIsDeadOrGhost(unit)
	
	if isDead then mana = 0 end
	
	frame.manaBar:SetMinMaxValues(0, maxMana)
	frame.manaBar:SetValue(mana)
	
	local powerType, powerToken = UnitPowerType(unit)
	local info = PowerBarColor[powerToken] or PowerBarColor[powerType]
	if info then
		frame.manaBar:SetStatusBarColor(info.r, info.g, info.b)
	end
end

function Healbox:UpdateUnitBuffs(frame, unit)
	local buffIndex = 1
	for i = 1, 40 do
		local name, rank, icon, count, debuffType, duration, expirationTime, unitCaster = UnitBuff(unit, i)
		if not name then break end
		if unitCaster == "player" and self.activeSpellsHash[name] then
			local buffFrame = frame["buff"..buffIndex]
			if buffFrame then
				buffFrame.icon:SetTexture(icon)
				if count > 1 then
					buffFrame.count:SetText(count)
				else
					buffFrame.count:SetText("")
				end
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
	for i = buffIndex, 4 do
		if frame["buff"..i] then frame["buff"..i]:Hide() end
	end
end

function Healbox:UpdateUnitDebuffs(frame, unit)
	local debuffs = {}
	
	for i = 1, 40 do
		local name, rank, icon, count, debuffType = UnitDebuff(unit, i)
		if not name then break end
		if debuffType then
			debuffs[debuffType] = true
		end
	end
	
	local activeDebuffColor = nil
	local highestDebuff = nil
	
	for _, dtype in ipairs(DEBUFF_PRIORITY) do
		if debuffs[dtype] and self.canCure[dtype] then
			activeDebuffColor = DebuffTypeColor[dtype] or DebuffTypeColor["none"]
			highestDebuff = dtype
			break
		end
	end
	
	if highestDebuff then
		frame.debuffHighlight:SetVertexColor(activeDebuffColor.r, activeDebuffColor.g, activeDebuffColor.b, 0.4)
		frame.debuffHighlight:Show()
	else
		frame.debuffHighlight:Hide()
	end
	
	for i = 1, self.db.profile.buttonCount do
		local btn = frame.spellButtons[i]
		if btn and btn:IsShown() then
			local spellName = self.db.profile.spells[i]
			local cure = spellName and CuresByName[spellName]
			local highlight = false
			if cure then
				for _, dtype in ipairs(DEBUFF_PRIORITY) do
					if debuffs[dtype] and cure[dtype] then
						highlight = true
						local color = DebuffTypeColor[dtype]
						btn.debuffHighlight:SetVertexColor(color.r, color.g, color.b)
						break
					end
				end
			end
			if highlight then
				btn.debuffHighlight:Show()
			else
				btn.debuffHighlight:Hide()
			end
		end
	end
end

-- Drag and Drop Support
function Healbox:OnSpellButtonEnter(btn)
	if not self.db.profile.showTooltips then return end
	local spellName = self.db.profile.spells[btn.index]
	if spellName then
		GameTooltip_SetDefaultAnchor(GameTooltip, btn)
		local link = GetSpellLink(spellName)
		if link then
			GameTooltip:SetHyperlink(link)
		end
		local unit = btn:GetParent().TargetUnit
		if unit and UnitExists(unit) then
			GameTooltip:AddLine("Target: |cFF00FF00" .. (UnitName(unit) or ""), 1, 1, 1)
		end
		GameTooltip:Show()
	else
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:SetText("|cFFFFFFFFNo Spell|n|cFF00FF00Drag and drop a spell|nhere from your spellbook.")
		GameTooltip:Show()
	end
end

function Healbox:OnSpellButtonReceiveDrag(btn)
	if InCombatLockdown() then
		print("|cFFFF0000Healbox:|r Cannot change spells in combat.")
		return
	end
	
	local infoType, index, bookType = GetCursorInfo()
	if infoType == "spell" then
		local spellName = GetSpellBookItemName(index, bookType)
		if IsPassiveSpell(index, bookType) then
			print("|cFFFF0000Healbox:|r Cannot assign passive spells.")
			return
		end
		
		local name, rank, icon = GetSpellInfo(spellName)
		local oldSpell = self.db.profile.spells[btn.index]
		self.db.profile.spells[btn.index] = name
		self.db.profile.icons[btn.index] = icon
		
		self:UpdateSpells()
		ClearCursor()
		
		if IsShiftKeyDown() and oldSpell then
			PickupSpell(oldSpell)
		end
	end
end

function Healbox:OnSpellButtonDragStart(btn)
	if InCombatLockdown() then return end
	if IsShiftKeyDown() then
		local spellName = self.db.profile.spells[btn.index]
		if spellName then
			self.db.profile.spells[btn.index] = nil
			self.db.profile.icons[btn.index] = nil
			self:UpdateSpells()
			PickupSpell(spellName)
		end
	end
end

function Healbox:RefreshAllFrames()
	if self.activeFrames then
		for frame in pairs(self.activeFrames) do
			if frame.TargetUnit then
				if self.db.profile.showNameText then
					frame.healthBar.name:SetText(UnitName(frame.TargetUnit) or "Unknown")
				else
					frame.healthBar.name:SetText("")
				end
				self:UpdateUnitHealth(frame, frame.TargetUnit)
			end
		end
	end
end
