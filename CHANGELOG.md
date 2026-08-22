# Changelog

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
- Duplicate-element slots queued redundant casts (verified exhaustively).
- Shadow tiering now falls back to the next *ready* tier.
- `Copy Image (4+)` is recognised as shadows up.
- puphelper 1.09's `autcooldown` typo.

### Changed
- One buff scan and one recast scan per frame, shared across modules and
  performed only while armed.
- Oil count cached (2 s) instead of rescanned every frame.
