local Healbox = Healbox

local function CreateSpellButton(parent, index)
	local name = parent:GetName() .. "_Spell" .. index
	local btn = CreateFrame("Button", name, parent, "HealboxSpellButtonTemplate")
	
	btn.index = index
	btn:SetPoint("LEFT", parent, "RIGHT", 4 + (index - 1) * 32, 0)
	
	btn:SetAttribute("type1", "spell")
	btn:SetAttribute("useparent-unit", "true")
	
	btn.debuffHighlight = btn:CreateTexture(nil, "OVERLAY")
	btn.debuffHighlight:SetAllPoints()
	btn.debuffHighlight:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	btn.debuffHighlight:SetBlendMode("ADD")
	btn.debuffHighlight:Hide()
	
	return btn
end

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

local function InitialConfigFunction(self)
	self.spellButtons = {}
	
	self.debuffHighlight = self:CreateTexture(nil, "OVERLAY")
	self.debuffHighlight:SetAllPoints(self.healthBar)
	self.debuffHighlight:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
	self.debuffHighlight:SetBlendMode("ADD")
	self.debuffHighlight:Hide()
	
	for i = 1, 4 do
		CreateBuffFrame(self, i)
	end
	
	for i = 1, 15 do
		local btn = CreateSpellButton(self, i)
		self.spellButtons[i] = btn
	end
	
	Healbox.activeFrames = Healbox.activeFrames or {}
	Healbox.activeFrames[self] = true
	
	-- Initialize the layout
	Healbox:UpdateButtons()
end

local function SetupHeader(header, groupFilter, isParty)
	header:SetAttribute("template", "HealboxUnitButtonTemplate")
	header:SetAttribute("templateType", "Button")
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

function Healbox:CreateFrames()
	self.activeFrames = {}
	self.headers = {}
	self.groupHeaders = {}
	self.containers = {}
	
	local function CreateGroupContainer(name, titleText)
		local container = CreateFrame("Frame", name.."Container", UIParent)
		container:SetSize(120, 16)
		container:EnableMouse(true)
		container:SetMovable(true)
		container:SetClampedToScreen(true)
		container:RegisterForDrag("LeftButton")
		container:SetScript("OnDragStart", function(self) self:StartMoving() end)
		container:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			local point, _, relativePoint, x, y = self:GetPoint()
			Healbox.db.profile.positions[name] = { point = point, relativePoint = relativePoint, x = x, y = y }
		end)
		
		local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		title:SetPoint("TOPLEFT", container, "TOPLEFT", 5, -2)
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

	-- Party Header
	local partyContainer, partyHeader = CreateGroupContainer("HealboxPartyHeader", "Party")
	local partyPos = Healbox.db.profile.positions["HealboxPartyHeader"]
	if partyPos then
		partyContainer:ClearAllPoints()
		partyContainer:SetPoint(partyPos.point, UIParent, partyPos.relativePoint, partyPos.x, partyPos.y)
	else
		partyContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -200)
	end
	SetupHeader(partyHeader, nil, true)
	self.partyHeader = partyHeader
	self.partyContainer = partyContainer
	self.headers["Party"] = partyHeader
	
	-- Group Headers (1-8)
	local lastContainer = partyContainer
	for i = 1, 8 do
		local name = "HealboxGroupHeader"..i
		local container, header = CreateGroupContainer(name, "Group " .. i)
		local pos = Healbox.db.profile.positions[name]
		if pos then
			container:ClearAllPoints()
			container:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
		else
			container:SetPoint("TOPLEFT", lastContainer, "BOTTOMLEFT", 0, -20)
		end
		SetupHeader(header, i, false)
		self.groupHeaders[i] = header
		self.headers["Group"..i] = header
		container.isGroup = i
		lastContainer = container
	end
end

function Healbox:UpdateVisibility()
	if InCombatLockdown() then
		print("|cFFFF0000Healbox:|r Cannot change frame visibility in combat.")
		return
	end
	
	if self.db.profile.showParty then
		self.partyContainer:Show()
		self.partyContainer.header:Show()
	else
		self.partyContainer:Hide()
		self.partyContainer.header:Hide()
	end
	
	for _, container in ipairs(self.containers) do
		if container.isGroup then
			if self.db.profile.showGroups[container.isGroup] then
				container:Show()
				container.header:Show()
			else
				container:Hide()
				container.header:Hide()
			end
		end
	end
end

function Healbox:UpdateScale()
	local scale = self.db.profile.scale
	for _, container in ipairs(self.containers) do
		container:SetScale(scale)
	end
end

function Healbox:OnUnitFrameShow(frame)
	local unit = frame:GetAttribute("unit")
	if unit then
		frame.TargetUnit = unit
		self.unitFrames[unit] = self.unitFrames[unit] or {}
		self.unitFrames[unit][frame] = true
		
		if Healbox.db.profile.showNameText then
			frame.healthBar.name:SetText(UnitName(unit) or "Unknown")
		else
			frame.healthBar.name:SetText("")
		end
		
		self:UpdateUnitHealth(frame, unit)
		self:UpdateUnitMana(frame, unit)
		if self.UpdateUnitBuffs then self:UpdateUnitBuffs(frame, unit) end
		if self.UpdateUnitDebuffs then self:UpdateUnitDebuffs(frame, unit) end
	end
	
	self:UpdateManaBarVisibility()
	self:UpdateButtons()
end

function Healbox:OnUnitFrameHide(frame)
	local unit = frame.TargetUnit
	if unit and self.unitFrames[unit] then
		self.unitFrames[unit][frame] = nil
	end
	frame.TargetUnit = nil
end

function Healbox:OnUnitFrameAttributeChanged(frame, name, value)
	if name == "unit" then
		if frame.TargetUnit and self.unitFrames[frame.TargetUnit] then
			self.unitFrames[frame.TargetUnit][frame] = nil
		end
		
		if value and frame:IsShown() then
			frame.TargetUnit = value
			self.unitFrames[value] = self.unitFrames[value] or {}
			self.unitFrames[value][frame] = true
			
			if Healbox.db.profile.showNameText then
				frame.healthBar.name:SetText(UnitName(value) or "Unknown")
			else
				frame.healthBar.name:SetText("")
			end
			
			self:UpdateUnitHealth(frame, value)
			self:UpdateUnitMana(frame, value)
			if Healbox.UpdateUnitBuffs then Healbox:UpdateUnitBuffs(frame, value) end
			if Healbox.UpdateUnitDebuffs then Healbox:UpdateUnitDebuffs(frame, value) end
		else
			frame.TargetUnit = nil
		end
	end
end
