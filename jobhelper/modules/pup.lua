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

    Measured from play logs: every cast of an element ADDS roughly 8-10 to
    that element's chance, while it decays at only about 1 per minute. So
    "wait a bit and try again" -- what this guard did at first -- is a
    death spiral: probe-casts build burden faster than it decays, and the
    log showed Wind climbing 5 -> 14 -> 23 -> ... -> 64 with an overload on
    nearly every recast, re-triggered one second after each Overload wore
    off.

    A cast is never a free probe. The element is held until its ESTIMATED
    chance (last reading minus decay for the time elapsed) is back under
    the threshold, and the bar shows the wait.

    Decay measured from 39 high-burden reading pairs across two nights of
    logs: tightly clustered at ~0.265 per second (about 1 point per 4
    seconds), confirmed by two near-pure-decay runs (66->16 over 209s,
    58->0 over 254s). 0.25/s is used -- a shade under the measured median,
    erring toward holding a few seconds long. A 23 reading at the default
    threshold of 5 holds that element for roughly 75 seconds. On servers
    without the chat line the table stays empty and the guard never
    engages.
]]--

local DECAY_PER_SEC = 0.25;

local burden = {};      -- ability name -> { chance, at }

ashita.events.register('text_in', 'jobhelper_pup_burden', function (e)
    -- Incoming chat carries colour/autotranslate control bytes; strip them
    -- so the pattern sees plain text.
    local clean = e.message:gsub('[].', ''):gsub('%c', '');
    local element, chance = string.match(clean, '(%a+) Maneuver overload chance is (%d+)%%');
    if (element ~= nil and MANEUVERS:contains(element)) then
        burden[element .. ' Maneuver'] = { chance = tonumber(chance), at = os.time() };
    end
end);

local function EstimatedChance(name, now)
    local b = burden[name];
    if (b == nil) then
        return 0;
    end
    return math.max(0, b.chance - (now - b.at) * DECAY_PER_SEC);
end

--[[
    What the cast itself will add. The printed number -- the one the server
    ROLLS -- is the post-cast chance, and the increment scales with how
    many stacks of that same element will then be up. Measured from the
    fast-gap reading pairs: first stack prints +0..1, a second +6..12, a
    third +14..16. Upper bounds are used so the guard errs safe.
]]--
local STACK_INCREMENT = T{ 2, 12, 16 };

local function IncrementFor(stacks_after)
    return STACK_INCREMENT[math.min(stacks_after, 3)];
end

--[[
    The guard question is "what would this cast PRINT", not "what has the
    burden decayed to": predicted roll = estimate + increment. With the
    default threshold of 5 this means single stacks flow freely (they
    print 0-1) and duplicate stacks are refused outright, because a second
    stack can never roll under ~12 no matter how long you wait -- exactly
    the casts that produced every overload in the logs.
]]--
local function PredictedRoll(name, now, stacks_after)
    return EstimatedChance(name, now) + IncrementFor(stacks_after);
end

local function GuardHeld(name, cfg, now, stacks_after)
    local threshold = cfg.overload_guard[1];
    return threshold > 0 and PredictedRoll(name, now, stacks_after) > threshold;
end

--[[
    The wait until a held cast becomes acceptable -- or what OL it needs,
    when no amount of waiting gets its predicted roll under the threshold.
]]--
local function GuardWait(name, cfg, now, stacks_after)
    local inc = IncrementFor(stacks_after);
    if (inc > cfg.overload_guard[1]) then
        return string.format('needs OL>%d', inc);
    end

    local seconds = math.ceil((EstimatedChance(name, now) + inc - cfg.overload_guard[1]) / DECAY_PER_SEC);
    if (seconds >= 90) then
        return string.format('~%dm', math.ceil(seconds / 60));
    end
    return string.format('~%ds', math.max(seconds, 1));
end

--[[ '/jh burden': ground truth for whether the chat parser is working. ]]--
function M.Debug(ctx)
    local any = false;
    for name, b in pairs(burden) do
        any = true;
        util.Message(string.format('%s: read %d, %ds ago, estimate %d',
            name, b.chance, os.time() - b.at, EstimatedChance(name, os.time())));
    end
    if (not any) then
        util.Message('burden table is EMPTY -- no overload-chance chat line has been parsed. '
            .. 'If maneuvers have printed chances this session, the parser is not matching and the guard is inert.');
    end
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
            local stacks_after = (ctx.buffs[name] or 0) + 1;
            if (not GuardHeld(name, cfg, ctx.now, stacks_after)) then
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
    util.Tip('Overload guard: largest overload roll to accept. A cast is skipped when its predicted printed chance (decayed reading + stack increment) exceeds this. Duplicate stacks print 12+, so they need OL above that. 0 disables.');

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

    -- Elements the overload guard is holding, with the estimated wait --
    -- a slot that quietly stops restacking must say why.
    local held, seen = T{}, {};
    for i = 1, 3 do
        local pick = cfg.slots[i];
        if (pick ~= nil and pick > -1 and not seen[pick]) then
            seen[pick] = true;
            local name = AbilityOf(pick);
            local stacks_after = (ctx.buffs ~= nil and (ctx.buffs[name] or 0) or 0) + 1;
            if (GuardHeld(name, cfg, ctx.now, stacks_after)) then
                held[#held + 1] = string.format('%s %s',
                    MANEUVERS[pick + 1], GuardWait(name, cfg, ctx.now, stacks_after));
            end
        end
    end
    if (#held > 0) then
        imgui.SameLine();
        imgui.TextColored({ 0.95, 0.75, 0.25, 1.0 }, '!' .. #held);
        util.Tip('Overload guard is holding: ' .. table.concat(held, ', ')
            .. '. Estimated wait until the chance is back under your threshold.');
    end
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
