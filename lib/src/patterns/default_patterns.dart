const embeddedTelegramPatternsYaml = r'''# Telegram message patterns for the Trading Challenge copy-trader.
#
# This is the fallback used when the remote pattern host is unavailable. It is
# kept in sync with config/telegram_patterns.yaml (the Rust embedded copy).
# Supported actions are enter, add, reduce, close, ignore, and guard. Named
# capture groups can extract btc, usd, pct, dir, and trigger. Separate
# instructions joined by AND are evaluated as separate actions. "ADDED $5000
# AND ADDING $5000 TO LIMIT TRIGGER AT 64,300" creates a market add and a
# conditional limit add. A LIMIT TRIGGER AT price clause creates a limit order.
#
# Past-tense / hypothetical safety: trade verbs are anchored to the start of a
# line (real signals are terse commands), and a `guard` action vetoes the whole
# message when conditional wording ("should have", "if I had", "for example")
# is present, so commentary never trades. Rust regex has no lookbehind.
# When a message does not match, give the complete message and this file to a
# browser-based AI assistant such as ChatGPT, Claude, or Gemini and ask for a
# minimal Rust-regex pattern that preserves these named groups and semantics.

version: 1
patterns:
  - name: hypothetical
    regex: '(?i)\b(?:should|would|could)(?:''ve|ve|\s+(?:have|of))\b|\bif\s+i\s+(?:had|would|were)\b|\bwish\s+i\b|\bimagine\b|\bfor\s+(?:example|instance)\b|\bwhat\s+if\b|\bhypothetical'
    action: guard
    priority: 1
    enabled: true
  - name: entry
    regex: '(?im)^\s*(?:STARTED|OPENING|OPENED)\b.*?(?P<btc>[\d.]+)\s*BTC.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 10
    enabled: true
  - name: entry_usd
    regex: '(?im)^\s*(?:OPENING|OPENED|STARTED)\b.*?\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM])\b)?.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 11
    enabled: true
  - name: entry_usd_short
    regex: '(?im)^\s*(?:OPENING|OPENED|STARTED)\b.*?\b(?P<usd>[\d,]+(?:\.\d+)?)\s*(?P<mult>[KM])\b.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 12
    enabled: true
  - name: entry_verbless
    regex: '(?im)^\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM]))?\s*(?:BTC|XBT|BITCOIN)\b[^\n]*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 13
    enabled: true
  - name: entry_verbless_short
    regex: '(?im)^\s*(?P<usd>[\d,]+(?:\.\d+)?)\s*(?P<mult>[KM])\s*(?:BTC|XBT|BITCOIN)\b[^\n]*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 14
    enabled: true
  - name: add_usd
    regex: '(?im)(?:^|\bAND\s+)\s*ADD(?:ED|ING)\b\s*\$?(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM])\b)?(?:(?:\s+(?:SCALP|BITCOIN|BTC|XBT))*\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?'
    action: add
    priority: 21
    enabled: true
  - name: add_btc
    regex: '(?im)(?:^|\bAND\s+)\s*ADD(?:ED|ING)\b\s*(?P<btc>[\d.]+)\s*BTC(?:(?:\s+(?:SCALP|BITCOIN|BTC|XBT))*\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?'
    action: add
    priority: 20
    enabled: true
  - name: reduce_usd
    regex: '(?im)^\s*REDUC(?:E|ED|ING)\b\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM])\b)?'
    action: reduce
    priority: 30
    enabled: true
  - name: reduce_btc
    regex: '(?im)^\s*REDUC(?:E|ED|ING)\b\s*(?P<btc>[\d.]+)\s*BTC'
    action: reduce
    priority: 31
    enabled: true
  - name: reduce_pct
    regex: '(?im)^\s*REDUC(?:E|ED|ING)\b.*?(?P<pct>\d+)\s*%'
    action: reduce
    priority: 32
    enabled: true
  - name: reduce_taking_pct
    regex: '(?im)^\s*TAKING\s+(?P<pct>\d+)\s*%\s+OUT\b'
    action: reduce
    priority: 33
    enabled: true
  - name: close
    regex: '(?im)^\s*(CLOSED|CLOSING|CLOSE|EXIT|EXITED|FLAT|STOPPED OUT|TP HIT|TOOK PROFIT)\b'
    action: close
    priority: 40
    enabled: true
  - name: noop
    regex: '(?i)\b(TRADE UPDATE|CHAT TEST|NOTIFICATIONS|GOOD MORNING)\b'
    action: ignore
    priority: 90
    enabled: true
''';

const localTelegramPatternsTemplate = '''# User Telegram pattern overrides and additions.
#
# The application merges this file after the embedded or remote patterns.
# Matching names replace the corresponding remote pattern; new names are
# appended. Leave this list empty to use the remote patterns unchanged.
# See telegram_patterns.README.txt for the complete format and examples.

version: 1
patterns: []
''';
