--[[
    jobhelper -- Copyright (c) 2026 watahero. MIT License; see LICENSE.
    Derived from runehelper/puphelper/ninhelper, Copyright (c) 2021 Dan
    (GetAwayCoxn). Independent fork; not supported by the original author.
]]--

--[[
    jobhelper/modules/nin.lua -- Ninja

    This is the module CatsEyeXI changes most. Most of what ninhelper
    automated is above the server's level 75 cap on retail:

        Utsusemi: San  96      Migawari: Ichi  88
        Myoshu: Ichi   85      Kakka: Ichi     93
        Gekka: Ichi   ~90      Yain: Ichi     ~96
        Yonin / Innin  40  -- the two that do fit

    ninhelper rendered all of them and let its HasSpell guards silently
    untick whatever the character could not cast, so the panel advertised
    six features that did nothing. Here a control is only drawn if the
    client says the spell is known, which also means nothing is hardcoded
    about which server this is: if CatsEyeXI re-levels one of these the way
    it granted Futae at 75, its control appears on its own.

    Shadow tiering walks San -> Ni -> Ichi and simply finds San unknown on a
    75 cap, so it settles on Ni without being told.
]]--

require('common');
local imgui = require('imgui');
local util = require('util');

local M = T{ id = 'nin', label = 'NIN' };

-- Ninja tools, and the toolbag to open when the loose tools run out.
local TOOLS = T{
    shihei = { item = 1179, bag = 5314, bag_name = 'Toolbag (Shihe)' },
    shika  = { item = 2972, bag = 5868, bag_name = 'Toolbag (Shika)' },
};

-- Utsusemi, best tier first.
local SHADOW_TIERS = T{ 'Utsusemi: San', 'Utsusemi: Ni', 'Utsusemi: Ichi' };

-- Self-buff ninjutsu, in cast priority order.
local NINJUTSU = T{
    { key = 'migawari', label = 'Migawari', spell = 'Migawari: Ichi', buff = 'Migawari',         tool = 'shika' },
    { key = 'myoshu',   label = 'Myoshu',   spell = 'Myoshu: Ichi',   buff = 'Subtle Blow Plus', tool = 'shika' },
    { key = 'kakka',    label = 'Kakka',    spell = 'Kakka: Ichi',    buff = 'Store TP',         tool = 'shika' },
    { key = 'gekka',    label = 'Gekka',    spell = 'Gekka: Ichi',    buff = 'Enmity Boost',     tool = 'shika', excludes = 'yain' },
    { key = 'yain',     label = 'Yain',     spell = 'Yain: Ichi',     buff = 'Pax',              tool = 'shika', excludes = 'gekka' },
};

local ABILITIES = T{
    { key = 'yonin', label = 'Yonin', ability = 'Yonin', buff = 'Yonin', excludes = 'innin' },
    { key = 'innin', label = 'Innin', ability = 'Innin', buff = 'Innin', excludes = 'yonin' },
};

M.defaults = T{
    use = T{ shadows = T{ false } },
    need_haste = T{ false },
    shika_shadows = T{ false },
    delay = T{ 4 },   -- seconds between attempts
};

for _, e in ipairs(NINJUTSU) do M.defaults.use[e.key] = T{ false }; end
for _, e in ipairs(ABILITIES) do M.defaults.use[e.key] = T{ false }; end

----------------------------------------------------------------------------
-- Capability
----------------------------------------------------------------------------

local function NinLevel(ctx)
    return util.JobLevel(ctx, util.job.NIN);
end

--[[
    Whether a ninjutsu can actually be cast right now: learned, AND the
    current NIN level meets the spell's requirement. The second half matters
    for sub NIN -- HasSpell stays true for everything learned while leveling
    NIN as a main, but a /NIN37 cannot cast what needs 40. The requirement
    comes from the DATs, so cexidats re-levels are honored automatically.
]]--
local function Knows(ctx, spellName)
    local spell = util.GetSpell(spellName);
    if (spell == nil or not ctx.player:HasSpell(spell.Index)) then
        return false;
    end

    local required = util.SpellLevel(spell, util.job.NIN);
    return required == nil or required <= NinLevel(ctx);
end

