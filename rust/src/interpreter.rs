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

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Size {
    Usd(f64),
    Btc(f64),
    Pct(f64),
    FullClose,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Action {
    pub kind: ActionKind,
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
}

pub fn interpret(text: &str, hit: Option<RuleHit>, state: &InterpreterState) -> Action {
    let Some(hit) = hit else {
        return unresolved(ActionKind::Ignore, text);
    };

    if hit.action == RuleAction::Ignore {
        return Action {
            kind: ActionKind::Ignore,
            direction: None,
            size: None,
            trigger_price: None,
            confidence_high: true,
            needs_approval: false,
            raw_text: text.to_string(),
        };
    }

    let direction = hit.direction.or(state.last_direction);
    let size = hit.size.or_else(|| match hit.action {
        RuleAction::Close => Some(Size::FullClose),
        _ => state.last_trade_size_usd.map(Size::Usd),
    });
    let kind = match hit.action {
        RuleAction::Enter => ActionKind::Enter,
        RuleAction::Add => ActionKind::Add,
        RuleAction::Reduce => ActionKind::Reduce,
        RuleAction::Close => ActionKind::Close,
        RuleAction::Ignore => ActionKind::Ignore,
    };

    let needs_direction = matches!(kind, ActionKind::Enter | ActionKind::Add);
    let needs_size = matches!(
        kind,
        ActionKind::Enter | ActionKind::Add | ActionKind::Reduce
    );
    let complete = (!needs_direction || direction.is_some()) && (!needs_size || size.is_some());
    Action {
        kind,
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
        direction: None,
        size: None,
        trigger_price: None,
        confidence_high: false,
        needs_approval: true,
        raw_text: text.to_string(),
    }
}
