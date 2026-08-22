--[[
    jobhelper -- Copyright (c) 2026 watahero. MIT License; see LICENSE.
    Derived from runehelper/puphelper/ninhelper, Copyright (c) 2021 Dan
    (GetAwayCoxn). Independent fork; not supported by the original author.
]]--

--[[
    jobhelper/modules/run.lua -- Rune Fencer

    CatsEyeXI scaled RUN down to level 75 with matching AF/relic, so unlike
    NIN and PUP nothing this module drives sits above the cap: the 2nd and
    3rd Rune Enchantment charges (35/65) and Vivacious Pulse (55) all fit.

    Slot and Pulse availability are still resolved from the character rather
    than assumed. runehelper hardcoded "not main RUN means no 3rd rune and no
    Pulse", which happens to be right for /RUN 37 on a 75 cap but would be
    wrong the moment a server changes the thresholds or uncaps subjobs.
]]--

require('common');
local imgui = require('imgui');
local util = require('util');

local M = T{ id = 'run', label = 'RUN' };

local RUNES = T{
    { name = 'Ignis',    hint = 'Fire/Ice'   },
    { name = 'Gelus',    hint = 'Ice/Wind'   },
    { name = 'Flabra',   hint = 'Wind/Earth' },
    { name = 'Tellus',   hint = 'Earth/Ltng' },
    { name = 'Sulpor',   hint = 'Ltng/Water' },
    { name = 'Unda',     hint = 'Water/Fire' },
    { name = 'Lux',      hint = 'Light/Dark' },
    { name = 'Tenebrae', hint = 'Dark/Light' },
};

-- Element aliases for '/jh set fire ice wind', in RUNES order.
local ELEMENTS = T{ 'fire', 'ice', 'wind', 'earth', 'thunder', 'water', 'light', 'dark' };

local combo_items;
local function ComboItems()
    if (combo_items == nil) then
        combo_items = 'None\0';
        for _, r in ipairs(RUNES) do
            combo_items = combo_items .. r.name .. ' (' .. r.hint .. ')\0';
        end
    end
    return combo_items;
end

M.defaults = T{
    slots = T{ -1, -1, -1 },   -- indices into RUNES, -1 for empty
    pulse = T{ 70 },           -- HP/MP% to fire Vivacious Pulse at, 0 disables

    -- RUN level at which each rune slot unlocks. Retail Rune Enchantment
    -- thresholds, which CatsEyeXI kept when it scaled the job to 75. A
    -- server that re-tunes them only needs this edited.
    slot_levels = T{ 1, 35, 65 },
};

----------------------------------------------------------------------------

--[[ The level this character counts as for RUN purposes, or 0 if not RUN. ]]--
local function RuneLevel(ctx)
    if (ctx.mainJob == util.job.RUN) then
        return ctx.mainLevel;
    elseif (ctx.subJob == util.job.RUN) then
        return ctx.subLevel;
    end
    return 0;
end

--[[
    How many rune slots this character can actually hold.

    Thresholds are settings so a server that re-tunes Rune Enchantment needs
    a config edit rather than a code change.
]]--
local function MaxSlots(ctx, cfg)
    local level, unlocked = RuneLevel(ctx), 0;
    for _, required in ipairs(cfg.slot_levels) do
        if (level >= required) then
            unlocked = unlocked + 1;
        end
    end
    return unlocked;
end

local function HasPulse(ctx)
    local ability = util.GetAbility('Vivacious Pulse');
    return ability ~= nil and ctx.player:HasAbility(ability.Id);
end

function M.Gate(ctx)
    return ctx.mainJob == util.job.RUN or ctx.subJob == util.job.RUN;
end

----------------------------------------------------------------------------

function M.Tick(ctx, cfg)
    -- Runes are job abilities; Amnesia is already handled by the host guard.
    local maxSlots = MaxSlots(ctx, cfg);
    local wanted = T{};
    for i = 1, maxSlots do
        local pick = cfg.slots[i];
        if (pick ~= nil and pick > -1) then
            wanted[#wanted + 1] = RUNES[pick + 1].name;
        end
    end

    local total = 0;
    for _, r in ipairs(RUNES) do
        total = total + (ctx.buffs[r.name] or 0);
    end

    -- Every rune shares one recast timer, so asking about the first one we
    -- want is the same question as asking about Rune Enchantment -- and a
    -- rune name is certain to resolve as an ability, which is why
    -- runehelper's own comment noted the timer always reported as Ignis.
    if (#wanted > 0 and ctx:Ready(wanted[1]) and ctx:Throttle('run.rune', 2)) then
        -- One cast per tick: all runes share a recast, so a second queued
        -- rune only fails with "Unable to use job ability". The throttle
        -- brings us back for the next one once the timer clears.
        local needed = util.RotationNeeds(wanted, ctx.buffs);
        if (#needed > 0) then
            util.Cast('/ja "' .. needed[1] .. '" <me>');
        end
    end

    -- Vivacious Pulse restores HP, or MP when every rune up is Tenebrae.
    if (cfg.pulse[1] > 0 and total >= maxSlots and maxSlots > 0
        and HasPulse(ctx) and ctx:Ready('Vivacious Pulse')
        and ctx:Throttle('run.pulse', 2)) then

        local dark = (ctx.buffs['Tenebrae'] or 0);
        local pct = (dark >= maxSlots) and ctx.mpp or ctx.hpp;
        if (pct < cfg.pulse[1]) then
            util.Cast('/ja "Vivacious Pulse" <me>');
        end
    end
end

----------------------------------------------------------------------------

--[[ One bar row: slot combos, lock indicator, pulse slider. ]]--
function M.Draw(ctx, cfg)
    local maxSlots = MaxSlots(ctx, cfg);

    if (maxSlots == 0) then
        imgui.TextDisabled('level too low for runes');
        return;
    end

    imgui.PushItemWidth(64);
    for i = 1, maxSlots do
        if (i > 1) then imgui.SameLine(); end

        local sel = { (cfg.slots[i] or -1) + 1 };
        if (imgui.Combo('##jhrune' .. i, sel, ComboItems())) then
            cfg.slots[i] = sel[1] - 1;
            M.dirty = true;
        end
    end
    imgui.PopItemWidth();

    -- Locked slots are stated, not silently missing.
    if (maxSlots < 3) then
        imgui.SameLine();
        imgui.TextDisabled(maxSlots .. '/3');
        imgui.ShowHelp(string.format('RUN level %d. Slot %d unlocks at %d.',
            RuneLevel(ctx), maxSlots + 1, cfg.slot_levels[maxSlots + 1] or 0));
    end

    if (HasPulse(ctx)) then
        imgui.SameLine();
        imgui.PushItemWidth(74);
        if (imgui.SliderInt('##jhpulse', cfg.pulse, 0, 100, 'P:%d%%')) then
            M.dirty = true;
        end
        imgui.PopItemWidth();
        imgui.ShowHelp('Vivacious Pulse below this HP% (MP% when every rune is Tenebrae). 0 disables.');
    end
end

----------------------------------------------------------------------------

--[[ '/jh set fire ice wind' -- also accepts rune names. ]]--
local set_choices;

function M.Set(cfg, args)
    if (set_choices == nil) then
        set_choices = T{};
        for idx, r in ipairs(RUNES) do
            set_choices[idx] = { ELEMENTS[idx], r.name:lower() };
        end
    end
    return util.ParseSlots(cfg.slots, args, set_choices);
end

return M;
