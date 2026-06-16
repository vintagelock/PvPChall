local ADDON_NAME = "PvPSpecTracker"

-- ---------------------------------------------------------------------------
-- All retail specs, grouped by role.
-- Names/icons are filled at runtime via GetSpecializationInfoByID().
-- ---------------------------------------------------------------------------
local ROLE_ORDER = { "healer", "tank", "melee", "ranged" }
local ROLE_LABEL = { healer="Healers", tank="Tanks", melee="Melee", ranged="Ranged" }

local SPEC_LIST = {
    -- Healers
    { role="healer", specID=65  },  -- Holy Paladin
    { role="healer", specID=105 },  -- Restoration Druid
    { role="healer", specID=256 },  -- Discipline Priest
    { role="healer", specID=257 },  -- Holy Priest
    { role="healer", specID=264 },  -- Restoration Shaman
    { role="healer", specID=270 },  -- Mistweaver Monk
    { role="healer", specID=1468},  -- Preservation Evoker

    -- Tanks
    { role="tank",   specID=250 },  -- Blood Death Knight
    { role="tank",   specID=581 },  -- Vengeance Demon Hunter
    { role="tank",   specID=104 },  -- Guardian Druid
    { role="tank",   specID=268 },  -- Brewmaster Monk
    { role="tank",   specID=66  },  -- Protection Paladin
    { role="tank",   specID=73  },  -- Protection Warrior

    -- Melee DPS
    { role="melee",  specID=251 },  -- Frost Death Knight
    { role="melee",  specID=252 },  -- Unholy Death Knight
    { role="melee",  specID=577 },  -- Havoc Demon Hunter
    { role="melee",  specID=103 },  -- Feral Druid
    { role="melee",  specID=255 },  -- Survival Hunter
    { role="melee",  specID=269 },  -- Windwalker Monk
    { role="melee",  specID=70  },  -- Retribution Paladin
    { role="melee",  specID=259 },  -- Assassination Rogue
    { role="melee",  specID=260 },  -- Outlaw Rogue
    { role="melee",  specID=261 },  -- Subtlety Rogue
    { role="melee",  specID=263 },  -- Enhancement Shaman
    { role="melee",  specID=71  },  -- Arms Warrior
    { role="melee",  specID=72  },  -- Fury Warrior

    -- Ranged DPS
    { role="ranged", specID=102 },  -- Balance Druid
    { role="ranged", specID=253 },  -- Beast Mastery Hunter
    { role="ranged", specID=254 },  -- Marksmanship Hunter
    { role="ranged", specID=62  },  -- Arcane Mage
    { role="ranged", specID=63  },  -- Fire Mage
    { role="ranged", specID=64  },  -- Frost Mage
    { role="ranged", specID=258 },  -- Shadow Priest
    { role="ranged", specID=262 },  -- Elemental Shaman
    { role="ranged", specID=265 },  -- Affliction Warlock
    { role="ranged", specID=266 },  -- Demonology Warlock
    { role="ranged", specID=267 },  -- Destruction Warlock
    { role="ranged", specID=1467},  -- Devastation Evoker
    { role="ranged", specID=1473},  -- Augmentation Evoker
    { role="ranged",  specID=1477},  -- Devourer Demon Hunter
}

-- Runtime-populated lookup: specID -> { name, className, classFile, icon, role }
local SPEC_INFO = {}

