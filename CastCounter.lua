-- CastCounter: how many times you cast each of your spells, in a damage-meter style window, with a
-- report to chat. It reads your 1.12 combat log lines ("Your Hurricane hits X for 413 Nature
-- damage.", "You cast Rejuvenation on Y.") with patterns built from the client's own GlobalStrings.
--
-- 1.12 has no per-cast combat log event, so a cast is counted from its lines: every line of the
-- same spell within CastCounterDB.window seconds of the counted one is the same cast (an area spell
-- hitting ten targets writes ten lines). Hits are counted too, shown in the tooltip.
--
-- Lua 5.0 (the 1.12 client): table.getn, string.find captures, `this` and `arg1` in scripts.

CastCounter = {}
local CC = CastCounter

local DEFAULTS = {
	window = 0.4, rows = 10, shown = true, reportChannel = "PARTY", reportLines = 10,
}

-- { GlobalStrings name, English fallback, argument holding the spell }. A targeted form comes before
-- its untargeted one, so "You cast X on Y." is not read as the spell "X on Y".
local TEMPLATES = {
	{ "SPELLCASTGOSELFTARGETTED", "You cast %s on %s.", 1 },
	{ "SPELLCASTGOSELF", "You cast %s.", 1 },
	{ "SPELLPERFORMGOSELFTARGETTED", "You perform %s on %s.", 1 },
	{ "SPELLPERFORMGOSELF", "You perform %s.", 1 },
	{ "SPELLLOGCRITSCHOOLSELFOTHER", "Your %s crits %s for %d %s damage.", 1 },
	{ "SPELLLOGSCHOOLSELFOTHER", "Your %s hits %s for %d %s damage.", 1 },
	{ "SPELLLOGCRITSELFOTHER", "Your %s crits %s for %d.", 1 },
	{ "SPELLLOGSELFOTHER", "Your %s hits %s for %d.", 1 },
	{ "HEALEDCRITSELFSELF", "Your %s critically heals you for %d.", 1 },
	{ "HEALEDSELFSELF", "Your %s heals you for %d.", 1 },
	{ "HEALEDCRITSELFOTHER", "Your %s critically heals %s for %d.", 1 },
	{ "HEALEDSELFOTHER", "Your %s heals %s for %d.", 1 },
	{ "SPELLMISSSELFOTHER", "Your %s missed %s.", 1 },
	{ "SPELLRESISTSELFOTHER", "Your %s was resisted by %s.", 1 },
	{ "SPELLDODGEDSELFOTHER", "Your %s was dodged by %s.", 1 },
	{ "SPELLPARRIEDSELFOTHER", "Your %s was parried by %s.", 1 },
	{ "SPELLBLOCKEDSELFOTHER", "Your %s was blocked by %s.", 1 },
	{ "SPELLEVADEDSELFOTHER", "Your %s was evaded by %s.", 1 },
	{ "SPELLLOGABSORBSELFOTHER", "Your %s is absorbed by %s.", 1 },
}

-- Your spell lines. The periodic events (damage and heal over time ticks) are left out: a tick is
-- not a cast.
local EVENTS = { "CHAT_MSG_SPELL_SELF_DAMAGE", "CHAT_MSG_SPELL_SELF_BUFF" }

local function Print(text)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100CastCounter|r: " .. text)
end

-- ---------------------------------------------------------------------------------------------
-- Parsing

-- A Lua pattern from a printf-style template, and for each argument number the capture holding
-- it. Handles %s, %d and positional %1$s.
function CC.ToPattern(fmt)
	local pat, captureOf, n = "^", {}, 0
	local i, len = 1, string.len(fmt)
	while i <= len do
		local c = string.sub(fmt, i, i)
		if c == "%" then
			local _, e, pos, conv = string.find(fmt, "^(%d?)%$?([sd])", i + 1)
			if conv then
				n = n + 1
				captureOf[tonumber(pos) or n] = n
				if conv == "d" then pat = pat .. "(%d+)" else pat = pat .. "(.-)" end
				i = e + 1
			else
				pat = pat .. "%%"
				i = i + 1
				if string.sub(fmt, i, i) == "%" then i = i + 1 end
			end
		else
			if string.find(c, "[%^%$%(%)%.%[%]%*%+%-%?]") then pat = pat .. "%" .. c else pat = pat .. c end
			i = i + 1
		end
	end
	return pat, captureOf
end

local RULES = {}

function CC.BuildRules()
	RULES = {}
	for i = 1, table.getn(TEMPLATES) do
		local t = TEMPLATES[i]
		local fmt = getglobal(t[1])
		if type(fmt) ~= "string" then fmt = t[2] end
		local pat, captureOf = CC.ToPattern(fmt)
		if captureOf[t[3]] then table.insert(RULES, { pat = pat, spell = captureOf[t[3]] }) end
	end
end

-- The spell one of your combat lines names, or nothing for a line it does not know.
function CC.Parse(msg)
	if type(msg) ~= "string" or string.len(msg) > 400 or string.sub(msg, 1, 3) ~= "You" then return end
	for i = 1, table.getn(RULES) do
		local r = RULES[i]
		local m = { string.find(msg, r.pat) }
		if m[1] then return m[r.spell + 2] end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Counting

local lastCast = {}
local dirty = true

-- This character's counts: { casts, hits, spells = { [spell] = { casts, hits } } }.
function CC.Mine()
	local me = UnitName("player") or "You"
	local p = CastCounterDB.data[me]
	if not p then
		p = { casts = 0, hits = 0, spells = {} }
		CastCounterDB.data[me] = p
	end
	return p, me
end

function CC.Record(spell, now)
	local p = CC.Mine()
	local s = p.spells[spell]
	if not s then
		s = { casts = 0, hits = 0 }
		p.spells[spell] = s
	end
	s.hits = s.hits + 1
	p.hits = p.hits + 1
	local t = lastCast[spell]
	if not t or now - t > CastCounterDB.window then
		s.casts = s.casts + 1
		p.casts = p.casts + 1
		lastCast[spell] = now
	end
	dirty = true
end

function CC.OnMessage(msg)
	local spell = CC.Parse(msg)
	if spell then CC.Record(spell, GetTime()) end
end

function CC.Reset()
	local _, me = CC.Mine()
	CastCounterDB.data[me] = nil
	lastCast = {}
	CC.offset = 0
	dirty = true
end

local function ByValue(a, b)
	if a.value ~= b.value then return a.value > b.value end
	return a.label < b.label
end

-- Your spells, the most cast first, and the total.
function CC.Rows()
	local p = CC.Mine()
	local rows = {}
	for spell, s in pairs(p.spells) do
		table.insert(rows, { label = spell, value = s.casts, hits = s.hits })
	end
	table.sort(rows, ByValue)
	return rows, p.casts
end

-- ---------------------------------------------------------------------------------------------
-- Look: Azeroth FieldKit's "Chronicle" cards when FieldKit is loaded (its own surfaces, fonts and
-- card opacity setting), a plain dark card otherwise.

