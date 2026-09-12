--[[
    jobhelper -- RUN, PUP and NIN helpers in one compact bar, for CatsEyeXI.

    Copyright (c) 2026 watahero
    Derived from runehelper, puphelper and ninhelper,
    Copyright (c) 2021 Dan (GetAwayCoxn) -- https://github.com/GetAwayCoxn
    Buff-counting approach after Thorny's luashitacast gData.GetBuffCount.
    Released under the MIT License; see LICENSE in the repository root.

    This is an independent fork. Please do not report problems with it to
    the original author.
]]--

addon.name      = 'jobhelper';
addon.author    = 'watahero';
addon.version   = '2.1.4';
addon.desc      = 'RUN/PUP/NIN helpers in one compact bar for CatsEyeXI. Fork of runehelper, puphelper and ninhelper by GetAwayCoxn.';
addon.link      = 'https://github.com/watahero/jobhelper';

--[[
    One window, one d3d_present callback, one buff scan, one recast scan.

    Replaces runehelper 1.07, puphelper 1.09 and ninhelper 1.02, keeping the
    local changes those had picked up (rate limits, the resting guard, the
    widened incapacitation list, element hints, '/rh set', 4s maneuvers).

    Modules gate themselves. RUN and NIN also work as subjobs, so at most
    two are ever live at once -- your main job's module, plus one for a
    /RUN or /NIN sub -- and the bar stacks whichever are showing.

    Why the shared context matters: runehelper rebuilt the buff table once
    per rune, and puphelper once per maneuver, each time walking all 32 buff
    slots through the resource manager. That is 256 and 288 lookups per
    frame respectively, doubled while both addons were loaded on NIN/RUN.
    Here it happens once, for everyone. '/jh perf' shows the result.
]]--

require('common');
local bit = require('bit');
local imgui = require('imgui');
local settings = require('settings');
local util = require('util');

local modules = T{
    require('modules.run'),
    require('modules.pup'),
    require('modules.nin'),
};

----------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------

local default_settings = T{
    open = T{ true },
    auto_size = T{ true },
    towns = util.default_towns:copy(),
    modules = T{},
};

for _, m in ipairs(modules) do
    default_settings.modules[m.id] = m.defaults;
end

local config = settings.load(default_settings);

settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then
        config = s;
    end
end);

local function Save()
    settings.save();
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local state = {
    enabled = false,
    throttles = {},
    live = T{},

    -- Rolling cost of our own present callback, for '/jh perf'.
    perf = { frames = 0, total = 0.0, last = 0.0 },
};

local btn_on   = { 0.13, 0.42, 0.17, 1.0 };
local btn_off  = { 0.42, 0.14, 0.14, 1.0 };
local btn_held = { 0.48, 0.36, 0.08, 1.0 };

----------------------------------------------------------------------------
-- Per-frame context
----------------------------------------------------------------------------

local ctx = {};

