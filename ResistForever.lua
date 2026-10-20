-- Resist Forever
-- Partial-resist chances on the character panel resistance tooltips.
-- Built for World of Warcraft: Forever 1.60.1 (Interface 16001).

local PROBABILITY_EPSILON = 0.0005
-- Direct-spell partial resists land in 10% damage steps (Forever beta / wowsims).
-- The 0% outcome is kept internally and never shown.
local PARTIAL_REDUCTIONS = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 }

-- Enum.Damageclass on build 1.60.1.70009. FirstResist is 2, LastResist is 6.
local SCHOOLS = {
    { name = "Fire", fallback = 2, atlas = "UI-Character-Info-Resistance-Fire" },
    { name = "Nature", fallback = 3, atlas = "UI-Character-Info-Resistance-Nature" },
    { name = "Frost", fallback = 4, atlas = "UI-Character-Info-Resistance-Frost" },
    { name = "Shadow", fallback = 5, atlas = "UI-Character-Info-Resistance-Shadow" },
    { name = "Arcane", fallback = 6, atlas = "UI-Character-Info-Resistance-Arcane" },
}

local function SchoolID(name, fallback)
    local damageClass = Enum and Enum.Damageclass
    local value = damageClass and damageClass[name]
    if type(value) == "number" then
        return value
    end
    return fallback
end

