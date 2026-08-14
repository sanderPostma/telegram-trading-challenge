use serde::{Deserialize, Serialize};

use crate::patterns::{RuleAction, RuleHit};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Enter,
    Add,
    Reduce,
    Close,
    Ignore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Long,
    Short,
}

/// The traded instrument. Deliberately a closed enum rather than a string or a
/// config-driven registry: this crate submits real orders, and a closed set
/// makes the compiler point at every site that still assumes one asset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Asset {
    Btc,
    Eth,
}

impl Asset {
    pub const ALL: [Asset; 2] = [Asset::Btc, Asset::Eth];

    /// Every spelling the channel uses for this asset. Order matters only for
    /// building the regex alternation; longest-first avoids a prefix match
    /// swallowing the longer alias (`ETH` before `ETHER` would strand `ETHER`).
    pub fn aliases(&self) -> &'static [&'static str] {
        match self {
            Asset::Btc => &["BITCOIN", "XBT", "BTC"],
            Asset::Eth => &["ETHEREUM", "ETHER", "ETH"],
        }
    }

    /// The WEEX perpetual symbol.
    pub fn symbol(&self) -> &'static str {
        match self {
            Asset::Btc => "BTCUSDT",
            Asset::Eth => "ETHUSDT",
        }
    }

    /// The short name shown in the UI and in log lines.
    pub fn display(&self) -> &'static str {
        match self {
            Asset::Btc => "BTC",
            Asset::Eth => "ETH",
        }
    }

    pub fn from_alias(text: &str) -> Option<Asset> {
        let upper = text.trim().to_uppercase();
        Asset::ALL
            .into_iter()
            .find(|asset| asset.aliases().iter().any(|alias| *alias == upper))
    }

    pub fn from_symbol(symbol: &str) -> Option<Asset> {
        let upper = symbol.trim().to_uppercase();
        Asset::ALL.into_iter().find(|asset| asset.symbol() == upper)
    }

    /// Regex alternation over every alias of every asset, longest-first.
    pub fn alias_alternation() -> String {
        let mut aliases: Vec<&'static str> = Asset::ALL
            .into_iter()
            .flat_map(|asset| asset.aliases().iter().copied())
            .collect();
        aliases.sort_by_key(|alias| std::cmp::Reverse(alias.len()));
        aliases.join("|")
    }
}

