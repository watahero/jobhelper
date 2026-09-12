--[[
    jobhelper -- Copyright (c) 2026 watahero. MIT License; see LICENSE.
    Derived from runehelper/puphelper/ninhelper, Copyright (c) 2021 Dan
    (GetAwayCoxn). Independent fork; not supported by the original author.
]]--

--[[
    jobhelper/modules/pup.lua -- Puppetmaster

    CatsEyeXI notes:
      - "/pup is not usable, whilst you can set PUP as a subjob summoning the
        Automaton will not function" -- so this stays main-job only, which is
        what puphelper already did.
      - Cooldown is a level 77 job ability on retail and so sits above the 75
        cap. Rather than assume it is gone, the control is bound to
        HasAbility: if CatsEyeXI granted it at 75 the way it granted NIN's
        Futae, it simply appears.
]]--

require('common');
local imgui = require('imgui');
local util = require('util');

local M = T{ id = 'pup', label = 'PUP' };

local MANEUVERS = T{
    'Dark', 'Light', 'Earth', 'Wind', 'Fire', 'Ice', 'Thunder', 'Water',
};

local AUTOMATON_OIL_2 = 18733;

local combo_items;
local function ComboItems()
    if (combo_items == nil) then
        combo_items = 'None\0';
        for _, name in ipairs(MANEUVERS) do
            combo_items = combo_items .. name .. '\0';
        end
    end
    return combo_items;
end

local function AbilityOf(idx)
    return MANEUVERS[idx + 1] .. ' Maneuver';
end

M.defaults = T{
    slots = T{ -1, -1, -1 },     -- indices into MANEUVERS, -1 for empty
    repair_at = T{ 0 },          -- pet HP%% to Repair at, 0 disables
    auto_deploy = T{ true },
    auto_cooldown = T{ false },
    auto_light = T{ 0, 90 },     -- force slot 1 to Light below [1], restore at [2]
    overload_guard = T{ 5 },     -- hold an element whose reported overload
                                 -- chance is at or above this %%; 0 disables

    -- Slot 1's user-chosen maneuver, remembered so auto-light can put it
    -- back after the pet recovers.
    light_restore = T{ -1 },
};

----------------------------------------------------------------------------
-- Overload guard
----------------------------------------------------------------------------

--[[
    CatsEyeXI announces the overload chance after every maneuver:

        Godwen's Light Maneuver overload chance is 12%.

    Stacking the same element keeps its burden high, and recasting the
    moment a stack drops holds it there -- an 11%% roll produced a real
    overload in play. Remember the last reported chance per element and,
    when it is at or above the configured threshold, hold that element for
    a while so its burden can decay; other elements are unaffected. The
    next cast refreshes the reading, so a still-hot element just keeps
    getting spaced out. On servers without this message the table stays
    empty and the guard never engages.
]]--

local GUARD_HOLD = 30;  -- seconds to space out an element reported hot

local burden = {};      -- ability name -> { chance, at }

ashita.events.register('text_in', 'jobhelper_pup_burden', function (e)
    local element, chance = string.match(e.message, '(%a+) Maneuver overload chance is (%d+)%%');
    if (element ~= nil and MANEUVERS:contains(element)) then
        burden[element .. ' Maneuver'] = { chance = tonumber(chance), at = os.time() };
    end
end);

local function GuardHeld(name, cfg, now)
    local threshold = cfg.overload_guard[1];
    if (threshold <= 0) then
        return false;
    end

    local b = burden[name];
    return b ~= nil and b.chance >= threshold and (now - b.at) < GUARD_HOLD;
end

----------------------------------------------------------------------------

local function HasCooldown(ctx)
    return util.HasAbilityByName(ctx.player, 'Cooldown');
end

--[[
    Oil count, refreshed at most every 2 seconds. Counting means walking 9
    containers x 81 slots, which is far too much to do per frame for a label
    that changes only when Repair fires or items move.
]]--
local oil = { count = 0, at = -10 };

local function OilCount(now)
    if (now - oil.at >= 2) then
        oil.count = util.CountItem(AUTOMATON_OIL_2);
        oil.at = now;
    end
    return oil.count;
end

function M.Gate(ctx)
    return ctx.mainJob == util.job.PUP and ctx.petIndex ~= nil;
end

----------------------------------------------------------------------------

