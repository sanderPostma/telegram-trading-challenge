# Telegram Challenge Copy-Trader

> ⚠️ **Note:** This project is currently under active construction and development. Features and APIs may change.

A high-performance, automated copy-trading desktop application designed to monitor Telegram channels for trading signals and perfectly mirror them on the WEEX exchange. Built with a sleek Flutter interface and powered by a lightning-fast Rust core.

## Risk Disclaimer

This software does not provide financial, investment, legal, or tax advice. Trading, including automated and copy trading, can result in substantial losses. You are solely responsible for your trading decisions, API credentials, exchange configuration, and any orders submitted through this application. Use it at your own risk.

Before using real funds, independently review and test the application, its configuration, and its order behavior. You may use any AI coding agent and/or a qualified software-security or financial professional to vet the application. Nothing in this repository guarantees signal quality, trade execution, profitability, or protection from loss.

> [!CAUTION]
> **Do not enable Auto-Approve on multiple devices at the same time.** Each device has its own local Telegram deduplication state; there is currently no shared cross-device lease. Multiple devices can therefore process the same Telegram message and submit duplicate trades to the same WEEX account.

## 🚀 Features

- **Automated Telegram Monitoring:** Connects directly to Telegram to instantly intercept and parse incoming trade signals (Entries, Adds, Reduces, Closes, Take Profits, Stop Losses).
- **Proportional Size Scaling:** Automatically scales trade sizes to your WEEX balance based on the Master/Challenge account balance ratio, ensuring risk management matches the master account perfectly.
- **Lightning-Fast Rust Core:** Order parsing, signature generation, idempotent deduplication, and execution are handled by an optimized Rust backend for maximum speed and reliability.
- **Simulation & Paper Trading:** Test your setup safely using a built-in simulation mode that tracks hypothetical execution and PnL without risking real capital.
- **Approval Workflows:** Toggle "Auto-Approve" on to automatically mirror trades, or turn it off to manually review, adjust, and approve incoming parsed signals via a dialog before execution.
- **Live Position & Balance Tracking:** Full graphical dashboard tracking live WEEX balance staircases, unrealized PnL, mark prices, and open positions directly in the app.
- **Customizable Pattern Matching:** Configure and fine-tune your own Regex rules to adapt to different Telegram signal providers seamlessly.

## 🛠 Tech Stack

- **Frontend UI:** Flutter (Desktop Linux/macOS/Windows)
- **Backend / Execution Engine:** Rust
- **Integration:** `flutter_rust_bridge` (v2) for zero-latency FFI between the UI and execution core.

## ⚙️ How It Works

1. **Listen:** The app establishes a connection to Telegram to monitor incoming messages in real-time.
2. **Parse:** Rust-based Regex pattern matchers scan the messages for actionable trade signals.
3. **Scale:** The exact order size is calculated based on the proportional difference between your local WEEX balance and the master's stated balance.
4. **Execute:** The order is securely signed locally in Rust and dispatched to the WEEX API for instant execution.
5. **Reconcile:** The app continually polls WEEX to verify order fills, sync the latest balance, and map PnL to your historical equity chart.

## ⬇️ Downloading, Installing & Running