local WIDTH, ROW_HEIGHT = 220, 15
local frame, rowFrames, reportPanel
CC.offset = 0

local CLASS_COLORS = {
	WARRIOR = { 0.78, 0.61, 0.43 }, MAGE = { 0.41, 0.80, 0.94 }, ROGUE = { 1.00, 0.96, 0.41 },
	DRUID = { 1.00, 0.49, 0.04 }, HUNTER = { 0.67, 0.83, 0.45 }, SHAMAN = { 0.00, 0.44, 0.87 },
	PRIEST = { 1.00, 1.00, 1.00 }, WARLOCK = { 0.58, 0.51, 0.79 }, PALADIN = { 0.96, 0.55, 0.73 },
}
local GOLD = { 0.85, 0.71, 0.42 }

-- Your class's colour for the bars (a druid's orange).
local function BarColor()
	local _, token = UnitClass("player")
	return CLASS_COLORS[token or ""] or { 0.8, 0.55, 0.1 }
end

local function Theme()
	if type(FieldKitTheme) == "table" and type(FieldKitTheme.Surface) == "function"
		and type(FieldKitTheme.Update) == "function" and type(FieldKitTheme.State) == "function" then
		return FieldKitTheme
	end
end

local PLAIN = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Dress `f` as a card ("card") or a button ("button").
local function Skin(f, kind)
	local T = Theme()
	if T and pcall(T.Surface, f, kind, true) and f.fieldkitSkin then return end
	f:SetBackdrop(PLAIN)
	if kind == "button" then
		f:SetBackdropColor(0.094, 0.129, 0.149, 0.9)
	else
		f:SetBackdropColor(0.063, 0.09, 0.106, 0.85)
	end
	f:SetBackdropBorderColor(0.54, 0.44, 0.27, 1)
