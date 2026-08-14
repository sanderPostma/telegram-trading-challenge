use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::interpreter::{Asset, Direction, Size};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleAction {
    Enter,
    Add,
    Reduce,
    Close,
    Ignore,
    /// A message-level veto. If any enabled guard rule matches, the whole
    /// message is treated as discussion and produces no automated action.
    /// This is how hypothetical/conditional wording ("should have added
    /// $5000") is suppressed, since Rust regex has no lookbehind to express
    /// it inline. Guard rules never produce a `RuleHit`.
    Guard,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatternRule {
    pub name: String,
    pub regex: String,
    pub action: RuleAction,
    pub priority: i32,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatternDocument {
    pub version: u32,
    pub patterns: Vec<PatternRule>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RuleHit {
    pub rule_name: String,
    pub action: RuleAction,
    pub asset: Option<Asset>,
    pub direction: Option<Direction>,
    pub size: Option<Size>,
    pub trigger_price: Option<f64>,
}

/// Message-level narrative cutoffs.
///
/// The parser's original defence against long messages was implicit: trade
/// verbs had to sit at the start of a line, and narrative buries its verbs
/// mid-sentence. The verbless entry rule (`10 ETH LONG`) has no verb to anchor,
/// so that defence is made explicit here. A message longer than either bound is
/// treated as discussion and produces no action at all.
///
/// The bounds are deliberately generous: the widest genuine signal in the test
/// corpus is a two-line compound with an account-balance status line.
pub const MAX_SIGNAL_LINES: usize = 4;
pub const MAX_SIGNAL_CHARS: usize = 320;

fn is_narrative(text: &str) -> bool {
    text.chars().count() > MAX_SIGNAL_CHARS
        || text.lines().filter(|line| !line.trim().is_empty()).count() > MAX_SIGNAL_LINES
}

pub fn default_rules() -> Vec<PatternRule> {
    parse_pattern_document(default_rules_yaml()).expect("embedded pattern YAML is valid")
}

pub fn default_rules_yaml() -> &'static str {
    include_str!("../../config/telegram_patterns.yaml")
}

pub fn parse_pattern_document(source: &str) -> anyhow::Result<Vec<PatternRule>> {
    let document = parse_document(source)?;
    if !SUPPORTED_DOCUMENT_VERSIONS.contains(&document.version) {
        anyhow::bail!("unsupported pattern document version {}", document.version);
    }
    if document.patterns.is_empty() {
        anyhow::bail!("pattern document contains no patterns");
    }
    for pattern in &document.patterns {
        Regex::new(&pattern.regex)
            .map_err(|error| anyhow::anyhow!("invalid regex for {}: {error}", pattern.name))?;
    }
    Ok(document.patterns)
}

pub fn merge_pattern_documents(base: &str, local: &str) -> anyhow::Result<String> {
    let mut base_document = parse_document(base)?;
    let local_document = parse_document(local)?;
    if !SUPPORTED_DOCUMENT_VERSIONS.contains(&base_document.version)
        || !SUPPORTED_DOCUMENT_VERSIONS.contains(&local_document.version)
    {
        anyhow::bail!("unsupported pattern document version");
    }
    // A v1 local override names v1 rules. `add_btc`/`reduce_btc` became
    // `add_coin`/`reduce_coin`, and merging is by name, so a v1 override of
    // those would silently attach to nothing. Carry it onto the new name
    // instead of dropping it on the floor.
    let local_document = migrate_v1_rule_names(local_document);

    for local_pattern in local_document.patterns {
        if let Some(existing) = base_document
            .patterns
            .iter_mut()
            .find(|pattern| pattern.name == local_pattern.name)
        {
            *existing = local_pattern;
        } else {
            base_document.patterns.push(local_pattern);
        }
    }
    if base_document.patterns.is_empty() {
        anyhow::bail!("merged pattern document contains no patterns");
    }
    serde_yaml::to_string(&base_document).map_err(Into::into)
}

/// Document versions this build understands. v1 is the BTC-only grammar; v2
/// adds the `asset` capture group and the `qty` rename.
pub const SUPPORTED_DOCUMENT_VERSIONS: [u32; 2] = [1, 2];

/// v1 rule name -> v2 rule name, for names that changed meaning-preservingly.
const RENAMED_RULES: [(&str, &str); 2] = [("add_btc", "add_coin"), ("reduce_btc", "reduce_coin")];

fn migrate_v1_rule_names(mut document: PatternDocument) -> PatternDocument {
    if document.version != 1 {
        return document;
    }
    for pattern in &mut document.patterns {
        if let Some((_, new_name)) = RENAMED_RULES.iter().find(|(old, _)| *old == pattern.name) {
            pattern.name = (*new_name).to_string();
        }
    }
    document
}

fn parse_document(source: &str) -> anyhow::Result<PatternDocument> {
    let document: PatternDocument = serde_yaml::from_str(source)?;
    for pattern in &document.patterns {
        Regex::new(&pattern.regex)
            .map_err(|error| anyhow::anyhow!("invalid regex for {}: {error}", pattern.name))?;
    }
    Ok(document)
}

pub fn match_first(text: &str, rules: &[PatternRule]) -> anyhow::Result<Option<RuleHit>> {
    Ok(match_actions(text, rules)?.into_iter().next())
}

pub fn match_actions(text: &str, rules: &[PatternRule]) -> anyhow::Result<Vec<RuleHit>> {
    // Long messages are narrative, not signals. This runs before the guard
    // rules because it is cheaper and because it is the backstop the verbless
    // entry rule depends on — that rule has no verb to anchor to a line start.
    if is_narrative(text) {
        return Ok(Vec::new());
    }

    // A guard rule vetoes the entire message before any trade verb is
    // considered. Hypothetical/discussion posts ("I should have added $5000",
    // "for example, if you close the trade...") must never place an order.
    for rule in rules
        .iter()
        .filter(|rule| rule.enabled && rule.action == RuleAction::Guard)
    {
        let re = Regex::new(&rule.regex)?;
        if re.is_match(text) {
            return Ok(Vec::new());
        }
    }

    let mut matches = Vec::new();
    for rule in rules
        .iter()
        .filter(|rule| rule.enabled && rule.action != RuleAction::Guard)
    {
        let re = Regex::new(&rule.regex)?;
        for caps in re.captures_iter(text) {
            let Some(full_match) = caps.get(0) else {
                continue;
            };
            matches.push((
                full_match.start(),
                rule.priority,
                RuleHit {
                    rule_name: rule.name.clone(),
                    action: rule.action,
                    asset: parse_asset(&caps, text),
                    direction: caps.name("dir").and_then(|m| parse_direction(m.as_str())),
                    size: parse_size(&caps),
                    trigger_price: caps.name("trigger").and_then(|m| parse_number(m.as_str())),
                },
            ));
        }
    }

    matches.sort_by_key(|(start, priority, _)| (*start, *priority));
    let mut hits = Vec::new();
    let mut previous_start = None;
    for (start, _, hit) in matches {
        // A rule set can contain overlapping alternatives. The higher-priority
        // rule wins for a given text offset, while separate instructions remain.
        if previous_start == Some(start) {
            continue;
        }
        previous_start = Some(start);
        hits.push(hit);
    }
    Ok(hits)
}

/// Extracts the challenge (master) account balance announced in a channel
/// message. Recognizes both the "Account balance $10,000" status line and the
/// terse "NEW BALANCE $7,800" announcement, with an optional `:`/`=` separator.
pub fn extract_master_balance(text: &str) -> Option<f64> {
    Regex::new(
        r"(?i)(?:NEW\s+BALANCE|ACCOUNT\s+BALANCE)\s*[:=]?\s*\$?(?P<v>[\d,]+(?:\.\d+)?)",
    )
    .ok()?
    .captures(text)?
    .name("v")
    .and_then(|m| parse_number(m.as_str()))
}

pub fn extract_trade_size(text: &str) -> Option<f64> {
    Regex::new(r"(?i)Trade Size\s*\$?(?P<v>[\d,]+(?:\.\d+)?)")
        .ok()?
        .captures(text)?
        .name("v")
        .and_then(|m| parse_number(m.as_str()))
}

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

    // "TP SET 64450" is the terse channel shorthand for the same advisory
    // level. Only the SET/TARGET (or punctuated "TP:") forms arm a watch —
    // "TP HIT" reports a fill and is handled by the `close` pattern rule.
    let re = Regex::new(
        r"(?i)(?:full\s+close\s+target|target\s+(?:for|to)\s+(?:a\s+)?full\s+close(?:\s+is)?|(?:TP|TAKE\s+PROFIT)\s+(?:SET|TARGET)(?:\s+(?:AT|IS|TO))?|(?:TP|TAKE\s+PROFIT)\s*[:=])\s*:?\s*\$?(?P<low>[\d,]+(?:\.\d+)?)(?:\s*(?:-|–|—|to)\s*\$?(?P<high>[\d,]+(?:\.\d+)?))?",
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

fn parse_direction(value: &str) -> Option<Direction> {
    match value.to_ascii_lowercase().as_str() {
        "long" => Some(Direction::Long),
        "short" => Some(Direction::Short),
        _ => None,
    }
}

fn parse_size(caps: &regex::Captures<'_>) -> Option<Size> {
    // `qty` is the current name for a base-asset quantity; `btc` is the v1 name,
    // still accepted so a user's existing local pattern override keeps working.
    if let Some(v) = caps.name("usd").and_then(|m| parse_number(m.as_str())) {
        // A "k"/"m" suffix scales the notional ("20k btc long" is $20,000).
        let scale = match caps.name("mult").map(|m| m.as_str().to_ascii_lowercase()) {
            Some(suffix) if suffix == "k" => 1_000.0,
            Some(suffix) if suffix == "m" => 1_000_000.0,
            _ => 1.0,
        };
        return Some(Size::Usdt(v * scale));
    }
    if let Some(v) = caps
        .name("qty")
        .or_else(|| caps.name("btc"))
        .and_then(|m| parse_number(m.as_str()))
    {
        return Some(Size::Coin(v));
    }
    if let Some(v) = caps.name("pct").and_then(|m| parse_number(m.as_str())) {
        return Some(Size::Pct(v / 100.0));
    }
    None
}

fn parse_asset(caps: &regex::Captures<'_>, message: &str) -> Option<Asset> {
    // Where the asset is load-bearing — the unit suffix on a quantity — the
    // rule captures it structurally.
    if let Some(asset) = caps
        .name("asset")
        .and_then(|m| Asset::from_alias(m.as_str()))
    {
        return Some(asset);
    }
    // Elsewhere it is free-floating filler ("OPENED $30,000 SCALP SHORT BTC"),
    // where pinning it down in the regex would mean an optional group inside a
    // lazy wildcard — fragile, and it would silently stop capturing. Scanning
    // the matched text is both simpler and easier to reason about.
    // Prefer the matched span: in a compound message ("ADDED 0.5 BTC AND
    // ADDING 2 ETH") each instruction names its own asset, and the span keeps
    // them apart. Only when the span names none — the asset trails the match,
    // as in "OPENED $30,000 SCALP SHORT ETHEREUM" — widen to the whole message.
    caps.get(0)
        .and_then(|m| sole_asset_mentioned(m.as_str()))
        .or_else(|| sole_asset_mentioned(message))
}

/// The asset named in `text`, or `None` if none or more than one is named.
///
/// Refusing to pick between two named assets matters: a message mentioning both
/// is not a signal this parser understands, and guessing would put an order on
/// the wrong book.
fn sole_asset_mentioned(text: &str) -> Option<Asset> {
    let mut found: Option<Asset> = None;
    for asset in Asset::ALL {
        if !mentions_asset(text, asset) {
            continue;
        }
        match found {
            None => found = Some(asset),
            Some(existing) if existing == asset => {}
            Some(_) => return None,
        }
    }
    found
}

fn mentions_asset(text: &str, asset: Asset) -> bool {
    let pattern = format!(r"(?i)\b(?:{})\b", asset.aliases().join("|"));
    Regex::new(&pattern)
        .map(|re| re.is_match(text))
        .unwrap_or(false)
}

fn parse_number(value: &str) -> Option<f64> {
    value.replace(',', "").parse::<f64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_real_signal_shapes() {
        let rules = default_rules();

        let entry = match_first("STARTED 0.5BTC SHORT", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(entry.action, RuleAction::Enter);
        assert_eq!(entry.direction, Some(Direction::Short));
        assert_eq!(entry.size, Some(Size::Coin(0.5)));

        let add = match_first("ADDED $5,000 TO SHORT", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(add.action, RuleAction::Add);
        assert_eq!(add.direction, Some(Direction::Short));
        assert_eq!(add.size, Some(Size::Usdt(5000.0)));

        let add_without_to = match_first("ADDED $5000 SHORT", &rules).unwrap().unwrap();
        assert_eq!(add_without_to.action, RuleAction::Add);
        assert_eq!(add_without_to.direction, Some(Direction::Short));
        assert_eq!(add_without_to.size, Some(Size::Usdt(5000.0)));

        // A bare number with no "$" is still a USD add (real message "ADDED
        // 10000"). It must not be dropped for lacking the dollar sign.
        let add_bare = match_first("ADDED 10000", &rules).unwrap().unwrap();
        assert_eq!(add_bare.action, RuleAction::Add);
        assert_eq!(add_bare.size, Some(Size::Usdt(10_000.0)));

        // A bare BTC quantity must still parse as BTC, not USD, even though the
        // now-optional "$" lets the USD rule also match the digits.
        let add_bare_btc = match_first("ADDED 0.5 BTC SHORT", &rules).unwrap().unwrap();
        assert_eq!(add_bare_btc.action, RuleAction::Add);
        assert_eq!(add_bare_btc.direction, Some(Direction::Short));
        assert_eq!(add_bare_btc.size, Some(Size::Coin(0.5)));

        let compound = match_actions(
            "ADDED $5000 AND ADDING $5000 TO LIMIT TRIGGER AT 64,300",
            &rules,
        )
        .unwrap();
        assert_eq!(compound.len(), 2);
        assert_eq!(compound[0].size, Some(Size::Usdt(5000.0)));
        assert_eq!(compound[0].trigger_price, None);
        assert_eq!(compound[1].size, Some(Size::Usdt(5000.0)));
        assert_eq!(compound[1].trigger_price, Some(64_300.0));

        let noise = match_first("CHAT TEST", &rules).unwrap().unwrap();
        assert_eq!(noise.action, RuleAction::Ignore);
    }

    #[test]
    fn scalp_style_signals_classify() {
        let rules = default_rules();

        // The newer channel format: a USD-notional entry with "SCALP BITCOIN"
        // filler between the size and the direction.
        let long = match_first("OPENING $50000 SCALP BITCOIN LONG", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(long.action, RuleAction::Enter);
        assert_eq!(long.direction, Some(Direction::Long));
        assert_eq!(long.size, Some(Size::Usdt(50_000.0)));

        // The SHORT variant.
        let short = match_first("OPENING $50000 SCALP BITCOIN SHORT", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(short.action, RuleAction::Enter);
        assert_eq!(short.direction, Some(Direction::Short));
        assert_eq!(short.size, Some(Size::Usdt(50_000.0)));

        // The REDUCE variant (scalp gerund + USD amount).
        let reduce = match_first("REDUCING $25000 SCALP BITCOIN LONG", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(reduce.action, RuleAction::Reduce);
        assert_eq!(reduce.size, Some(Size::Usdt(25_000.0)));

        // The CLOSE variant.
        let close = match_first("CLOSING SCALP BITCOIN LONG", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(close.action, RuleAction::Close);

        // "CLOSED ALL TRADES" is a real close (the exact message from the bug
        // report) and must not be swallowed as noise.
        let close_all = match_first("CLOSED ALL TRADES", &rules).unwrap().unwrap();
        assert_eq!(close_all.action, RuleAction::Close);
    }

    #[test]
    fn scalp_signals_name_the_asset_after_the_direction() {
        let rules = default_rules();

        // The channel also writes the asset last: "OPENED $30,000 SCALP SHORT
        // BTC". The trailing "BTC" must not be read as a BTC quantity, and the
        // direction must survive the "SCALP" filler.
        for (text, direction) in [
            ("OPENED $30,000 SCALP SHORT BTC", Direction::Short),
            ("OPENED $30,000 SCALP LONG BTC", Direction::Long),
            ("OPENING $30,000 SCALP SHORT BTC", Direction::Short),
            ("opened $30,000 scalp short btc", Direction::Short),
        ] {
            let hit = match_first(text, &rules).unwrap().unwrap();
            assert_eq!(hit.action, RuleAction::Enter, "{text:?}");
            assert_eq!(hit.direction, Some(direction), "{text:?}");
            assert_eq!(hit.size, Some(Size::Usdt(30_000.0)), "{text:?}");
        }

        // Trailing commentary on later lines does not disturb the signal line.
        let with_comment =
            match_first("OPENED $30,000 SCALP SHORT BTC\n\nlets see how this goes", &rules)
                .unwrap()
                .unwrap();
        assert_eq!(with_comment.direction, Some(Direction::Short));
        assert_eq!(with_comment.size, Some(Size::Usdt(30_000.0)));

        // A genuine BTC quantity in the same word order still reads as BTC.
        let btc_qty = match_first("OPENED 0.5 BTC SCALP SHORT", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(btc_qty.size, Some(Size::Coin(0.5)));
        assert_eq!(btc_qty.direction, Some(Direction::Short));
    }

    #[test]
    fn adds_keep_a_direction_stated_across_scalp_filler() {
        let rules = default_rules();

        // Without this the direction is dropped and the add inherits whichever
        // side the interpreter last remembered — the wrong side after a flip.
        for text in [
            "ADDED $10,000 SCALP SHORT BTC",
            "ADDED $10,000 SCALP BITCOIN SHORT",
            "ADDING $10,000 BTC SHORT",
        ] {
            let hit = match_first(text, &rules).unwrap().unwrap();
            assert_eq!(hit.action, RuleAction::Add, "{text:?}");
            assert_eq!(hit.direction, Some(Direction::Short), "{text:?}");
            assert_eq!(hit.size, Some(Size::Usdt(10_000.0)), "{text:?}");
        }

        let btc = match_first("ADDED 0.25 BTC SCALP SHORT", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(btc.action, RuleAction::Add);
        assert_eq!(btc.direction, Some(Direction::Short));
        assert_eq!(btc.size, Some(Size::Coin(0.25)));

        // The filler must not run past an "AND" boundary and swallow the second
        // instruction while hunting for a direction later on the line.
        let compound = match_actions("ADDED $5000 AND ADDING $5000 TO SHORT", &rules).unwrap();
        assert_eq!(compound.len(), 2, "got {compound:?}");
        assert_eq!(compound[0].size, Some(Size::Usdt(5000.0)));
        assert_eq!(compound[0].direction, None);
        assert_eq!(compound[1].size, Some(Size::Usdt(5000.0)));
        assert_eq!(compound[1].direction, Some(Direction::Short));
    }

    #[test]
    fn shorthand_and_verbless_entries_classify() {
        let rules = default_rules();

        // "20k" is a USD notional shorthand; "btc" here names the asset, not a
        // quantity, so this is $20,000 of BTC and not 20 BTC.
        let shorthand = match_first("opened 20k btc long", &rules).unwrap().unwrap();
        assert_eq!(shorthand.action, RuleAction::Enter);
        assert_eq!(shorthand.direction, Some(Direction::Long));
        assert_eq!(shorthand.size, Some(Size::Usdt(20_000.0)));

        // A verbless headline entry: amount, asset, direction, all on one line.
        let verbless = match_first("$20,000 BTC LONG FOR CHALLENGE", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(verbless.action, RuleAction::Enter);
        assert_eq!(verbless.direction, Some(Direction::Long));
        assert_eq!(verbless.size, Some(Size::Usdt(20_000.0)));

        // The shorthand must not hijack a real BTC quantity entry.
        let btc_qty = match_first("OPENED 0.5 BTC LONG", &rules).unwrap().unwrap();
        assert_eq!(btc_qty.size, Some(Size::Coin(0.5)));

        // The k/m shorthand also applies to adds and reduces.
        let add = match_first("ADDED 10k", &rules).unwrap().unwrap();
        assert_eq!(add.action, RuleAction::Add);
        assert_eq!(add.size, Some(Size::Usdt(10_000.0)));

        // PnL/prose lines with a dollar figure are not verbless entries: they
        // lack the asset+direction shape the rule requires.
        for text in [
            "$20,000 profit on the challenge so far",
            "BTC LONG is looking good here",
        ] {
            let hit = match_first(text, &rules).unwrap();
            assert_ne!(
                hit.map(|h| h.action),
                Some(RuleAction::Enter),
                "must not be an entry: {text:?}"
            );
        }
    }

    #[test]
    fn narrative_past_tense_does_not_trade() {
        let rules = default_rules();

        // Real channel message id 114: the author recounts a *separate* eth
        // trade ("This is not challenge"). The verb is buried mid-paragraph
        // and the post is hypothetical/conditional, so it must produce no add.
        let narrative = "The tiny loss on the challenge so far of $1700 is \
             replaced with a $10,000 profit\n\nI think I added $20,000 of \
             margin to take the trade\n\nWe're not even close to needing more \
             margin nor would I use it";
        let hits = match_actions(narrative, &rules).unwrap();
        assert!(
            hits.is_empty(),
            "narrative recap must not produce any action, got {hits:?}"
        );

        // Line-anchoring alone: a buried verb without any guard word is still
        // ignored because it is not a terse command on its own line.
        let buried = "price action was ugly so I closed my other book and \
             later I added $5000 to that position";
        assert!(match_actions(buried, &rules).unwrap().is_empty());
    }

    #[test]
    fn hypothetical_wording_is_vetoed() {
        let rules = default_rules();
        for text in [
            "I should have added $5000 here",
            "if I had added $5,000 we would be up",
            "I wish I added $10,000 earlier",
            "imagine if you STARTED 0.5BTC SHORT at the top",
            "for example, REDUCE $5000 when it hits target",
            "what if we CLOSED here",
        ] {
            assert!(
                match_actions(text, &rules).unwrap().is_empty(),
                "guarded message should produce no action: {text:?}"
            );
        }
    }

    #[test]
    fn terse_signals_still_match_after_anchoring() {
        let rules = default_rules();

        // Signal line followed by commentary (real message id 152 shape).
        let with_comment = "ADDED $10000\n\nYes i know its playing with fire \
             but the analysis says we are fine";
        let add = match_first(with_comment, &rules).unwrap().unwrap();
        assert_eq!(add.action, RuleAction::Add);
        assert_eq!(add.size, Some(Size::Usdt(10_000.0)));

        // Compound: the second instruction after AND is still captured.
        let compound = match_actions(
            "ADDED $5000 AND ADDING $5000 TO LIMIT TRIGGER AT 64,300",
            &rules,
        )
        .unwrap();
        assert_eq!(compound.len(), 2);
        assert_eq!(compound[1].trigger_price, Some(64_300.0));
    }

    #[test]
    fn reduce_supports_percent_dollars_and_btc() {
        let rules = default_rules();

        let pct = match_first("REDUCED 50% of the position", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(pct.action, RuleAction::Reduce);
        assert_eq!(pct.size, Some(Size::Pct(0.5)));

        let usd = match_first("REDUCE $5000", &rules).unwrap().unwrap();
        assert_eq!(usd.action, RuleAction::Reduce);
        assert_eq!(usd.size, Some(Size::Usdt(5000.0)));

        let btc = match_first("REDUCED 0.2 BTC", &rules).unwrap().unwrap();
        assert_eq!(btc.action, RuleAction::Reduce);
        assert_eq!(btc.size, Some(Size::Coin(0.2)));

        // A stray percentage in prose is not a reduction.
        assert!(match_first("we are down about 3% on the day", &rules)
            .unwrap()
            .is_none());

        // "Taking X% out ..." is a reduction; the trailing "$300 banked" is
        // realized-PnL commentary, not a size, and must be ignored.
        let taking = match_first("Taking 50% out of the trade $300 banked", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(taking.action, RuleAction::Reduce);
        assert_eq!(taking.size, Some(Size::Pct(0.5)));
    }

    #[test]
    fn close_only_matches_at_line_start() {
        let rules = default_rules();

        // Proximity / discussion uses of "close" must not classify as a close.
        for text in [
            "So close but did not trigger",
            "the lines getting very very close to a bear cross",
            "No plans to close, if you like you can use a stoploss",
        ] {
            let hit = match_first(text, &rules).unwrap();
            assert_ne!(
                hit.map(|h| h.action),
                Some(RuleAction::Close),
                "must not be a close: {text:?}"
            );
        }

        // A real terse close signal still classifies.
        let closed = match_first("CLOSED", &rules).unwrap().unwrap();
        assert_eq!(closed.action, RuleAction::Close);
    }

    #[test]
    fn extracts_metadata_values() {
        assert_eq!(
            extract_master_balance("Account balance $10,000"),
            Some(10_000.0)
        );
        // The channel also announces the challenge balance as "NEW BALANCE".
        assert_eq!(
            extract_master_balance("NEW BALANCE $7,800"),
            Some(7_800.0)
        );
        assert_eq!(
            extract_master_balance("New balance: 12,500.50"),
            Some(12_500.50)
        );
        assert_eq!(extract_trade_size("Trade Size $31,000"), Some(31_000.0));
    }

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

    #[test]
    fn extracts_take_profit_target() {
        // The terse channel shorthand for the same advisory close level.
        assert_eq!(
            extract_close_target_range("TP SET 64450"),
            Some((64_450.0, 64_450.0))
        );
        assert_eq!(
            extract_close_target_range("tp set $64,450"),
            Some((64_450.0, 64_450.0))
        );
        // A range and the spelled-out / punctuated variants.
        assert_eq!(
            extract_close_target_range("TP SET 64450-64500"),
            Some((64_450.0, 64_500.0))
        );
        assert_eq!(
            extract_close_target_range("TP: 64450"),
            Some((64_450.0, 64_450.0))
        );
        assert_eq!(
            extract_close_target_range("TAKE PROFIT SET AT 64450"),
            Some((64_450.0, 64_450.0))
        );
        // Hypothetical wording still vetoes arming.
        assert_eq!(extract_close_target_range("what if TP SET 64450"), None);
    }

    #[test]
    fn take_profit_set_is_not_a_close_signal() {
        let rules = default_rules();

        // "TP SET" announces a target; only "TP HIT" is a close. Arming must not
        // flatten the book.
        let hits = match_actions("TP SET 64450", &rules).unwrap();
        assert!(
            hits.iter().all(|hit| hit.action != RuleAction::Close),
            "TP SET must not classify as a close, got {hits:?}"
        );

        let hit = match_first("TP HIT", &rules).unwrap().unwrap();
        assert_eq!(hit.action, RuleAction::Close);
    }

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

    #[test]
    fn merges_local_overrides_without_losing_remote_updates() {
        let local = r#"
version: 1
patterns:
  - name: close
    regex: '(?i)\bCUSTOM CLOSE\b'
    action: close
    priority: 40
    enabled: true
  - name: custom_add
    regex: '(?i)\bCUSTOM ADD\b'
    action: add
    priority: 50
    enabled: true
"#;
        let merged = merge_pattern_documents(default_rules_yaml(), local).unwrap();
        let rules = parse_pattern_document(&merged).unwrap();
        // 15 default patterns (guard, entry, entry_usd, entry_usd_short,
        // entry_verbless, entry_verbless_short, entry_bare_qty, add_usd,
        // add_coin, reduce_usd, reduce_coin, reduce_pct, reduce_taking_pct,
        // close, noop) + the new custom_add override.
        assert_eq!(rules.len(), 16);
        assert_eq!(
            rules
                .iter()
                .find(|rule| rule.name == "close")
                .unwrap()
                .regex,
            r"(?i)\bCUSTOM CLOSE\b"
        );
        assert!(rules.iter().any(|rule| rule.name == "entry"));
        assert!(rules.iter().any(|rule| rule.name == "custom_add"));
    }

    // --- Multi-asset -----------------------------------------------------

    #[test]
    fn bare_quantity_headline_opens_a_position() {
        let rules = default_rules();
        let hit = match_first("10 ETH LONG", &rules).unwrap().unwrap();
        assert_eq!(hit.rule_name, "entry_bare_qty");
        assert_eq!(hit.action, RuleAction::Enter);
        assert_eq!(hit.asset, Some(Asset::Eth));
        assert_eq!(hit.size, Some(Size::Coin(10.0)));
        assert_eq!(hit.direction, Some(Direction::Long));
    }

    #[test]
    fn bare_quantity_headline_requires_the_whole_line() {
        let rules = default_rules();
        // The verbless rule has no verb to anchor to a line start, so the line
        // must be the signal and nothing else. Commentary must not trade.
        for chatter in [
            "10 ETH LONG was the right call yesterday",
            "10 ETH LONG would have been nice",
            "if 10 ETH LONG had been open we'd be up",
            "I am watching 10 ETH LONG here",
        ] {
            assert!(
                match_actions(chatter, &rules).unwrap().is_empty(),
                "chatter must not produce an action: {chatter:?}"
            );
        }
    }

    #[test]
    fn bare_mention_without_a_quantity_stays_inert() {
        // The v1 guarantee: an asset name plus a direction is not a signal.
        let rules = default_rules();
        assert!(match_actions("BTC LONG is looking good here", &rules)
            .unwrap()
            .is_empty());
        assert!(match_actions("ETH LONG is looking good here", &rules)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn long_messages_are_treated_as_narrative() {
        let rules = default_rules();
        let narrative = format!("STARTED 0.5 BTC SHORT\n{}", "filler line\n".repeat(8));
        assert!(
            match_actions(&narrative, &rules).unwrap().is_empty(),
            "a message past the line budget must produce no action"
        );
        let wordy = format!("10 ETH LONG\n{}", "x".repeat(MAX_SIGNAL_CHARS));
        assert!(match_actions(&wordy, &rules).unwrap().is_empty());
    }

    #[test]
    fn genuine_signals_stay_within_the_narrative_budget() {
        // The guard must not clip real traffic. These are the widest shapes in
        // the corpus above.
        let rules = default_rules();
        let compound = "ADDED $5000 AND ADDING $5000 TO LIMIT TRIGGER AT $63,000";
        assert!(!match_actions(compound, &rules).unwrap().is_empty());
        let with_balance = "OPENED $30,000 SCALP SHORT BTC\nAccount balance $10,000";
        assert!(!match_actions(with_balance, &rules).unwrap().is_empty());
    }

    #[test]
    fn asset_is_read_from_every_signal_shape() {
        let rules = default_rules();
        let cases: [(&str, Asset); 8] = [
            ("STARTED 0.5BTC SHORT", Asset::Btc),
            ("STARTED 4 ETH SHORT", Asset::Eth),
            ("OPENING $50000 SCALP BITCOIN LONG", Asset::Btc),
            ("OPENED $30,000 SCALP SHORT ETHEREUM", Asset::Eth),
            ("$20,000 BTC LONG FOR CHALLENGE", Asset::Btc),
            ("$20,000 ETH LONG FOR CHALLENGE", Asset::Eth),
            ("ADDED 0.5 XBT SHORT", Asset::Btc),
            ("REDUCED 0.2 ETH", Asset::Eth),
        ];
        for (text, expected) in cases {
            let hit = match_first(text, &rules)
                .unwrap()
                .unwrap_or_else(|| panic!("no hit for {text:?}"));
            assert_eq!(hit.asset, Some(expected), "wrong asset for {text:?}");
        }
    }

    #[test]
    fn a_message_naming_two_assets_resolves_to_neither() {
        // Guessing here would put the order on the wrong book.
        assert_eq!(sole_asset_mentioned("BTC and ETH both look good"), None);
        assert_eq!(sole_asset_mentioned("BITCOIN is up"), Some(Asset::Btc));
        assert_eq!(sole_asset_mentioned("no assets here"), None);
    }

    #[test]
    fn quantity_still_beats_notional_for_a_bare_coin_amount() {
        // The v1 ambiguity rule: "ADDED 0.5 BTC" is half a coin, not 50 cents.
        let rules = default_rules();
        let hit = match_first("ADDED 0.5 ETH SHORT", &rules).unwrap().unwrap();
        assert_eq!(hit.size, Some(Size::Coin(0.5)));
        let notional = match_first("ADDED 10000", &rules).unwrap().unwrap();
        assert_eq!(notional.size, Some(Size::Usdt(10_000.0)));
    }

    #[test]
    fn v1_local_overrides_survive_the_rule_rename() {
        let local = "version: 1\npatterns:\n  - name: add_btc\n    regex: 'CUSTOM'\n    action: add\n    priority: 5\n    enabled: true\n";
        let merged = merge_pattern_documents(default_rules_yaml(), local).unwrap();
        let rules = parse_pattern_document(&merged).unwrap();
        let renamed = rules.iter().find(|r| r.name == "add_coin").unwrap();
        assert_eq!(renamed.regex, "CUSTOM", "a v1 override must not be orphaned");
        assert!(!rules.iter().any(|r| r.name == "add_btc"));
    }
}
