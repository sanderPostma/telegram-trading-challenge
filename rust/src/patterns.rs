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
            r"(?i)\bADDED\b\s*\$(?P<usd>[\d,]+)",
            RuleAction::Add,
            20,
        ),
        rule(
            "add_btc",
            r"(?i)\bADDED\b\s*(?P<btc>[\d.]+)\s*BTC",
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
    let mut rules = rules.iter().filter(|r| r.enabled).collect::<Vec<_>>();
    rules.sort_by_key(|r| r.priority);

    for rule in rules {
        let re = Regex::new(&rule.regex)?;
        let Some(caps) = re.captures(text) else {
            continue;
        };
        return Ok(Some(RuleHit {
            rule_name: rule.name.clone(),
            action: rule.action,
            direction: caps.name("dir").and_then(|m| parse_direction(m.as_str())),
            size: parse_size(&caps),
        }));
    }

    Ok(None)
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
        assert_eq!(add.size, Some(Size::Usd(5000.0)));

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