end

-- After a size change: the themed card redraws its slices.
local function Reskin(f)
	local T = Theme()
	if T and f.fieldkitSkin then T.Update(f) end
end

-- Hover or selection of a skinned button.
local function Lit(b, on)
	local T = Theme()
	if T and b.fieldkitSkin then
		T.State(b, on)
	elseif on then
		b:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
	else
		b:SetBackdropBorderColor(0.54, 0.44, 0.27, 1)
	end
end

local function Button(parent, label, w, h, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(w)
	b:SetHeight(h)
	Skin(b, "button")
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetAllPoints(b)
	fs:SetJustifyH("CENTER")
	fs:SetText(label)
	fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
	b.label = fs
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function() Lit(this, true) end)
	b:SetScript("OnLeave", function() Lit(this, this.ccSelected) end)
	return b
end

local function Select(b, on)
	b.ccSelected = on and true or false
	Lit(b, b.ccSelected)
	if on then b.label:SetTextColor(1, 1, 1) else b.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end
end

-- ---------------------------------------------------------------------------------------------
-- Window

function CC.Refresh()
	if not frame or not frame:IsVisible() then return end
	dirty = false
	local rows, total = CC.Rows()
	frame.total:SetText(total .. " casts")
	if CC.UpdateReportPanel then CC.UpdateReportPanel() end

	local maxRows = CastCounterDB.rows
	local shown = math.min(table.getn(rows), maxRows)
	local maxOffset = math.max(0, table.getn(rows) - maxRows)
	if CC.offset > maxOffset then CC.offset = maxOffset end

	-- The card fits the rows it shows, as FieldKit's meters do.
	local height = 28 + ROW_HEIGHT * math.max(shown, 1)
	if CastCounterDB.collapsed then height = 24 end
	if frame:GetHeight() ~= height then
		frame:SetHeight(height)
		Reskin(frame)
	end

	local top = rows[1] and rows[1].value or 0
	local color = BarColor()
	for i = 1, maxRows do
		local rf = rowFrames[i]
		local r = rows[i + CC.offset]
		if CastCounterDB.collapsed then
			rf:Hide()
		elseif r then
			local share = total > 0 and math.floor(r.value * 100 / total + 0.5) or 0
			rf.label:SetText(r.label)
			rf.value:SetText(r.value)
			rf.share:SetText(share .. "%")
			rf:SetValue(top > 0 and r.value / top or 0)
			rf:SetStatusBarColor(color[1], color[2], color[3], 0.55)
			rf.row = r
			rf:Show()
		elseif i == 1 and table.getn(rows) == 0 then
			rf.label:SetText("|cffa6b3b3Cast a spell to start counting|r")
			rf.value:SetText("")
			rf.share:SetText("")
			rf:SetValue(0)
			rf.row = nil
			rf:Show()
		else
			rf.row = nil
			rf:Hide()
		end
	end
	if CastCounterDB.collapsed then frame.total:Hide() else frame.total:Show() end
end

local function RowTooltip()
	local r = this.row
	if not r then return end
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	GameTooltip:AddLine(r.label, GOLD[1], GOLD[2], GOLD[3])
	GameTooltip:AddDoubleLine("Casts", r.value, 0.94, 0.91, 0.83, 1, 1, 1)
	GameTooltip:AddDoubleLine("Hits (every target)", r.hits, 0.94, 0.91, 0.83, 1, 1, 1)
	if r.value > 0 then
		GameTooltip:AddDoubleLine("Hits per cast", string.format("%.1f", r.hits / r.value), 0.94, 0.91, 0.83, 1, 1, 1)
	end
	GameTooltip:Show()
end

