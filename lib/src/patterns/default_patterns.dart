const embeddedTelegramPatternsYaml = r'''# Telegram message patterns for the Trading Challenge copy-trader.
#
# This is the fallback used when the remote pattern host is unavailable. It is
# kept in sync with config/telegram_patterns.yaml (the Rust embedded copy).
# Supported actions are enter, add, reduce, close, ignore, and guard. Named
# capture groups can extract qty, asset, usd, pct, dir, and trigger. Separate
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

version: 2
patterns:
  # --- Guard: message-level veto for hypothetical / discussion posts. --------
  - name: hypothetical
    regex: '(?i)\b(?:should|would|could)(?:''ve|ve|\s+(?:have|of))\b|\bif\s+i\s+(?:had|would|were)\b|\bwish\s+i\b|\bimagine\b|\bfor\s+(?:example|instance)\b|\bwhat\s+if\b|\bhypothetical'
    action: guard
    priority: 1
    enabled: true
  # --- Trade signals (verb anchored to line start). -------------------------
  # Entry verbs cover both the terse past-tense channel style ("STARTED 0.5BTC
  # SHORT") and the newer scalp style ("OPENING $50000 SCALP BITCOIN LONG",
  # "OPENED $30,000 SCALP SHORT BTC"). entry captures a BTC quantity; entry_usd
  # captures a USD notional. Filler between the amount and the direction is
  # skipped by `.*?`, so the asset may sit on either side of SHORT/LONG.
  - name: entry
    regex: '(?im)^\s*(?:STARTED|OPENING|OPENED)\b.*?(?P<qty>[\d.]+)\s*(?P<asset>BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH)\b.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 10
    enabled: true
  - name: entry_usd
    regex: '(?im)^\s*(?:OPENING|OPENED|STARTED)\b.*?\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM])\b)?.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 11
    enabled: true
  # Shorthand notional without a "$": the k/m suffix is what marks the number as
  # dollars ("opened 20k btc long" = $20,000 of BTC). A bare quantity keeps its
  # BTC reading through the `entry` rule, which wins the tie on priority.
  - name: entry_usd_short
    regex: '(?im)^\s*(?:OPENING|OPENED|STARTED)\b.*?\b(?P<usd>[\d,]+(?:\.\d+)?)\s*(?P<mult>[KM])\b.*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 12
    enabled: true
  # Verbless headline entry: "$20,000 BTC LONG FOR CHALLENGE". The amount must
  # open the line and be followed by the asset and a direction, so PnL prose
  # ("$20,000 profit ...") does not open a position. Only an explicit "$" or a
  # k/m suffix marks the number as a notional; a bare "0.5 BTC LONG" headline
  # stays unmatched rather than being read as $0.50.
  - name: entry_verbless
    regex: '(?im)^\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM]))?\s*(?P<asset>BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH)\b[^\n]*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 13
    enabled: true
  - name: entry_verbless_short
    regex: '(?im)^\s*(?P<usd>[\d,]+(?:\.\d+)?)\s*(?P<mult>[KM])\s*(?P<asset>BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH)\b[^\n]*?\b(?P<dir>SHORT|LONG)\b'
    action: enter
    priority: 14
    enabled: true
  # Bare quantity headline: "10 ETH LONG". No verb and no "$", so the usual
  # line-start verb anchor cannot protect this rule — the whole line must
  # therefore BE the signal and nothing else. "10 ETH LONG was the right call"
  # is narrative and must not fire, which the trailing $ anchor enforces. The
  # cost is that a genuine signal with a trailing comment stays unmatched; that
  # is the correct direction to fail in an app that submits real orders.
  # See also MAX_SIGNAL_LINES / MAX_SIGNAL_CHARS in rust/src/patterns.rs.
  - name: entry_bare_qty
    regex: '(?im)^\s*(?P<qty>[\d.]+)\s*(?P<asset>BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH)\s+(?P<dir>SHORT|LONG)\s*[.!]?\s*$'
    action: enter
    priority: 15
    enabled: true
  # The "$" is optional so a bare notional ("ADDED 10000") is still a USD add.
  # add_btc has the lower priority number so a bare BTC quantity ("ADDED 0.5
  # BTC") wins the tie against add_usd, which would otherwise read the digits as
  # dollars.
  # Adds also carry the scalp filler ("ADDED $10,000 SCALP SHORT BTC"). Unlike
  # the entry rules this is an explicit word list, not `.*?`: a lazy wildcard
  # here would run past an "... AND ADDING ..." boundary to find a later
  # direction and swallow the second instruction of a compound message. A
  # direction the author states must win — without it the add silently inherits
  # the last remembered side and can be sent against a flipped position.
  - name: add_usd
    regex: '(?im)(?:^|\bAND\s+)\s*ADD(?:ED|ING)\b\s*\$?(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM])\b)?(?:(?:\s+(?:SCALP|BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH))*\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?'
    action: add
    priority: 21
    enabled: true
  - name: add_coin
    regex: '(?im)(?:^|\bAND\s+)\s*ADD(?:ED|ING)\b\s*(?P<qty>[\d.]+)\s*(?P<asset>BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH)\b(?:(?:\s+(?:SCALP|BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH))*\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?'
    action: add
    priority: 20
    enabled: true
  # Reduce verbs accept the past tense ("REDUCED"), the bare imperative
  # ("REDUCE") and the scalp gerund ("REDUCING $25000 SCALP BITCOIN LONG").
  - name: reduce_usd
    regex: '(?im)^\s*REDUC(?:E|ED|ING)\b\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?P<mult>[KM])\b)?'
    action: reduce
    priority: 30
    enabled: true
  - name: reduce_coin
    regex: '(?im)^\s*REDUC(?:E|ED|ING)\b\s*(?P<qty>[\d.]+)\s*(?P<asset>BITCOIN|ETHEREUM|ETHER|XBT|BTC|ETH)\b'
    action: reduce
    priority: 31
    enabled: true
  - name: reduce_pct
    regex: '(?im)^\s*REDUC(?:E|ED|ING)\b.*?(?P<pct>\d+)\s*%'
    action: reduce
    priority: 32
    enabled: true
  # "Taking 50% out of the trade" is a partial reduction. Any trailing dollar
  # figure ("$300 banked") is realized-PnL commentary, not a size.
  - name: reduce_taking_pct
    regex: '(?im)^\s*TAKING\s+(?P<pct>\d+)\s*%\s+OUT\b'
    action: reduce
    priority: 33
    enabled: true
  # Close verbs include the scalp gerund "CLOSING" and "CLOSED ALL TRADES".
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
