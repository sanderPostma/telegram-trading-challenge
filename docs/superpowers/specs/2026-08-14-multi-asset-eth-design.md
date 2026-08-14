# Multi-Asset Support: ETH Alongside BTC

Date: 2026-08-14
Status: Approved for planning

## Problem

The app is single-asset by construction. BTC is not a configuration value; it is
baked into the type system, the field names, the regex grammar, the exchange
symbol, and every UI label. Roughly 400 call sites across Rust and Dart assume
one asset.

The structural gap is in the core types: `RuleHit` (`rust/src/patterns.rs:36`)
and `Action` (`rust/src/interpreter.rs:32`) carry no symbol field at all, so a
parsed signal cannot express which asset it refers to. Everything downstream
inherits that limitation.

The trigger is a live signal the channel posted:

```
10 ETH LONG
```

Two separate problems in one line: a new asset, and a message shape that would
not match even as `10 BTC LONG`. Entry rules require a verb
(`STARTED|OPENING|OPENED`) or a `$`/k-m suffix, and `rust/src/patterns.rs:448`
explicitly asserts that a bare `"BTC LONG is looking good here"` produces no
action.

## Decisions

Settled during brainstorming:

1. **Concurrent positions, one per asset.** BTC and ETH can be open
   simultaneously. Position state, close-target watching, and the dashboard are
   currently built around a single open position and must be keyed by symbol.
2. **A two-variant enum, not a general registry.** `Asset { Btc, Eth }`. The
   compiler then locates every site needing a new arm — valuable across ~400
   call sites in code that submits real orders. A third asset reopens these
   files; that cost is accepted.
3. **Verbless bare-quantity entry rule**, anchored at both ends (see Grammar).
4. **Order-size caps are USDT notional**, not per-asset quantity.
5. **Dashboard is a combined positions table plus a detail pane.**
6. **The parser must keep ignoring long messages** — as an explicit guard, not
   as an emergent property.

## Core Model (Rust)

A new `Asset` enum in `interpreter.rs`, beside `Size` rather than inside it:

```rust
pub enum Asset { Btc, Eth }
```

With: `aliases()` (`BTC|XBT|BITCOIN`, `ETH|ETHER|ETHEREUM`), `symbol()` →
`"BTCUSDT"`/`"ETHUSDT"`, `display()` → `"BTC"`/`"ETH"`, `qty_step()`,
`price_step()`.

`Size` loses all asset knowledge:

```rust
pub enum Size { Usdt(f64), Coin(f64), Pct(f64), FullClose }
```

`Size::Btc` → `Size::Coin` (magnitude only; the asset travels beside it).
`Size::Usd` → `Size::Usdt`, so the codebase stops using two names for the quote
currency.

`asset: Asset` is added to the four pipeline types:

| Type | Location |
| --- | --- |
| `RuleHit` | `rust/src/patterns.rs:36` |
| `Action` | `rust/src/interpreter.rs:32` |
| `ScaledOrder` | `rust/src/scaling.rs:14` |
| `OrderIntent` | `rust/src/risk.rs:158` |

### Renames

- `qty_btc` → `qty` (`scaling.rs`, `risk.rs:158`, `api/mod.rs:328`)
- `scaled_btc` → `scaled_qty` (`scaling.rs:14`)
- `max_order_qty_btc` → removed (see Config Upgrade)
- `ManualSizeUnit::Btc` → `ManualSizeUnit::Coin` (`api/mod.rs:121`)

### Ambiguous asset inheritance — fail closed

`interpret()` (`interpreter.rs:48`) carries the last direction and size forward
when a message omits them, so `REDUCE 0.2` inherits from the prior signal. Asset
must join that inheritance, which creates a failure mode that does not exist
today: a bare `REDUCED 0.2` after both a BTC and an ETH signal is genuinely
ambiguous.

Rule: where a message names an asset, inheritance is scoped to that asset. Where
it does not, the action inherits from the most recent signal — but is
**rejected, not guessed**, if two assets have been active within the message
window. Dropping an ambiguous reduce is preferable to reducing the wrong book.

## Grammar

### What actually makes the parser ignore long messages

There is no length check anywhere in the parser. Two narrower mechanisms do the
work:

1. **Line-anchoring** — every trade verb must sit at the start of a line (`^`).
   Real signals are terse commands on their own line; narrative buries the verb
   mid-sentence (`config/telegram_patterns.yaml:26-28`).
2. **The `hypothetical` guard** (`config/telegram_patterns.yaml:57`) — a
   message-level veto on `should've / would have / if I had / wish I / imagine /
   for example / what if / hypothetical`.

### The tension

