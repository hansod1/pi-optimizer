local addonName, addonTable = ...

_G.Details_PIMeter_ST = {}
_G.Details_PIMeter_Cleave3 = {}
_G.Details_PIMeter_Cleave5 = {}

local SpecNameToID = {
    ["Blood Death Knight"] = 250, ["Frost Death Knight"] = 251, ["Unholy Death Knight"] = 252,
    ["Havoc Demon Hunter"] = 577, ["Vengeance Demon Hunter"] = 581,
    ["Devourer Demon Hunter"] = 1480,
    ["Balance Druid"] = 102, ["Feral Druid"] = 103, ["Guardian Druid"] = 104, ["Restoration Druid"] = 105,
    ["Beast_Mastery Hunter"] = 253, ["Marksmanship Hunter"] = 254, ["Survival Hunter"] = 255,
    ["Arcane Mage"] = 62, ["Fire Mage"] = 63, ["Frost Mage"] = 64,
    ["Brewmaster Monk"] = 268, ["Windwalker Monk"] = 269, ["Mistweaver Monk"] = 270,
    ["Holy Paladin"] = 65, ["Protection Paladin"] = 66, ["Retribution Paladin"] = 70,
    ["Discipline Priest"] = 256, ["Holy Priest"] = 257, ["Shadow Priest"] = 258,
    ["Assassination Rogue"] = 259, ["Outlaw Rogue"] = 260, ["Subtlety Rogue"] = 261,
    ["Elemental Shaman"] = 262, ["Enhancement Shaman"] = 263, ["Restoration Shaman"] = 264,
    ["Affliction Warlock"] = 265, ["Demonology Warlock"] = 266, ["Destruction Warlock"] = 267,
    ["Arms Warrior"] = 71, ["Fury Warrior"] = 72, ["Protection Warrior"] = 73,
    ["Devastation Evoker"] = 1467, ["Preservation Evoker"] = 1468, ["Augmentation Evoker"] = 1473
}

---------------------------------------------------------------------
-- Bloodmallet parsing
---------------------------------------------------------------------

local function Trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Keys like "{Spec}" are the baseline, plain "Spec" keys are the PI values.
-- Returns a table of specID -> (PI / baseline).
local function ParseBloodmalletJSON(jsonString)
    local results = {}
    local tempMap = {}

    for spec, val in string.gmatch(jsonString, '"%{([^%}]+)%}"%s*:%s*(%d+)') do
        tempMap[Trim(spec)] = { base = tonumber(val) }
    end

    for spec, val in string.gmatch(jsonString, '"([%a%s_]+)"%s*:%s*(%d+)') do
        local cleanedSpec = Trim(spec)
        if tempMap[cleanedSpec] then
            tempMap[cleanedSpec].pi = tonumber(val)
        end
    end

    for specName, data in pairs(tempMap) do
        local specID = SpecNameToID[specName]
        if specID and data.base and data.pi and data.base > 0 then
            results[specID] = data.pi / data.base
        end
    end
    return results
end

local function BuildCoefficientTables()
    local raw = addonTable.RawData or {}
    local parsedST = ParseBloodmalletJSON(raw.ST or "")
    local parsedCleave3 = ParseBloodmalletJSON(raw.Cleave3 or "")
    local parsedCleave5 = ParseBloodmalletJSON(raw.Cleave5 or "")

    for _, specID in pairs(SpecNameToID) do
        _G.Details_PIMeter_ST[specID] = parsedST[specID] or 1.0
        _G.Details_PIMeter_Cleave3[specID] = parsedCleave3[specID] or 1.0
        _G.Details_PIMeter_Cleave5[specID] = parsedCleave5[specID] or 1.0
    end
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function Short(n)
    if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if n >= 1000 then return string.format("%.1fK", n / 1000) end
    return string.format("%d", n)
end