-- ---------------------------------------------------------------------------
-- SavedVariables defaults
-- ---------------------------------------------------------------------------
local DB_DEFAULTS = {
    ratings       = {},      -- [specID] = { maxRating2v2, maxRating3v3 }
    hiddenSpecs   = {},      -- [specID] = true

    bracketFilter   = "best",  -- "best" | "2v2" | "3v3"
    ratingThreshold = 1800,
    debugMode       = false,
    activeRole      = "healer",
    showUnplayed    = true,    -- show specs with 0 rating
    sortAlpha       = false,   -- sort alphabetically instead of rating-desc

    overlayScale  = 1.0,
    overlayAlpha  = 0.9,
    overlayWidth  = 300,
    lockOverlay   = false,
    titleVisible  = true,

    hideInArena   = true,
    hideInBG      = false,
    hideInWorld   = false,

    overlayAnchor = { point="CENTER", x=0, y=0 },
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local db
local overlay, settingsFrame
local specInfoReady = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function GetRatingForBracket(bracket)
    local info
    if bracket == "2v2" then
        info = C_PvP.GetRatingInfo and C_PvP.GetRatingInfo(1)
    elseif bracket == "3v3" then
        info = C_PvP.GetRatingInfo and C_PvP.GetRatingInfo(2)
    end
    return info and info.rating or 0
end

local function GetBestRating()
    local r2 = GetRatingForBracket("2v2")
    local r3 = GetRatingForBracket("3v3")
    return math.max(r2, r3), r2, r3
end

local function GetRatingForSpec(specID)
    if db.debugMode then
        -- Deterministic fake rating seeded by specID so it's consistent
        local fake = (specID * 137 + 421) % 1200 + 1200
        return fake
    end
    local entry = db.ratings[specID]
    if not entry then return 0 end
    local f = db.bracketFilter
    if f == "2v2" then return entry.maxRating2v2 or 0 end
    if f == "3v3" then return entry.maxRating3v3 or 0 end
    return math.max(entry.maxRating2v2 or 0, entry.maxRating3v3 or 0)
end

local function GetClassColor(classFile)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function DirtyOverlay()
    if overlay then overlay.dirty = true end
end

-- Updates which role tab buttons are visible on the overlay.
-- Hides tabs whose role has ALL specs hidden; always shows "All".
local function RefreshOverlayTabs()
    if not overlay or not overlay.tabBtns then return end

    -- Which roles have at least one visible spec?
    local visibleRoles = {}
    for _, s in ipairs(SPEC_LIST) do
        if not db.hiddenSpecs[s.specID] then
            visibleRoles[s.role] = true
        end
    end

    local activeStillVisible = false
    for _, btn in ipairs(overlay.tabBtns) do
        local allRolesVisible = (next(db.hiddenSpecs) == nil)
        local show = (btn.roleKey == "all" and allRolesVisible) or visibleRoles[btn.roleKey]
        btn:SetShown(show ~= nil and show ~= false)
        if btn.roleKey == db.activeRole and show then
            activeStillVisible = true
        end
    end

    -- If the active tab is now hidden, switch to the first visible role
    if not activeStillVisible then
        for _, btn in ipairs(overlay.tabBtns) do
            if btn:IsShown() and btn.roleKey ~= "all" then
                overlay.SelectRole(btn.roleKey)
                return
            end
        end
        overlay.SelectRole("all")
    end
end

-- ---------------------------------------------------------------------------
-- Populate SPEC_INFO at login (API needs to be loaded)
-- ---------------------------------------------------------------------------
local function BuildSpecInfo()
    for _, s in ipairs(SPEC_LIST) do
        local id, name, _, icon, _, _, classFile = GetSpecializationInfoByID(s.specID)
        if id then
            local _, className = GetClassInfo(GetClassInfoBySpecID and GetClassInfoBySpecID(s.specID) or 0)
            -- fallback: derive className from classFile
            if not className or className == "" then
                className = classFile and (classFile:sub(1,1) .. classFile:sub(2):lower()) or "Unknown"
            end
            SPEC_INFO[s.specID] = {
                name      = name,
                className = className,
                classFile = classFile,
                icon      = icon,
                role      = s.role,
            }
        end
    end
    specInfoReady = true
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------
local function CheckAndRecord()
    local specIndex = GetSpecialization()
    if not specIndex then return end
    local specID = select(1, GetSpecializationInfo(specIndex))
    if not specID then return end

    local _, r2, r3 = GetBestRating()
    local entry = db.ratings[specID] or { maxRating2v2=0, maxRating3v3=0 }
    local changed = false
    if r2 > (entry.maxRating2v2 or 0) then entry.maxRating2v2 = r2; changed = true end
    if r3 > (entry.maxRating3v3 or 0) then entry.maxRating3v3 = r3; changed = true end
    if changed then
        db.ratings[specID] = entry
        DirtyOverlay()
    end
end

-- ---------------------------------------------------------------------------
-- Zone / arena hide logic
-- ---------------------------------------------------------------------------
local function UpdateZoneState()
    if not overlay then return end
    local _, instanceType = IsInInstance()
    local inArena = (instanceType == "arena") or (C_PvP.IsArena and C_PvP.IsArena()) or false
    local inBG    = (instanceType == "pvp")
    local inWorld = (instanceType == "none" or instanceType == nil)

    local hide =
        (db.hideInArena and inArena) or
        (db.hideInBG    and inBG)    or
        (db.hideInWorld and inWorld)

    if hide then
        overlay:Hide()
        if settingsFrame then settingsFrame:Hide() end
    else
        overlay:Show()
        DirtyOverlay()
    end
end

-- ---------------------------------------------------------------------------
-- Overlay row pool
-- ---------------------------------------------------------------------------
local TICK_ICON  = "Interface\\RaidFrame\\ReadyCheck-Ready"
local CROSS_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"

local function MakeOverlayRow(parent)
    local row = CreateFrame("Frame", nil, parent)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row.ratingText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.ratingText:SetJustifyH("RIGHT")

    row.tick = row:CreateTexture(nil, "OVERLAY")
    row.tick:SetSize(20, 20)
    row.tick:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    return row
end

-- ---------------------------------------------------------------------------
-- Overlay refresh
-- ---------------------------------------------------------------------------
local ROLE_TAB_H = 22
local TITLE_H    = 20
local ROW_GAP    = 2

local function RefreshOverlay(self)
    if not db or not specInfoReady then return end

    local threshold = db.ratingThreshold
    local rowH      = 26
    local iconSz    = 20
    local pad       = 6
    local role      = db.activeRole

    -- Gather specs for this role
    local specRows = {}
    for _, s in ipairs(SPEC_LIST) do
        if s.role == role or role == "all" then
            local info = SPEC_INFO[s.specID]
            if info and not db.hiddenSpecs[s.specID] then
                local rating = GetRatingForSpec(s.specID)
                if db.showUnplayed or rating > 0 then
                    table.insert(specRows, { specID=s.specID, info=info, rating=rating })
                end
            end
        end
    end

    -- Sort
    if db.sortAlpha then
        table.sort(specRows, function(a,b) return a.info.name < b.info.name end)
    else
        table.sort(specRows, function(a,b)
            if a.rating ~= b.rating then return a.rating > b.rating end
            local aDone = a.rating >= threshold
            local bDone = b.rating >= threshold
            if aDone ~= bDone then return aDone end
            return a.info.name < b.info.name
        end)
    end

    -- Pool management
    self.rowPool = self.rowPool or {}
    while #self.rowPool < #specRows do
        table.insert(self.rowPool, MakeOverlayRow(self))
    end
    for _, r in ipairs(self.rowPool) do r:Hide() end

    -- Debug watermark
    if self.debugLabel then self.debugLabel:SetShown(db.debugMode) end

    -- Title
    local titleH = db.titleVisible and TITLE_H or 0
    if self.titleText then
        self.titleText:SetShown(db.titleVisible)
        self.divider:SetShown(db.titleVisible)
    end

    -- Role tabs
    local tabTop = -(titleH + 2)

    -- Content rows
    local contentTop = -(titleH + ROLE_TAB_H + 8)

    if #specRows == 0 then
        self.emptyLabel:Show()
        self.emptyLabel:SetPoint("TOP", self, "TOP", 0, contentTop - 14)
        self:SetHeight(titleH + ROLE_TAB_H + 60)
        self.dirty = false
        return
    end
    self.emptyLabel:Hide()

    local totalH = titleH + ROLE_TAB_H + 8 + pad
    for i, data in ipairs(specRows) do
        local row   = self.rowPool[i]
        local yOff  = contentTop - pad - (i-1) * (rowH + ROW_GAP)
        row:SetHeight(rowH)
        row:SetPoint("TOPLEFT", self, "TOPLEFT", pad, yOff)
        row:SetPoint("RIGHT",   self, "RIGHT",   -pad, 0)

        -- Icon
        row.icon:SetSize(iconSz, iconSz)
        row.icon:SetTexture(data.info.icon)

        -- Label: "SpecName" coloured by class, then "- ClassName" in dimmer colour
        local r, g, b = GetClassColor(data.info.classFile)
        row.label:SetText(string.format(
            "|cff%02x%02x%02x%s|r |cff888888%s|r",
            r*255, g*255, b*255,
            data.info.name,
            data.info.className))
        row.label:SetPoint("LEFT",  row.icon,   "RIGHT", 6, 0)
        row.label:SetPoint("RIGHT", row.tick,   "LEFT",  -54, 0)

        -- Tick or cross
        local done = data.rating >= threshold
        local hasRating = data.rating > 0
        if done then
            row.tick:SetTexture(TICK_ICON)
            row.tick:Show()
            row.ratingText:SetText(string.format("|cff00ff96%d|r", data.rating))
        elseif hasRating then
            row.tick:SetTexture(CROSS_ICON)
            row.tick:Show()
            row.ratingText:SetText(string.format("|cffaaaaaa%d|r", data.rating))
        else
            row.tick:Hide()
            row.ratingText:SetText("|cff555555-----|r")
        end
        row.ratingText:SetPoint("RIGHT", row, "RIGHT", (done or hasRating) and -24 or -4, 0)

        row:Show()
        totalH = totalH + rowH + ROW_GAP
    end

    self:SetHeight(totalH + pad)
    self.dirty = false
end

-- ---------------------------------------------------------------------------
-- Role tab buttons on the overlay
-- ---------------------------------------------------------------------------
local TAB_ROLES = {
    { key="healer", label="Heal"   },
    { key="tank",   label="Tank"   },
    { key="melee",  label="Melee"  },
    { key="ranged", label="Range"  },
    { key="all",    label="All"    },
}

local function BuildRoleTabs(overlay)
    local tabW   = math.floor((db.overlayWidth - 8) / #TAB_ROLES)
    local tabBtns = {}

    local function SelectRole(key)
        db.activeRole = key
        for _, btn in ipairs(tabBtns) do
            if btn.roleKey == key then
                btn:LockHighlight()
                btn:SetFontString(btn:GetFontString())
                local fs = btn:GetFontString()
                if fs then fs:SetTextColor(1, 0.82, 0) end
            else
                btn:UnlockHighlight()
                local fs = btn:GetFontString()
                if fs then fs:SetTextColor(0.8, 0.8, 0.8) end
            end
        end
        DirtyOverlay()
    end

    local titleH = TITLE_H + 2
    for i, def in ipairs(TAB_ROLES) do
        local btn = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
        btn:SetSize(tabW, ROLE_TAB_H)
        btn:SetPoint("TOPLEFT", overlay, "TOPLEFT", 4 + (i-1)*tabW, -(titleH))
        btn:SetText(def.label)
        btn.roleKey = def.key
        btn:SetScript("OnClick", function() SelectRole(def.key) end)
        table.insert(tabBtns, btn)
    end

    overlay.tabBtns   = tabBtns
    overlay.SelectRole = SelectRole

    SelectRole(db.activeRole)
    RefreshOverlayTabs()
end

-- ---------------------------------------------------------------------------
-- Create overlay
-- ---------------------------------------------------------------------------
local function CreateOverlay()
    local f = CreateFrame("Frame", "PvPSpecTrackerOverlay", UIParent, "BackdropTemplate")
    f:SetSize(db.overlayWidth, 200)
    f:SetScale(db.overlayScale)
    f:SetAlpha(db.overlayAlpha)
    f:SetClampedToScreen(true)
    f:SetMovable(not db.lockOverlay)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) if not db.lockOverlay then s:StartMoving() end end)
    f:SetScript("OnDragStop",  function(s)
        s:StopMovingOrSizing()
        local pt, _, _, x, y = s:GetPoint()
        db.overlayAnchor = { point=pt, x=x, y=y }
    end)

    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=14,
        insets={ left=3, right=3, top=3, bottom=3 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 1)
    f:SetBackdropBorderColor(0.35, 0.35, 0.45, 1)

    -- Title
    f.titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.titleText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -5)
    f.titleText:SetText("|cffffffffSnow|r|cff00ffffmixy|r |cffffcc00PvP Spec Tracker|r")

    -- Settings cog
    local cog = CreateFrame("Button", nil, f)
    cog:SetSize(14, 14)
    cog:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    cog:SetNormalTexture("Interface\\GossipFrame\\GossipGossipIcon")
    cog:SetHighlightTexture("Interface\\GossipFrame\\GossipGossipIcon")
    cog:SetScript("OnClick",  function() PvPSpecTrackerSettings_Toggle() end)
    cog:SetScript("OnEnter",  function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:SetText("PvP Spec Tracker settings")
        GameTooltip:Show()
    end)
    cog:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Divider below title
    f.divider = f:CreateTexture(nil, "ARTWORK")
    f.divider:SetHeight(1)
    f.divider:SetPoint("TOPLEFT",  f, "TOPLEFT",  4, -18)
    f.divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -18)
    f.divider:SetColorTexture(0.35, 0.35, 0.45, 0.7)

    -- Empty state label
    f.emptyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.emptyLabel:SetText("No specs to show")
    f.emptyLabel:Hide()

    f.debugLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.debugLabel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 4)
    f.debugLabel:SetText("|cffff4444DEBUG|r")
    f.debugLabel:Hide()

    f.rowPool    = {}
    f.dirty      = true
    f.RefreshRows = RefreshOverlay

    -- Anchor
    local a = db.overlayAnchor
    f:SetPoint(a.point or "CENTER", UIParent, a.point or "CENTER", a.x or 0, a.y or 0)

    BuildRoleTabs(f)

    f:SetScript("OnUpdate", function(self, elapsed)
        self._t = (self._t or 0) + elapsed
        if self._t >= 1.5 and self.dirty then
            self._t = 0
            self:RefreshRows()
        end
    end)

    f:Show()
    return f
