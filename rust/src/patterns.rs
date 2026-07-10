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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatternRule {
    pub name: String,
    pub regex: String,
    pub action: RuleAction,
    pub priority: i32,
    pub enabled: bool,
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
    vec![
        rule(
            "entry",
            r"(?i)\bSTARTED\b.*?(?P<btc>[\d.]+)\s*BTC.*?\b(?P<dir>SHORT|LONG)\b",
            RuleAction::Enter,
            10,
        ),
        rule(
            "add_usd",
            r"(?i)\bADD(?:ED|ING)\b\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?",
            RuleAction::Add,
            20,
        ),
        rule(
            "add_btc",
            r"(?i)\bADD(?:ED|ING)\b\s*(?P<btc>[\d.]+)\s*BTC(?:\s+(?:TO\s+)?(?P<dir>SHORT|LONG)\b)?(?:\s+TO\s+LIMIT\s+TRIGGER\s+AT\s*\$?(?P<trigger>[\d,]+(?:\.\d+)?))?",
            RuleAction::Add,
            21,
        ),
        rule(
            "reduce_pct",
            r"(?i)\bREDUCE[D]?\b.*?(?P<pct>\d+)\s*%",
            RuleAction::Reduce,
            30,
        ),
        rule(
            "close",
            r"(?i)\b(CLOSED|CLOSE|EXIT|EXITED|FLAT|STOPPED OUT|TP HIT|TOOK PROFIT)\b",
            RuleAction::Close,
            40,
        ),
        rule(
            "noop",
            r"(?i)\b(TRADE UPDATE|CHAT TEST|NOTIFICATIONS|GOOD MORNING)\b",
            RuleAction::Ignore,
            90,
        ),
    ]
}

pub fn match_first(text: &str, rules: &[PatternRule]) -> anyhow::Result<Option<RuleHit>> {
    Ok(match_actions(text, rules)?.into_iter().next())
}

pub fn match_actions(text: &str, rules: &[PatternRule]) -> anyhow::Result<Vec<RuleHit>> {
    let mut matches = Vec::new();
    for rule in rules.iter().filter(|rule| rule.enabled) {
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

fn rule(name: &str, regex: &str, action: RuleAction, priority: i32) -> PatternRule {
    PatternRule {
        name: name.to_string(),
        regex: regex.to_string(),
        action,
        priority,
        enabled: true,
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
    fn extracts_metadata_values() {
        assert_eq!(
            extract_master_balance("Account balance $10,000"),
            Some(10_000.0)
        );
        assert_eq!(extract_trade_size("Trade Size $31,000"), Some(31_000.0));
    }
}
