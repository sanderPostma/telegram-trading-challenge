# Close-Target Watch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the signal channel posts an advisory full-close target (e.g. "my target for full close is 63600-63700"), arm a price watch that opens a live-updating close-confirmation dialog when price reaches the zone — never auto-closing.

**Architecture:** All parsing/predicate logic lives in Rust (`patterns.rs`), exposed through the existing flutter_rust_bridge `crate::api` surface. The Dart `AppController` orchestrates state (the armed watch), persistence, arming from Telegram, evaluation on each price tick, and the confirmation dialog. The dialog reuses the existing full-flatten path (`manualFlatten`).

**Tech Stack:** Rust (regex, serde) + flutter_rust_bridge 2.12.0; Flutter/Dart (ChangeNotifier controller, SharedPreferences, Material dialogs).

## Global Constraints

- **Never auto-close.** The dialog is always operator-confirmed, even under auto-approve. Nothing flattens without an explicit "Close now" click.
- **Rust owns logic.** Parsers and the trigger predicate live in Rust behind the bridge; Dart only orchestrates state/UI. (flutter_rust_bridge `=2.12.0`.)
- **Exactly one armed watch.** A newer target message replaces the previous watch and clears any triggered state.
- **Near-edge-by-direction trigger.** Target is a range `[low, high]` with `low <= high`. LONG fires when `price >= low`; SHORT fires when `price <= high`. Position side is read live at fire time.
- **Persist across restart.** The armed watch survives an app restart.
- TDD, minimal implementations, frequent commits.

**Bridge codegen command (used in Task 3):** from `apps/tmg-challenge`, run `flutter_rust_bridge_codegen generate` (config in `flutter_rust_bridge.yaml`: `rust_input: crate::api`, `dart_output: lib/src/bridge`).

---

### Task 1: Rust — extract the close-target range

**Files:**
- Modify: `rust/src/patterns.rs` (add function near `extract_trade_size`, ~line 167; add tests in the existing `#[cfg(test)] mod tests`)

**Interfaces:**
- Produces: `pub fn extract_close_target_range(text: &str) -> Option<(f64, f64)>` — returns `(low, high)` with `low <= high`; `high == low` for a single value; `None` when no target phrasing or when the text is hypothetical/guarded.

- [ ] **Step 1: Write the failing tests**

Add inside `mod tests` in `rust/src/patterns.rs`:

```rust
#[test]
fn extracts_close_target_range() {
    // Range with the canonical channel phrasing.
    assert_eq!(
        extract_close_target_range("my target for full close is 63600-63700"),
        Some((63_600.0, 63_700.0))
    );
    // "to" separator and a leading verb-first phrasing.
    assert_eq!(
        extract_close_target_range("full close target 63600 to 63700"),
        Some((63_600.0, 63_700.0))
    );
    // En-dash separator and thousands separators / dollar sign.
    assert_eq!(
        extract_close_target_range("target for full close is $63,600–$63,700"),
        Some((63_600.0, 63_700.0))
    );
    // Single value: high == low.
    assert_eq!(
        extract_close_target_range("target for full close is 63600"),
        Some((63_600.0, 63_600.0))
    );
    // Reversed order normalizes so low <= high.
    assert_eq!(
        extract_close_target_range("target for full close is 63700-63600"),
        Some((63_600.0, 63_700.0))
    );
    // Hypothetical wording must not arm anything.
    assert_eq!(
        extract_close_target_range("if I had a target for full close it would be 63600"),
        None
    );
    // Unrelated prose does not match.
    assert_eq!(extract_close_target_range("closed half, banked $300"), None);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test extracts_close_target_range`
Expected: FAIL — `cannot find function extract_close_target_range`.

- [ ] **Step 3: Write minimal implementation**

Add near the other extractors in `rust/src/patterns.rs` (after `extract_trade_size`):