end

-- ---------------------------------------------------------------------------
-- Settings UI helpers
-- ---------------------------------------------------------------------------

-- Spacing constants used across all tabs
local S_PAD    = 20   -- left/right margin inside a tab panel
local S_ITEM   = 30   -- vertical gap between checkboxes / radios
local S_SLIDER = 56   -- vertical space consumed by one slider (label + track + gap)
local S_SEC    = 16   -- extra space ABOVE a new section header
local S_HEAD   = 26   -- height of section header + its divider line

-- MakeSlider: anchoring is always done by the caller after creation.
-- Returns (labelFontString, slider) -- caller re-anchors both.
local _sid = 0
local function MakeSlider(parent, lbl, minV, maxV, step, fmt)
    _sid = _sid + 1
    local name = "PvPSTSl" .. _sid
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText(lbl)
    local sl = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    _G[name.."Low"]:SetText(tostring(minV))
    _G[name.."High"]:SetText(tostring(maxV))
    sl.vLabel = _G[name.."Text"]
    sl.fmt    = fmt or "%s"
    sl.lbl    = fs
    sl:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val / step + 0.5) * step
        self.vLabel:SetText(string.format(self.fmt, val))
        if self.OnChange then self.OnChange(val) end
    end)
    function sl:Sync(v)
        self:SetValue(v)
        self.vLabel:SetText(string.format(self.fmt, v))
    end
    -- helper: anchor label then slider below it, both stretching to tab width
    function sl:AnchorBelow(anchor, xOff, yOff)
        self.lbl:SetPoint("TOPLEFT", anchor, "TOPLEFT", xOff, yOff)
        self:SetPoint("TOPLEFT", anchor, "TOPLEFT", xOff + 10, yOff - 20)
        self:SetPoint("RIGHT",   anchor, "RIGHT",   -(xOff + 10), 0)
    end
    return sl
