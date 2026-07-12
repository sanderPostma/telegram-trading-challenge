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
        assert_eq!(rules.len(), 7);
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