local SCHOOL_BY_ATLAS = {}
local SCHOOL_IDS = {}
for _, school in ipairs(SCHOOLS) do
    local id = SchoolID(school.name, school.fallback)
    SCHOOL_BY_ATLAS[school.atlas] = id
    SCHOOL_IDS[#SCHOOL_IDS + 1] = id
end

local cache = {
    level = {},
    resistance = {
        player = {},
        pet = {},
    },
}

local openRow
local appending = false
local hooksInstalled = false

--------------------------------------------------
-- Numbers that are safe to do math on
--------------------------------------------------

local function IsSecret(value)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then
            return true
        end
    end
    if type(canaccessvalue) == "function" then
        local ok, allowed = pcall(canaccessvalue, value)
        if ok and not allowed then
            return true
        end
    end
    return false
end

local function UsableNumber(value)
    if type(value) ~= "number" or IsSecret(value) then
        return false
    end
    local ok = pcall(function()
        if value ~= value then
            error("nan")
        end
        return value + 0
    end)
    return ok
end

local function UsableString(value)
    if type(value) ~= "string" or value == "" or IsSecret(value) then
        return false
    end
    return true
end

local function WholeLevel(value)
    if not UsableNumber(value) or value < 1 then
        return nil
    end
    return math.floor(value + 0.5)
end

local function FormatPercent(fraction)
    return string.format("%.1f%%", fraction * 100)
end

--------------------------------------------------
-- Math. No unit API calls.
--------------------------------------------------

-- Observed Forever direct-spell average resistance (wowsims/forever combat-log model):
--   average = R / (R + 9 * attackerLevel)
-- Attacker Spell Piercing is unknown here, so R is the defender's positive
-- readable resistance only. Do not treat the paper-doll ExpectedSpellResistance
-- UI helper (historically 0.75 * R / (5L) on earlier Forever builds) as the
-- server-side partial-resist model.
local function ComputeAverageResistance(resistance, attackerLevel)
    if not UsableNumber(resistance) or resistance <= 0 or not attackerLevel or attackerLevel < 1 then
        return nil
    end
    return resistance / (resistance + 9 * attackerLevel)
end

-- Direct magical damage only. Non-channeled periodic ticks appear to use about
-- one tenth of this average, and channels/binary spells differ; those are not
-- shown because the addon is not spell-specific.
-- Forever outcomes are 0/10/.../100% resisted. Edge averages use the closed
-- 0-20% / 80-100% forms; the middle uses P(x) = max(0, 0.5 - 2.5*|x - a|).
local function ComputePartialResistBuckets(resistance, attackerLevel)
    if not UsableNumber(resistance) or resistance <= 0 then
        return nil
    end
    local average = ComputeAverageResistance(resistance, attackerLevel)
    if not average or average <= 0 then
        return nil
    end
    if average > 1 then
        average = 1
    end

    local buckets = {}
    for step = 0, 10 do
        buckets[step * 10] = 0
    end

    if average <= 0.10 then
        buckets[0] = 1 - 7.5 * average
        buckets[10] = 5 * average
        buckets[20] = 2.5 * average
    elseif average >= 0.90 then
        local inv = 1 - average
        buckets[100] = 1 - 7.5 * inv
        buckets[90] = 5 * inv
        buckets[80] = 2.5 * inv
    else
        for step = 0, 10 do
            local outcome = step / 10
            local weight = 0.5 - 2.5 * math.abs(outcome - average)
            if weight < 0 then
                weight = 0
            end
            buckets[step * 10] = weight
        end
    end
    return buckets
end

-- Base spell miss from level difference only (before attacker spell hit).
-- Forever model: +3 or more levels above the caster -> 17%; otherwise
-- max(0, 4% + levelDiff * 1%). There is no unavoidable 1% miss floor; a
-- calculated 1% from a three-level caster advantage is still possible, and
-- attacker spell hit (unknown here) can reduce any of these values to 0.
-- No separate player-target (old Classic PvP 13%/+7%) table is applied; current
-- Forever evidence does not confirm that split for this addon.
local function ComputeSpellMiss(defenderLevel, attackerLevel)
    if not defenderLevel or not attackerLevel or defenderLevel < 1 or attackerLevel < 1 then
        return nil
    end
    local levelDiff = defenderLevel - attackerLevel
    if levelDiff >= 3 then
        return 0.17
    end
    local miss = 0.04 + levelDiff * 0.01
    if miss < 0 then
        return 0
    end
    return miss
end

local function BuildResistanceContext(resistance, defenderLevel, attackerLevel)
    local context = {
        spellMiss = ComputeSpellMiss(defenderLevel, attackerLevel),
    }
    if UsableNumber(resistance) and resistance > 0 then
        context.buckets = ComputePartialResistBuckets(resistance, attackerLevel)
    end
    return context
end

--------------------------------------------------
-- Data from the client
--------------------------------------------------

-- UnitResistance returns base, real, effective, bonus.
-- PaperDollFrame_SetResistance displays the third return (effectiveResistance).
-- The resistance rows do not call that function. They pass the second return
-- (realResistance) into the row text and into ExpectedSpellResistance.
-- A readable row value is the number this tooltip already described, so it wins.
-- A direct read prefers effectiveResistance, then realResistance.
local function GetUnitResistance(unit, schoolID)
    if not UnitResistance or not unit or not schoolID then
        return nil
    end
    local ok, _, realResistance, effectiveResistance = pcall(UnitResistance, unit, schoolID)
    if not ok then
        return nil
    end
    if UsableNumber(effectiveResistance) then
        return effectiveResistance
    end
    if UsableNumber(realResistance) then
        return realResistance
    end
    return nil
end

local function GetUnitLevel(unit)
    if not UnitLevel or not unit then
        return nil
    end
    local ok, level = pcall(UnitLevel, unit)
    if not ok then
        return nil
    end
    return WholeLevel(level)
end

local function ResolveUnitLevel(unit)
    local live = GetUnitLevel(unit)
    if live then
        cache.level[unit] = live
        return live, false
    end
    if cache.level[unit] then
        return cache.level[unit], true
    end
    return nil, false
end

local function ResolveResistance(unit, schoolID, frame)
    local unitCache = cache.resistance[unit]
    if not unitCache then
        unitCache = {}
        cache.resistance[unit] = unitCache
    end
    if frame and UsableNumber(frame.numericValue) then
        unitCache[schoolID] = frame.numericValue
        return frame.numericValue, false
    end
    local live = GetUnitResistance(unit, schoolID)
    if live ~= nil then
        unitCache[schoolID] = live
        return live, false
    end
    local saved = unitCache[schoolID]
    if saved ~= nil then
        return saved, true
    end
    return nil, false
end

-- Target level is the assumed attacker level. The target's resistance is not used.
-- A non-positive UnitLevel (classic skull targets often return -1) is not a level.
-- Forever's docs do not define that sentinel, so the target section is omitted
-- rather than assuming defender level + 3.
local function GetTargetContext()
    if not UnitExists then
        return nil
    end
    local existsOK, exists = pcall(UnitExists, "target")
    if not existsOK or not exists then
        return nil
    end
    if UnitIsUnit then
        local sameOK, sameUnit = pcall(UnitIsUnit, "target", "player")
        if sameOK and sameUnit then
            return nil
        end
    end
    if not UnitLevel then
        return nil
    end
    local levelOK, levelValue = pcall(UnitLevel, "target")
    if not levelOK then
        return nil
    end
    local level = WholeLevel(levelValue)
    if not level then
        return nil
    end

    local name
    if UnitName then
        local nameOK, nameValue = pcall(UnitName, "target")
        if nameOK and UsableString(nameValue) then
            name = nameValue
        end
    end
    return { name = name, level = level }
end

local function RefreshResistanceCache()
    for _, unit in ipairs({ "player", "pet" }) do
        local level = GetUnitLevel(unit)
        if level then
            cache.level[unit] = level
        end
        local unitCache = cache.resistance[unit]
        if not unitCache then
            unitCache = {}
            cache.resistance[unit] = unitCache
        end
        for _, schoolID in ipairs(SCHOOL_IDS) do
            local resistance = GetUnitResistance(unit, schoolID)
            if resistance ~= nil then
                unitCache[schoolID] = resistance
            end
        end
    end
end

--------------------------------------------------
-- Tooltip
--------------------------------------------------

local function ContextHasRows(context)
    if not context then
        return false
    end
    if context.buckets then
        for _, reduction in ipairs(PARTIAL_REDUCTIONS) do
            local chance = context.buckets[reduction]
            if chance and chance >= PROBABILITY_EPSILON and FormatPercent(chance) ~= "0.0%" then
                return true
            end
        end
    end
    return context.spellMiss and context.spellMiss >= PROBABILITY_EPSILON and FormatPercent(context.spellMiss) ~= "0.0%"
end

local function AddRow(label, valueText)
    GameTooltip:AddDoubleLine(
        label,
        valueText,
        NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b,
        HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b
    )
end

local function AddContext(label, context)
    GameTooltip:AddLine(label, HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
    if context.buckets then
        for _, reduction in ipairs(PARTIAL_REDUCTIONS) do
            local chance = context.buckets[reduction]
            if chance and chance >= PROBABILITY_EPSILON then
                local text = FormatPercent(chance)
                if text ~= "0.0%" then
                    AddRow(reduction .. "% damage resisted", text)
                end
            end
        end
    end
    if context.spellMiss and context.spellMiss >= PROBABILITY_EPSILON then
        local text = FormatPercent(context.spellMiss)
        if text ~= "0.0%" then
            AddRow("Base spell miss", text)
        end
    end
end

local function SchoolFromFrame(frame)
    if not frame then
        return nil
    end
    if frame.resistForeverSchool then
        return frame.resistForeverSchool
    end
    local icon = frame.Icon
    if not icon or not icon.GetAtlas then
        return nil
    end
    local ok, atlas = pcall(icon.GetAtlas, icon)
    if not ok or not atlas then
        return nil
    end
    local schoolID = SCHOOL_BY_ATLAS[atlas]
    if schoolID then
        frame.resistForeverSchool = schoolID
    end
    return schoolID
end

local function IsUnderFrame(frame, ancestor)
    if not frame or not ancestor then
        return false
    end
    if frame.IsDescendantOf then
        return frame:IsDescendantOf(ancestor)
    end
    local parent = frame:GetParent()
    while parent do
        if parent == ancestor then
            return true
        end
        parent = parent:GetParent()
    end
    return false
end

-- Player resists live on CharacterStatsPaneScrollBox.
-- Pet resists live on CharacterStatsPanePetScrollBox (same icon rows).
-- Prefer frame.unit when the paper-doll row already stamped it.
local function ResolveTooltipUnit(frame)
    if frame and UsableString(frame.unit) and (frame.unit == "player" or frame.unit == "pet") then
        return frame.unit
    end
    if IsUnderFrame(frame, CharacterStatsPanePetScrollBox) then
        return "pet"
    end
    if IsUnderFrame(frame, CharacterStatsPaneScrollBox) then
        return "player"
    end
    return nil
end

local function IsResistanceRow(frame)
    return ResolveTooltipUnit(frame) ~= nil and SchoolFromFrame(frame) ~= nil
end

-- Keep Blizzard's native resistance tooltip intact. Earlier Forever builds
-- exposed an ExpectedSpellResistance / RESISTANCE_TOOLTIP_SUBTEXT average from
-- the paper-doll UI; that line is not duplicated here, and it is not treated as
-- the current server-side partial-resist model. Negative resistance has no
-- verified partial-resist line; only base spell miss is added in that case.
local function AppendResistanceTooltip(frame, schoolID, unit)
    if not schoolID or not unit or not GameTooltip:IsOwned(frame) then
        return
    end

    local defenderLevel, levelIsStale = ResolveUnitLevel(unit)
    if not defenderLevel then
        return
    end
    local resistance, resistanceIsStale = ResolveResistance(unit, schoolID, frame)
    if resistance == nil then
        return
    end

    local ownContext = BuildResistanceContext(resistance, defenderLevel, defenderLevel)
    local targetContext
    local targetLabel
    local target = GetTargetContext()
    if target and target.level ~= defenderLevel then
        targetContext = BuildResistanceContext(resistance, defenderLevel, target.level)
        if target.name then
            targetLabel = target.name .. " · Level " .. target.level
        else
            targetLabel = "Current target · Level " .. target.level
        end
    end

    local showOwn = ContextHasRows(ownContext)
    local showTarget = targetContext and ContextHasRows(targetContext)
    if not showOwn and not showTarget then
        return
    end

    openRow = frame
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Resist Forever", NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
    if showOwn then
        AddContext("Against level " .. defenderLevel, ownContext)
    end
    if showTarget then
        if showOwn then
            GameTooltip:AddLine(" ")
        end
        AddContext(targetLabel, targetContext)
    end
    if resistanceIsStale or levelIsStale then
        local r, g, b = 0.5, 0.5, 0.5
        if GRAY_FONT_COLOR then
            r, g, b = GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b
        end
        GameTooltip:AddLine("Using last available resistance value", r, g, b)
    end
    GameTooltip:Show()
end

local function AfterPaperDollStatTooltip(frame)
    if appending or not IsResistanceRow(frame) then
        return
    end
    appending = true
    AppendResistanceTooltip(frame, SchoolFromFrame(frame), ResolveTooltipUnit(frame))
    appending = false
end

local function RefreshOpenTooltip()
    local row = openRow
    if not row or not PaperDollStatTooltip or not GameTooltip or not GameTooltip:IsShown() then
        return
    end
    if not GameTooltip:IsOwned(row) then
        return
    end
    PaperDollStatTooltip(row)
end

--------------------------------------------------
-- Hooks and events
--------------------------------------------------

local function TagResistanceRow(frame, elementData)
    local atlas = elementData and elementData.atlas
    frame.resistForeverSchool = atlas and SCHOOL_BY_ATLAS[atlas] or nil
    -- The sheet rebuilds these rows when stats change. If this row is the
    -- one under the cursor, draw the tooltip again from the new value.
    if appending or frame ~= openRow or not PaperDollStatTooltip then
        return
    end
    if not GameTooltip:IsShown() or not GameTooltip:IsOwned(frame) then
        return
    end
    PaperDollStatTooltip(frame)
end

local function InstallHooks()
    if hooksInstalled then
        return
    end
    if type(hooksecurefunc) ~= "function" or type(PaperDollStatTooltip) ~= "function" then
        return
    end
    if not CharacterStatFrameScrollBoxIconElementMixin then
        return
    end

    hooksecurefunc(CharacterStatFrameScrollBoxIconElementMixin, "Init", TagResistanceRow)
    hooksecurefunc("PaperDollStatTooltip", AfterPaperDollStatTooltip)
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnHide", function()
            openRow = nil
        end)
    end
    hooksInstalled = true
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_PET")
if eventFrame.RegisterUnitEvent then
    eventFrame:RegisterUnitEvent("UNIT_AURA", "player", "pet")
    eventFrame:RegisterUnitEvent("UNIT_RESISTANCES", "player", "pet")
    eventFrame:RegisterUnitEvent("UNIT_LEVEL", "player", "pet")
else
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:RegisterEvent("UNIT_RESISTANCES")
    eventFrame:RegisterEvent("UNIT_LEVEL")
end

eventFrame:SetScript("OnEvent", function(_, event, unit)
    if (event == "UNIT_AURA" or event == "UNIT_RESISTANCES" or event == "UNIT_LEVEL")
        and unit and unit ~= "player" and unit ~= "pet" then
        return
    end
    InstallHooks()
    RefreshResistanceCache()
    if event ~= "ADDON_LOADED" then
        RefreshOpenTooltip()
    end
end)

InstallHooks()