```rust
/// Extracts an advisory full-close price target, e.g. "target for full close is
/// 63600-63700". Returns `(low, high)` normalized so `low <= high`; a single
/// value yields `high == low`. Returns `None` for hypothetical/guarded wording,
/// mirroring the `hypothetical` guard used by the pattern engine.
pub fn extract_close_target_range(text: &str) -> Option<(f64, f64)> {
    // Same vocabulary as the YAML `hypothetical` guard: discussion, not a signal.
    let guard = Regex::new(
        r"(?i)\b(?:should|would|could)(?:'ve|ve|\s+(?:have|of))\b|\bif\s+i\s+(?:had|would|were)\b|\bwish\s+i\b|\bimagine\b|\bfor\s+(?:example|instance)\b|\bwhat\s+if\b|\bhypothetical",
    )
    .ok()?;
    if guard.is_match(text) {
        return None;
    }

    let re = Regex::new(
        r"(?i)(?:full\s+close\s+target|target\s+(?:for|to)\s+(?:a\s+)?full\s+close(?:\s+is)?)\s*:?\s*\$?(?P<low>[\d,]+(?:\.\d+)?)(?:\s*(?:-|–|—|to)\s*\$?(?P<high>[\d,]+(?:\.\d+)?))?",
    )
    .ok()?;
    let caps = re.captures(text)?;
    let low = parse_number(caps.name("low")?.as_str())?;
    let high = caps
        .name("high")
        .and_then(|m| parse_number(m.as_str()))
        .unwrap_or(low);
    Some((low.min(high), low.max(high)))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd rust && cargo test extracts_close_target_range`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rust/src/patterns.rs
