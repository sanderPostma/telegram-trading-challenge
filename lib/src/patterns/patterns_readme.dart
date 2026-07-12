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

Named capture groups are interpreted by the app:

- btc: BTC quantity
- usd: USDT notional
- pct: percentage to reduce
- dir: LONG or SHORT
- trigger: optional limit trigger price

Separate instructions joined by AND are processed as separate actions. Test
changes with a sample Telegram message before publishing the YAML. Any AI
coding assistant such as ChatGPT, Claude, or Gemini can help generate or
review regex expressions from complete message samples. Ask it to preserve
the named capture groups and action semantics, then test the YAML before
publishing it.
''';
