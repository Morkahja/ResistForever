-- Resist Forever
-- Partial-resist chances on the character panel resistance tooltips.
-- Built for World of Warcraft: Forever 1.60.1 (Interface 16001).

local PROBABILITY_EPSILON = 0.0005
local PARTIAL_REDUCTIONS = { 25, 50, 75, 100 }

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

-- PaperDollFrameStats.lua CharacterHitFrame_OnEnter declares
-- spellMissChances = { 4, 5, 6, 17 } (PvE, levels 0-3 above the caster).
-- Blizzard's classic tables also split player targets (PvP) from mobs (PvE):
--   PvE +3 = 17%, then +11% per further level
--   PvP +3 = 13%, then +7% per further level
-- Index is how many levels the defender is above the caster.
local SPELL_MISS_PVE = {
    [0] = 0.04,
    [1] = 0.05,
    [2] = 0.06,
    [3] = 0.17,
}
local SPELL_MISS_PVP = {
    [0] = 0.04,
    [1] = 0.05,
    [2] = 0.06,
    [3] = 0.13,
}

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

-- Forever's own helper, PaperDollFrameStats.lua ExpectedSpellResistance:
--   0.75 * resistance / (casterLevel * 5)
-- That helper has no level-20 floor and no 75% cap.
local function ComputeAverageResistance(resistance, attackerLevel)
    if not UsableNumber(resistance) or not attackerLevel or attackerLevel < 1 then
        return nil
    end
    return 0.75 * resistance / (attackerLevel * 5)
end

-- Partial-resist distribution is not in the Forever UI.
-- This is the classic bell curve P(x) = 0.5 - 2.5*|x - average|,
-- sampled every 10% and folded into the 25% outcomes. Treat it as an estimate.
local function ComputePartialResistBuckets(resistance, attackerLevel)
    if not UsableNumber(resistance) or resistance <= 0 then
        return nil
    end
    local average = ComputeAverageResistance(resistance, attackerLevel)
    if not average or average <= 0 then
        return nil
    end
    -- The curve is only defined through a full resist. The client helper
    -- itself does not clamp.
    if average > 1 then
        average = 1
    end

    local weights = {}
    local sum = 0
    for step = 0, 10 do
        local outcome = step / 10
        local weight = 0.5 - 2.5 * math.abs(outcome - average)
        if weight < 0 then
            weight = 0
        end
        weights[step] = weight
        sum = sum + weight
    end

    local buckets = { [0] = 0, [25] = 0, [50] = 0, [75] = 0, [100] = 0 }
    if sum <= 0 then
        buckets[0] = 1
        return buckets
    end

    for step = 0, 10 do
        local outcome = step / 10
        local chance = weights[step] / sum
        if outcome < 0.125 then
            buckets[0] = buckets[0] + chance
        elseif outcome < 0.375 then
            buckets[25] = buckets[25] + chance
        elseif outcome < 0.625 then
            buckets[50] = buckets[50] + chance
        elseif outcome < 0.875 then
            buckets[75] = buckets[75] + chance
        else
            buckets[100] = buckets[100] + chance
        end
    end
    return buckets
end

-- Miss chance for a caster of attackerLevel against a defender of defenderLevel.
-- Player defenders use the PvP column; pets and other non-players use PvE.
-- Below the caster, classic tables fall 1% per level to 0% at -4 and lower.
-- Above +3, continuation is the classic +11% (PvE) / +7% (PvP) per level.
local function ComputeSpellMiss(defenderLevel, attackerLevel, defenderIsPlayer)
    if not defenderLevel or not attackerLevel or defenderLevel < 1 or attackerLevel < 1 then
        return nil
    end
    local levelsAboveCaster = defenderLevel - attackerLevel
    local table = defenderIsPlayer and SPELL_MISS_PVP or SPELL_MISS_PVE
    local verified = table[levelsAboveCaster]
    if verified then
        return verified
    end

    local miss
    if levelsAboveCaster > 3 then
        local base = defenderIsPlayer and 0.13 or 0.17
        local step = defenderIsPlayer and 0.07 or 0.11
        miss = base + (levelsAboveCaster - 3) * step
    else
        miss = 0.04 + levelsAboveCaster * 0.01
    end
    if miss < 0 then
        miss = 0
    elseif miss > 1 then
        miss = 1
    end
    return miss
end

local function BuildResistanceContext(resistance, defenderLevel, attackerLevel, defenderIsPlayer)
    local context = {
        spellMiss = ComputeSpellMiss(defenderLevel, attackerLevel, defenderIsPlayer),
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
            AddRow("Spell miss", text)
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

-- Native tooltip already shows floor(0.75 * resistance / (playerLevel * 5) * 100)
-- via RESISTANCE_TOOLTIP_SUBTEXT. That is the same-level average, so it is not
-- repeated here. Negative resistance has no verified partial-resist or
-- vulnerability line in Forever; only spell miss is added.
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

    local defenderIsPlayer = unit == "player"
    local ownContext = BuildResistanceContext(resistance, defenderLevel, defenderLevel, defenderIsPlayer)
    local targetContext
    local targetLabel
    local target = GetTargetContext()
    if target and target.level ~= defenderLevel then
        targetContext = BuildResistanceContext(resistance, defenderLevel, target.level, defenderIsPlayer)
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