function CC.CreateWindow()
	local n = CastCounterDB.rows
	frame = CreateFrame("Frame", "CastCounterFrame", UIParent)
	frame:SetFrameStrata("LOW")
	frame:SetWidth(WIDTH)
	frame:SetHeight(28 + ROW_HEIGHT)
	Skin(frame, "card")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:EnableMouseWheel(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function() frame:StartMoving() end)
	frame:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint()
		CastCounterDB.pos = { point, relPoint, x, y }
	end)
	frame:SetScript("OnMouseWheel", function()
		CC.offset = math.max(0, CC.offset - arg1)
		CC.Refresh()
	end)
	local elapsed = 0
	frame:SetScript("OnUpdate", function()
		elapsed = elapsed + arg1
		if elapsed >= 0.5 then
			elapsed = 0
			if dirty then CC.Refresh() end
		end
	end)
	frame:SetScript("OnShow", function() CC.Refresh() end)
	local pos = CastCounterDB.pos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("LEFT", UIParent, "LEFT", 4, -60)
	end

	-- Header: the title, the total, then Report, Reset and the collapse button, as FieldKit's.
	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 9, -7)
	frame.title:SetText("Casts")
	frame.total = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.total:SetPoint("LEFT", frame.title, "RIGHT", 6, 0)
	frame.total:SetTextColor(0.65, 0.70, 0.70)

	local collapse = Button(frame, "-", 18, 17, function()
		CastCounterDB.collapsed = not CastCounterDB.collapsed
		this.label:SetText(CastCounterDB.collapsed and "+" or "-")
		if CastCounterDB.collapsed and reportPanel then reportPanel:Hide() end
		CC.Refresh()
	end)
	collapse:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
	collapse:SetFrameLevel(frame:GetFrameLevel() + 10)
	if CastCounterDB.collapsed then collapse.label:SetText("+") end
	local reset = Button(frame, "Reset", 38, 17, function() CC.Reset(); CC.Refresh() end)
	reset:SetPoint("RIGHT", collapse, "LEFT", -2, 0)
	reset:SetFrameLevel(frame:GetFrameLevel() + 10)
	local report = Button(frame, "Report", 44, 17, function() CC.ToggleReportPanel() end)
	report:SetPoint("RIGHT", reset, "LEFT", -2, 0)
	report:SetFrameLevel(frame:GetFrameLevel() + 10)

	rowFrames = {}
	for i = 1, n do
		local rf = CreateFrame("StatusBar", nil, frame)
		rf:SetHeight(ROW_HEIGHT - 2)
		rf:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -22 - ROW_HEIGHT * (i - 1))
		rf:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -22 - ROW_HEIGHT * (i - 1))
		rf:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
		rf:SetMinMaxValues(0, 1)
		rf.share = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		rf.share:SetPoint("RIGHT", rf, "RIGHT", -3, 0)
		rf.share:SetWidth(34)
		rf.share:SetJustifyH("RIGHT")
		rf.share:SetTextColor(0.65, 0.70, 0.70)
		rf.value = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		rf.value:SetPoint("RIGHT", rf.share, "LEFT", -6, 0)
		rf.value:SetWidth(48)
		rf.value:SetJustifyH("RIGHT")
		rf.label = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		rf.label:SetPoint("LEFT", rf, "LEFT", 3, 0)
		rf.label:SetPoint("RIGHT", rf.value, "LEFT", -4, 0)
		rf.label:SetJustifyH("LEFT")
		rf:EnableMouse(true)
		rf:RegisterForDrag("LeftButton")
		rf:SetScript("OnDragStart", function() frame:StartMoving() end)
		rf:SetScript("OnDragStop", function() frame:GetScript("OnDragStop")() end)
		rf:SetScript("OnEnter", RowTooltip)
		rf:SetScript("OnLeave", function() GameTooltip:Hide() end)
		rf:Hide()
		rowFrames[i] = rf
	end

	if CastCounterDB.shown then frame:Show() else frame:Hide() end
end

function CC.Toggle()
	if frame:IsVisible() then frame:Hide() else frame:Show() end
	CastCounterDB.shown = frame:IsVisible() and true or false
end

-- ---------------------------------------------------------------------------------------------
-- Reporting

local REPORT_CHANNELS = { "SAY", "PARTY", "RAID", "GUILD", "OFFICER", "WHISPER" }
local CHANNEL_LABELS = {
	SAY = "Say", PARTY = "Party", RAID = "Raid", GUILD = "Guild", OFFICER = "Officer",
	WHISPER = "Whisper", CHANNEL = "Channel",
}

-- The lines a report sends: a heading with the total, then your top `count` spells with their
-- share.
function CC.ReportLines(count)
	local rows, total = CC.Rows()
	local _, me = CC.Mine()
	local lines = { "CastCounter - " .. me .. "'s casts (" .. total .. " total)" }
	for i = 1, math.min(count, table.getn(rows)) do
		local r = rows[i]
		local share = total > 0 and math.floor(r.value * 100 / total + 0.5) or 0
		table.insert(lines, i .. ". " .. r.label .. "  " .. r.value .. " (" .. share .. "%)")
	end
	return lines
