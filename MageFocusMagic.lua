--[[ MageFocusMagic - who trades Focus Magic with whom (WoW 3.3.5a)

	Every mage in the group is put into a trade: pairs where possible, and a
	ring of three for the odd one out. The plan is built from the mage names
	sorted alphabetically, so every mage running this addon sees exactly the
	same plan without anyone having to agree on anything. Raid indices are not
	used for that: they differ between a party and a raid, and they shift as
	people join and leave.

	A Focus Magic button sits on screen; clicking it opens the panel with one
	row per trade. In the panel, clicking a name whispers that mage the order,
	clicking an icon casts Focus Magic on them. ]]

MageFocusMagic = {}
local MFM = MageFocusMagic

local FOCUS_MAGIC = 54646
local FM_NAME = GetSpellInfo(FOCUS_MAGIC) or "Focus Magic"
local FM_ICON = select(3, GetSpellInfo(FOCUS_MAGIC))
	or "Interface\\Icons\\Spell_Arcane_StudentOfMagic"

-- The tag names the addon in the one message that asks for something; the
-- order itself goes out plain, so it reads like a line somebody typed.
local TAG = "[MageFocusMagic]"
local ORDER = "Focus Magic order: "

local FLAT = "Interface\\Buttons\\WHITE8X8"
local MAGE_COLOR = { 0.41, 0.80, 0.94 }

local SEP_W   = 18 -- the "<>" or ">" between two blocks
local ROW_GAP = 5
local PAD     = 8

-- A block is its icon plus room for a name. Every block in the panel is the
-- same width, so the rows line up into columns, and a name longer than that is
-- cut short with "..." rather than widening its row.
local function blockH() return MFM.db.iconSize end
local function nameW() return MFM.db.iconSize * 4 end

-- one whisper asking for the trade per player per 10 minutes, and the order
-- itself at most once every 10 seconds, however many names get clicked
local ASK_COOLDOWN = 600
local PLAN_COOLDOWN = 10

MFM.defaults = {
	point = { "CENTER", "CENTER", 0, 0 }, -- the button
	locked = false,
	buttonSize = 32,
	iconSize = 22,   -- a block in the panel is this tall
	anchor = "auto", -- which way the panel opens, see ANCHORS
}

-- Where the panel opens from the button, the same choices RaidLeadKit offers.
-- "auto" picks the corner that keeps the panel away from the screen edges.
MFM.ANCHORS = {
	{ key = "auto",      label = "Automatic (away from the screen edges)" },
	{ key = "below",     label = "Below, growing right",  "TOPLEFT",     "BOTTOMLEFT",  0, -2 },
	{ key = "belowLeft", label = "Below, growing left",   "TOPRIGHT",    "BOTTOMRIGHT", 0, -2 },
	{ key = "above",     label = "Above, growing right",  "BOTTOMLEFT",  "TOPLEFT",     0, 2 },
	{ key = "aboveLeft", label = "Above, growing left",   "BOTTOMRIGHT", "TOPRIGHT",    0, 2 },
	{ key = "right",     label = "To the right",          "TOPLEFT",     "TOPRIGHT",    2, 0 },
	{ key = "left",      label = "To the left",           "TOPRIGHT",    "TOPLEFT",    -2, 0 },
}

MFM.mages = {}   -- sorted list of { name, unit, buffed, mine }
MFM.groups = {}  -- list of { kind = "pair"|"chain", [1..n] = name }
MFM.byName = {}  -- name -> its entry in mages, refilled per draw
MFM.giver = {}   -- name -> the mage the plan has casting on them
MFM.lastAsk = {}     -- name -> when we last asked them
MFM.lastPlan = 0     -- the whispered order
MFM.lastAnnounce = 0 -- the announce, on its own cooldown

