# jobhelper

Rune Fencer, Puppetmaster and Ninja automation for [Ashita v4](https://www.ashitaxi.com/),
merged into one compact bar and tuned for the [CatsEyeXI](https://catseyexi.com/)
private server (level 75 cap, level sync, custom DATs via cexidats).

> **This is an independent fork**, not the original. It derives from
> [Rune-Helper](https://github.com/GetAwayCoxn/Rune-Helper),
> [Pup-Helper](https://github.com/GetAwayCoxn/Pup-Helper) and NINhelper by
> **GetAwayCoxn**, who has no involvement in this version. Please report
> problems here, not to him. See [Attribution](#attribution).

## What it does

| job | automation |
|---|---|
| **RUN** (main or sub) | keeps up to three chosen runes up; Vivacious Pulse below an HP% (MP% when every rune is Tenebrae) |
| **PUP** (main, pet out) | keeps three chosen maneuvers up; auto Deploy, Repair below a pet HP%, auto-swap to Light below a pet HP%, Cooldown on Overload |
| **NIN** (main or sub) | recasts the best Utsusemi you can cast when shadows drop, with toolbag opening; Migawari / Myoshu / Kakka / Gekka / Yain; Yonin / Innin; optional "wait for Haste" |

Up to two modules can be live at once (your main job's plus a /RUN or /NIN
sub); the bar stacks whichever apply and hides entirely on other jobs.
Settings are saved per character.

## Install

1. Copy the `jobhelper` folder into `Ashita\addons\`.
2. Load it with `/addon load jobhelper`, or add that line to
   `Ashita\scripts\default.txt` below the `/wait 3`.
3. If you were using runehelper, puphelper or ninhelper, remove their load
   lines and unload them — all three share commands and abilities with this
   addon, and running both double-casts.

## Commands

`/jh` (also `/jobhelper`, and the legacy `/rh` `/ph` `/nh`) shows or hides the bar.
Double-clicking the bar hides it too.

| command | effect |
|---|---|
| `/jh toggle` | arm or disarm every live module |
| `/jh status` | say which modules are live, and why the bar is hidden if it is |
| `/jh set fire ice wind` | set the three rune or maneuver slots. Also takes rune names (`ignis`) and `none` |
| `/jh deploy` | toggle PUP auto-deploy |
| `/jh size` | switch between the compact bar and a decorated, hand-resizable window |
| `/jh town add` / `del` / `list` | treat the current zone as a town, where the addon always disarms |
| `/jh perf` | average cost per frame of this addon |

The bar disarms itself in towns, while mounted, dead, zoning, or on a job
with nothing to do, and pauses while resting or incapacitated.

## How it handles CatsEyeXI

Nothing about the server is hardcoded. Every control is bound to what the
game client says your character can actually do right now:

- Spells and abilities are checked with `HasSpell` / `HasAbility`, and spell
  level requirements are read from the client's own DATs (which cexidats
  overrides), compared against your main or sub job level.
- Rune slots unlock from your RUN level against thresholds in settings.
- The Shika-tools fallback only appears if shikanofuda is in your inventory.

So on a 75-cap server the NIN row is short — shadows plus Yonin/Innin — and
a `+N` marker lists what was withheld and the level it needs. If a patch
re-levels something under the cap, its control appears on its own.

Read from CatsEyeXI's DATs at time of writing: Myoshu 85, Migawari 88,
Gekka 88, Yain 91, Kakka 93, Utsusemi: San 96 — all above the cap.
PUP as a subjob cannot summon on CatsEyeXI, so that module stays main-only.

## Changes from the originals

Behaviour kept from the installed versions (runehelper 1.07, puphelper 1.09,
ninhelper 1.02): cast rate limits, the resting guard, the widened
incapacitation list, rune element hints, `/rh set`, the 4-second maneuver
delay.

Fixed along the way:

- **Shika Shadows checkbox did nothing** — ninhelper tested the option's
  table rather than its value, so the fallback was permanently on.
- **Redundant casts** — naming the same element in two slots queued the
  ability more times than needed. Verified across all 4096 slot/buff
  combinations: 144 differ, every one the original over-firing.
- **Shadow tier fallback** — ninhelper stopped at the highest known tier
  even when it was recasting; this drops to the next tier that is ready.
- **4+ shadows** — `Copy Image (4+)` now counts as shadows up.
- **Per-frame cost** — one buff scan and one recast scan per frame, shared
  by every module, and only while armed. The originals rebuilt the buff
  table once per ability per frame (256–288 resource lookups each).

## Development

No build step. `tools/` holds two checks runnable with plain Python:

```
python tools/luacheck.py jobhelper/jobhelper.lua jobhelper/util.lua jobhelper/modules/*.lua
python tools/rotation_equiv.py
```

`luacheck.py` verifies block and bracket balance in the Lua sources (no Lua
interpreter needed). `rotation_equiv.py` exhaustively compares the shared
rotation rule against the originals' nested conditionals.

Layout:

```
jobhelper/
  jobhelper.lua     host: events, shared per-frame context, guards, bar, commands
  util.lua          resource lookups, buff/recast scans, rotation rule, inventory
  modules/
    run.lua         one file per job; each exposes Gate, Tick, Draw, defaults
    pup.lua
    nin.lua
```

A module sees only the `ctx` the host builds each frame. Adding a job is one
new file and one line in the `modules` list.

## Attribution

- **GetAwayCoxn** (Dan) — author of Rune-Helper, Pup-Helper and NINhelper,
  the MIT-licensed addons this is derived from. His copyright notice is
  retained in [LICENSE](LICENSE).
- **Thorny** — the buff-counting approach comes from `gData.GetBuffCount`
  in luashitacast, as the originals credited.
- **Towbes** — the pupper addon for Ashita v3 that inspired Pup-Helper.

## License

MIT. See [LICENSE](LICENSE).
