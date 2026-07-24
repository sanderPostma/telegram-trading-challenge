use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::interpreter::{Direction, Size};

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
    pub direction: Option<Direction>,
    pub size: Option<Size>,
    pub trigger_price: Option<f64>,
}

pub fn default_rules() -> Vec<PatternRule> {
    parse_pattern_document(default_rules_yaml()).expect("embedded pattern YAML is valid")
}

pub fn default_rules_yaml() -> &'static str {
    include_str!("../../config/telegram_patterns.yaml")
}

pub fn parse_pattern_document(source: &str) -> anyhow::Result<Vec<PatternRule>> {
    let document = parse_document(source)?;
    if document.version != 1 {
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
    if base_document.version != 1 || local_document.version != 1 {
        anyhow::bail!("unsupported pattern document version");
    }

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

pub fn extract_master_balance(text: &str) -> Option<f64> {
    Regex::new(r"(?i)Account balance\s*\$?(?P<v>[\d,]+(?:\.\d+)?)")
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

fn parse_direction(value: &str) -> Option<Direction> {
    match value.to_ascii_lowercase().as_str() {
        "long" => Some(Direction::Long),
        "short" => Some(Direction::Short),
        _ => None,
    }
}

fn parse_size(caps: &regex::Captures<'_>) -> Option<Size> {
    if let Some(v) = caps.name("usd").and_then(|m| parse_number(m.as_str())) {
        return Some(Size::Usd(v));
    }
    if let Some(v) = caps.name("btc").and_then(|m| parse_number(m.as_str())) {
        return Some(Size::Btc(v));
    }
    if let Some(v) = caps.name("pct").and_then(|m| parse_number(m.as_str())) {
        return Some(Size::Pct(v / 100.0));
    }
    None
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
        assert_eq!(entry.size, Some(Size::Btc(0.5)));

        let add = match_first("ADDED $5,000 TO SHORT", &rules)
            .unwrap()
            .unwrap();
        assert_eq!(add.action, RuleAction::Add);
        assert_eq!(add.direction, Some(Direction::Short));
        assert_eq!(add.size, Some(Size::Usd(5000.0)));

        let add_without_to = match_first("ADDED $5000 SHORT", &rules).unwrap().unwrap();
        assert_eq!(add_without_to.action, RuleAction::Add);
        assert_eq!(add_without_to.direction, Some(Direction::Short));
        assert_eq!(add_without_to.size, Some(Size::Usd(5000.0)));

        let compound = match_actions(
            "ADDED $5000 AND ADDING $5000 TO LIMIT TRIGGER AT 64,300",
            &rules,
        )
        .unwrap();
        assert_eq!(compound.len(), 2);
        assert_eq!(compound[0].size, Some(Size::Usd(5000.0)));
        assert_eq!(compound[0].trigger_price, None);
        assert_eq!(compound[1].size, Some(Size::Usd(5000.0)));
        assert_eq!(compound[1].trigger_price, Some(64_300.0));

        let noise = match_first("CHAT TEST", &rules).unwrap().unwrap();
        assert_eq!(noise.action, RuleAction::Ignore);
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
        assert_eq!(add.size, Some(Size::Usd(10_000.0)));

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
        assert_eq!(usd.size, Some(Size::Usd(5000.0)));

        let btc = match_first("REDUCED 0.2 BTC", &rules).unwrap().unwrap();
        assert_eq!(btc.action, RuleAction::Reduce);
        assert_eq!(btc.size, Some(Size::Btc(0.2)));

        // A stray percentage in prose is not a reduction.
        assert!(match_first("we are down about 3% on the day", &rules)
            .unwrap()
            .is_none());
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
        assert_eq!(extract_trade_size("Trade Size $31,000"), Some(31_000.0));
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
        // 9 default patterns (guard, entry, add_usd, add_btc, reduce_usd,
        // reduce_btc, reduce_pct, close, noop) + the new custom_add override.
        assert_eq!(rules.len(), 10);
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
}