end

local function MakeCheck(parent, lbl, x, y, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb.text:SetText(lbl)
    cb:SetScript("OnClick", function(self) onChange(self:GetChecked()) end)
    function cb:Sync(v) self:SetChecked(v) end
    return cb
end

local function MakeRadioGroup(parent, opts, x, y, onChange)
    local btns = {}
    local function syncAll(val)
        for _, b in ipairs(btns) do b:SetChecked(b.rval == val) end
    end
    for i, opt in ipairs(opts) do
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - (i - 1) * S_ITEM)
        cb.text:SetText(opt.label)
        cb.rval = opt.value
        cb:SetScript("OnClick", function(self) onChange(self.rval); syncAll(self.rval) end)
        table.insert(btns, cb)
    end
    return syncAll
end

local function MakeBtn(parent, lbl, w, h, x, y, fn)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetText(lbl)
    b:SetScript("OnClick", fn)
    return b
end

local function SectionHead(parent, text, x, y, tabW)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText("|cffffcc00" .. text .. "|r")
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  parent, "TOPLEFT",  x,       y - 18)
    div:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(x - 4), y - 18)
    div:SetColorTexture(0.55, 0.55, 0.65, 0.5)
end

-- ---------------------------------------------------------------------------
-- Settings tabs
-- ---------------------------------------------------------------------------
local function BuildTabFilters(tab)
    local x, y = S_PAD, -S_PAD

    SectionHead(tab, "Bracket to track", x, y); y = y - S_HEAD

    local syncBracket = MakeRadioGroup(tab, {
        { label = "Best of 2v2 & 3v3 (whichever is higher)", value = "best" },
        { label = "2v2 only",                                 value = "2v2"  },
        { label = "3v3 only",                                 value = "3v3"  },
    }, x + 8, y, function(v) db.bracketFilter = v; DirtyOverlay() end)
    y = y - (3 * S_ITEM) - S_SEC

    SectionHead(tab, "Rating threshold", x, y); y = y - S_HEAD
    local thr = MakeSlider(tab, "Minimum CR to show a spec as achieved", 0, 2800, 50, "%d CR")
    thr:AnchorBelow(tab, x, y)
    thr.OnChange = function(v) db.ratingThreshold = v; DirtyOverlay() end
    y = y - S_SLIDER - S_SEC

    SectionHead(tab, "Overlay list options", x, y); y = y - S_HEAD
    local showUnplayed = MakeCheck(tab, "Show specs with no recorded rating (displays as dashes)", x + 8, y, function(v)
        db.showUnplayed = v; DirtyOverlay()
    end); y = y - S_ITEM
    local sortAlpha = MakeCheck(tab, "Sort specs alphabetically instead of by rating", x + 8, y, function(v)
        db.sortAlpha = v; DirtyOverlay()
    end); y = y - S_ITEM - S_SEC

    SectionHead(tab, "Quick filters", x, y); y = y - S_HEAD

    local quickDesc = tab:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    quickDesc:SetPoint("TOPLEFT", tab, "TOPLEFT", x + 8, y)
    quickDesc:SetText("Presets that show/hide specs by role. Your per-spec settings on the Specs tab are preserved.")
    quickDesc:SetWordWrap(true)
    quickDesc:SetPoint("RIGHT", tab, "RIGHT", -x, 0)
    y = y - 30

    local function SetRoleOnly(role)
        for _, s in ipairs(SPEC_LIST) do
            db.hiddenSpecs[s.specID] = (s.role ~= role) or nil
        end
        DirtyOverlay()
        RefreshOverlayTabs()
    end

    local function ClearRoleFilter()
        db.hiddenSpecs = {}
        DirtyOverlay()
        RefreshOverlayTabs()
    end

    MakeBtn(tab, "Healers only",  110, 26, x + 8,       y, function() SetRoleOnly("healer") end)
    MakeBtn(tab, "Tanks only",    110, 26, x + 8 + 116,  y, function() SetRoleOnly("tank")   end)
    MakeBtn(tab, "Melee only",    110, 26, x + 8 + 232,  y, function() SetRoleOnly("melee")  end)
    y = y - 34

    MakeBtn(tab, "Ranged only",   110, 26, x + 8,       y, function() SetRoleOnly("ranged")  end)
    MakeBtn(tab, "Show all roles",110, 26, x + 8 + 116,  y, function() ClearRoleFilter()      end)

    tab.Sync = function()
        syncBracket(db.bracketFilter)
        thr:Sync(db.ratingThreshold)
        showUnplayed:Sync(db.showUnplayed)
        sortAlpha:Sync(db.sortAlpha)
    end