Prebuilt desktop bundles for every tagged version are on the
[**Releases page**](https://github.com/sanderPostma/telegram-trading-challenge/releases).
Download the asset for your platform from the latest release:

| Platform | Asset |
| --- | --- |
| Linux (x64) | `trading-challenge-linux-x64.tar.gz` |
| Windows (x64) | `trading-challenge-windows-x64.zip` |
| macOS | `trading-challenge-macos.zip` |

There is no installer. Each asset is a self-contained bundle — unpack it wherever you like and run it from there. Keep the executable together with the `lib/` and `data/` folders next to it; moving the executable out on its own will not work.

### Linux

```bash
mkdir -p ~/apps/trading-challenge
tar -xzf trading-challenge-linux-x64.tar.gz -C ~/apps/trading-challenge
~/apps/trading-challenge/trading_challenge
```

The bundle needs GTK 3 and the app-indicator library for the tray icon. On Debian/Ubuntu:

```bash
sudo apt-get install libgtk-3-0 libayatana-appindicator3-1
```

To get a desktop launcher entry, create `~/.local/share/applications/trading-challenge.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Trading Challenge Copy-Trader
Exec=/home/YOUR_USER/apps/trading-challenge/trading_challenge
Terminal=false
Categories=Office;Finance;
```

### Windows

Unzip `trading-challenge-windows-x64.zip` and run `trading_challenge.exe` from the extracted folder.

The binary is unsigned, so SmartScreen shows "Windows protected your PC" on first launch. Choose **More info → Run anyway** if you trust the download.

### macOS

Unzip `trading-challenge-macos.zip` and move `trading_challenge.app` to `/Applications`.

The app is neither signed nor notarized, so Gatekeeper blocks it on first launch. Either right-click the app and choose **Open** (then confirm), or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/trading_challenge.app
```

### First run

The setup wizard asks for your WEEX API key, secret, and passphrase, plus your Telegram phone number, API ID, and API hash (from [my.telegram.org](https://my.telegram.org)). Telegram sends a login code you enter in the app.

Credentials are encrypted into your local application data directory — `~/.local/share/com.atomicvoid.tradingchallenge` on Linux, `~/Library/Application Support/com.atomicvoid.tradingchallenge` on macOS, `%APPDATA%\com.atomicvoid.tradingchallenge` on Windows. See [Security & Keys](#-security--keys) below.

Before trading real funds:

- Leave **Simulation mode** on until you have watched it parse live signals correctly.
- Leave **Auto-approve** off until you trust the parsing.
- Set the **Risk limits** in Settings — they are all off by default.
- Use a WEEX API key with **withdrawals disabled**.
- Run **one** auto-approving instance per exchange account. There is no cross-device lock.

### Verifying a download

Release assets are built by [GitHub Actions](.github/workflows/build-binaries.yml) from the tagged commit; the run and its logs are public under the Actions tab. They are not code-signed. If you would rather not trust a prebuilt binary, build from source as below — the result is equivalent apart from the credential-sealing key.

## 📦 Building & Running

### Requirements
- Flutter SDK (latest stable)
- Rust toolchain (`rustup`)
- WEEX API Keys (generated via your WEEX account)
- Telegram API ID & Hash (generated via my.telegram.org)

### Build Instructions

To build the desktop application, standard Flutter and Cargo commands apply:

```bash
# Get Flutter dependencies
flutter pub get

# Generate Rust/Dart bindings (if modifying the Rust API)
flutter_rust_bridge_codegen generate

# Build for your desktop platform (e.g. Linux)
flutter build linux

# (Optional) Run Rust tests
cd rust && cargo test
```

## 🔒 Security & Keys
Your WEEX API keys and Telegram credentials are **only stored locally** on your device. The app communicates directly with Telegram and WEEX without any intermediate servers. Order signing is performed locally within the Rust core.

**What is protected so far.** Credentials are encrypted at rest with XChaCha20-Poly1305 in `credentials.enc`, sealed by a key combining an application-embedded half with a random per-install key file (`credentials.key`, mode 0600) — neither half opens the blob alone, so a copied backup or synced folder without the key file is inert. No passphrase is required. Released binaries bake their embedded half in at compile time from a repository secret, so it is not readable in the source; builds made without that secret fall back to an in-source default and work unchanged, and a released binary can still open credentials sealed by such a build. The data directory and the Telegram session file are tightened to owner-only. Every order — signal-driven, auto-approved, or manual — passes a hard risk gate in Rust (`rust/src/risk.rs`) before reaching WEEX: kill switch, per-order size cap, total exposure cap, symbol allowlist, leverage cap, daily loss limit, and a stale-signal cutoff. Every numeric limit is off until you set it, and the size and loss caps accept either an absolute amount (`5000`) or a share of account balance (`15%`) — the percentage form holds its meaning as the account grows. Closing a position is never blocked by a limit. Deduplication state is written atomically (temp file, fsync, rename), and actions left unfinished by a crash are checked against WEEX by client order id at startup — confirmed, written off, or reported, but never blindly retried.

**What is not protected.** Encryption at rest does not stop malware running as your user, which can read the key file exactly as the app does. There is no defence against a compromised Telegram source channel: anyone who can post there can move your position, subject only to the risk limits above. Use an API key without withdrawal permission, keep the limits set, and run exactly one auto-approving instance per exchange account.