--[[ Returns ready, seconds-remaining. ]]--
local function SpellReady(spellName)
    local spell = util.GetSpell(spellName);
    if (spell == nil) then
        return false, 0;
    end

    local timer = AshitaCore:GetMemoryManager():GetRecast():GetSpellTimer(spell.Index) / 60;
    return timer <= 0, timer;
end

local function HasAbility(ctx, abilityName)
    return util.HasAbilityByName(ctx.player, abilityName);
end

----------------------------------------------------------------------------
-- Tools
----------------------------------------------------------------------------

--[[
    Ensure a tool is on hand, opening a toolbag if the loose ones ran out.

    Returns true when the spell can be cast now; false after queueing a
    toolbag open (the cast retries next tick) or when nothing is left, in
    which case the feature switches itself off rather than spinning.
]]--
local function EnsureTool(kind, entryKey, label, cfg)
    local tool = TOOLS[kind];

    if (util.HasItem(tool.item)) then
        return true;
    elseif (util.HasItem(tool.bag)) then
        util.Cast('/item "' .. tool.bag_name .. '" <me>');
        return false;
    end

    -- Shadows may fall back to shika tools once shihei is exhausted. This is
    -- the checkbox ninhelper tested as `vars.useShikaShadows`, a table, which
    -- is always truthy in Lua -- so the fallback was permanently on and the
    -- checkbox did nothing.
    if (kind == 'shihei' and cfg.shika_shadows[1]) then
        return EnsureTool('shika', entryKey, label, cfg);
    end

    util.Message('out of tools and bags for ' .. label .. ', disabling it');
    cfg.use[entryKey][1] = false;
    M.dirty = true;
    return false;
end

----------------------------------------------------------------------------

--[[
    Main or sub: Utsusemi is the whole reason /NIN exists, so the module
    shows up for it. Everything above the sub's level (Migawari and friends,
    Yonin/Innin as main-only abilities) drops out through the same
    capability checks that handle the level cap.
]]--
function M.Gate(ctx)
    return ctx.mainJob == util.job.NIN or ctx.subJob == util.job.NIN;
end

--[[
    Whether any shikanofuda (or a bag of them) is on hand, refreshed every
    couple of seconds. Gates the Shika toggle: shikanofuda is the 99-era
    universal support tool, so on a 75-cap server there is normally nothing
    to substitute and no reason to show the option -- but that is an
    inventory fact, not something to hardcode about the server.
]]--
local shika_stock = { has = false, at = -10 };

local function HasShikaStock(now)
    if (now - shika_stock.at >= 2) then
        shika_stock.has = util.HasItem(TOOLS.shika.item) or util.HasItem(TOOLS.shika.bag);
        shika_stock.at = now;
    end
    return shika_stock.has;
end

function M.Tick(ctx, cfg)
    if (ctx.status ~= util.status.ENGAGED or ctx.targetIndex == nil) then
        return;
    end

    if (cfg.need_haste[1] and (ctx.buffs['Haste'] or 0) + (ctx.buffs['March'] or 0) == 0) then
        return;
    end

    -- Only work a mob actually being fought: not untouched, not nearly dead.
    local targetHpp = AshitaCore:GetMemoryManager():GetEntity():GetHPPercent(ctx.targetIndex);
    if (targetHpp >= 98 or targetHpp <= 2) then
        return;
    end

    if (not ctx:Throttle('nin.act', cfg.delay[1])) then
        return;
    end

    -- Shadows first; the rest is worth little without them.
    if (cfg.use.shadows[1] and (ctx.buffs['Copy Image'] or 0) == 0) then
        -- Best tier that is both known and off cooldown, so a recasting Ni
        -- still falls back to Ichi rather than waiting.
        for _, tier in ipairs(SHADOW_TIERS) do
            if (Knows(ctx, tier) and SpellReady(tier)) then
                if (EnsureTool('shihei', 'shadows', 'Shadows', cfg)) then
                    util.Cast('/ma "' .. tier .. '" <me>');
                end
                break;
            end
        end

        -- Shadows outrank everything else here, matching ninhelper: when
        -- they are down we spend the tick on them even if nothing was ready.
        return;
    end

    for _, e in ipairs(NINJUTSU) do
        if (cfg.use[e.key][1] and (ctx.buffs[e.buff] or 0) == 0 and Knows(ctx, e.spell)) then
            local ready, timer = SpellReady(e.spell);
            if (ready) then
                if (EnsureTool(e.tool, e.key, e.label, cfg)) then
                    util.Cast('/ma "' .. e.spell .. '" <me>');
                end
                return;
            elseif (e.key == 'migawari' and ctx:Throttle('nin.migawari.warn', 15)) then
                util.Message(string.format('Migawari down, %d sec', timer));
            end
        end
    end

    for _, e in ipairs(ABILITIES) do
        if (cfg.use[e.key][1] and (ctx.buffs[e.buff] or 0) == 0
            and HasAbility(ctx, e.ability) and ctx:Ready(e.ability)) then
            util.Cast('/ja "' .. e.ability .. '" <me>');
            return;
        end
    end