end

local function BuildTabDisplay(tab)
    local x, y = S_PAD, -S_PAD

    SectionHead(tab, "Overlay scale & opacity", x, y); y = y - S_HEAD

    local sc = MakeSlider(tab, "Scale  (1.0 = normal size)", 0.5, 2.0, 0.05, "%.2f")
    sc:AnchorBelow(tab, x, y)
    sc.OnChange = function(v) db.overlayScale = v; if overlay then overlay:SetScale(v) end end
    y = y - S_SLIDER

    local al = MakeSlider(tab, "Opacity  (1.0 = fully opaque)", 0.1, 1.0, 0.05, "%.2f")
    al:AnchorBelow(tab, x, y)
    al.OnChange = function(v) db.overlayAlpha = v; if overlay then overlay:SetAlpha(v) end end
    y = y - S_SLIDER - S_SEC

    SectionHead(tab, "Panel width", x, y); y = y - S_HEAD
    local ow = MakeSlider(tab, "Width in pixels", 220, 600, 10, "%d px")
    ow:AnchorBelow(tab, x, y)
    ow.OnChange = function(v) db.overlayWidth = v; if overlay then overlay:SetWidth(v) end end
    y = y - S_SLIDER - S_SEC

    SectionHead(tab, "Other options", x, y); y = y - S_HEAD
    local titleCb = MakeCheck(tab, "Show title bar on overlay", x + 8, y, function(v)
        db.titleVisible = v; DirtyOverlay()
    end); y = y - S_ITEM
    local lockCb = MakeCheck(tab, "Lock overlay position (disable drag-to-move)", x + 8, y, function(v)
        db.lockOverlay = v; if overlay then overlay:SetMovable(not v) end
    end); y = y - S_ITEM - S_SEC

    SectionHead(tab, "Position", x, y); y = y - S_HEAD
    MakeBtn(tab, "Reset position & scale to defaults", 240, 26, x + 8, y, function()
        db.overlayAnchor = { point = "CENTER", x = 0, y = 0 }
        db.overlayScale  = 1.0
        if overlay then
            overlay:ClearAllPoints()
            overlay:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            overlay:SetScale(1.0)
        end
        sc:Sync(1.0)
    end)

    tab.Sync = function()
        sc:Sync(db.overlayScale)
        al:Sync(db.overlayAlpha)
        ow:Sync(db.overlayWidth)
        titleCb:Sync(db.titleVisible)
        lockCb:Sync(db.lockOverlay)
    end
end