end

-- Why `channel` cannot take a report now, or nil when it can.
local function CannotSend(channel, target)
	if channel == "PARTY" and GetNumPartyMembers() == 0 and GetNumRaidMembers() == 0 then
		return "you are not in a party."
	elseif channel == "RAID" and GetNumRaidMembers() == 0 then
		return "you are not in a raid."
	elseif (channel == "GUILD" or channel == "OFFICER") and not IsInGuild() then
		return "you are not in a guild."
	elseif channel == "WHISPER" and (not target or target == "") then
		return "type the name to whisper."
	elseif channel == "CHANNEL" and not tonumber(target or "") then
		return "give the channel's number, e.g. /cc report channel 5."
	end
end

-- Send the report to `channel` (nil prints it to your own chat window only). `target` is the name
-- for a whisper or the number of a chat channel.
function CC.Report(channel, count, target)
	local lines = CC.ReportLines(count)
	if table.getn(lines) == 1 then
		Print("nothing to report yet.")
		return false
	end
	if channel then
		local why = CannotSend(channel, target)
		if why then
			Print("cannot report to " .. (CHANNEL_LABELS[channel] or channel) .. ": " .. why)
			return false
		end
	end
	for i = 1, table.getn(lines) do
		if channel then SendChatMessage(lines[i], channel, nil, target) else Print(lines[i]) end
	end
	return true
end

function CC.UpdateReportPanel()
	if not reportPanel or not reportPanel:IsVisible() then return end
	local p = reportPanel
	for i = 1, table.getn(p.channelButtons) do
		local b = p.channelButtons[i]
		Select(b, b.channel == CastCounterDB.reportChannel)
	end
	p.count:SetText(CastCounterDB.reportLines)
	if CastCounterDB.reportChannel == "WHISPER" then p.whisper:Show() else p.whisper:Hide() end
end

local function CreateReportPanel()
	local p = CreateFrame("Frame", "CastCounterReportFrame", frame)
	p:SetFrameStrata("LOW")
	p:SetWidth(WIDTH)
	p:SetHeight(112)
	p:SetPoint("TOP", frame, "BOTTOM", 0, -2)
	Skin(p, "card")
	p:EnableMouse(true)
	p:Hide()

	local heading = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	heading:SetPoint("TOPLEFT", p, "TOPLEFT", 9, -7)
	heading:SetText("Report to")

	p.channelButtons = {}
	for i = 1, table.getn(REPORT_CHANNELS) do
		local ch = REPORT_CHANNELS[i]
		local b = Button(p, CHANNEL_LABELS[ch], 66, 18, function()
			CastCounterDB.reportChannel = this.channel
			CC.UpdateReportPanel()
		end)
		local col, row = math.mod(i - 1, 3), math.floor((i - 1) / 3)
		b:SetPoint("TOPLEFT", p, "TOPLEFT", 8 + col * 69, -22 - row * 20)
		b.channel = ch
		table.insert(p.channelButtons, b)
	end

	local linesLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	linesLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 9, -69)
	linesLabel:SetText("Lines")
	local minus = Button(p, "-", 18, 17, function()
		CastCounterDB.reportLines = math.max(1, CastCounterDB.reportLines - 1)
		CC.UpdateReportPanel()
	end)
	minus:SetPoint("LEFT", linesLabel, "RIGHT", 6, 0)
	local count = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	count:SetPoint("LEFT", minus, "RIGHT", 2, 0)
	count:SetWidth(22)
	count:SetJustifyH("CENTER")
	p.count = count
	local plus = Button(p, "+", 18, 17, function()
		CastCounterDB.reportLines = math.min(25, CastCounterDB.reportLines + 1)
		CC.UpdateReportPanel()
	end)
	plus:SetPoint("LEFT", count, "RIGHT", 2, 0)

	local whisper = CreateFrame("EditBox", "CastCounterWhisperBox", p, "InputBoxTemplate")
	whisper:SetWidth(90)
	whisper:SetHeight(16)
	whisper:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -67)
	whisper:SetAutoFocus(false)
	whisper:SetMaxLetters(12)
	whisper:SetScript("OnEnterPressed", function() this:ClearFocus() end)
	whisper:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	p.whisper = whisper

	local send = Button(p, "Send report", 100, 20, function()
		local ch = CastCounterDB.reportChannel
		local target = ch == "WHISPER" and p.whisper:GetText() or nil
		if CC.Report(ch, CastCounterDB.reportLines, target) then p:Hide() end
	end)
	send:SetPoint("BOTTOM", p, "BOTTOM", 0, 7)

	reportPanel = p
