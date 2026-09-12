# Changelog

## 2.1.6 — 2026-09-12

### Added
- Debug trail in logs/jobhelper-debug.log: every cast the addon queues,
  every maneuver decision (what was needed, what was held), every parsed
  overload reading, every hold/disarm transition -- and byte-escaped raw
  copies of overload chat messages. Play evidence (a Wind cast that the
  guard must have held if it had any data) indicates the chat parser has
  likely never matched a live message; the raw captures settle that from
  disk after the next session.
- /jh why prints the full maneuver decision snapshot (hold state,
  readiness, needed casts, per-element guard verdicts) to chat and the
  debug log.

## 2.1.5 — 2026-09-12

### Fixed
- The amber "!" marker showed constantly. It evaluated every slot's
  hypothetical NEXT stack (already-stacked Light -> "a second Light would
  need OL>12" -> flagged), so with buffs comfortably up it flagged
  everything, permanently. It now flags only casts the rotation wants
  right now that the guard is actually blocking, and shows nothing while
  the bar is disarmed.

## 2.1.4 — 2026-09-12

### Fixed
- The overload guard compared the wrong number. It held until the DECAYED
  estimate fell under the threshold, but the chance the server rolls (and
  prints) is the POST-cast value: the cast's own increment, which scales
  with same-element stacks (+0-1 first, +6-12 second, +14-16 third). So
  the guard waited politely and then authorized ~20 rolls -- every
  overload in tonight's log was a duplicate-stack cast, while
  single-stack Light printed 0 all night. The guard now predicts the
  printed roll (estimate + stack increment) and skips any cast above the
  OL threshold. At the default of 5, single stacks flow freely and
  duplicate stacks are refused outright (they cannot roll under ~12);
  the "!" marker says "needs OL>12" instead of a wait time in that case.
- Chat parsing now strips colour/autotranslate control bytes before
  matching, in case the live message bytes differ from the plain log
  text.

### Added
- /jh burden prints each element's last parsed reading, its age, and the
  current estimate -- if maneuvers have printed chances but this table is
  empty, the parser is not matching and the guard is inert. Ground truth
  for diagnosing the guard from in game.

## 2.1.3 — 2026-09-12

### Fixed
- The overload guard's decay rate was wrong by an order of magnitude.
  2.1.2 assumed burden decays ~1 point per minute; fitting 39 high-burden
  reading pairs from two nights of logs (including two near-pure-decay
  runs, 66->16 over 209s and 58->0 over 254s) puts it at ~0.265 per
  second -- about 1 point every 4 seconds. The guard now uses 0.25/s, so
  a 23 reading at the default threshold holds ~75 seconds instead of 18
  minutes. The "!" marker shows the wait in seconds or minutes to match.

## 2.1.2 — 2026-09-12

### Fixed
- The overload guard's 2.1.0 design caused the very spiral it was meant to
  stop. It held a hot element for a fixed 30s and then "refreshed the
  reading" by casting -- but play logs show each cast ADDS roughly 8-10 to
  that element's chance while decay is only ~1 per minute, so the probe
  casts built burden faster than it decayed (Wind: 5 -> 14 -> 23 -> ... ->
  64, overloading on nearly every recast, re-triggered seconds after each
  Overload wore off). A cast is never a free probe: the element is now
  held until its estimated chance (last reading minus decay for the time
  elapsed) is back under the threshold, and the bar shows a "!N" marker
  naming the held elements and the estimated wait.

## 2.1.1 — 2026-09-12

### Fixed
- Armed-but-frozen after an interrupted cast. The mid-cast hold read the
  cast bar's percent, and an interrupted cast (a failing Instant Warp
  scroll, observed in play) can leave the bar parked mid-value, so the
  hold never released. A bar that has not moved for 1.5s is now treated
  as leftover, not as a cast.
- The addon now says why it is doing nothing. Disarming (town, mounted,
  dead) prints the reason in chat, the ON button turns amber "HLD" while
  a hold (casting, invisible, resting, incapacitated) is active with the
  reason on hover, and /jh status reports it too.
- The PUP pet/oil readout was mangled (imgui treated its percent sign as
  a printf directive); it now reads "hp|oil" cleanly.

### Changed
- All "(?)" help markers replaced by hover tooltips on the widgets
  themselves, removing the ragged tail of markers from the bar rows.

## 2.1.0 — 2026-09-11

### Added
- PUP overload guard. CatsEyeXI announces each maneuver's overload chance
  in chat; the addon now remembers the last reported chance per element
  and, when it is at or above a configurable threshold (OL slider,
  default 5%, 0 disables), spaces that element's recasts out by 30s so
  its burden can decay. Other elements are unaffected and can still cast
  in the same tick. Motivated by a real overload in play at a reported
  11% while the addon recast Light the moment a stack dropped. On servers
  without the chat line the guard never engages.

## 2.0.2 — 2026-08-20

### Fixed
- Nothing acts while Invisible any more. The hold was PUP-only (inherited
  from puphelper), so RUN would cast a rune mid-sneak and strip Invisible.
  It now lives in the host guard and covers every module.
- Nothing acts while a spell cast is in flight. Previously the NIN module
  could start a second Utsusemi during the first one's cast time, burning
  an extra shihei.

### Changed
- Buff names are resolved once per buff id and memoized; the armed-frame
  buff scan is now plain table reads.
- The NIN "withheld spells" tooltip is rebuilt at most every 2 seconds
  instead of every frame.
- Shared job-level and has-ability helpers moved into util (no behavior
  change).

## 2.0.1 — 2026-08-20

### Fixed
- Runes and maneuvers are now cast one per tick. Each shares a single
  recast timer, so queuing several at once (as the originals and 2.0.0
  did) only produced "Unable to use job ability" for all but the first.
  Stacking the same element three times is unaffected and verified.

### Changed
- Corrected the 2.0.0 note claiming the originals wasted charges on
  duplicate-element slots. They did not; the extra queued casts failed
  harmlessly. The only real difference was the message spam above.

## 2.0.0 — 2026-08-20

First release of the fork. Merges runehelper 1.07, puphelper 1.09 and
ninhelper 1.02 (GetAwayCoxn) into a single addon.

### Added
- One compact, undecorated, auto-sizing bar for all three jobs; stacks the
  modules live for the current main/sub job. `/jh size` for a decorated,
  resizable window.
- Capability-driven controls: spells and abilities appear only when the
  character has them, with spell levels read from the client DATs. Withheld
  NIN spells are listed with their required level in a `+N` tooltip.
- NIN module works as a subjob (Utsusemi tiering respects sub level).
- Per-character settings.
- `/jh status`, `/jh town add|del|list`, `/jh perf`, `/jh size`.
- `/jh set` works for RUN as well as PUP, and accepts rune names.
- Shika fallback shown only when shikanofuda is in inventory.
- Load message identifies the fork and its author.

### Fixed (relative to the originals)
- ninhelper's Shika Shadows checkbox was inert (tested the table, not the value).
- Shadow tiering now falls back to the next *ready* tier.
- `Copy Image (4+)` is recognised as shadows up.
- puphelper 1.09's `autcooldown` typo.

### Changed
- One buff scan and one recast scan per frame, shared across modules and
  performed only while armed.
- Oil count cached (2 s) instead of rescanned every frame.
