# Changelog

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
