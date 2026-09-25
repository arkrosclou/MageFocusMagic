--[[ MageFocusMagic - the slash command and the options panel.

	Four settings, one column, no scrolling: the button size, the size of the
	blocks in the panel, which way the panel opens, and whether the button can
	be dragged. ]]

local MFM = MageFocusMagic

-- ---------------------------------------------------------------------------
-- slash command
-- ---------------------------------------------------------------------------
SLASH_MAGEFOCUSMAGIC1 = "/mfm"
SlashCmdList["MAGEFOCUSMAGIC"] = function(msg)
	-- the addon only sets itself up on a mage
	if not MFM.db then
		MFM:Print("this addon only does something on a mage")
		return
	end
	local db = MFM.db
	local cmd = string.lower(strtrim(msg or ""))
	if cmd == "" or cmd == "config" then
		MFM:OpenOptions()
	elseif cmd == "toggle" then
		MFM:TogglePanel()
	elseif cmd == "lock" or cmd == "unlock" then
		db.locked = cmd == "lock"
		if MFM.RefreshOptions then MFM:RefreshOptions() end
		MFM:Print("button " .. (db.locked and "locked" or "unlocked"))
	elseif cmd == "reset" then
		MFM:ResetPosition()
		MFM:Print("button moved back to the center")
	elseif cmd == "plan" then
		if #MFM.groups == 0 or MFM.sample then
			MFM:Print("no other mage in the group")
		else
			MFM:Print(MFM:PlanText())
		end
	else
		MFM:Print("commands: config | toggle | lock | unlock | reset | plan")
		MFM:Print("click a name to whisper the order, an icon to cast " .. MFM.FM_NAME)
	end
end

-- ---------------------------------------------------------------------------
-- options panel
-- ---------------------------------------------------------------------------
-- One column, every widget placed below the previous one by a running y.
local PAD = 16

local widgetCount = 0
local function uniqueName(kind)
	widgetCount = widgetCount + 1
	return "MageFocusMagic" .. kind .. widgetCount
end

local function header(parent, y, text)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetPoint("TOPLEFT", PAD, y)
	fs:SetText(text)
	return y - 22
end

function MFM:OpenOptions()
	InterfaceOptionsFrame_OpenToCategory(self.options)
	InterfaceOptionsFrame_OpenToCategory(self.options) -- the first call only opens the frame
end

function MFM:InitConfig()
	local db = self.db
	local panel = CreateFrame("Frame", "MageFocusMagicOptions", UIParent)
	panel.name = "|cff69ccf0Mage|rFocusMagic"
	self.options = panel

	local checks, radios, sliders = {}, {}, {}

	local y = -PAD
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", PAD, y)
	title:SetText("|cff69ccf0Mage|rFocusMagic")
	y = y - 22
	local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", PAD, y)
	note:SetWidth(400)
	note:SetJustifyH("LEFT")
	note:SetText("Left-click the button for the order, right-click for these options, drag to move it. "
		.. "In the panel, click a name to whisper that mage the order, or an icon to cast Focus Magic.")
	y = y - 34

	-- 1. the button
	y = header(panel, y, "Button")
	local cb = CreateFrame("CheckButton", uniqueName("Check"), panel, "InterfaceOptionsCheckButtonTemplate")
	cb:SetPoint("TOPLEFT", PAD - 4, y)
	_G[cb:GetName() .. "Text"]:SetText("Lock the button in place")
	cb:SetScript("OnClick", function(s) db.locked = s:GetChecked() and true or false end)
	cb.get = function() return db.locked end
	checks[#checks + 1] = cb
	y = y - 26

	-- sliders: label above, value in the label, applied as it moves
	local function slider(label, minV, maxV, get, set)
		y = y - 18
		local s = CreateFrame("Slider", uniqueName("Slider"), panel, "OptionsSliderTemplate")
		local name = s:GetName()
		s:SetPoint("TOPLEFT", PAD + 4, y)
		s:SetWidth(220)
		s:SetMinMaxValues(minV, maxV)
		s:SetValueStep(1)
		_G[name .. "Low"]:SetText(tostring(minV))
		_G[name .. "High"]:SetText(tostring(maxV))
		s:SetScript("OnValueChanged", function(_, v)
			v = math.floor(v + 0.5)
			_G[name .. "Text"]:SetText(label .. ": " .. v .. " px")
			if get() ~= v then set(v) end
		end)
		s.refresh = function()
			s:SetValue(get())
			_G[name .. "Text"]:SetText(label .. ": " .. get() .. " px")
		end
		sliders[#sliders + 1] = s
		y = y - 40
	end
	slider("Button size", 16, 64,
		function() return db.buttonSize end,
		function(v) db.buttonSize = v self:ApplySettings() end)
	slider("Row height", 14, 40,
		function() return db.iconSize end,
		function(v) db.iconSize = v self:ApplySettings() end)

	-- 2. which way the panel opens
	y = header(panel, y, "The order opens")
	for _, a in ipairs(self.ANCHORS) do
		local r = CreateFrame("CheckButton", uniqueName("Radio"), panel, "UIRadioButtonTemplate")
		r:SetPoint("TOPLEFT", PAD, y)
		_G[r:GetName() .. "Text"]:SetText(a.label)
		r.key = a.key
		r:SetScript("OnClick", function()
			db.anchor = a.key
			self:RefreshOptions()
			self:ApplySettings()
		end)
		radios[#radios + 1] = r
		y = y - 20
	end

	y = y - 12
	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetPoint("TOPLEFT", PAD, y)
	reset:SetWidth(160)
	reset:SetHeight(22)
	reset:SetText("Reset button position")
	reset:SetScript("OnClick", function() self:ResetPosition() end)

	function self:RefreshOptions()
		for _, c in ipairs(checks) do c:SetChecked(c.get()) end
		for _, r in ipairs(radios) do r:SetChecked(r.key == db.anchor) end
		for _, s in ipairs(sliders) do s.refresh() end
	end
	panel:SetScript("OnShow", function() self:RefreshOptions() end)
	InterfaceOptions_AddCategory(panel)
end
