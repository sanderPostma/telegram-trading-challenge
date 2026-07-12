const embeddedTelegramPatternsYaml = r'''# Telegram message patterns for the Trading Challenge copy-trader.
#
# This is the fallback used when the remote pattern host is unavailable.
# Supported actions are enter, add, reduce, close, and ignore. Named capture
# groups can extract btc, usd, pct, dir, and trigger. Separate instructions
# joined by AND are evaluated as separate actions. "ADDED $5000 AND ADDING
# $5000 TO LIMIT TRIGGER AT 64,300" creates a market add and a conditional
# limit add. A LIMIT TRIGGER AT price clause creates a limit order.
# When a message does not match, give the complete message and this file to a
# browser-based AI assistant such as ChatGPT, Claude, or Gemini and ask for a
# minimal Rust-regex pattern that preserves these named groups and semantics.

version: 1
patterns:
  - name: entry
    regex: '(?i)\bSTARTED\b.*?(?P<btc>[\d.]+)\s*BTC.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 10
    enabled: true
  - name: add_usd
    regex: '(?i)\bADD(?:ED|ING)\b\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?'
    action: add
    priority: 20
    enabled: true
  - name: add_btc
    regex: '(?i)\bADD(?:ED|ING)\b\s*(?P<btc>[\d.]+)\s*BTC(?:\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?'
    action: add
    priority: 21
    enabled: true
  - name: reduce_pct
    regex: '(?i)\bREDUCE[D]?\b.*?(?P<pct>\d+)\s*%'
    action: reduce
    priority: 30
    enabled: true
  - name: close
    regex: '(?i)\b(CLOSED|CLOSE|EXIT|EXITED|FLAT|STOPPED OUT|TP HIT|TOOK PROFIT)\b'
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
