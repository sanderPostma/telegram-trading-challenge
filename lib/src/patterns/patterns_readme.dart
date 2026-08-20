const telegramPatternsReadme = '''Telegram pattern configuration
================================

The app writes these files to the Trading Challenge user profile:

- telegram_patterns.embedded.yaml: the compiled fallback patterns
- telegram_patterns.remote.yaml: the last validated remote download
- telegram_patterns.remote.etag: the remote HTTP ETag
- telegram_patterns.local.yaml: your additions and overrides

The app reads the remote file, or the embedded file if remote data is not
available, and then merges telegram_patterns.local.yaml on top. A local rule
with the same name replaces the remote rule; a new name is added. Remote
updates therefore do not erase local changes.

Danger: multiple devices
------------------------

Do not enable Auto-Approve on multiple devices at the same time. Each device
has its own local Telegram deduplication state; there is currently no shared
cross-device lease. Multiple devices can therefore process the same Telegram
message and submit duplicate trades to the same WEEX account.

Remote source:
https://telegram-patterns.sander.dnsrouter.nl/telegram_patterns.yaml

Using an AI coding assistant
----------------------------

When a Telegram message is not recognized, give your chatbot the complete
Telegram message text together with both of these files:

telegram_patterns.README.txt
telegram_patterns.local.yaml

Ask ChatGPT, Claude, Gemini, or another coding agent to propose the smallest
pattern addition or override that handles the message. Alternatively, point
your coding agent directly at both files and provide the message as the test
case. The README explains the supported YAML format, merge behavior, named
capture groups, AND handling, and LIMIT TRIGGER AT handling. Review and test
the result before publishing changes to the remote pattern host.

The YAML document must contain a version and a patterns list. Each pattern has:

- name: a stable descriptive name
- regex: a Rust regex expression
- action: enter, add, reduce, close, or ignore
- priority: lower numbers win when matches start at the same position
- enabled: true or false

Supported actions are enter, add, reduce, close, and ignore. Separate
instructions joined by AND are evaluated as separate actions. For example,
"ADDED \$5000 AND ADDING \$5000 TO LIMIT TRIGGER AT 64,300" creates one market
add and one conditional limit add. A LIMIT TRIGGER AT price clause creates a
limit order; without it the order is sent at market.

Not everything is driven by these patterns. Take-profit targets are matched in
code, not in this YAML: "TP SET 64450" (also "TP: 64450", "TAKE PROFIT SET AT
64450", "target for full close is 63600-63700", and ranges) places a real TP on
WEEX for the open position, in whichever direction it runs. The plan carries no
size, so the exchange closes the entire position when the trigger is reached —
including anything added afterwards — without asking. It keeps working while
the app is closed. Replacing a target cancels the previous one first.

If there is no open position, or the app is in simulation mode, or WEEX rejects
the plan, the target falls back to an app-side close-watch that asks you to
confirm when the price gets there. "TP HIT" reports a fill and is a close
signal, handled by the close pattern below.

Named capture groups are interpreted by the app:

- qty: quantity of the traded coin (`btc` is still accepted, from older rules)
- asset: which coin — BTC, XBT, BITCOIN, ETH, ETHER, or ETHEREUM
- usd: USDT notional
- pct: percentage to reduce
- dir: LONG or SHORT
- trigger: optional limit trigger price

BTC and ETH are both tradable and can be open at the same time. Where a rule
does not capture `asset` itself, the app reads the coin named anywhere in the
message — but only if exactly one coin is named. A message mentioning both is
ambiguous and produces no trade.

A message that names no coin at all inherits the open position's, and is sent
for manual review rather than guessed when both books are open. "REDUCED 25%"
is therefore unambiguous with one position open and needs review with two.

Two rules protect against narrative being read as a signal. Trade verbs must
start a line, and the verbless shorthand ("10 ETH LONG") must be the entire
line — "10 ETH LONG was the right call" does not trade. Messages longer than
four lines or 320 characters are treated as discussion and ignored outright.

An exit stated subject-first ("trade closed", "eth position closed") has no
verb at the line start to anchor, so it follows the verbless rule: the whole
line must be the signal. "the trade closed at a loss yesterday" does not
trade, and neither does "trade closed in profit" — a trailing comment costs
the signal, which is the safer way to be wrong.

Separate instructions joined by AND are processed as separate actions. Test
changes with a sample Telegram message before publishing the YAML. Any AI
coding assistant such as ChatGPT, Claude, or Gemini can help generate or
review regex expressions from complete message samples. Ask it to preserve
the named capture groups and action semantics, then test the YAML before
publishing it.
''';