The verb is precisely what the line-anchor was protecting. `^STARTED` is a
strong signal because narrative rarely opens a line with a trade verb.
`^10 ETH LONG` is a much weaker anchor: a line beginning `10 ETH LONG was the
right call yesterday` matches it, and no guard word appears to veto it. A
start-anchored-only verbless rule would measurably widen what the parser accepts
from long messages.

### Resolution — anchor at both ends

```
(?im)^\s*(?P<qty>[\d.]+)\s*(?P<asset>BTC|XBT|BITCOIN|ETH|ETHER|ETHEREUM)\s+(?P<dir>LONG|SHORT)\s*[.!]?\s*$
```

The whole line must be the signal and nothing else. `10 ETH LONG` fires;
`10 ETH LONG was the right call` does not. A real signal with a trailing comment
will not fire — the correct failure direction for an app that submits real
orders.

### Explicit length guard

A new message-level guard treats over-long messages as narrative and vetoes them
outright, making the ignore-long-messages property real rather than emergent.
Threshold to be validated against the existing test corpus in `patterns.rs`
before being fixed; starting point is 3 lines / 200 characters. It must not
break the compound `... AND ADDING ...` form or messages carrying an
`Account balance $10,000` status line.

### Asset capture on existing rules

Every existing rule gains an optional `(?P<asset>...)` group over the alias set.
Where the asset is currently matched and discarded as filler
(`entry_verbless:92`, `entry_verbless_short:97`, the
`(?:\s+(?:SCALP|BITCOIN|BTC|XBT))*` lists at `:112` and `:117`), the alias set
widens to include ETH and the group is captured rather than dropped. Where BTC
is a *unit suffix* on a quantity (`entry:69`, `add_btc:117`,
`reduce_btc:129`) it stays load-bearing and the rule is generalised to any
asset alias, with `add_btc`/`reduce_btc` renamed `add_coin`/`reduce_coin`.

The `usd`-before-`btc` precedence in `parse_size` (`patterns.rs:229-247`) and
the priority ordering (`add_btc` 20 beats `add_usd` 21; `entry` 10 beats
`entry_usd_short` 12) exist purely to disambiguate "BTC as unit" from "BTC as
asset name". This must be preserved for both assets.

### Rule renames orphan local overrides

Remote and local pattern documents merge by rule *name*
(`merge_pattern_documents`, `patterns.rs:67-88`). Renaming `add_btc` →
`add_coin` silently orphans any user's local override of the old name. The
migration must detect v1 rule names in `telegram_patterns.local.yaml` and warn
rather than silently ignore them.

### Three synced copies

The grammar exists in three hand-synced places, all of which change together:

- `config/telegram_patterns.yaml` (source of truth, `include_str!`-ed at
  `patterns.rs:49-51`)
- `lib/src/patterns/default_patterns.dart` (duplicated Dart string)
- `lib/src/patterns/patterns_readme.dart:72` (user-facing docs)

Plus the node02 ConfigMap rollout for the remote copy.

`patterns.rs:710` asserts `rules.len() == 15` and needs updating.

## Risk Gate

`maxOrderNotional` already exists as a percent-capable notional cap
(`lib/src/models/trading.dart:198`), and `max_order_qty_btc` is a *second,
separate* quantity rail layered on top. Making caps asset-neutral is therefore
mostly a removal, not a conversion.

- `max_order_qty_btc` / `maxOrderQtyBtc` is removed.
- `maxOrderNotional`, `maxPositionNotional`, and `dailyLoss` are already
  notional and need no semantic change.
- The user-facing message at `risk.rs:204` (`"order size {:.4} BTC exceeds…"`)
  becomes notional and asset-neutral.
- `hasAnyLimit` (`trading.dart:217`) drops its `maxOrderQtyBtc` term. A user
  whose only armed rail was that cap correctly starts getting the "no limits
  set" nag again.
- Total exposure is evaluated across both assets combined, since it is an
  account-level rail.

## Config Upgrade

No schema version exists today; migrations are ad-hoc key fallbacks
(`json['maxOrderNotional'] ?? json['maxOrderNotionalUsd']`, `trading.dart:264`).
Add an explicit `configVersion` int, defaulting to `1` when absent, with one
migration step to `2`.

Guiding stance: **never silently widen or drop a safety rail.**

### 1. `symbolAllowlist` blocks ETH outright

The default and the stored value for every existing user is `['BTCUSDT']`
(`trading.dart:201`, `:275`), enforced case-insensitively at
`risk.rs:169-183`. After upgrade every ETH signal is rejected by the risk gate
while the UI shows ETH as supported. This applies even to users who never
configured anything, because it is the *default*.

`ETHUSDT` is **not** auto-added. Migration raises a one-time explicit prompt in
Settings — *"ETH support was added. Your symbol allowlist currently permits
BTCUSDT only, so ETH signals will be rejected. Add ETHUSDT?"* — with the
allowlist unchanged until answered.