--[[ Whether an ability is off cooldown. O(1) against the frame's recast map. ]]--
function ctx:Ready(abilityName)
    local ability = util.GetAbility(abilityName);
    if (ability == nil) then
        return false;
    end
    return (self.recasts[ability.RecastTimerId] or 0) <= 0;
end

--[[ Rate limit by key. Only consumes the slot when it returns true. ]]--
function ctx:Throttle(key, seconds)
    local last = state.throttles[key];
    if (last ~= nil and self.now - last < seconds) then
        return false;
    end
    state.throttles[key] = self.now;
    return true;
end

--[[
    The cheap facts: enough to decide which modules are live and to draw
    their panels. Runs every frame on every job, so it must stay small --
    a handful of direct memory reads, no scans.
]]--
local function BuildLightContext()
    local memory = AshitaCore:GetMemoryManager();
    local player = memory:GetPlayer();

    ctx.player = player;
    ctx.now = os.time();
    ctx.mainJob = player:GetMainJob();
    ctx.subJob = player:GetSubJob();
    ctx.mainLevel = player:GetMainJobLevel();
    ctx.subLevel = player:GetSubJobLevel();

    local pet = memory:GetEntity():GetPetTargetIndex(memory:GetParty():GetMemberTargetIndex(0));
    ctx.petIndex = (pet ~= nil and pet ~= 0) and pet or nil;

    return ctx;
end

--[[
    The expensive per-frame state -- full buff and recast scans, zone name,
    vitals, target. Only the Tick path reads any of this, so it is built
    only while the addon is armed.
]]--
local function ExtendContext()
    local memory = AshitaCore:GetMemoryManager();
    local party = memory:GetParty();
    local myIndex = party:GetMemberTargetIndex(0);

    ctx.zone = AshitaCore:GetResourceManager():GetString('zones.names', party:GetMemberZone(0));
    ctx.status = memory:GetEntity():GetStatus(myIndex);
    ctx.hpp = party:GetMemberHPPercent(0);
    ctx.mpp = party:GetMemberMPPercent(0);
    ctx.buffs = util.ScanBuffs(ctx.player);
    ctx.recasts = util.ScanRecasts();

    local target = memory:GetTarget():GetTargetIndex(0);
    ctx.targetIndex = (target ~= nil and target ~= 0) and target or nil;
end

----------------------------------------------------------------------------
-- Guards
----------------------------------------------------------------------------

local function IsTown(zone)
    if (zone == nil) then
        return true;
    end
    for _, name in ipairs(config.towns) do
        if (name == zone) then
            return true;
        end
    end
    return false;
end

--[[
    Conditions that switch the addon off rather than merely pausing it, so it
    never silently re-arms when you did not ask for it. Returns the reason,
    which is announced in chat -- "enabled but nothing happens" must always
    have a visible explanation.
]]--
local function ForceOffReason(c)
    if (IsTown(c.zone)) then
        return 'town zone';
    elseif ((c.buffs['Mounted'] or 0) > 0) then
        return 'mounted';
    elseif (c.status == util.status.DEAD or c.status == util.status.DEAD_ENGAGED) then
        return 'dead';
    end
    return nil;
end

--[[
    Whether a cast is genuinely in flight. Job abilities are locked out
    during one anyway, and acting before a spell's buff lands double-casts
    it (seen in play as Utsusemi burning two shihei).

    A live cast bar's percent moves every frame between 0 and 1. An
    INTERRUPTED cast can leave the bar parked mid-value -- observed in play
    when a failing Instant Warp scroll froze it and the addon then held
    forever, armed but doing nothing. So a bar that has not moved for a
    moment is treated as leftover, not as a cast.
]]--
local castbar = { last = -1, moved_at = 0 };

local function IsCasting()
    local percent = AshitaCore:GetMemoryManager():GetCastBar():GetPercent();
    if (percent <= 0 or percent >= 1) then
        castbar.last = percent;
        return false;
    end

    local t = os.clock();
    if (percent ~= castbar.last) then
        castbar.last = percent;
        castbar.moved_at = t;
        return true;
    end
    return (t - castbar.moved_at) < 1.5;
end

--[[ Conditions that pause this frame only. Returns the reason, for status. ]]--
local function HoldReason(c)
    if (c.status == util.status.RESTING) then
        return 'resting';
    end

    -- Any rune, maneuver or ninjutsu strips Invisible, so hold everything
    -- while it is up. puphelper had this for maneuvers only; runes were
    -- observed breaking invisibility in play, hence it lives here now.
    if ((c.buffs['Invisible'] or 0) > 0) then
        return 'invisible';
    end

    if (IsCasting()) then
        return 'casting';
    end

    for name in pairs(util.incapacitating) do
        if ((c.buffs[name] or 0) > 0) then
            return name:lower();
        end
    end
    return nil;
end

----------------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------------

ashita.events.register('d3d_present', 'jobhelper_present', function ()
    local started = os.clock();

    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player:GetIsZoning() ~= 0) then
        state.enabled = false;
        return;
    end

    local c = BuildLightContext();

    -- Which modules apply to this job right now.
    state.live = T{};
    for _, m in ipairs(modules) do
        if (m.Gate(c)) then
            state.live[#state.live + 1] = m;
        end
    end

    if (#state.live == 0) then
        state.enabled = false;
        return;
    end

    -- The scans and guards only matter while armed; idle frames stay cheap.
    if (state.enabled) then
        ExtendContext();

        local off = ForceOffReason(c);
        if (off ~= nil) then
            -- Announce the disarm: this runs exactly once per transition,
            -- and re-arming in the same spot announces it again, so an
            -- enable that will not stick is never a mystery.
            state.enabled = false;
            state.hold = nil;
            util.Message('disarmed: ' .. off);
        else
            state.hold = HoldReason(c);
            if (state.hold == nil) then
                for _, m in ipairs(state.live) do
                    m.Tick(c, config.modules[m.id]);
                end
            end
        end
    end

    -- imgui.Begin's title-bar X writes into config.open directly; detect
    -- that and persist it, so closing with X and closing with /jh leave
    -- the same state on disk.
    local was_open = config.open[1];

    if (config.open[1]) then
        -- Compact is the default: an undecorated bar with tight spacing that
        -- sizes itself to its contents. '/jh size' switches to a decorated,
        -- hand-resizable window using the same layout.
        local compact = config.auto_size[1];
        local flags = 0;

        if (compact) then
            imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 7, 5 });
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 5, 4 });
            imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 5, 2 });
            imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 5.0);
            flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoDecoration);
        else
            imgui.SetNextWindowSize({ 320, 180 }, ImGuiCond_FirstUseEver);
        end

        if (imgui.Begin('jobhelper', config.open, flags)) then
            -- Green running, red off, amber when armed but held -- so a bar
            -- that is doing nothing on purpose says so at a glance.
            local color, label = btn_off, 'OFF';
            if (state.enabled) then
                if (state.hold ~= nil) then
                    color, label = btn_held, 'HLD';
                else
                    color, label = btn_on, 'ON ';
                end
            end

            imgui.PushStyleColor(ImGuiCol_Button, color);
            if (imgui.SmallButton(label)) then
                state.enabled = not state.enabled;
                state.hold = nil;
            end
            imgui.PopStyleColor();
            if (state.hold ~= nil) then
                util.Tip('held: ' .. state.hold);
            end

            for i, m in ipairs(state.live) do
                if (i == 1) then
                    imgui.SameLine();
                else
                    imgui.Separator();
                end
                if (#state.live > 1) then
                    imgui.TextDisabled(m.label);
                    imgui.SameLine();
                end
                m.Draw(c, config.modules[m.id]);

                if (m.dirty) then
                    m.dirty = nil;
                    Save();
                end
            end

            -- No title bar in compact mode, so double-click hides instead.
            if (compact and imgui.IsWindowHovered() and imgui.IsMouseDoubleClicked(ImGuiMouseButton_Left)) then
                config.open[1] = false;
            end
        end
        imgui.End();

        if (compact) then
            imgui.PopStyleVar(4);
        end
    end

    if (was_open ~= config.open[1]) then
        Save();
    end

    -- Rolling average of our own cost.
    local elapsed = (os.clock() - started) * 1000.0;
    state.perf.frames = state.perf.frames + 1;
    state.perf.total = state.perf.total + elapsed;
    state.perf.last = elapsed;
end);

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

