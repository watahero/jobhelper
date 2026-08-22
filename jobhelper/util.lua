--[[
    jobhelper -- Copyright (c) 2026 watahero. MIT License; see LICENSE.
    Derived from runehelper/puphelper/ninhelper, Copyright (c) 2021 Dan
    (GetAwayCoxn). Independent fork; not supported by the original author.
]]--

--[[
    jobhelper/util.lua

    Shared helpers for every job module. Nothing in here knows about a
    specific job -- if it does, it belongs in modules/ instead.

    The originals resolved recasts by walking all 32 timer slots and
    string-comparing ability names, once per ability, per frame. That is
    also why runehelper's comment says "every rune is Ignis": all eight
    runes share a single recast timer id, so GetAbilityByTimerId returns
    whichever ability owns it first. Resolving an ability's RecastTimerId
    once at load and looking it up in a per-frame map gives the correct
    shared timer and costs one table index instead of a 32-slot scan.
]]--

require('common');

local util = T{};

-- Default town list. Zone names come from the client's DATs, which cexidats
-- overrides on CatsEyeXI, so custom zones will not be in here. Users add
-- their own with '/jh town add' while standing in the zone; the merged list
-- lives in settings.
util.default_towns = T{
    'Tavnazian Safehold', 'Al Zahbi', 'Aht Urhgan Whitegate', 'Nashmau',
    'Southern San d\'Oria [S]', 'Bastok Markets [S]', 'Windurst Waters [S]',
    'San d\'Oria-Jeuno Airship', 'Bastok-Jeuno Airship', 'Windurst-Jeuno Airship',
    'Kazham-Jeuno Airship', 'Southern San d\'Oria', 'Northern San d\'Oria',
    'Port San d\'Oria', 'Chateau d\'Oraguille', 'Bastok Mines', 'Bastok Markets',
    'Port Bastok', 'Metalworks', 'Windurst Waters', 'Windurst Walls',
    'Port Windurst', 'Windurst Woods', 'Heavens Tower', 'Ru\'Lude Gardens',
    'Upper Jeuno', 'Lower Jeuno', 'Port Jeuno', 'Rabao', 'Selbina', 'Mhaura',
    'Kazham', 'Norg', 'Mog Garden', 'Celennia Memorial Library',
    'Western Adoulin', 'Eastern Adoulin',
};

-- Buffs that mean "we cannot act right now". Distinct from Mounted, which
-- means "the user is travelling and we should switch ourselves off entirely".
util.incapacitating = T{
    ['Sleep'] = true, ['Charm'] = true, ['Terror'] = true,
    ['Petrification'] = true, ['Stun'] = true, ['Amnesia'] = true,
};

util.job = T{ NIN = 13, PUP = 18, RUN = 22 };

-- Entity status values used by the guards.
util.status = T{ IDLE = 0, ENGAGED = 1, DEAD = 2, DEAD_ENGAGED = 3, RESTING = 33 };

----------------------------------------------------------------------------
-- Resource lookups (cached; the underlying DATs never change at runtime)
----------------------------------------------------------------------------

local ability_cache = {};
local spell_cache = {};

--[[ Resolve an ability by English name. Returns the IAbility or nil. ]]--
function util.GetAbility(name)
    local hit = ability_cache[name];
    if (hit ~= nil) then
        return hit ~= false and hit or nil;
    end

    local res = AshitaCore:GetResourceManager();
    local ability = res:GetAbilityByName(name, 2) or res:GetAbilityByName(name, 0);
    ability_cache[name] = ability or false;
    return ability;
end

--[[ Resolve a spell by English name. Returns the ISpell or nil. ]]--
function util.GetSpell(name)
    local hit = spell_cache[name];
    if (hit ~= nil) then
        return hit ~= false and hit or nil;
    end

    local res = AshitaCore:GetResourceManager();
    local spell = res:GetSpellByName(name, 2) or res:GetSpellByName(name, 0);
    spell_cache[name] = spell or false;
    return spell;
end

--[[
    The level a job needs to learn a spell, or nil if unknown/unlearnable.

    LevelRequired is exposed 1-based: [jobId + 1]. That is the convention
    every resource-reading addon on this install uses (blucheck, grimoire,
    tCrossBar). -1 means unlearnable; values above 99 mean job points.
    Display only -- every real gate goes through HasSpell.
]]--
function util.SpellLevel(spell, jobId)
    if (spell == nil or spell.LevelRequired == nil) then
        return nil;
    end

    local ok, lvl = pcall(function() return spell.LevelRequired[jobId + 1]; end);
    if (ok and type(lvl) == 'number' and lvl > 0 and lvl < 200) then
        return lvl;
    end
    return nil;
end

----------------------------------------------------------------------------
-- Per-frame state
----------------------------------------------------------------------------