local function BuildTabBehaviour(tab)
    local x, y = S_PAD, -S_PAD

    SectionHead(tab, "Auto-hide the overlay", x, y); y = y - S_HEAD

    local desc = tab:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", tab, "TOPLEFT", x + 8, y)
    desc:SetText("The overlay will hide automatically when you enter these areas.")
    y = y - 22

    local ar = MakeCheck(tab, "Hide while in an arena match", x + 8, y, function(v)
        db.hideInArena = v; UpdateZoneState()
    end); y = y - S_ITEM
    local bg = MakeCheck(tab, "Hide while in a battleground", x + 8, y, function(v)
        db.hideInBG = v; UpdateZoneState()
    end); y = y - S_ITEM
    local wo = MakeCheck(tab, "Hide while in the open world (outside instances)", x + 8, y, function(v)
        db.hideInWorld = v; UpdateZoneState()
    end)

    tab.Sync = function()
        ar:Sync(db.hideInArena)
        bg:Sync(db.hideInBG)
        wo:Sync(db.hideInWorld)
    end
end

local function BuildTabSpecs(tab)
    local TOOLBAR_H = 28   -- height of the toolbar row
    local ROW_H     = 32
    local SCROLL_TOP = S_PAD + TOOLBAR_H + 8   -- pixels from top where scroll starts

    -- - Row 1: "Show all" / "Hide all" on the left -
    local allBtn = MakeBtn(tab, "Show all", 90, TOOLBAR_H, S_PAD, -S_PAD, function()
        db.hiddenSpecs = {}; DirtyOverlay(); tab:Refresh()
    end)
    local noneBtn = MakeBtn(tab, "Hide all", 90, TOOLBAR_H, S_PAD + 96, -S_PAD, function()
        for _, s in ipairs(SPEC_LIST) do db.hiddenSpecs[s.specID] = true end
        DirtyOverlay(); tab:Refresh()
    end)

    -- - Row 1: role filter buttons on the right -
    local roleFilter = "all"
    local rfDefs = {
        { k="all",    label="All"   },
        { k="healer", label="Heal"  },
        { k="tank",   label="Tank"  },
        { k="melee",  label="Melee" },
        { k="ranged", label="Range" },
    }
    local rfBtnW = 46
    local rfBtns = {}
    for i = #rfDefs, 1, -1 do          -- build right-to-left so we can chain TOPLEFT
        local def = rfDefs[i]
        local b = CreateFrame("Button", nil, tab, "UIPanelButtonTemplate")
        b:SetSize(rfBtnW, TOOLBAR_H)
        if i == #rfDefs then
            b:SetPoint("TOPRIGHT", tab, "TOPRIGHT", -S_PAD, -S_PAD)
        else
            b:SetPoint("TOPRIGHT", rfBtns[1], "TOPLEFT", -3, 0)
        end
        b:SetText(def.label)
        local k = def.k
        b:SetScript("OnClick", function() roleFilter = k; tab:Refresh() end)
        table.insert(rfBtns, 1, b)
    end

    -- - Divider under toolbar -
    local toolDiv = tab:CreateTexture(nil, "ARTWORK")
    toolDiv:SetHeight(1)
    toolDiv:SetPoint("TOPLEFT",  tab, "TOPLEFT",  S_PAD,  -(S_PAD + TOOLBAR_H + 4))
    toolDiv:SetPoint("TOPRIGHT", tab, "TOPRIGHT", -S_PAD, -(S_PAD + TOOLBAR_H + 4))
    toolDiv:SetColorTexture(0.4, 0.4, 0.5, 0.4)

    -- - Scroll area -
    local scroll = CreateFrame("ScrollFrame", nil, tab, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     tab, "TOPLEFT",     S_PAD, -SCROLL_TOP)
    scroll:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -S_PAD - 20, S_PAD)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetHeight(1)
    scroll:SetScrollChild(content)

    -- content width is computed in Refresh once layout is done
    local function ContentWidth()
        local w = scroll:GetWidth()
        return (w > 10) and (w - 4) or 400
    end

    local rows = {}

    tab.Refresh = function()
        for _, r in ipairs(rows) do r:Hide() end
        rows = {}

        local specs = {}
        for _, s in ipairs(SPEC_LIST) do
            if roleFilter == "all" or s.role == roleFilter then
                local info = SPEC_INFO[s.specID]
                if info then
                    local entry = db.ratings[s.specID] or { maxRating2v2=0, maxRating3v3=0 }
                    local best  = math.max(entry.maxRating2v2 or 0, entry.maxRating3v3 or 0)
                    table.insert(specs, {
                        specID = s.specID, info = info,
                        r2 = entry.maxRating2v2 or 0,
                        r3 = entry.maxRating3v3 or 0,
                        best = best,
                    })
                end
            end
        end
        table.sort(specs, function(a, b)
            if a.info.role ~= b.info.role then return a.info.role < b.info.role end
            return a.info.name < b.info.name
        end)

        local cw   = ContentWidth()
        content:SetWidth(cw)

        local rowY = 0
        for idx, data in ipairs(specs) do
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(cw, ROW_H)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -rowY)

            -- zebra stripe
            if (idx % 2) == 0 then
                local stripe = row:CreateTexture(nil, "BACKGROUND")
                stripe:SetAllPoints(row)
                stripe:SetColorTexture(1, 1, 1, 0.04)
            end

            -- spec icon
            local ico = row:CreateTexture(nil, "ARTWORK")
            ico:SetSize(22, 22)
            ico:SetPoint("LEFT", row, "LEFT", 4, 0)
            ico:SetTexture(data.info.icon)
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            -- achieved tick (far right)
            local tk
            if data.best >= db.ratingThreshold then
                tk = row:CreateTexture(nil, "OVERLAY")
                tk:SetSize(18, 18)
                tk:SetTexture(TICK_ICON)
                tk:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end

            -- ratings text, left of tick (or flush right if no tick)
            local rl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rl:SetPoint("RIGHT", row, "RIGHT", tk and -26 or -6, 0)
            rl:SetJustifyH("RIGHT")
            rl:SetText(string.format(
                "|cff00ff962v2:%d|r  |cff00ccff3v3:%d|r",
                data.r2, data.r3))

            -- clear-data button, left of ratings
            local del = CreateFrame("Button", nil, row)
            del:SetSize(14, 14)
            del:SetPoint("RIGHT", rl, "LEFT", -6, 0)
            del:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
            del:SetAlpha(0.2)
            del:SetScript("OnEnter", function(s)
                s:SetAlpha(1)
                GameTooltip:SetOwner(s, "ANCHOR_LEFT")
                GameTooltip:SetText("Clear saved rating for this spec")
                GameTooltip:Show()
            end)
            del:SetScript("OnLeave", function(s) s:SetAlpha(0.2); GameTooltip:Hide() end)
            local sid = data.specID
            del:SetScript("OnClick", function()
                db.ratings[sid] = nil; DirtyOverlay(); tab:Refresh()
            end)

            -- visibility checkbox
            local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            cb:SetSize(22, 22)
            cb:SetPoint("LEFT", ico, "RIGHT", 2, 0)
            cb:SetChecked(not db.hiddenSpecs[data.specID])
            cb:SetScript("OnClick", function(self)
                db.hiddenSpecs[sid] = self:GetChecked() and nil or true
                DirtyOverlay()
            end)

            -- class-coloured spec name, fills space between checkbox and del button
            local cr, cg, cb2 = GetClassColor(data.info.classFile)
            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("LEFT",  cb,  "RIGHT", 4, 0)
            lbl:SetPoint("RIGHT", del, "LEFT",  -6, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetWordWrap(false)
            lbl:SetText(string.format("|cff%02x%02x%02x%s|r  %s",
                cr*255, cg*255, cb2*255, data.info.className, data.info.name))

            table.insert(rows, row)
            rowY = rowY + ROW_H + 2
        end

        if #specs == 0 then
            local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            empty:SetPoint("TOP", content, "TOP", 0, -20)
            empty:SetText("No specs match this filter.")
            table.insert(rows, empty)
            rowY = 40
        end

        content:SetHeight(math.max(rowY, 20))
    end

    tab.Sync = function() tab:Refresh() end
end

local function BuildTabData(tab)
    local x, y = S_PAD, -S_PAD

    SectionHead(tab, "Debug", x, y); y = y - S_HEAD

    local debugChk = MakeCheck(tab, "Debug mode (shows fake ratings when no data recorded)", x + 8, y, function(checked)
        db.debugMode = checked
        DirtyOverlay()
    end)
    y = y - S_ITEM - S_SEC

    SectionHead(tab, "Export", x, y); y = y - S_HEAD

    local expDesc = tab:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    expDesc:SetPoint("TOPLEFT", tab, "TOPLEFT", x + 8, y)
    expDesc:SetText("Prints all specs with recorded ratings to the chat window.")
    y = y - 20

    MakeBtn(tab, "Print all recorded specs to chat", 220, 26, x + 8, y, function()
        local any = false
        for _, s in ipairs(SPEC_LIST) do
            local info  = SPEC_INFO[s.specID]
            local entry = db.ratings[s.specID]
            if info and entry then
                local best = math.max(entry.maxRating2v2 or 0, entry.maxRating3v3 or 0)
                if best > 0 then
                    print(string.format("|cffffcc00PvPST:|r %s %s   2v2: %d   3v3: %d",
                        info.className, info.name,
                        entry.maxRating2v2 or 0, entry.maxRating3v3 or 0))
                    any = true
                end
            end
        end
        if not any then print("|cffffcc00PvPST:|r No rated specs recorded yet.") end
    end)
    y = y - 44 - S_SEC

    SectionHead(tab, "Danger zone", x, y); y = y - S_HEAD

    local warnDesc = tab:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    warnDesc:SetPoint("TOPLEFT", tab, "TOPLEFT", x + 8, y)
    warnDesc:SetText("These actions are permanent and cannot be undone.")
    y = y - 24

    MakeBtn(tab, "Clear all recorded rating data", 220, 26, x + 8, y, function()
        if tab._conf then
            db.ratings = {}; DirtyOverlay()
            print("|cffffcc00PvPSpecTracker:|r All rating data cleared.")
            tab._conf = nil
        else
            tab._conf = true
            print("|cffff4444PvPSpecTracker:|r Click again within 4 seconds to confirm.")
            C_Timer.After(4, function() tab._conf = nil end)
        end
    end)
    y = y - 38

    MakeBtn(tab, "Reset ALL settings to defaults", 220, 26, x + 8, y, function()
        if tab._confR then
            local saved  = db.ratings
            PvPSpecTrackerDB = {}
            db           = PvPSpecTrackerDB
            for k, v in pairs(DB_DEFAULTS) do db[k] = v end
            db.ratings   = saved
            if overlay then
                overlay:SetScale(db.overlayScale)
                overlay:SetAlpha(db.overlayAlpha)
                overlay:SetWidth(db.overlayWidth)
            end
            DirtyOverlay()
            if settingsFrame then
                for _, t in ipairs(settingsFrame.tabPanels or {}) do
                    if t.Sync then t.Sync() end
                end
            end
            print("|cffffcc00PvPSpecTracker:|r Settings reset to defaults.")
            tab._confR = nil
        else
            tab._confR = true
            print("|cffff4444PvPSpecTracker:|r Click again within 4 seconds to confirm.")
            C_Timer.After(4, function() tab._confR = nil end)
        end
    end)

    tab.Sync = function() debugChk:SetChecked(db.debugMode) end
end

-- ---------------------------------------------------------------------------
-- Settings frame (tabbed)
-- ---------------------------------------------------------------------------
local TABS = {
    { label = "Filters",   build = BuildTabFilters   },
    { label = "Display",   build = BuildTabDisplay   },
    { label = "Behaviour", build = BuildTabBehaviour },
    { label = "Specs",     build = BuildTabSpecs     },
    { label = "Data",      build = BuildTabData      },
}

local function CreateSettingsFrame()
    local W, H   = 520, 580
    local TAB_BTN_H = 28
    local TAB_Y     = -44  -- top of tab buttons
    local CONTENT_Y = TAB_Y - TAB_BTN_H - 8  -- top of content area

    local f = CreateFrame("Frame", "PvPSpecTrackerSettings", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=8, right=8, top=8, bottom=8 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    f:Hide()

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("|cffffcc00PvP Spec Tracker  -  Settings|r")

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Thin divider under title
    local titleDiv = f:CreateTexture(nil, "ARTWORK")
    titleDiv:SetHeight(1)
    titleDiv:SetPoint("TOPLEFT",  f, "TOPLEFT",  12, TAB_Y + 6)
    titleDiv:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, TAB_Y + 6)
    titleDiv:SetColorTexture(0.4, 0.4, 0.5, 0.4)

    -- Tab buttons
    local tabBtns, tabPanels = {}, {}
    local tabW = math.floor((W - 28) / #TABS)

    local function ShowTab(idx)
        for i, p in ipairs(tabPanels) do p:SetShown(i == idx) end
        for i, b in ipairs(tabBtns) do
            if i == idx then
                b:LockHighlight()
                local fs = b:GetFontString()
                if fs then fs:SetTextColor(1, 0.85, 0) end
            else
                b:UnlockHighlight()
                local fs = b:GetFontString()
                if fs then fs:SetTextColor(0.85, 0.85, 0.85) end
            end
        end
        if tabPanels[idx] and tabPanels[idx].Sync then tabPanels[idx]:Sync() end
    end

    for i, def in ipairs(TABS) do
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(tabW, TAB_BTN_H)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + (i - 1) * tabW, TAB_Y)
        btn:SetText(def.label)
        local idx = i
        btn:SetScript("OnClick", function() ShowTab(idx) end)
        table.insert(tabBtns, btn)

        -- Content panel for this tab
        local panel = CreateFrame("Frame", nil, f)
        panel:SetPoint("TOPLEFT",     f, "TOPLEFT",     14,  CONTENT_Y)
        panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14,  14)
        panel:Hide()
        def.build(panel)
        table.insert(tabPanels, panel)
    end

    f.tabPanels = tabPanels
    f:SetScript("OnShow", function() ShowTab(1) end)
    return f
