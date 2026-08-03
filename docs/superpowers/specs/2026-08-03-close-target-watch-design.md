# Close-Target Watch — design

**Date:** 2026-08-03
**Status:** Approved (brainstorming), pending implementation plan

## Problem

The signal channel sometimes posts an *advisory* full-close target, e.g.:

> my target for full close is 63600-63700

This is **not** a limit order and must not place one. The author will later post
the real close instruction. We want the app to help the operator not miss the
zone: when live price reaches the target, surface a **confirmation dialog that
stays open and keeps updating the live price**, so the operator can close on the
author's word (or dismiss). Nothing closes automatically — the dialog is the
gate.

## Decisions (from brainstorming)

- **Arming:** auto-detected from the message; the safety gate is the confirm
  dialog at the target, not the arming step. A mis-parse only produces a
  dismissable prompt — nothing closes without an explicit click.
- **Trigger edge — near edge by direction:** the target is a range `[low, high]`.
  A LONG (price rising into the zone) fires at `low`; a SHORT (price falling into
  the zone) fires at `high`. Position side is read live at fire time.
- **Dialog:** stays open and live-updates price + P&L until the operator acts.
  **Close now** flattens; **Dismiss** disarms the watch.
- **Persistence:** the armed watch survives an app restart (saved in `AppConfig`,
  restored on launch, re-evaluated on price reconnect).
- **Cardinality:** exactly one armed watch at a time; a newer target message
  replaces the previous one.
- **Architecture rule:** parsers and predicates (business logic) live in **Rust**
  (via flutter_rust_bridge); Dart only orchestrates state, persistence, and the
  UI/dialog.

## Architecture

### Rust (logic — `rust/src/patterns.rs` + `rust/src/api/mod.rs`)

1. `pub struct CloseTarget { low: f64, high: f64 }` (`low <= high`, normalized).
2. `pub fn extract_close_target(text: &str) -> Option<CloseTarget>` — mirrors the
   existing `extract_master_balance` / `extract_trade_size` extractors.
   - Recognizes phrasing such as:
     - `target for full close is 63600-63700`
     - `full close target 63600 to 63700`
     - single value: `target for full close is 63600` (`high == low`)
   - Tolerates a leading `$` and thousands `,`. Range separators: `-`, `–`, `to`.
   - Returns `None` on hypothetical / guarded wording (reuse the same guard
     vocabulary already used by the pattern engine, e.g. "should have",
     "if I had", "imagine", "for example", "what if").
   - Normalizes so `low <= high` regardless of the order written.
3. `pub fn close_target_should_fire(direction: Direction, price: f64, low: f64,
   high: f64) -> bool` — pure predicate:
   - `Direction::Long  => price >= low`
   - `Direction::Short => price <= high`
   - Caller guarantees `price > 0` and an open position before calling.
4. Bridge functions in `api/mod.rs` exposing both (`extract_close_target`,
   `close_target_should_fire`), then run `flutter_rust_bridge_codegen generate`.

### Dart (state + UI orchestration)

5. **State** — `CloseTargetWatch { double low; double high; String source;
   DateTime armedAt; }` held on `AppController`, plus a transient
   `bool closeTargetTriggered`. Persisted inside `AppConfig`
   (`toPersistentJson` / `fromJson`), restored on load.
6. **Arming** — in `handleIncomingTelegramMessage`, after the normal action
   handling, call the Rust `extractCloseTarget`. A hit arms/replaces the single
   watch, clears any stale `closeTargetTriggered`, logs
   `Close-watch armed 63600–63700 (from Telegram …)`, and `notifyListeners()`.
   The target message otherwise parses to Ignore and takes no trade action.
7. **Trigger** — on each WEEX price tick (where `config.markPrice` updates), if a
   watch is armed, a position is open, and `markPrice > 0`, call
   `closeTargetShouldFire(position.direction, markPrice, low, high)`. On the
   first true, set `closeTargetTriggered = true` and `notifyListeners()`. When
   the position is flat the tick simply does not fire — the watch is **not**
   disarmed by a flat tick (a target may arrive before the position is opened).
   Disarming happens only via §10 (disarm-on-flatten, i.e. a position that
   existed going to zero), Cancel, Dismiss, or replacement by a newer target.
8. **Dialog** (`app_shell`) — when `closeTargetTriggered`, show a
   `barrierDismissible: false` dialog wrapped in `ListenableBuilder(controller)`
   so it re-renders every tick. Shows: target range, **live** mark price, and
   unrealized P&L. Buttons:
   - **Close now** → `controller.manualFlatten()` then disarm.
   - **Dismiss** → disarm (clears watch + triggered).
   Only one dialog at a time (guarded like the existing approval dialog). Because
   this is a full close, it inherently honors the existing "a close is always
   confirmed" rule even under auto-approve.
9. **Panel indicator** — the Reduce/Exit panel (`ManualReducePanel`) shows the
   armed watch (`Close-watch armed 63600–63700`) with a **Cancel** button that
   disarms. (Manual arm field is out of scope for v1.)
10. **Disarm-on-flatten** — whenever the position goes flat (manual flatten,
    Telegram close, reduce to zero, exchange reconciliation), clear any armed
    watch and triggered flag.

## Data flow

```
Telegram msg ──▶ handleIncomingTelegramMessage
                   │   (normal action handling unchanged)
                   └─▶ rust.extractCloseTarget(text)
                         └─ Some(low,high) ──▶ arm/replace CloseTargetWatch (persist)

WEEX price tick ──▶ markPrice updated
                     └─ watch armed & position open & markPrice>0
                          └─ rust.closeTargetShouldFire(side, price, low, high)
                               └─ true (first) ──▶ closeTargetTriggered = true ──▶ notify

app_shell listens ──▶ triggered ──▶ live confirm dialog
                                        ├─ Close now ─▶ manualFlatten() + disarm
                                        └─ Dismiss ───▶ disarm
```

## Error / edge handling

- **No open position** when armed or when price enters the zone → do not fire;
  disarm on flatten. A target that arrives while flat still arms (position may be
  opened later); it simply never fires until a position exists.
- **`markPrice <= 0`** (price feed down) → skip evaluation; re-evaluate on the
  next valid tick / reconnect.
- **New target message** replaces the existing watch and clears the triggered
  flag (so a stale open dialog for the old target is superseded).
- **Author posts the real CLOSE** later → handled by the existing close path;
  the resulting flatten disarms the watch.
- **Side flips** between arm and fire → the live position side at fire time
  decides the edge; the stored range is side-agnostic.
- **Single value target** (`high == low`) → LONG fires at/above it, SHORT at/below
  it.

## Testing

- **Rust** — `extract_close_target`: range, single value, `$`/`,`, `-`/`–`/`to`
  separators, reversed order (normalizes), guarded/hypothetical → `None`, and a
  benign non-target sentence → `None`.
- **Rust** — `close_target_should_fire`: LONG at/above `low` fires and below does
  not; SHORT at/below `high` fires and above does not; exact-edge fires.
- **Dart** — arming replaces a prior watch and clears the triggered flag;
  disarm-on-flatten clears the watch; persistence round-trips through
  `AppConfig` JSON. (Trigger orchestration is thin glue over the Rust predicate.)

## Out of scope (v1)

- Manual arm field in the panel (auto-arm + Cancel is enough for v1).
- Multiple simultaneous watches (single watch only).
- Partial-reduce targets (this is full-close only).
- Auto-closing at the target (explicitly rejected — always operator-confirmed).