--[[
    Buff name -> count, built once per frame.

    The originals rebuilt this inside a loop over their ability list, so
    runehelper did 8 passes over 32 buffs (256 resource lookups per frame)
    and puphelper did 9. One pass gives every module the same answer.
]]--
function util.ScanBuffs(player)
    local counts = {};
    local res = AshitaCore:GetResourceManager();

    for _, id in pairs(player:GetBuffs()) do
        if (id ~= nil and id > 0 and id < 1024) then
            local name = res:GetString('buffs.names', id);
            if (name ~= nil and name ~= '') then
                -- Stacking buffs report as 'Copy Image (3)' -- and the top
                -- tier as 'Copy Image (4+)', plus sign included. Index by
                -- the base name so callers can ask for 'Copy Image' and get
                -- an answer regardless of how many shadows are up.
                local base = name:match('^(.-)%s*%([%d%+]+%)$') or name;
                counts[base] = (counts[base] or 0) + 1;
            end
        end
    end
    return counts;
end

--[[ Recast timer id -> remaining time, built once per frame. ]]--
function util.ScanRecasts()
    local map = {};
    local recast = AshitaCore:GetMemoryManager():GetRecast();

    for x = 0, 31 do
        local timer = recast:GetAbilityTimer(x);
        if (timer > 0) then
            map[recast:GetAbilityTimerId(x)] = timer;
        end
    end
    return map;
end

----------------------------------------------------------------------------
-- Rotation
----------------------------------------------------------------------------

--[[
    Work out which abilities to use to reach the requested stack of runes or
    maneuvers, and in what order.

    slots  -- up to 3 ability names, in slot order
    counts -- buff name -> how many are currently up

    Runes and maneuvers both apply a buff named after the ability, so the
    ability name doubles as the buff name here.

    An ability is used once for every copy the slots ask for that is not
    already up. Naming the same element twice asks for two stacks of it.

    This replaces two ~60-line blocks of nested conditionals that said the
    same thing. Worth noting one behavioural difference: runehelper's slot 1
    only ever fired when the element was completely absent, so picking the
    same rune in slots 1 and 2 built the second stack more slowly than
    picking it in slots 2 and 3. Here every slot pulls its weight.
]]--
function util.RotationNeeds(slots, counts)
    local wanted = {};
    for _, name in ipairs(slots) do
        wanted[name] = (wanted[name] or 0) + 1;
    end

    local queued, out = {}, {};
    for _, name in ipairs(slots) do
        local have = (counts[name] or 0) + (queued[name] or 0);
        if (have < wanted[name]) then
            queued[name] = (queued[name] or 0) + 1;
            out[#out + 1] = name;
        end
    end
    return out;
end

--[[
    Apply '/jh set <a> <b> <c>' words to a 3-slot selection.

    slots   -- the module's slot array (0-based picks, -1 empty), mutated
    args    -- the words, one per slot position
    choices -- per pick index, the list of words that select it

    Returns whether anything matched. Shared by RUN and PUP so the command
    behaves identically for both.
]]--
function util.ParseSlots(slots, args, choices)
    local applied = false;

    for slot = 1, 3 do
        local word = args[slot];
        if (word ~= nil) then
            word = word:lower();
            if (word == 'none') then
                slots[slot] = -1;
                applied = true;
            else
                for idx, words in ipairs(choices) do
                    for _, accept in ipairs(words) do
                        if (word == accept) then
                            slots[slot] = idx - 1;
                            applied = true;
                        end
                    end
                end
            end
        end
    end
    return applied;
end

----------------------------------------------------------------------------
-- Inventory
----------------------------------------------------------------------------

-- Inventory (0) plus the wardrobes/satchel bags puphelper counted from.
local oil_containers = T{ 0, 8, 10, 11, 12, 13, 14, 15, 16 };

--[[ Total count of an item id across the bags the game can use it from. ]]--
function util.CountItem(id, containers)
    local total = 0;
    local inv = AshitaCore:GetMemoryManager():GetInventory();

    for _, c in ipairs(containers or oil_containers) do
        for i = 1, 81 do
            local item = inv:GetContainerItem(c, i);
            if (item ~= nil and item.Id == id) then
                total = total + item.Count;
            end
        end
    end
    return total;
end

--[[ Whether at least one of an item id is in the main inventory bag. ]]--
function util.HasItem(id)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    for i = 1, 81 do
        local item = inv:GetContainerItem(0, i);
        if (item ~= nil and item.Id == id) then
            return true;
        end
    end
    return false;
end

----------------------------------------------------------------------------
-- Misc
----------------------------------------------------------------------------

function util.Cast(command)
    AshitaCore:GetChatManager():QueueCommand(1, command);
end

local chat = require('chat');

function util.Message(str)
    print(chat.header('jobhelper'):append(chat.message(tostring(str))));
end

return util;