### 2. Removing `maxOrderQtyBtc` can silently loosen protection

If `maxOrderQtyBtc = 0.5` and `maxOrderNotional` is off, deleting the field
leaves no per-order cap at all.

Migration rule: if `maxOrderQtyBtc > 0`, convert it to a notional using the BTC
mark price at migration time and write it into `maxOrderNotional` **only if
that is currently off**. If both are set, keep `maxOrderNotional` and discard
the quantity rail. Either way, record the outcome and surface it in Settings for
acknowledgement. If no mark price is available, leave the config unmigrated and
retry rather than guessing.

### 3. Local pattern overrides

See "Rule renames orphan local overrides" above.

## Contract Specs

`qty_step` and `price_step` are config constants defaulting to BTC's `0.0001` /
`0.1` (`weex.rs:268-270`), and Dart re-hardcodes the same numbers in about
twelve places (`app_controller.dart:68, 522, 556, 823, 904, 2251, 2323, 2330,
2338, 2434, 2463`, plus `priceStep: 0.1` at `:1663`, `:2435`).

- Steps move behind `Asset::qty_step()` / `Asset::price_step()` in Rust.
- Dart sources them from Rust rather than redeclaring them, so the two sides
  cannot drift.
- **ETH's actual WEEX steps must be confirmed from the exchange's contract
  endpoint, not guessed.** Wrong rounding silently misprices orders. This is a
  blocking prerequisite for the execution work.

## UI

A combined positions table plus detail pane.

- **Positions table** (new, top of dashboard): one row per open asset — asset,
  direction, qty, mark, unrealized PnL. Selecting a row drives the detail pane.
- **Account-level elements stay shared**: balance, equity staircase, and the
  balance-ratio header are already account-scoped.
- **Detail pane**: today's dashboard body rendered for the selected asset.
  Manual-entry, reduce, and close-target controls move inside it and act on that
  asset.
- **Labels stop being literals**: `'WEEX BTC live'` (`dashboard_page.dart:203`),
  `'Scaled BTC'` (`:509`), `'Reduce BTC'` (`:728`), `'Remaining BTC'`
  (`:761-764`), `:478`, `:634`, `:678`, `:709`, `:916`, and
  `app_shell.dart:166, 229` all become `asset.display()`-driven — as do the ~15
  log strings in `app_controller.dart` that hardcode `" BTC"`.
- **Enums**: `SizeUnit { btc, usdt }` → `{ coin, usdt }` (`trading.dart:3`);
  `_ReduceMode { percent, usdt, btc }` → `{ percent, usdt, coin }`
  (`dashboard_page.dart:569`). Segmented buttons label from the selected asset.
- **Settings** gains the allowlist prompt from Config Upgrade.

## Plumbing

- Hardcoded `symbol: 'BTCUSDT'` at `app_controller.dart:1153, 1653, 1717, 2087,
  2426, 2457` becomes per-asset.
- REST URLs with `symbol=BTCUSDT` inlined at `app_controller.dart:3025, 3044,
  3073` become per-asset.
- The price WS at `api/mod.rs:158` hardcodes `"BTCUSDT"` and needs a second
  subscription; channel names at `weex.rs:1152-1154` follow.
- `WeexConfig::default()` (`weex.rs:268`) stops defaulting to a single symbol.
- The blank-symbol fallback to `"BTCUSDT"` at `weex.rs:637` is removed; a blank
  symbol becomes an error rather than a silent BTC order.
- Dedup keys (`dedup.rs`) and in-flight action recovery must include the asset,
  or a BTC and an ETH action could collide.

## Testing

- **Rust**: `Asset` alias parsing; both-ends anchoring accepts `10 ETH LONG` and
  rejects `10 ETH LONG was the right call`; the length guard; ambiguous-asset
  inheritance is rejected; `patterns.rs:448` (bare mention inert) still passes;
  per-asset rounding; risk gate with a mixed-asset allowlist; combined exposure
  across assets.
- **Dart**: v1 → v2 config round-trip for each migration branch; the allowlist
  prompt appears and does not auto-widen; positions table with zero, one, and
  two open positions; label rendering per asset.
- `test/widget_test.dart:35` (`find.text('BTC')`) and
  `test/lot_rounding_test.dart` need updating for the new UI and steps.

## Explicitly Out of Scope

- A general asset registry or config-driven asset list (decision 2).
- Any third asset.
- Cross-device position leasing (the existing single-instance caveat is
  unchanged and still applies per README).

## Open Questions

1. **The screenshot of the triggering message was never received.** The
   both-ends anchoring is designed from the paraphrase `10 ETH LONG`. If the
   real message carries trailing text, the rule will not fire and the anchoring
   must be revisited.
2. Exact length-guard threshold, pending validation against the test corpus.
3. ETH's real WEEX `qty_step` / `price_step`.