local aliases = T{ '/jobhelper', '/jh', '/runehelper', '/rh', '/puphelper', '/ph', '/ninhelper', '/nh' };

local function Live(id)
    for _, m in ipairs(state.live) do
        if (m.id == id) then
            return m;
        end
    end
    return nil;
end

local JOB_NAMES = T{
    [util.job.NIN] = 'NIN', [util.job.PUP] = 'PUP', [util.job.RUN] = 'RUN',
};

--[[
    Say where the window is and, if it is not on screen, why.

    Three separate conditions hide it -- closed, no module for this job, and
    zoning -- and none of them used to announce themselves, so "no window"
    was indistinguishable from "addon is broken". Every command reports
    through here now.
]]--
local function ReportStatus()
    local names = T{};
    for _, m in ipairs(state.live) do
        names[#names + 1] = m.label;
    end

    if (#names == 0) then
        local job = JOB_NAMES[ctx.mainJob or 0];
        if (job == 'PUP') then
            util.Message('hidden: PUP has no pet out. Summon the automaton and it appears.');
        else
            util.Message('hidden: nothing to do on this job. Modules are RUN (main or sub), PUP, NIN.');
        end
        return;
    end

    if (not config.open[1]) then
        util.Message(table.concat(names, ' + ') .. ' ready, window closed. /jh to show it.');
        return;
    end

    local mode = 'idle -- /jh toggle to arm';
    if (state.enabled) then
        mode = (state.hold ~= nil) and ('running, but held: ' .. state.hold) or 'running';
    end
    util.Message(string.format('%s, window open, %s.', table.concat(names, ' + '), mode));
end

ashita.events.register('command', 'jobhelper_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not aliases:contains(args[1]:lower())) then
        return;
    end

    e.blocked = true;
    local verb = (#args > 1) and args[2]:lower() or nil;

    if (verb == nil) then
        config.open[1] = not config.open[1];
        Save();
        ReportStatus();
        return;
    end

    if (verb == 'status') then
        ReportStatus();
        return;
    end

    if (verb == 'toggle') then
        state.enabled = not state.enabled;
        util.Message(state.enabled and 'enabled' or 'disabled');

    elseif (verb == 'set') then
        -- Route to whichever live module understands slots.
        local rest = T{};
        for i = 3, #args do
            rest[#rest + 1] = args[i];
        end

        local applied = false;
        for _, m in ipairs(state.live) do
            if (m.Set ~= nil and m.Set(config.modules[m.id], rest)) then
                applied = true;
            end
        end
        if (applied) then
            Save();
        else
            util.Message('nothing set -- no live module took those arguments');
        end

    elseif (verb == 'deploy') then
        local pup = Live('pup');
        if (pup ~= nil) then
            local cfg = config.modules.pup;
            cfg.auto_deploy[1] = not cfg.auto_deploy[1];
            util.Message('auto deploy ' .. (cfg.auto_deploy[1] and 'on' or 'off'));
            Save();
        else
            util.Message('not on PUP with a pet out');
        end

    elseif (verb == 'size') then
        config.auto_size[1] = not config.auto_size[1];
        util.Message(config.auto_size[1] and 'window auto-fits its contents'
                                          or 'window is manually sizable');
        Save();

    elseif (verb == 'town') then
        local action = (#args > 2) and args[3]:lower() or 'list';
        -- Fetched directly: ctx.zone is only populated while armed.
        local zone = AshitaCore:GetResourceManager():GetString('zones.names',
            AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));

        if (action == 'add' and zone ~= nil) then
            if (not config.towns:contains(zone)) then
                config.towns:append(zone);
                Save();
            end
            util.Message('"' .. zone .. '" counts as a town');
        elseif (action == 'del' and zone ~= nil) then
            for i, name in ipairs(config.towns) do
                if (name == zone) then
                    table.remove(config.towns, i);
                    Save();
                    break;
                end
            end
            util.Message('"' .. zone .. '" no longer counts as a town');
        else
            util.Message(string.format('%d town zones; here is "%s" (%s)',
                #config.towns, tostring(zone),
                IsTown(zone) and 'a town' or 'not a town'));
        end

    elseif (verb == 'burden') then
        local pup = Live('pup');
        if (pup ~= nil and pup.Debug ~= nil) then
            pup.Debug(ctx);
        else
            util.Message('not on PUP with a pet out');
        end

    elseif (verb == 'perf') then
        local p = state.perf;
        if (p.frames == 0) then
            util.Message('no frames measured yet');
        else
            util.Message(string.format('%.3f ms/frame average over %d frames (last %.3f ms)',
                p.total / p.frames, p.frames, p.last));
            p.frames, p.total = 0, 0.0;
        end

    else
        util.Message('commands: status, toggle, set, deploy, size, town add|del|list, burden, perf');
    end
end);

ashita.events.register('load', 'jobhelper_load', function ()
    -- Announce on load, and say whose fork this is so problems with it are
    -- not reported to the original author. Without a load message an addon
    -- whose window is legitimately hidden looks exactly like one that failed.
    util.Message(string.format('v%s by %s -- a fork of GetAwayCoxn\'s runehelper/puphelper/ninhelper, not the original.',
        addon.version, addon.author));
    util.Message('/jh shows the bar, /jh status says where it is.');
end);

ashita.events.register('unload', 'jobhelper_unload', function ()
    Save();
end);