/// How much to trade. Magnitude only — the instrument travels beside this as an
/// [`Asset`], so that a quantity can never silently belong to the wrong book.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Size {
    Usdt(f64),
    Coin(f64),
    Pct(f64),
    FullClose,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Action {
    pub kind: ActionKind,
    pub asset: Option<Asset>,
    pub direction: Option<Direction>,
    pub size: Option<Size>,
    pub trigger_price: Option<f64>,
    pub confidence_high: bool,
    pub needs_approval: bool,
    pub raw_text: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InterpreterState {
    pub last_direction: Option<Direction>,
    pub last_trade_size_usd: Option<f64>,
    /// The asset of the most recent actionable signal, used when a follow-up
    /// message omits it ("REDUCED 0.2").
    pub last_asset: Option<Asset>,
    /// Assets considered live for inheritance purposes — in practice those with
    /// open exposure. When a message omits the asset and more than one of these
    /// is live, the reference is ambiguous and we refuse to guess.
    pub active_assets: Vec<Asset>,
}

impl InterpreterState {
    /// Resolves the asset for a message that did not name one.
    ///
    /// Returns `None` when the reference is ambiguous — more than one asset is
    /// live and nothing in the message disambiguates. Reducing the wrong book is
    /// far worse than dropping a reduce, so this fails closed rather than
    /// falling back to the most recent signal.
    fn inherit_asset(&self) -> Option<Asset> {
        let mut live: Vec<Asset> = self.active_assets.clone();
        live.sort_by_key(|asset| *asset as usize);
        live.dedup();
        match live.len() {
            0 => self.last_asset,
            1 => Some(live[0]),
            _ => None,
        }
    }
}

pub fn interpret(text: &str, hit: Option<RuleHit>, state: &InterpreterState) -> Action {
    let Some(hit) = hit else {
        return unresolved(ActionKind::Ignore, text);
    };

    if hit.action == RuleAction::Ignore {
        return Action {
            kind: ActionKind::Ignore,
            asset: None,
            direction: None,
            size: None,
            trigger_price: None,
            confidence_high: true,
            needs_approval: false,
            raw_text: text.to_string(),
        };
    }

    let asset = hit.asset.or_else(|| state.inherit_asset());
    let direction = hit.direction.or(state.last_direction);
    let size = hit.size.or_else(|| match hit.action {
        RuleAction::Close => Some(Size::FullClose),
        _ => state.last_trade_size_usd.map(Size::Usdt),
    });
    let kind = match hit.action {
        RuleAction::Enter => ActionKind::Enter,
        RuleAction::Add => ActionKind::Add,
        RuleAction::Reduce => ActionKind::Reduce,
        RuleAction::Close => ActionKind::Close,
        // Guard rules are vetoes filtered out in `match_actions`, so they never
        // reach interpretation; Ignore keeps the match exhaustive and safe.
        RuleAction::Ignore | RuleAction::Guard => ActionKind::Ignore,
    };

    let needs_direction = matches!(kind, ActionKind::Enter | ActionKind::Add);
    let needs_size = matches!(
        kind,
        ActionKind::Enter | ActionKind::Add | ActionKind::Reduce
    );
    // Every actionable kind needs to know which book it applies to. An
    // unresolved asset therefore drops confidence and forces manual approval
    // rather than defaulting to a book that may be the wrong one.
    let complete = (!needs_direction || direction.is_some())
        && (!needs_size || size.is_some())
        && asset.is_some();
    Action {
        kind,
        asset,
        direction,
        size,
        trigger_price: hit.trigger_price,
        confidence_high: complete,
        needs_approval: !complete,
        raw_text: text.to_string(),
    }
}

fn unresolved(kind: ActionKind, text: &str) -> Action {
    Action {
        kind,
        asset: None,
        direction: None,
        size: None,
        trigger_price: None,
        confidence_high: false,
        needs_approval: true,
        raw_text: text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::patterns::{default_rules, match_first};

    fn hit(text: &str) -> Option<crate::patterns::RuleHit> {
        match_first(text, &default_rules()).unwrap()
    }

    #[test]
    fn aliases_resolve_to_their_asset() {
        for alias in ["BTC", "btc", "XBT", "Bitcoin"] {
            assert_eq!(Asset::from_alias(alias), Some(Asset::Btc), "{alias}");
        }
        for alias in ["ETH", "eth", "ether", "ETHEREUM"] {
            assert_eq!(Asset::from_alias(alias), Some(Asset::Eth), "{alias}");
        }
        assert_eq!(Asset::from_alias("SOL"), None);
        assert_eq!(Asset::from_symbol("ethusdt"), Some(Asset::Eth));
        assert_eq!(Asset::from_symbol("SOLUSDT"), None);
    }

    #[test]
    fn longer_aliases_precede_their_prefixes_in_the_alternation() {
        // ETH before ETHEREUM in an alternation would strand the longer alias.
        let alternation = Asset::alias_alternation();
        let eth = alternation.find("ETH|").unwrap_or(usize::MAX);
        let ethereum = alternation.find("ETHEREUM").unwrap();
        assert!(ethereum < eth, "got {alternation}");
    }

    #[test]
    fn a_named_asset_wins_over_inherited_state() {
        let state = InterpreterState {
            last_asset: Some(Asset::Btc),
            active_assets: vec![Asset::Btc],
            ..Default::default()
        };
        let action = interpret("10 ETH LONG", hit("10 ETH LONG"), &state);
        assert_eq!(action.asset, Some(Asset::Eth));
        assert!(action.confidence_high);
    }

    #[test]
    fn an_unnamed_asset_inherits_the_only_live_book() {
        let state = InterpreterState {
            last_direction: Some(Direction::Long),
            active_assets: vec![Asset::Eth],
            ..Default::default()
        };
        let action = interpret("REDUCED 25%", hit("REDUCED 25%"), &state);
        assert_eq!(action.asset, Some(Asset::Eth));
        assert!(action.confidence_high);
        assert!(!action.needs_approval);
    }

    #[test]
    fn an_unnamed_asset_with_two_live_books_fails_closed() {
        // Reducing the wrong book is worse than not reducing at all.
        let state = InterpreterState {
            last_direction: Some(Direction::Long),
            last_asset: Some(Asset::Btc),
            active_assets: vec![Asset::Btc, Asset::Eth],
            ..Default::default()
        };
        let action = interpret("REDUCED 25%", hit("REDUCED 25%"), &state);
        assert_eq!(
            action.asset, None,
            "an ambiguous reference must not resolve to a book"
        );
        assert!(!action.confidence_high);
        assert!(
            action.needs_approval,
            "an ambiguous reduce must go to manual approval, never straight through"
        );
    }

    #[test]
    fn a_flat_account_falls_back_to_the_last_signal() {
        let state = InterpreterState {
            last_direction: Some(Direction::Short),
            last_asset: Some(Asset::Eth),
            active_assets: Vec::new(),
            ..Default::default()
        };
        let action = interpret("REDUCED 25%", hit("REDUCED 25%"), &state);
        assert_eq!(action.asset, Some(Asset::Eth));
    }

    #[test]
    fn an_inherited_size_is_a_usdt_notional() {
        let state = InterpreterState {
            last_direction: Some(Direction::Long),
            last_trade_size_usd: Some(5_000.0),
            active_assets: vec![Asset::Btc],
            ..Default::default()
        };
        let action = interpret("ADDED", hit("ADDED 0"), &state);
        assert_eq!(action.asset, Some(Asset::Btc));
    }
}