local function GroupUnits()
    local u = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do u[#u + 1] = "raid" .. i end
    elseif IsInGroup() then
        u[1] = "player"
        for i = 1, GetNumSubgroupMembers() do u[#u + 1] = "party" .. i end
    else
        u[1] = "player"
    end
    return u
end

---------------------------------------------------------------------
-- Spec lookup (own spec directly, others via inspect, out of combat)
---------------------------------------------------------------------

local specCache = {}   -- guid -> specID
local pending = nil    -- guid currently being inspected

local function RefreshOwnSpec()
    local idx = GetSpecialization and GetSpecialization()
    local id = idx and GetSpecializationInfo and GetSpecializationInfo(idx)
    local guid = UnitGUID("player")
    if id and guid then specCache[guid] = id end
end

local function InspectNext()
    if pending or InCombatLockdown() then return end
    for _, unit in ipairs(GroupUnits()) do
        local guid = UnitGUID(unit)
        if guid and not specCache[guid] and not UnitIsUnit(unit, "player")
           and UnitIsConnected(unit) and CanInspect(unit) then
            pending = guid
            NotifyInspect(unit)
            return
        end
    end
end

---------------------------------------------------------------------
-- Ranking from Blizzard's damage meter (readable out of combat only)
---------------------------------------------------------------------

-- sessionType: 0 = Overall, 1 = Current, 2 = Expired (previous fight)
local function ReadSession(sessionType)
    if not C_DamageMeter then return nil end
    if C_DamageMeter.IsDamageMeterAvailable and not C_DamageMeter.IsDamageMeterAvailable() then
        return nil
    end
    local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, 0) -- 0 = DamageDone
    if not ok or type(s) ~= "table" then return nil end
    if type(s.combatSources) ~= "table" or #s.combatSources == 0 then return nil end

    local dur
    if not IsSecret(s.durationSeconds) then dur = tonumber(s.durationSeconds) end
    if not dur then
        local ok2, d = pcall(C_DamageMeter.GetSessionDurationSeconds, sessionType)
        if ok2 and not IsSecret(d) then dur = tonumber(d) end
    end
    return s.combatSources, dur
end

-- returns rows, errorMessage, stats
local function RankPI(coeffs, sessionType)
    local sources, dur = ReadSession(sessionType)
    if not sources then return nil, "no damage meter data yet" end
    if not dur or dur <= 0 then return nil, "no fight duration available" end

    local guidToUnit = {}
    for _, unit in ipairs(GroupUnits()) do
        local g = UnitGUID(unit)
        if g then guidToUnit[g] = unit end
    end

    local rows = {}
    local stats = { total = #sources, secret = 0, notGroup = 0, priest = 0 }

    for _, src in ipairs(sources) do
        if IsSecret(src.sourceGUID) or IsSecret(src.totalAmount) or IsSecret(src.name) then
            stats.secret = stats.secret + 1
        elseif not guidToUnit[src.sourceGUID] then
            stats.notGroup = stats.notGroup + 1
        else
            local dmg = tonumber(src.totalAmount) or 0
            local specID = specCache[src.sourceGUID]
            local coeff = specID and coeffs[specID] or 1.0
            local dps = dmg / dur
            rows[#rows + 1] = {
                name = src.name, class = src.classFilename, specID = specID, guid = src.sourceGUID,
                dps = dps, coeff = coeff, gain = dps * (coeff - 1),
            }
        end
    end
    table.sort(rows, function(a, b) return a.gain > b.gain end)
    return rows, nil, stats
end

---------------------------------------------------------------------
-- Window
---------------------------------------------------------------------

local MAX_ROWS = 8
local ROW_H = 16
local mode = "ST"   -- "ST" or "Cleave"
local MODE_LABEL = { ST = "ST", Cleave3 = "3T", Cleave5 = "5T" }
local MODE_NEXT  = { ST = "Cleave3", Cleave3 = "Cleave5", Cleave5 = "ST" }
local source = 1

-- x offset, width, justification for each column
local COLS = {
    name = { 8,   112, "LEFT"  },
    spec = { 124, 92,  "LEFT"  },
    dps  = { 220, 54,  "RIGHT" },
    mult = { 278, 54,  "RIGHT" },
    gain = { 336, 56,  "RIGHT" },
}
local COL_ORDER = { "name", "spec", "dps", "mult", "gain" }
local HEADERS = { name = "Player", spec = "Spec", dps = "DPS", mult = "Mult", gain = "Gain" }

local win = CreateFrame("Frame", "PIMeterWindow", UIParent, "BackdropTemplate")
win:SetSize(400, 42 + MAX_ROWS * ROW_H + 34)
win:SetPoint("CENTER", UIParent, "CENTER", 400, 0)
win:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
win:SetBackdropColor(0, 0, 0, 0.75)
win:SetBackdropBorderColor(0, 0, 0, 1)
win:SetMovable(true)
win:EnableMouse(true)
win:SetClampedToScreen(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if PIMeterDB then PIMeterDB.pos = { point, relPoint, x, y } end
end)

local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 8, -8)
title:SetWidth(230)
title:SetJustifyH("LEFT")
title:SetWordWrap(false)
title:SetText("PI Gain")

local modeBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
modeBtn:SetSize(70, 18)
modeBtn:SetPoint("TOPRIGHT", -6, -5)
modeBtn:SetText("ST")

local srcBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
srcBtn:SetSize(70, 18)
srcBtn:SetPoint("RIGHT", modeBtn, "LEFT", -4, 0)
srcBtn:SetText("Last")

local resetBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
resetBtn:SetSize(54, 18)
resetBtn:SetPoint("BOTTOMRIGHT", -6, 5)
resetBtn:SetText("Reset")

local function MakeCell(col, y, template)
    local c = COLS[col]
    local fs = win:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", c[1], y)
    fs:SetSize(c[2], ROW_H)
    fs:SetJustifyH(c[3])
    fs:SetWordWrap(false)
    return fs
end

-- header row
for _, col in ipairs(COL_ORDER) do
    MakeCell(col, -26, "GameFontNormalSmall"):SetText(HEADERS[col])
end

-- data rows
local cells = {}
for i = 1, MAX_ROWS do
    cells[i] = {}
    for _, col in ipairs(COL_ORDER) do
        cells[i][col] = MakeCell(col, -42 - (i - 1) * ROW_H)
    end
    local hl = win:CreateTexture(nil, "BACKGROUND")
    hl:SetPoint("TOPLEFT", 4, -42 - (i - 1) * ROW_H)
    hl:SetSize(392, ROW_H)
    hl:SetColorTexture(1, 0.82, 0, 0.2)
    hl:Hide()
    cells[i].hl = hl
end

local status = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
status:SetPoint("BOTTOMLEFT", 8, 6)
status:SetSize(320, 24)
status:SetJustifyH("LEFT")
status:SetJustifyV("BOTTOM")

local lastRender

local function FocusGUID()
    if not UnitExists("focus") then return nil end
    local g = UnitGUID("focus")
    if not g or IsSecret(g) then return nil end
    return g
end

local function Render(rows, err, stats, label)
    lastRender = { rows = rows, err = err, stats = stats, label = label }
	title:SetText("PI Gain (" .. (MODE_LABEL[mode] or mode) .. ")" .. (label and (" - " .. label) or ""))

    for i = 1, MAX_ROWS do
        cells[i].hl:Hide()
        for _, col in ipairs(COL_ORDER) do cells[i][col]:SetText("") end
    end

    if not rows then
        status:SetText(err or "no data")
        return
    end

    local focusGuid = FocusGUID()
    local focusName
    local unknownSpec = 0

    for i, r in ipairs(rows) do
        if not r.specID then unknownSpec = unknownSpec + 1 end
        local isFocus = focusGuid and r.guid == focusGuid
        if isFocus then focusName = r.name end

        if i <= MAX_ROWS then
            local c = cells[i]
            local name = (r.name or "?"):match("^[^-]+") or "?"   -- strip realm
            local color = r.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[r.class]
            if color then
                name = string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
            end
            local spec = "?"
            if r.specID then
                spec = select(2, GetSpecializationInfoByID(r.specID)) or tostring(r.specID)
            end
            c.name:SetText((isFocus and "|cffffd100>|r" or "") .. i .. ". " .. name)
            c.spec:SetText(spec)
            c.dps:SetText(Short(r.dps))
            c.mult:SetText(string.format("x%.3f", r.coeff))
            c.gain:SetText("|cff80ff80+" .. Short(r.gain) .. "|r")
            if isFocus then c.hl:Show() end
        end
    end

    if #rows == 0 and stats then
        status:SetText(string.format("0 usable rows: %d sources, %d secret, %d not in group, %d priest",
            stats.total, stats.secret, stats.notGroup, stats.priest))
        return
    end

	local note = (label == "overall") and "Based on overall session. Drag to move."
								   or "Based on last fight. Drag to move."
    if unknownSpec > 0 then
        note = unknownSpec .. " player(s) not inspected yet - stand near them"
    end
    if #rows > MAX_ROWS then
        note = note .. string.format(" (top %d of %d)", MAX_ROWS, #rows)
    end
    if focusGuid then
        local who = focusName and focusName:match("^[^-]+")
        note = (who and ("Focus: " .. who) or "Focus not in list") .. " | " .. note
    end
    status:SetText(note)
end

local function Coeffs()
    if mode == "Cleave5" then return _G.Details_PIMeter_Cleave5 end
    if mode == "Cleave3" then return _G.Details_PIMeter_Cleave3 end
    return _G.Details_PIMeter_ST
end

local function Refresh()
    if InCombatLockdown() then
        if lastRender then
            Render(lastRender.rows, lastRender.err, lastRender.stats, lastRender.label)
        end
        status:SetText("In combat - showing last result")
        return
    end

    local rows, err, stats, label
    if source == 0 then
        rows, err, stats = RankPI(Coeffs(), 0)
        label = "overall"
    else
        rows, err, stats = RankPI(Coeffs(), 1)
        if not rows then
            rows, err, stats = RankPI(Coeffs(), 2)
            label = "previous"
        end
    end
    Render(rows, err, stats, label)
end

local function DoReset()
    if InCombatLockdown() then
        print("|cFF00FF00[PI Meter]|r Can't reset in combat.")
        return
    end
    if C_DamageMeter and C_DamageMeter.ResetAllCombatSessions then
        C_DamageMeter.ResetAllCombatSessions()
        lastRender = nil
        print("|cFF00FF00[PI Meter]|r Damage meter sessions reset.")
        C_Timer.After(0.5, Refresh)
    else
        print("|cFF00FF00[PI Meter]|r Reset isn't available on this client.")
    end
end

StaticPopupDialogs["PIMETER_RESET"] = {
    text = "Reset Blizzard's damage meter data? This also clears it for Blizzard's own meter and any other addon that reads it.",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function() DoReset() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

resetBtn:SetScript("OnClick", function()
    StaticPopup_Show("PIMETER_RESET")
end)

srcBtn:SetScript("OnClick", function()
    source = (source == 1) and 0 or 1
    srcBtn:SetText(source == 1 and "Last" or "Overall")
    Refresh()
end)

local refreshQueued = false
local function QueueRefresh(delay)
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(delay or 0.5, function()
        refreshQueued = false
        Refresh()
    end)
end

modeBtn:SetScript("OnClick", function()
    mode = MODE_NEXT[mode]
    modeBtn:SetText(MODE_LABEL[mode])
    Refresh()
end)

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("INSPECT_READY")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_FOCUS_CHANGED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        PIMeterDB = PIMeterDB or {}
        BuildCoefficientTables()
        local p = PIMeterDB.pos
        if p then
            win:ClearAllPoints()
            win:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        end
        if PIMeterDB.hidden then win:Hide() end
    elseif event == "INSPECT_READY" then
        for _, unit in ipairs(GroupUnits()) do
            if UnitGUID(unit) == arg1 then
                local id = GetInspectSpecialization(unit)
                if id and id > 0 then specCache[arg1] = id end
            end
        end
        pending = nil
        ClearInspectPlayer()
        QueueRefresh(0.5)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- the meter session may take a moment to finalize, so refresh twice
        C_Timer.After(1, Refresh)
        C_Timer.After(4, Refresh)
    elseif event == "PLAYER_REGEN_DISABLED" then
        status:SetText("In combat - showing last fight")
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        QueueRefresh(0.3)
    end
    RefreshOwnSpec()
    InspectNext()
end)
C_Timer.NewTicker(3, function() pending = nil; InspectNext() end)

---------------------------------------------------------------------
-- /pi [show|hide|st|cleave|debug]
---------------------------------------------------------------------

SLASH_PIMETER1 = "/pi"
SlashCmdList.PIMETER = function(msg)
    msg = (msg or ""):lower()
    if msg:find("hide") then
        win:Hide()
        if PIMeterDB then PIMeterDB.hidden = true end
        return
    end
    win:Show()
    if PIMeterDB then PIMeterDB.hidden = false end

    if msg:find("overall") then source = 0; srcBtn:SetText("Overall")
    elseif msg:find("last") then source = 1; srcBtn:SetText("Last") end
	
	if msg:find("reset") then DoReset() end
	
	local function SetMode(m) mode = m; modeBtn:SetText(MODE_LABEL[m]) end

    if msg:find("5") then SetMode("Cleave5")
    elseif msg:find("cleave") or msg:find("3") then SetMode("Cleave3")
    elseif msg:find("%f[%a]st%f[%A]") then SetMode("ST") end

    if msg:find("debug") then
        local sources, dur = ReadSession(1)
        print("|cFF00FF00[PI Meter]|r current session:", sources and #sources or "none", "duration:", dur or "none")
        sources, dur = ReadSession(2)
        print("|cFF00FF00[PI Meter]|r previous session:", sources and #sources or "none", "duration:", dur or "none")
        print("|cFF00FF00[PI Meter]|r group units:", #GroupUnits())
    end
    Refresh()
end