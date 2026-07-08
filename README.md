# Telegram Challenge Copy-Trader

Desktop Flutter shell plus Rust core for a Telegram-driven WEEX BTCUSDT copy-trader.

Current implementation:

- Dashboard with live-style account stats, event log, order table, position panel, simulation and auto-approve toggles.
- Manual scaled entry panel with switchable USDT/BTC input and Open Long / Open Short actions.
- Approval dialog path for manual orders when auto-approve is off.
- Setup, settings, and configurable message pattern screens.
- Rust core modules for scaling, pattern matching, interpretation, idempotent dedup reservation, WEEX signing helpers, and slim execution types.
- `flutter_rust_bridge` v2 dependency, generated bindings, and cargokit desktop build integration.

Verification:

```sh
flutter analyze
flutter test
flutter build linux
cd rust && cargo test
```