end

function PvPSpecTrackerSettings_Toggle()
    if not settingsFrame then settingsFrame = CreateSettingsFrame() end
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PVP_RATED_STATS_UPDATE")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("PLAYER_PVP_RANK_CHANGED")

ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        if type(PvPSpecTrackerDB) ~= "table" then PvPSpecTrackerDB = {} end
        db = PvPSpecTrackerDB
        for k,v in pairs(DB_DEFAULTS) do if db[k]==nil then db[k]=v end end
        if type(db.ratings)     ~="table" then db.ratings     = {} end
        if type(db.hiddenSpecs) ~="table" then db.hiddenSpecs = {} end

    elseif event == "PLAYER_ENTERING_WORLD" then
        BuildSpecInfo()
        if not overlay then overlay = CreateOverlay() end
        RefreshOverlayTabs()
        UpdateZoneState()
        CheckAndRecord()

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        UpdateZoneState()

    elseif event == "PVP_RATED_STATS_UPDATE"
        or event == "PLAYER_PVP_RANK_CHANGED"
        or event == "PLAYER_SPECIALIZATION_CHANGED" then
        CheckAndRecord()
        DirtyOverlay()
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_PVPSPECTRACKER1 = "/pvpspec"
SLASH_PVPSPECTRACKER2 = "/pst"