function M.Tick(ctx, cfg)
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local petHpp = entity:GetHPPercent(ctx.petIndex);

    -- Deploy onto a target the player is already fighting, once the pet is
    -- idle and the mob is neither untouched nor nearly dead.
    if (cfg.auto_deploy[1] and ctx.targetIndex ~= nil and ctx.status == util.status.ENGAGED
        and entity:GetStatus(ctx.petIndex) == util.status.IDLE
        and ctx:Throttle('pup.deploy', 5)) then

        local targetHpp = entity:GetHPPercent(ctx.targetIndex);
        if (targetHpp > 10 and targetHpp < 100) then
            util.Cast('/ja "Deploy" <t>');
        end
    end

    local overloaded = (ctx.buffs['Overload'] or 0) > 0;

    if (overloaded and cfg.auto_cooldown[1] and HasCooldown(ctx)
        and ctx:Ready('Cooldown') and ctx:Throttle('pup.cooldown', 2)) then
        util.Cast('/ja "Cooldown" <me>');
    end

    -- Auto-light swaps slot 1 to Light while the pet is hurt, then restores
    -- whatever the user had picked once it recovers.
    if (cfg.auto_light[1] > 0) then
        if (petHpp < cfg.auto_light[1]) then
            cfg.slots[1] = 1;  -- Light
        elseif (petHpp >= cfg.auto_light[2]) then
            cfg.slots[1] = cfg.light_restore[1];
        end
    end

    -- Maneuvers are locked out entirely while overloaded.
    if (not overloaded and ctx:Ready('Fire Maneuver') and ctx:Throttle('pup.maneuver', 4)) then
        local wanted = T{};
        for i = 1, 3 do
            local pick = cfg.slots[i];
            if (pick ~= nil and pick > -1) then
                wanted[#wanted + 1] = AbilityOf(pick);
            end
        end

        -- One cast per tick: maneuvers share a recast, so extra queued ones
        -- only fail with "Unable to use job ability". The 4s throttle comes
        -- back for the next stack once the timer clears. Elements the
        -- overload guard is holding are skipped, not just delayed, so a
        -- safe element can still go this tick.
        for _, name in ipairs(util.RotationNeeds(wanted, ctx.buffs)) do
            if (not GuardHeld(name, cfg, ctx.now)) then
                util.Cast('/ja "' .. name .. '" <me>');
                break;
            end
        end
    end

    -- Repair needs oil in the bag and the pet inside melee-ish range.
    if (cfg.repair_at[1] > 0 and petHpp < cfg.repair_at[1]
        and ctx:Ready('Repair') and ctx:Throttle('pup.repair', 2)
        and OilCount(ctx.now) > 0) then

        local distance = tonumber(entity:GetDistance(ctx.petIndex)) or 99;
        if (distance > 3 and distance < 16.5) then
            util.Cast('/ja "Repair" <me>');
        end
    end
end

----------------------------------------------------------------------------

--[[
    Two bar rows: maneuver combos with the Deploy/Cooldown toggles, then the
    repair and auto-light thresholds with pet status at the end.
]]--
function M.Draw(ctx, cfg)
    local entity = AshitaCore:GetMemoryManager():GetEntity();

    imgui.PushItemWidth(64);
    for i = 1, 3 do
        if (i > 1) then imgui.SameLine(); end

        local sel = { (cfg.slots[i] or -1) + 1 };
        if (imgui.Combo('##jhman' .. i, sel, ComboItems())) then
            cfg.slots[i] = sel[1] - 1;
            if (i == 1) then
                cfg.light_restore[1] = cfg.slots[1];
            end
            M.dirty = true;
        end
    end
    imgui.PopItemWidth();

    imgui.SameLine();
    if (imgui.Checkbox('Dep', cfg.auto_deploy)) then
        M.dirty = true;
    end
    util.Tip('Send the pet at your target once you engage.');

    -- Only offered when the character actually has the ability. On a 75 cap
    -- this normally means the control is absent rather than present-and-dead.
    if (HasCooldown(ctx)) then
        imgui.SameLine();
        if (imgui.Checkbox('Cool', cfg.auto_cooldown)) then
            M.dirty = true;
        end
    end

    imgui.PushItemWidth(74);
    if (imgui.SliderInt('##jhrepair', cfg.repair_at, 0, 100, 'R:%d%%')) then
        M.dirty = true;
    end
    imgui.PopItemWidth();
    util.Tip('Repair below this pet HP. 0 disables. Needs Automaton Oil +2.');

    imgui.SameLine();
    imgui.PushItemWidth(74);
    if (imgui.SliderInt('##jhguard', cfg.overload_guard, 0, 50, 'OL:%d%%')) then
        M.dirty = true;
    end
    imgui.PopItemWidth();
    util.Tip('Overload guard: an element whose reported overload chance reaches this value is spaced out (30s) so its burden decays. 0 disables.');

    imgui.SameLine();
    local low, high = { cfg.auto_light[1] }, { cfg.auto_light[2] };
    imgui.PushItemWidth(96);
    if (imgui.DragIntRange2('##jhlight', low, high, 1.0, 0, 100)) then
        cfg.auto_light[1] = low[1];
        cfg.auto_light[2] = math.max(low[1], high[1]);
        M.dirty = true;
    end
    imgui.PopItemWidth();
    util.Tip('Force Light maneuver below the first value, restore your pick at the second. First 0 disables.');

    imgui.SameLine();
    imgui.TextDisabled(string.format('%d|%d',
        entity:GetHPPercent(ctx.petIndex), OilCount(ctx.now)));
    util.Tip('Pet HP / Automaton Oil +2 on hand.');
end

----------------------------------------------------------------------------

--[[ '/jh set fire ice wind' ]]--
local set_choices;

function M.Set(cfg, args)
    if (set_choices == nil) then
        set_choices = T{};
        for idx, name in ipairs(MANEUVERS) do
            set_choices[idx] = { name:lower() };
        end
    end

    local applied = util.ParseSlots(cfg.slots, args, set_choices);
    if (applied) then
        cfg.light_restore[1] = cfg.slots[1];
    end
    return applied;
end

return M;