local function print_(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff69ccf0MageFocusMagic|r: " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- the plan
-- ---------------------------------------------------------------------------
-- every token string is built once here, so a scan allocates none of them
local RAID_TOKENS, PARTY_TOKENS = {}, { "player" }
for i = 1, 40 do RAID_TOKENS[i] = "raid" .. i end
for i = 1, 4 do PARTY_TOKENS[i + 1] = "party" .. i end

local function byName(a, b) return a.name < b.name end

-- Offline mages are left out: they cannot cast anything, and including them
-- would shift everyone else's partner the moment they log back in.
--
-- The entry tables are reused between scans. This runs on every roster change
-- for the whole raid, and there is no reason to hand the collector a fresh set
-- of tables each time.
local function collectMages(out)
	local raid = GetNumRaidMembers()
	local tokens = raid > 0 and RAID_TOKENS or PARTY_TOKENS
	local n = raid > 0 and raid or (GetNumPartyMembers() + 1)
	local found = 0
	for i = 1, n do
		local unit = tokens[i]
		local _, class = UnitClass(unit)
		if class == "MAGE" and UnitIsConnected(unit) then
			local name = UnitName(unit)
			if name then
				found = found + 1
				local e = out[found]
				if not e then e = {} out[found] = e end
				e.name, e.unit, e.sample = name, unit, nil
				e.buffed, e.mine, e.caster = nil, nil, nil
			end
		end
	end
	for i = #out, found + 1, -1 do out[i] = nil end
	table.sort(out, byName)
	return out
end

-- Pairs are the best trade: both mages feed each other. An odd mage out cannot
-- be paired, so the last three form a ring instead - A gives to B, B to C,
-- C back to A. Three is the smallest ring, so it is the only one ever needed.
-- The group tables are reused too; a pair has to clear the third slot a ring
-- may have left there.
local function putGroup(out, at, kind, a, b, c)
	local g = out[at]
	if not g then g = {} out[at] = g end
	g.kind, g[1], g[2], g[3] = kind, a, b, c
	return g
end

local function buildGroups(mages, out)
	local n = #mages
	local made = 0
	if n >= 2 then
		local lastPair = (n % 2 == 0) and n or (n - 3)
		local i = 1
		while i <= lastPair do
			made = made + 1
			putGroup(out, made, "pair", mages[i].name, mages[i + 1].name, nil)
			i = i + 2
		end
		if i <= n then
			made = made + 1
			putGroup(out, made, "chain", mages[i].name, mages[i + 1].name, mages[i + 2].name)
		end
	end
	for i = #out, made + 1, -1 do out[i] = nil end
	return out
end

local function groupOf(groups, name)
	for _, g in ipairs(groups) do
		for _, member in ipairs(g) do
			if member == name then return g end
		end
	end
	return nil
end

---One group as a line of text: "A <> B", or "A > B > C > A" for a ring.
local function groupText(g)
	if g.kind == "pair" then
		return g[1] .. " <> " .. g[2]
	end
	return table.concat(g, " > ") .. " > " .. g[1]
end

-- Who is in the group only changes when the roster does, and the roster says
-- so with an event. Between those, a refresh is just the buff read below: one
-- UnitBuff per mage, a handful of calls even in a full raid.
---With mineOnly, only your own target is read: nothing else is on screen.
function MFM:Rebuild(mineOnly)
	if self.rosterDirty then
		self.rosterDirty = false
		collectMages(self.mages)
		buildGroups(self.mages, self.groups)
	end
	local only = mineOnly and self:MyTarget() or nil
	for _, m in ipairs(self.mages) do
		if not only or m.name == only then
			local name, _, _, _, _, _, _, caster = UnitBuff(m.unit, FM_NAME)
			m.buffed = name ~= nil
			-- the border is about the one Focus Magic that is yours to keep up,
			-- so whose it is matters, not just that there is one
			m.mine = caster == "player"
			-- The game only names the caster while it can see them, so this is
			-- nil for a Focus Magic cast by somebody out of range. Unknown is
			-- not the same as wrong, and is never drawn as a mistake.
			m.caster = caster and UnitName(caster) or nil
		end
	end
end

-- Opened unlocked with nobody to show, the panel fills itself with a raid of
-- seven: two pairs and a ring, three rows, so its size and place can be judged
-- for what a raid will look like. Nothing here is clickable, and none of it
-- ever reaches chat.
local SAMPLE = { "Mage1", "Mage2", "Mage3", "Mage4", "Mage5", "Mage6", "Mage7" }

-- Built once and kept aside: the stand-ins never touch the real roster, so
-- nothing has to be undone when a mage finally shows up.
function MFM:SampleData()
	if not self.sampleMages then
		self.sampleMages, self.sampleGroups = {}, {}
		for i, name in ipairs(SAMPLE) do
			-- a couple of them without the buff, to show the borders
			self.sampleMages[i] = { name = name, sample = true,
				buffed = (i % 3) ~= 0, mine = false }
		end
		buildGroups(self.sampleMages, self.sampleGroups)
	end
	return self.sampleMages, self.sampleGroups
end

---The mage the plan has you casting Focus Magic on: the next one in your group.
function MFM:MyTarget()
	local me = UnitName("player")
	local g = groupOf(self.groups, me)
	if not g then return nil end
	for i, name in ipairs(g) do
		if name == me then return g[i % #g + 1] end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- chat
-- ---------------------------------------------------------------------------
-- Two whispers: the ask, which is the same words every time and would be spam
-- if repeated, and the order itself. They have their own cooldowns, so a
-- second click still resends the order but does not nag them again.
function MFM:Whisper(name)
	if name == UnitName("player") or self.sample then return end
	local g = groupOf(self.groups, name)
	if not g then return end

	local t = GetTime()
	if t - (self.lastAsk[name] or -ASK_COOLDOWN) >= ASK_COOLDOWN then
		self.lastAsk[name] = t
		SendChatMessage(TAG .. ": please use this Focus Magic order.", "WHISPER", nil, name)
	end
	if t - self.lastPlan < PLAN_COOLDOWN then
		print_(string.format("whisper is on cooldown, %ds left",
			math.ceil(PLAN_COOLDOWN - (t - self.lastPlan))))
		return
	end
	self.lastPlan = t
	SendChatMessage(ORDER .. groupText(g), "WHISPER", nil, name)
end

---Every group in one line, for the announce.
local planParts = {}
function MFM:PlanText()
	local parts = planParts
	wipe(parts)
	for i, g in ipairs(self.groups) do
		parts[i] = groupText(g)
	end
	-- "||" prints as one "|": a single one starts an escape code and the game
	-- refuses the whole message
	return table.concat(parts, " || ")
end

function MFM:Announce()
	if #self.groups == 0 then return end
	if self.sample then
		print_("these are placeholders - nothing to announce yet")
		return
	end
	local t = GetTime()
	if t - self.lastAnnounce < PLAN_COOLDOWN then
		print_(string.format("announce is on cooldown, %ds left",
			math.ceil(PLAN_COOLDOWN - (t - self.lastAnnounce))))
		return
	end
	self.lastAnnounce = t
	SendChatMessage(ORDER .. self:PlanText(),
		GetNumRaidMembers() > 0 and "RAID" or "PARTY")
end

-- ---------------------------------------------------------------------------
-- player blocks
-- ---------------------------------------------------------------------------
-- A block is an icon and a name side by side. The icon is a secure button, the
-- only way an addon may cast: the game itself reads the macro on the click.
-- The name next to it is a plain button that whispers. They never overlap, so
-- a click always goes where it looks like it goes.
function MFM:GetBlock(i)
	local b = self.blocks[i]
	if b then return b end

	b = CreateFrame("Frame", nil, self.panel)
	b:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
	b:SetBackdropBorderColor(0, 0, 0, 1)

	local icon = CreateFrame("Button", "MageFocusMagicIcon" .. i, b, "SecureActionButtonTemplate")
	icon:SetPoint("TOPLEFT", 0, 0)
	icon:RegisterForClicks("AnyUp")
	icon:SetAttribute("type", "macro")
	icon.tex = icon:CreateTexture(nil, "ARTWORK")
	icon.tex:SetPoint("TOPLEFT", 1, -1)
	icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
	icon.tex:SetTexture(FM_ICON)
	icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:SetScript("OnEnter", function(s)
		if not s.mage then return end
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		GameTooltip:SetText("Cast " .. FM_NAME .. " on " .. s.mage)
		GameTooltip:Show()
	end)
	icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b.icon = icon

	-- bright frame around an icon whose Focus Magic is missing; the colour says
	-- whose job it is (see BORDER_MINE / BORDER_ANY)
	b.border = CreateFrame("Frame", nil, b)
	b.border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
	b.border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
	b.border:SetBackdrop({ edgeFile = FLAT, edgeSize = 2 })
	b.border:SetFrameLevel(icon:GetFrameLevel() + 1)
	b.border:Hide()

	local nameBtn = CreateFrame("Button", nil, b)
	nameBtn:SetPoint("TOPLEFT", icon, "TOPRIGHT", 0, 0)
	nameBtn:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	nameBtn:RegisterForClicks("LeftButtonUp")
	nameBtn.text = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- pinned to both edges and one line high: a long name is cut short with
	-- "..." instead of spilling out of the block
	nameBtn.text:SetPoint("LEFT", 4, 0)
	nameBtn.text:SetPoint("RIGHT", -4, 0)
	nameBtn.text:SetHeight(10)
	nameBtn.text:SetJustifyH("CENTER")
	nameBtn:SetScript("OnClick", function(s)
		if s.mage then MFM:Whisper(s.mage) end
	end)
	nameBtn:SetScript("OnEnter", function(s) if s.mage then s.hl:Show() end end)
	nameBtn:SetScript("OnLeave", function(s) s.hl:Hide() end)
	nameBtn.hl = nameBtn:CreateTexture(nil, "BACKGROUND")
	nameBtn.hl:SetAllPoints()
	nameBtn.hl:SetTexture(FLAT)
	nameBtn.hl:SetVertexColor(1, 1, 1, 0.10)
	nameBtn.hl:Hide()
	b.nameBtn = nameBtn

	self.blocks[i] = b
	self:SizeBlock(b)
	return b
end

---The icon size option reaches a block here, and only when it changed.
function MFM:SizeBlock(b)
	local h = blockH()
	if b.sized == h then return end
	b.sized = h
	b:SetHeight(h)
	b:SetWidth(h + nameW())
	b.icon:SetWidth(h)
	b.icon:SetHeight(h)
end

-- Your own block sits a shade lighter than the others - enough to find
-- yourself in the row without a label saying so.
local BG_OTHER = { 0.07, 0.07, 0.09, 0.85 }
local BG_SELF  = { 0.16, 0.17, 0.22, 0.9 }

local BORDER_MINE  = { 1, 0.85, 0.1 }    -- your Focus Magic is missing on your own target
local BORDER_ANY   = { 1, 1, 1 }         -- somebody else's is missing
local BORDER_WRONG = { 0.3, 0.6, 1 }     -- buffed, but not by the mage the plan named

-- A block is drawn several times a second while the panel is open, and almost
-- nothing about it changes between draws. Every setter below is guarded by the
-- value the block already shows.
function MFM:SetBlock(b, m, isMe, owed, giver)
	self:SizeBlock(b)
	-- a stand-in is a picture of a mage: no whisper, no tooltip, no cast
	local real = (not isMe) and (not m.sample) and m.name or nil
	b.nameBtn.mage = real

	if b.cName ~= m.name then
		b.cName = m.name
		b.nameBtn.text:SetText(m.name)
		b.nameBtn.text:SetTextColor(MAGE_COLOR[1], MAGE_COLOR[2], MAGE_COLOR[3])
		b.nameBtn.hl:Hide()
	end

	local bg = isMe and BG_SELF or BG_OTHER
	if b.cBg ~= bg then
		b.cBg = bg
		b:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
	end

	-- The border carries the whole status; the icon itself stays as it is.
	-- Yellow is the one you can do something about right now: your Focus Magic
	-- is not on the mage the plan gave you. White is any other mage standing
	-- there without one, which is their partner's job, not yours.
	local c
	if owed then
		c = BORDER_MINE
	elseif not m.buffed then
		c = BORDER_ANY
	elseif m.caster and giver and m.caster ~= giver then
		-- a Focus Magic is up, but from the wrong mage: the trade has drifted
		-- out of the plan, and somebody is now covering two people
		c = BORDER_WRONG
	end
	if b.cBorder ~= c then
		b.cBorder = c
		if c then
			b.border:SetBackdropBorderColor(c[1], c[2], c[3], 1)
			b.border:Show()
		else
			b.border:Hide()
		end
	end

	-- Casting is protected: the macro may only be written out of combat, so in
	-- a fight a block keeps the aim it had when the fight started. Aiming at
	-- yourself is pointless, so your own icon is left doing nothing.
	local aim = real or ""
	if b.icon.aimed ~= aim and not InCombatLockdown() then
		b.icon.aimed = aim
		b.icon:SetAttribute("macrotext",
			real and ("/cast [target=" .. real .. "] " .. FM_NAME) or "")
	end
	b.icon.mage = real
	b:Show()
end

-- A separator is a pooled font string, and the ring's trailing one is wider
-- than the rest, so its width and text are set per use - but only when they
-- differ from what it already shows.
function MFM:SetSep(i, text, wide)
	local s = self.seps[i]
	if not s then
		s = self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		self.seps[i] = s
	end
	local w = wide and (SEP_W + nameW()) or SEP_W
	if s.cW ~= w then
		s.cW = w
		s:SetWidth(w)
		s:SetHeight(blockH())
		s:SetJustifyH(wide and "LEFT" or "CENTER")
	end
	if s.cText ~= text then
		s.cText = text
		s:SetText(text)
	end
	s:Show()
	return s
end

-- ---------------------------------------------------------------------------
-- button and panel
-- ---------------------------------------------------------------------------
-- The panel opens the way the options say. On "auto" it takes the side of the
-- button that has room, so a button parked near an edge does not push its
-- panel off screen.
local function anchorPanel(button, panel)
	local a
	for _, x in ipairs(MFM.ANCHORS) do
		if x.key == MFM.db.anchor then a = x end
	end
	panel:ClearAllPoints()
	if a and a[1] then
		panel:SetPoint(a[1], button, a[2], a[3], a[4])
		return
	end
	local x, y = button:GetCenter()
	local right = x and x > UIParent:GetWidth() / 2
	local up = y and y < UIParent:GetHeight() / 2
	local h = right and "RIGHT" or "LEFT"
	panel:SetPoint((up and "BOTTOM" or "TOP") .. h, button,
		(up and "TOP" or "BOTTOM") .. h, 0, up and 2 or -2)
end

function MFM:CreateDisplay()
	-- the button
	local b = CreateFrame("Button", "MageFocusMagicButton", UIParent)
	-- LOW: the game's own windows (character, bags, spellbook) open over it
	b:SetFrameStrata("LOW")
	b:SetClampedToScreen(true)
	b:SetMovable(true)
	b:SetWidth(self.db.buttonSize)
	b:SetHeight(self.db.buttonSize)
	b:RegisterForDrag("LeftButton")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnDragStart", function(s)
		if not MFM.db.locked then
			MFM.panel:Hide()
			s:StartMoving()
		end
	end)
	b:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local pt, _, rp, x, y = s:GetPoint()
		MFM.db.point = { pt, rp, x, y }
	end)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:SetTexture(FM_ICON)

	-- the same yellow the panel puts on your own target, so the button says
	-- "you owe a Focus Magic" without the panel being open
	b.border = CreateFrame("Frame", nil, b)
	b.border:SetPoint("TOPLEFT", -2, 2)
	b.border:SetPoint("BOTTOMRIGHT", 2, -2)
	b.border:SetBackdrop({ edgeFile = FLAT, edgeSize = 2 })
	b.border:SetBackdropBorderColor(BORDER_MINE[1], BORDER_MINE[2], BORDER_MINE[3], 1)
	b.border:Hide()
	b:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		GameTooltip:SetText("MageFocusMagic")
		GameTooltip:AddLine("Left click: the Focus Magic order", 1, 1, 1)
		GameTooltip:AddLine("Right click: options", 1, 1, 1)
		GameTooltip:AddLine(MFM.db.locked and "Locked in place"
			or "Drag to move", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local p = self.db.point
	b:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	self.button = b

	-- the panel
	local panel = CreateFrame("Frame", "MageFocusMagicPanel", UIParent)
	panel:SetFrameStrata("LOW")
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
	panel:SetBackdropColor(0.04, 0.04, 0.05, 0.92)
	panel:SetBackdropBorderColor(0, 0, 0, 1)
	panel:Hide()
	self.panel = panel

	panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.empty:SetPoint("CENTER")
	panel.empty:SetText("no other mage in the group")

	-- the announce, in the same flat look as a player block
	local btn = CreateFrame("Button", nil, panel)
	btn:SetHeight(blockH())
	btn:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
	btn:SetBackdropColor(0.07, 0.07, 0.09, 0.85)
	btn:SetBackdropBorderColor(0, 0, 0, 1)
	btn:RegisterForClicks("LeftButtonUp")
	local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("CENTER")
	label:SetText("Announce to raid")
	btn:SetWidth(label:GetStringWidth() + 20)
	local hl = btn:CreateTexture(nil, "BACKGROUND")
	hl:SetAllPoints()
	hl:SetTexture(FLAT)
	hl:SetVertexColor(1, 1, 1, 0.10)
	hl:Hide()
	btn:SetScript("OnEnter", function() hl:Show() end)
	btn:SetScript("OnLeave", function() hl:Hide() end)
	btn:SetScript("OnClick", function() MFM:Announce() end)
	panel.announce = btn

	-- Escape closes it, like the game's own windows
	tinsert(UISpecialFrames, panel:GetName())

	panel:SetScript("OnShow", function() MFM:Tick() end)
	-- the stand-ins only exist while they are on screen
	panel:SetScript("OnHide", function() MFM.sample = false end)
end

-- With the panel closed there is still the button's own border to keep right,
-- so the plan is rebuilt anyway - but only in a group, and without drawing
-- anything.
function MFM:Tick()
	if self.panel:IsShown() then
		self:UpdatePanel()
	elseif GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then
		self.sample = false
		self:Rebuild(true) -- closed: only the border on the button depends on this
	elseif #self.mages > 0 then
		-- left the group: drop what is left of the plan, once
		self.sample = false
		self.rosterDirty = true
		self:Rebuild()
	end

	-- your own target, missing your Focus Magic: the same thing the yellow
	-- border in the panel says. Stand-ins never light the button.
	local owed = false
	if not self.sample then
		local target = self:MyTarget()
		if target then
			for _, m in ipairs(self.mages) do
				if m.name == target then owed = not m.mine end
			end
		end
	end
	if self.cOwed ~= owed then
		self.cOwed = owed
		if owed then self.button.border:Show() else self.button.border:Hide() end
	end
end

function MFM:TogglePanel()
	local p = self.panel
	if p:IsShown() then
		p:Hide()
	else
		anchorPanel(self.button, p)
		p:Show()
	end
end

---After a change in the options.
function MFM:ApplySettings()
	local b, p = self.button, self.panel
	if not b then return end
	b:SetWidth(self.db.buttonSize)
	b:SetHeight(self.db.buttonSize)
	-- a new row height means every cached size and position is stale
	p.cW, p.cH = nil, nil
	p.announce:SetHeight(blockH())
	for _, s in ipairs(self.seps) do s.cW = nil end
	if p:IsShown() then
		anchorPanel(b, p)
		self:UpdatePanel()
	end
end

function MFM:ResetPosition()
	self.db.point = { "CENTER", "CENTER", 0, 0 }
	self.button:ClearAllPoints()
	self.button:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	if self.panel:IsShown() then anchorPanel(self.button, self.panel) end
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------
-- One row per trade: the mages of that group side by side. The game's fonts
-- have no arrow glyphs, so the direction is plain ASCII - "<>" between two
-- mages who trade, ">" along a ring.
local SEP_PAIR  = "<>"
local SEP_CHAIN = ">"

-- "> Name" for the end of a ring, built once per name it has ever shown
local ringText = setmetatable({}, { __index = function(t, name)
	local s = SEP_CHAIN .. " |cff777777" .. name .. "|r"
	t[name] = s
	return s
end })

function MFM:UpdatePanel()
	local p = self.panel
	if not p or not p:IsShown() then return end

	self:Rebuild()
	local mages, groups = self.mages, self.groups
	local me = UnitName("player")

	self.sample = false
	if #groups == 0 then
		if self.db.locked then
			for _, b in ipairs(self.blocks) do b:Hide() end
			for _, s in ipairs(self.seps) do s:Hide() end
			p.announce:Hide()
			p.empty:Show()
			p.cW, p.cH = nil, nil -- the size below is not the one rows produce
			p:SetWidth(200)
			p:SetHeight(blockH() + PAD * 2)
			return
		end
		-- unlocked: stand-ins, so there is something to size the panel by
		self.sample = true
		mages, groups = self:SampleData()
		me = SAMPLE[1]
	end
	p.empty:Hide()

	-- two lookups the rows need, kept between draws instead of rebuilt: what a
	-- name stands for, and who the plan has casting on whom
	local byName, giver = self.byName, self.giver
	wipe(byName)
	wipe(giver)
	for _, m in ipairs(mages) do byName[m.name] = m end
	for _, g in ipairs(groups) do
		for i, name in ipairs(g) do
			giver[g[i % #g + 1]] = name
		end
	end

	-- the one mage the plan makes your job, lit until your Focus Magic is on
	-- them. Another mage's Focus Magic on them is not yours and does not count.
	local myTarget = self.sample and SAMPLE[2] or self:MyTarget()
	local owed = (myTarget and not byName[myTarget].mine) and myTarget or nil

	local nBlocks, nSeps = 0, 0
	local widest, y = 0, -PAD
	for _, g in ipairs(groups) do
		local x = PAD
		for mi, name in ipairs(g) do
			if mi > 1 then
				nSeps = nSeps + 1
				local s = self:SetSep(nSeps, g.kind == "pair" and SEP_PAIR or SEP_CHAIN, false)
				s:ClearAllPoints()
				s:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
				x = x + SEP_W
			end

			nBlocks = nBlocks + 1
			local b = self:GetBlock(nBlocks)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
			self:SetBlock(b, byName[name], name == me, name == owed, giver[name])
			x = x + b:GetWidth()
		end
		-- a ring hands the buff back to the mage it started with
		if g.kind == "chain" then
			nSeps = nSeps + 1
			local s = self:SetSep(nSeps, ringText[g[1]], true)
			s:ClearAllPoints()
			-- left aligned, so it needs the gap the centred ones get for free
			s:SetPoint("TOPLEFT", p, "TOPLEFT", x + 3, y)
			x = x + SEP_W + s:GetStringWidth()
		end

		if x + PAD > widest then widest = x + PAD end
		y = y - blockH() - ROW_GAP
	end

	for i = nBlocks + 1, #self.blocks do self.blocks[i]:Hide() end
	for i = nSeps + 1, #self.seps do self.seps[i]:Hide() end

	p.announce:ClearAllPoints()
	p.announce:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y)
	p.announce:Show()

	local h = -y + blockH() + PAD
	if p.cW ~= widest or p.cH ~= h then
		p.cW, p.cH = widest, h
		p:SetWidth(widest)
		p:SetHeight(h)
	end
end

-- the slash command and the options panel live in Config.lua
function MFM:Print(msg) print_(msg) end
MFM.FM_NAME = FM_NAME

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
local driver = CreateFrame("Frame")

-- Half a second is fast enough for a buff going up and down, and it picks up
-- roster changes without a single event registration.
local since = 0
driver:SetScript("OnUpdate", function(_, dt)
	if not MFM.db then return end
	since = since + dt
	if since < 0.5 then return end
	since = 0
	MFM:Tick()
end)

driver:RegisterEvent("ADDON_LOADED")
driver:SetScript("OnEvent", function(self, event, arg1)
	if event ~= "ADDON_LOADED" then
		-- who is in the group, and therefore the whole plan, only changes here
		MFM.rosterDirty = true
		return
	end
	if arg1 ~= "MageFocusMagic" then return end
	self:UnregisterEvent("ADDON_LOADED")

	-- nobody but a mage has a Focus Magic to trade
	local _, class = UnitClass("player")
	if class ~= "MAGE" then return end

	MageFocusMagicDB = MageFocusMagicDB or {}
	for k, v in pairs(MFM.defaults) do
		if MageFocusMagicDB[k] == nil then
			MageFocusMagicDB[k] = (type(v) == "table") and { v[1], v[2], v[3], v[4] } or v
		end
	end
	MFM.db = MageFocusMagicDB
	MFM.blocks, MFM.seps = {}, {}
	MFM:CreateDisplay()

	-- a left click opens and closes the panel, a right click the options
	MFM.button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then
			if MFM.OpenOptions then MFM:OpenOptions() end
		else
			MFM:TogglePanel()
		end
	end)
	if MFM.InitConfig then MFM:InitConfig() end

	MFM.rosterDirty = true
	self:RegisterEvent("RAID_ROSTER_UPDATE")
	self:RegisterEvent("PARTY_MEMBERS_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
end)