SlashCmdList["PVPSPECTRACKER"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg=="" or msg=="settings" or msg=="config" then
        PvPSpecTrackerSettings_Toggle()
    elseif msg=="show" then if overlay then overlay:Show() end
    elseif msg=="hide" then if overlay then overlay:Hide() end
    elseif msg=="list" then
        for _, s in ipairs(SPEC_LIST) do
            local info  = SPEC_INFO[s.specID]
            local entry = db.ratings[s.specID]
            if info and entry then
                local best = math.max(entry.maxRating2v2 or 0, entry.maxRating3v3 or 0)
                if best > 0 then
                    print(string.format("|cffffcc00PvPST:|r %s %s  2v2:%d 3v3:%d",
                        info.className, info.name, entry.maxRating2v2 or 0, entry.maxRating3v3 or 0))
                end
            end
        end
    elseif msg=="reset" then
        db.overlayAnchor={point="CENTER",x=0,y=0}; db.overlayScale=1.0
        if overlay then overlay:ClearAllPoints(); overlay:SetPoint("CENTER",UIParent,"CENTER",0,0); overlay:SetScale(1.0) end
        print("|cffffcc00PvPSpecTracker:|r Position reset.")
    elseif msg=="clear" then
        db.ratings={}; DirtyOverlay()
        print("|cffffcc00PvPSpecTracker:|r All data cleared.")
    else
        print("|cffffcc00/pst|r  [settings|show|hide|list|reset|clear]")
    end
end