end

----------------------------------------------------------------------------

-- Bar labels; the tooltip-less short forms keep the row narrow.
local SHORT = T{
    migawari = 'Miga', myoshu = 'Myo', kakka = 'Kakka',
    gekka = 'Gekka', yain = 'Yain', yonin = 'Yonin', innin = 'Innin',
};

-- Cached "withheld spells" footer, rebuilt at most every 2 seconds.
local missing_cache = { text = nil, count = 0, at = -10 };

--[[ One flowing row of toggles, wrapping every five. ]]--
function M.Draw(ctx, cfg)
    local drawn = 0;

    local function Toggle(label, state, excludes, help)
        if (drawn > 0 and drawn % 5 ~= 0) then
            imgui.SameLine();
        end
        drawn = drawn + 1;

        if (imgui.Checkbox(label, state)) then
            if (excludes ~= nil and state[1]) then
                cfg.use[excludes][1] = false;
            end
            M.dirty = true;
        end
        if (help ~= nil) then
            util.Tip(help);
        end
    end

    local knowsUtsu = Knows(ctx, 'Utsusemi: Ichi');
    if (knowsUtsu) then
        Toggle('Shdw', cfg.use.shadows, nil,
            'Recast your best available Utsusemi when shadows drop.');
    end

    -- The withheld list only changes on job/level change or when a spell is
    -- learned, so rebuild it at most every 2 seconds instead of per frame
    -- (it costs five DAT reads and five string.formats).
    if (missing_cache.text == nil or ctx.now - missing_cache.at >= 2) then
        local lines = T{};
        for _, e in ipairs(NINJUTSU) do
            if (not Knows(ctx, e.spell)) then
                local level = util.SpellLevel(util.GetSpell(e.spell), util.job.NIN);
                lines[#lines + 1] = (level ~= nil)
                    and string.format('%s  (needs level %d)', e.spell, level)
                    or  string.format('%s  (not learnable)', e.spell);
            end
        end
        missing_cache.count = #lines;
        missing_cache.text = string.format('Unavailable at NIN %d:\n%s',
            NinLevel(ctx), table.concat(lines, '\n'));
        missing_cache.at = ctx.now;
    end

    for _, e in ipairs(NINJUTSU) do
        if (Knows(ctx, e.spell)) then
            Toggle(SHORT[e.key] or e.label, cfg.use[e.key], e.excludes);
        end
    end

    for _, e in ipairs(ABILITIES) do
        if (HasAbility(ctx, e.ability)) then
            Toggle(SHORT[e.key] or e.label, cfg.use[e.key], e.excludes);
        end
    end

    Toggle('Haste', cfg.need_haste, nil,
        'Hold everything until at least one Haste or March is up.');

    -- Only offered while shika tools are actually in the bag; without stock
    -- the fallback can never fire, so the checkbox would be dead weight.
    if (knowsUtsu and HasShikaStock(ctx.now)) then
        Toggle('Shika', cfg.shika_shadows, nil,
            'Allow shika tools for Utsusemi once shihei tools and bags run out.');
    end

    -- Withheld controls are stated, not silently missing.
    if (missing_cache.count > 0) then
        imgui.SameLine();
        imgui.TextDisabled('+' .. missing_cache.count);
        util.Tip(missing_cache.text);
    end
end

return M;