git commit -m "feat(rust): extract advisory close-target range from message text"
```

---

### Task 2: Rust — close-target trigger predicate

**Files:**
- Modify: `rust/src/patterns.rs` (add function; add tests in `mod tests`)

**Interfaces:**
- Consumes: `crate::interpreter::Direction` (already imported at the top of `patterns.rs`).
- Produces: `pub fn close_target_should_fire(direction: Direction, price: f64, low: f64, high: f64) -> bool` — LONG → `price >= low`; SHORT → `price <= high`.

- [ ] **Step 1: Write the failing tests**

Add inside `mod tests` in `rust/src/patterns.rs`:

```rust
#[test]
fn close_target_fires_on_near_edge_by_direction() {
    // LONG enters the zone from below → fires at/above the low edge.
    assert!(close_target_should_fire(Direction::Long, 63_600.0, 63_600.0, 63_700.0));
    assert!(close_target_should_fire(Direction::Long, 63_650.0, 63_600.0, 63_700.0));
    assert!(!close_target_should_fire(Direction::Long, 63_599.0, 63_600.0, 63_700.0));

    // SHORT enters the zone from above → fires at/below the high edge.
    assert!(close_target_should_fire(Direction::Short, 63_700.0, 63_600.0, 63_700.0));
    assert!(close_target_should_fire(Direction::Short, 63_650.0, 63_600.0, 63_700.0));
    assert!(!close_target_should_fire(Direction::Short, 63_701.0, 63_600.0, 63_700.0));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test close_target_fires_on_near_edge_by_direction`
Expected: FAIL — `cannot find function close_target_should_fire`.

- [ ] **Step 3: Write minimal implementation**

Add in `rust/src/patterns.rs` (below `extract_close_target_range`):

```rust
/// Whether live `price` has reached the advisory close zone for the current
/// position side. Near-edge by direction: a LONG (price rising into the zone)
/// fires at the low edge; a SHORT (price falling into the zone) fires at the
/// high edge. Callers guarantee an open position and `price > 0`.
pub fn close_target_should_fire(direction: Direction, price: f64, low: f64, high: f64) -> bool {
    match direction {
        Direction::Long => price >= low,
        Direction::Short => price <= high,
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd rust && cargo test close_target_fires_on_near_edge_by_direction`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rust/src/patterns.rs
git commit -m "feat(rust): add near-edge close-target trigger predicate"
```

---

### Task 3: Bridge — expose extractor + predicate to Dart

**Files:**
- Modify: `rust/src/api/mod.rs` (add `use`, struct, two `pub fn`s)
- Regenerate: `lib/src/bridge/*` and `rust/src/frb_generated.rs` (via codegen — do not hand-edit)

**Interfaces:**
- Consumes: `crate::patterns::{extract_close_target_range, close_target_should_fire}`, `crate::interpreter::Direction`.
- Produces (Rust): `pub struct CloseTarget { pub low: f64, pub high: f64 }`; `pub fn extract_close_target(text: String) -> Option<CloseTarget>`; `pub fn close_target_should_fire(direction: Direction, price: f64, low: f64, high: f64) -> bool`.
- Produces (Dart, generated in `lib/src/bridge/api.dart`): `class CloseTarget { double low; double high; }`, `Future<CloseTarget?> extractCloseTarget({required String text})`, `Future<bool> closeTargetShouldFire({required Direction direction, required double price, required double low, required double high})`.

- [ ] **Step 1: Add the Rust bridge surface**

In `rust/src/api/mod.rs`, extend the top-of-file `use crate::{…}` block to also import `Direction`:

```rust
use crate::{
    interpreter::{interpret, Action, Direction, InterpreterState},
    patterns::{
        close_target_should_fire as patterns_close_target_should_fire, default_rules,
        extract_close_target_range, match_actions, match_first, merge_pattern_documents,
        parse_pattern_document,
    },
    scaling::{scale_order, ScaleInput, ScaledOrder},
    telegram, weex, Size,
};
```

Add the struct near the other `ApiResult*` structs (after `ManualSizeUnit`, ~line 97):

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct CloseTarget {
    pub low: f64,
    pub high: f64,
}
```

Add the two functions near `classify_message` (~line 355):

```rust
pub fn extract_close_target(text: String) -> Option<CloseTarget> {
    extract_close_target_range(&text).map(|(low, high)| CloseTarget { low, high })
}

pub fn close_target_should_fire(direction: Direction, price: f64, low: f64, high: f64) -> bool {
    patterns_close_target_should_fire(direction, price, low, high)
}
```

- [ ] **Step 2: Verify Rust still builds**

Run: `cd rust && cargo build`
Expected: builds clean (no unused-import warnings — `Direction` and both patterns fns are now used).

- [ ] **Step 3: Regenerate the bridge**

Run: `flutter_rust_bridge_codegen generate`
Expected: updates `lib/src/bridge/*.dart` and `rust/src/frb_generated.rs`; exit 0.

- [ ] **Step 4: Verify the generated Dart symbols exist**

Run: `grep -n "extractCloseTarget\|closeTargetShouldFire\|class CloseTarget" lib/src/bridge/api.dart`
Expected: all three symbols present. Then `flutter analyze lib/src/bridge` → No issues.

- [ ] **Step 5: Commit**

```bash
git add rust/src/api/mod.rs rust/src/frb_generated.rs lib/src/bridge
git commit -m "feat(bridge): expose extractCloseTarget and closeTargetShouldFire"
```

---

### Task 4: Dart — CloseTargetWatch model + JSON round-trip

**Files:**
- Modify: `lib/src/models/trading.dart` (add class after `PriceCandle`, ~line 21)
- Test: `test/close_target_watch_test.dart` (create)

**Interfaces:**
- Produces: `class CloseTargetWatch { final double low; final double high; final String source; final DateTime armedAt; Map<String,Object> toJson(); static CloseTargetWatch? fromJson(Map<String,Object?>); }`

- [ ] **Step 1: Write the failing test**

Create `test/close_target_watch_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/models/trading.dart';

void main() {
  test('CloseTargetWatch round-trips through JSON', () {
    final watch = CloseTargetWatch(
      low: 63600,
      high: 63700,
      source: 'Telegram Signals',
      armedAt: DateTime.parse('2026-08-03T12:00:00.000Z'),
    );
    final restored = CloseTargetWatch.fromJson(watch.toJson());
    expect(restored, isNotNull);
    expect(restored!.low, 63600);
    expect(restored.high, 63700);
    expect(restored.source, 'Telegram Signals');
    expect(restored.armedAt, DateTime.parse('2026-08-03T12:00:00.000Z'));
  });

  test('CloseTargetWatch.fromJson returns null on malformed data', () {
    expect(CloseTargetWatch.fromJson({'low': 'nan'}), isNull);
    expect(CloseTargetWatch.fromJson(const {}), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/close_target_watch_test.dart`
Expected: FAIL — `CloseTargetWatch` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/src/models/trading.dart` after the `PriceCandle` class:

```dart
/// An armed advisory full-close price watch parsed from the signal channel.
/// [low]/[high] bound the target zone (low <= high). Held on the controller and
/// persisted so it survives an app restart.
class CloseTargetWatch {
  const CloseTargetWatch({
    required this.low,
    required this.high,
    required this.source,
    required this.armedAt,
  });

  final double low;
  final double high;
  final String source;
  final DateTime armedAt;

  Map<String, Object> toJson() => {
    'low': low,
    'high': high,
    'source': source,
    'armedAt': armedAt.toIso8601String(),
  };

  static CloseTargetWatch? fromJson(Map<String, Object?> json) {
    final low = json['low'];
    final high = json['high'];
    if (low is! num || high is! num) return null;
    final armedRaw = json['armedAt'];
    return CloseTargetWatch(
      low: low.toDouble(),
      high: high.toDouble(),
      source: json['source'] is String ? json['source'] as String : '',
      armedAt: (armedRaw is String ? DateTime.tryParse(armedRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/close_target_watch_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/models/trading.dart test/close_target_watch_test.dart
git commit -m "feat: add CloseTargetWatch model with JSON round-trip"
```

---

### Task 5: Dart — controller state, arm/disarm, persistence

**Files:**
- Modify: `lib/src/state/app_controller.dart` (fields near line 109-115; pref key near line 33; load in `loadConfig` ~line 122; methods)
- Test: `test/close_target_controller_test.dart` (create)

**Interfaces:**
- Consumes: `CloseTargetWatch` (Task 4).
- Produces: public field `CloseTargetWatch? closeTargetWatch`; public field `bool closeTargetTriggered`; `void armCloseTarget({required double low, required double high, required String source})`; `void cancelCloseTarget()`. Private: `void _disarmCloseTarget()`, `void _disarmCloseTargetIfFlat()`, `Future<void> _persistCloseTarget()`, `Future<void> _loadCloseTarget()`, const `_closeTargetPrefsKey`.

- [ ] **Step 1: Write the failing test**

Create `test/close_target_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('armCloseTarget stores a normalized watch and clears triggered', () {
    final c = AppController();
    c.closeTargetTriggered = true;
    c.armCloseTarget(low: 63600, high: 63700, source: 'Telegram');
    expect(c.closeTargetWatch, isNotNull);
    expect(c.closeTargetWatch!.low, 63600);
    expect(c.closeTargetWatch!.high, 63700);
    expect(c.closeTargetTriggered, isFalse);
  });

  test('a newer arm replaces the previous watch', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'a');
    c.armCloseTarget(low: 64000, high: 64100, source: 'b');
    expect(c.closeTargetWatch!.low, 64000);
    expect(c.closeTargetWatch!.source, 'b');
  });

  test('cancelCloseTarget disarms', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'a');
    c.cancelCloseTarget();
    expect(c.closeTargetWatch, isNull);
    expect(c.closeTargetTriggered, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/close_target_controller_test.dart`
Expected: FAIL — `armCloseTarget` / `closeTargetWatch` undefined.

- [ ] **Step 3: Write minimal implementation**

In `lib/src/state/app_controller.dart`:

Add the pref key next to `_configPrefsKey` (~line 33):

```dart
  static const _closeTargetPrefsKey = 'trading_challenge.close_target_watch.v1';
```

Add public fields next to `position` (~line 115):

```dart
  CloseTargetWatch? closeTargetWatch;
  bool closeTargetTriggered = false;
```

Add methods (e.g. just below `setSimulationMode`, ~line 1244):

```dart
  void armCloseTarget({
    required double low,
    required double high,
    required String source,
  }) {
    final lo = low <= high ? low : high;
    final hi = low <= high ? high : low;
    closeTargetWatch = CloseTargetWatch(
      low: lo,
      high: hi,
      source: source,
      armedAt: DateTime.now(),
    );
    closeTargetTriggered = false;
    _log(
      'Close-watch armed ${lo.toStringAsFixed(0)}–${hi.toStringAsFixed(0)} (from $source).',
    );
    unawaited(_persistCloseTarget());
    notifyListeners();
  }

  void cancelCloseTarget() {
    if (closeTargetWatch == null && !closeTargetTriggered) return;
    _disarmCloseTarget();
    _log('Close-watch cancelled.');
  }

  void _disarmCloseTarget() {
    closeTargetWatch = null;
    closeTargetTriggered = false;
    unawaited(_persistCloseTarget());
    notifyListeners();
  }

  Future<void> _persistCloseTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final watch = closeTargetWatch;
      if (watch == null) {
        await prefs.remove(_closeTargetPrefsKey);
      } else {
        await prefs.setString(_closeTargetPrefsKey, jsonEncode(watch.toJson()));
      }
    } catch (error, stackTrace) {
      _log('Close-watch could not be saved: $error',
          error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _loadCloseTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_closeTargetPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        closeTargetWatch = CloseTargetWatch.fromJson(decoded);
      }
    } catch (_) {
      // A corrupt cache is non-fatal; start disarmed.
    }
  }
```

In `loadConfig` (~line 122), after the config is restored and before `_initializePatterns()`, add:

```dart
      await _loadCloseTarget();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/close_target_controller_test.dart`
Expected: PASS. Then `flutter analyze lib/src/state/app_controller.dart` → No issues.

- [ ] **Step 5: Commit**

```bash
git add lib/src/state/app_controller.dart test/close_target_controller_test.dart
git commit -m "feat: close-target watch state, arm/disarm, and persistence"
```

---

### Task 6: Dart — arm from Telegram, evaluate on price tick, disarm on flatten

**Files:**
- Modify: `lib/src/state/app_controller.dart` (`handleIncomingTelegramMessage` ~line 461; `_applyWeexPrice` after `_markPositionToMarket(price)` ~line 1149; reconcile position set ~line 1240; `manualFlatten` sim branch; `_applyLocallyPlacedOrder` end)

**Interfaces:**
- Consumes: `rust.extractCloseTarget`, `rust.closeTargetShouldFire`, `rust_interpreter.Direction` (bridge, Task 3); `armCloseTarget`, `_disarmCloseTarget`, `closeTargetTriggered`, `closeTargetWatch` (Task 5).
- Produces: `void _maybeTriggerCloseTarget(double price)`, `void _disarmCloseTargetIfFlat()`, field `bool _evaluatingCloseTarget`.

- [ ] **Step 1: Add arming in the Telegram handler**

In `handleIncomingTelegramMessage`, after `rawText` is validated non-empty (right after the empty-guard block, ~line 468-473), add:

```dart
    if (useRustBridge) {
      try {
        final target = await rust.extractCloseTarget(text: rawText);
        if (target != null) {
          armCloseTarget(low: target.low, high: target.high, source: channel);
        }
      } catch (error, stackTrace) {
        await AppLog.write('Close-target extraction failed: $error',
            error: error, stackTrace: stackTrace);
      }
    }
```

- [ ] **Step 2: Add the trigger evaluator and hook it into the price tick**

Add the overlap-guard field next to `closeTargetTriggered` (~line 116):

```dart
  bool _evaluatingCloseTarget = false;
```

Add the method (near `armCloseTarget`):

```dart
  void _maybeTriggerCloseTarget(double price) {
    if (!useRustBridge) return;
    final watch = closeTargetWatch;
    if (watch == null || closeTargetTriggered || _evaluatingCloseTarget) return;
    if (price <= 0 || position.isFlat || position.direction == null) return;
    final direction = position.direction == TradeDirection.long
        ? rust_interpreter.Direction.long
        : rust_interpreter.Direction.short;
    _evaluatingCloseTarget = true;
    unawaited(
      rust
          .closeTargetShouldFire(
            direction: direction,
            price: price,
            low: watch.low,
            high: watch.high,
          )
          .then((fire) {
            if (fire && closeTargetWatch != null && !closeTargetTriggered) {
              closeTargetTriggered = true;
              _log(
                'Close-target reached ${watch.low.toStringAsFixed(0)}–${watch.high.toStringAsFixed(0)} at ${price.toStringAsFixed(2)} USDT.',
              );
              notifyListeners();
            }
          })
          .whenComplete(() => _evaluatingCloseTarget = false),
    );
  }
```

In `_applyWeexPrice`, immediately after `_markPositionToMarket(price);` (~line 1149) add:

```dart
    _maybeTriggerCloseTarget(price);
```

- [ ] **Step 3: Add disarm-on-flatten hooks**

Add the helper next to `_disarmCloseTarget` (in the block added in Task 5):

```dart
  void _disarmCloseTargetIfFlat() {
    if (closeTargetWatch != null && position.isFlat) {
      _disarmCloseTarget();
    }
  }
```

In `reconcileFromExchange`, right after the `position = PositionView(...)` assignment block completes (after the closing `);` at ~line 1240) add:

```dart
    _disarmCloseTargetIfFlat();
```

In `_applyLocallyPlacedOrder`, at the end of the reduce/close branch (just before its `return;` at ~line 1642) add:

```dart
      _disarmCloseTargetIfFlat();
```

In `manualFlatten`, in the simulation branch after `position = const PositionView(...)` is set (just before its `_log('Position flattened in simulation state…')`), add:

```dart
    _disarmCloseTargetIfFlat();
```

- [ ] **Step 4: Verify build + full suites**

Run: `flutter analyze lib` → No issues.
Run: `flutter test` → all pass.
Run: `cd rust && cargo test` → all pass.
Expected: green. (Trigger orchestration is thin glue over the Rust predicate, which is unit-tested in Task 2.)

- [ ] **Step 5: Commit**

```bash
git add lib/src/state/app_controller.dart
git commit -m "feat: arm close-watch from Telegram, evaluate on price tick, disarm on flatten"
```

---

### Task 7: Dart — live close-target confirmation dialog

**Files:**
- Modify: `lib/src/ui/app_shell.dart` (`_AppShellState`: add a shown-guard field ~line 22; add trigger detection in `build` next to the `pending` block ~line 30; add `_showCloseTargetDialog`)

**Interfaces:**
- Consumes: `controller.closeTargetTriggered`, `controller.closeTargetWatch`, `controller.position`, `controller.config.markPrice`, `controller.manualFlatten()`, `controller.cancelCloseTarget()`.

- [ ] **Step 1: Add the shown-guard field**

In `_AppShellState`, next to `String? _shownApprovalId;` (~line 22) add:

```dart
  bool _closeTargetDialogOpen = false;
```

- [ ] **Step 2: Detect the trigger in build**

In `build`, right after the existing `pending` block (the `if (pending != null …)` that calls `_showApproval`, ~line 30-38), add:

```dart
        if (widget.controller.closeTargetTriggered && !_closeTargetDialogOpen) {
          _closeTargetDialogOpen = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _showCloseTargetDialog(),
          );
        }
```

- [ ] **Step 3: Implement the live dialog**

Add to `_AppShellState` (near `_showApproval`, ~line 142):

```dart
  Future<void> _showCloseTargetDialog() async {
    if (!mounted) return;
    final controller = widget.controller;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Close-target reached'),
        content: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final watch = controller.closeTargetWatch;
            final position = controller.position;
            final live = controller.config.markPrice;
            return SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _kv(
                    'Target',
                    watch == null
                        ? '--'
                        : '${watch.low.toStringAsFixed(0)}–${watch.high.toStringAsFixed(0)} USDT',
                  ),
                  _kv('Live price', '${live.toStringAsFixed(2)} USDT'),
                  _kv('Side', position.direction?.name.toUpperCase() ?? 'FLAT'),
                  _kv('Size', '${position.qtyBtc.toStringAsFixed(4)} BTC'),
                  _kv(
                    'Unrealized P&L',
                    '${position.unrealizedPnlUsd.toStringAsFixed(2)} USDT',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Price reached the advisory close zone. This does not close '
                    'automatically — confirm to flatten, or dismiss to keep the '
                    'position open.',
                    style: TextStyle(color: Brand.muted),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.close),
            label: const Text('Close now'),
          ),
        ],
      ),
    );
    _closeTargetDialogOpen = false;
    if (result == true) {
      widget.controller.manualFlatten();
    }
    widget.controller.cancelCloseTarget();
  }
```

Note: `_kv` and `Brand` are already defined/imported in this file (used by `_showApproval`).

- [ ] **Step 4: Verify**

Run: `flutter analyze lib/src/ui/app_shell.dart` → No issues.
Run: `flutter test` → all pass (existing widget tests still green).

- [ ] **Step 5: Commit**

```bash
git add lib/src/ui/app_shell.dart
git commit -m "feat: live-updating close-target confirmation dialog"
```

---

### Task 8: Dart — armed-watch indicator + Cancel in the Reduce/Exit panel

**Files:**
- Modify: `lib/src/ui/dashboard_page.dart` (`_ManualReducePanelState.build` — insert an armed-watch row after the position summary text, before the mode `SegmentedButton`)

**Interfaces:**
- Consumes: `controller.closeTargetWatch`, `controller.cancelCloseTarget()`.

- [ ] **Step 1: Add the indicator widget**

In `_ManualReducePanelState.build`, capture the watch near the top (after `final position = controller.position;`):

```dart
    final watch = controller.closeTargetWatch;
```

Immediately after the position-summary `Text(...)` (the one showing "Open LONG …" / "No open position to reduce."), insert:

```dart
            if (watch != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Brand.surface2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Brand.border),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active_outlined,
                        color: Brand.gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Close-watch armed ${watch.low.toStringAsFixed(0)}–${watch.high.toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: controller.cancelCloseTarget,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ],
```

- [ ] **Step 2: Verify build**

Run: `flutter analyze lib/src/ui/dashboard_page.dart` → No issues.

- [ ] **Step 3: Manual smoke check (optional but recommended)**

Run: `flutter build linux --release` and confirm it builds. (Full interactive verification of the dialog is a runtime check; the logic paths are covered by Rust/Dart unit tests.)

- [ ] **Step 4: Run full suites**

Run: `flutter test` → all pass.
Run: `cd rust && cargo test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/ui/dashboard_page.dart
git commit -m "feat: show armed close-watch with cancel in the reduce/exit panel"
```

---

## Notes for the implementer

- **Persistence deviation from the spec:** the spec said "persisted in `AppConfig`". The plan instead uses a dedicated SharedPreferences key (`trading_challenge.close_target_watch.v1`) because `AppConfig.copyWith` uses `field ?? this.field`, which cannot express "set back to null" (disarm). A separate key is cleaner and keeps `AppConfig` unchanged. Behavior (survives restart, restored on load) is identical.
- **Bridge async:** `extractCloseTarget` / `closeTargetShouldFire` are async (Future). The price-tick evaluator calls the predicate fire-and-forget, guarded by `_evaluatingCloseTarget` (no overlapping calls) and `closeTargetTriggered` (fires once). If the Rust bridge is unavailable (`useRustBridge == false`), the watch never fires — acceptable, matching the app's reliance on Rust for parsing.
- **Deployment:** the new logic is compiled into the app (Rust + Dart); it does **not** touch the remote Telegram pattern YAML, so no Pi/node02 pattern republish is needed for this feature.