end

function CC.ToggleReportPanel()
	if not reportPanel then CreateReportPanel() end
	if reportPanel:IsVisible() then
		reportPanel:Hide()
		return
	end
	-- A whisper goes to the player you have targeted, unless you type another name.
	if UnitExists("target") and UnitIsPlayer("target") and reportPanel.whisper:GetText() == "" then
		reportPanel.whisper:SetText(UnitName("target"))
	end
	reportPanel:Show()
	CC.UpdateReportPanel()
end

-- ---------------------------------------------------------------------------------------------
-- Slash command

SLASH_CASTCOUNTER1 = "/cc"
SLASH_CASTCOUNTER2 = "/castcounter"
SlashCmdList["CASTCOUNTER"] = function(msg)
	local _, _, cmd, rest = string.find(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	if cmd == "" or cmd == "show" or cmd == "hide" or cmd == "toggle" then
		CC.Toggle()
	elseif cmd == "reset" then
		CC.Reset()
		CC.Refresh()
		Print("counts reset.")
	elseif cmd == "window" then
		local w = tonumber(rest)
		if w and w >= 0 and w <= 5 then
			CastCounterDB.window = w
			Print("lines of one spell within " .. w .. " s count as one cast.")
		else
			Print("window is " .. CastCounterDB.window .. " s. Use /cc window <seconds> (0 to 5).")
		end
	elseif cmd == "rows" then
		local r = tonumber(rest)
		if r and r >= 3 and r <= 40 then
			CastCounterDB.rows = math.floor(r)
			Print("rows set to " .. CastCounterDB.rows .. ". Type /reload to apply.")
		else
			Print("Use /cc rows <3-40>.")
		end
	elseif cmd == "report" then
		-- /cc report [say|party|raid|guild|officer | whisper <name> | channel <n>] [lines]
		local words = {}
		for w in string.gfind(rest or "", "%S+") do table.insert(words, w) end
		local channel, target, count, i = nil, nil, CastCounterDB.reportLines, 1
		local first = string.upper(words[1] or "")
		local short = { S = "SAY", P = "PARTY", R = "RAID", G = "GUILD", O = "OFFICER" }
		if first == "W" or first == "WHISPER" or first == "TELL" then
			channel, target, i = "WHISPER", words[2], 3
		elseif first == "C" or first == "CHANNEL" then
			channel, target, i = "CHANNEL", words[2], 3
		elseif short[first] or first == "SAY" or first == "PARTY" or first == "RAID" or first == "GUILD" or first == "OFFICER" then
			channel, i = short[first] or first, 2
		elseif first ~= "" and not tonumber(words[1]) then
			Print("Use /cc report [say|party|raid|guild|officer|whisper <name>|channel <n>] [lines].")
			return
		end
		if words[i] then
			local n = tonumber(words[i])
			if not n then
				Print("the number of lines must be a number.")
				return
			end
			count = math.max(1, math.min(25, math.floor(n)))
		end
		CC.Report(channel, count, target)
	else
		Print("/cc - show or hide; /cc reset; /cc report [say|party|raid|guild|officer|whisper <name>|channel <n>] [lines]; /cc window <seconds>; /cc rows <n>")
	end
end

-- ---------------------------------------------------------------------------------------------
-- Events

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:SetScript("OnEvent", function()
	if event == "VARIABLES_LOADED" then
		if type(CastCounterDB) ~= "table" then CastCounterDB = {} end
		for k, v in pairs(DEFAULTS) do
			if CastCounterDB[k] == nil then CastCounterDB[k] = v end
		end
		if type(CastCounterDB.data) ~= "table" then CastCounterDB.data = {} end
		-- Settings of the earlier versions, no longer used.
		CastCounterDB.view, CastCounterDB.enemies, CastCounterDB.debug = nil, nil, nil
		CC.BuildRules()
		CC.CreateWindow()
		for i = 1, table.getn(EVENTS) do this:RegisterEvent(EVENTS[i]) end
	else
		CC.OnMessage(arg1)
	end
end)
