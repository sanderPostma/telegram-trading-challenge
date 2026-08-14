//! Hard limits that sit between any order intent and the exchange.
//!
//! These deliberately live below the signal parser, so a malformed Telegram
//! message, a compromised channel, a scaling bug, or a manual fat-finger all
//! hit the same gate. Nothing reaches WEEX without passing [`evaluate`].
//!
//! Two rules shape the semantics:
//!
//! * Limits restrain *opening* risk. A reduce-only order always passes the
//!   size, exposure, and loss gates — you must be able to flatten a position
//!   even when every other rail has tripped.
//! * A limit of `0.0` (or an empty allowlist) means "not configured", not
//!   "block everything". Fresh installs therefore behave exactly as before,
//!   and each rail activates when the user sets a number.

use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

/// A limit expressed either as an absolute USD amount or as a percentage of
/// account balance.
///
/// The percentage form exists because this app is used for balance-scaling
/// challenges: a fixed "$500 per order" that fits a $7k account strangles the
/// same strategy at $500k, and the failure is silent. "15%" holds across two
/// orders of magnitude without ever being edited.
///
/// `value <= 0` means the limit is off, whichever form it is in.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Limit {
    pub value: f64,
    /// True when [`value`] is a percentage of account balance rather than USD.
    pub percent: bool,
}

impl Default for Limit {
    fn default() -> Self {
        Self::off()
    }
}

impl Limit {
    pub const fn off() -> Self {
        Self {
            value: 0.0,
            percent: false,
        }
    }

    pub const fn usd(value: f64) -> Self {
        Self {
            value,
            percent: false,
        }
    }

    pub const fn percent(value: f64) -> Self {
        Self {
            value,
            percent: true,
        }
    }

    pub fn is_off(&self) -> bool {
        !self.value.is_finite() || self.value <= 0.0
    }

    /// The limit in USD for the given balance.
    ///
    /// `None` when the limit is on but cannot be resolved — a percentage with
    /// no known balance. Callers must treat that as "cannot verify", not as
    /// "no limit".
    pub fn resolve(&self, account_balance_usd: f64) -> Option<f64> {
        if self.is_off() {
            return None;
        }
        if !self.percent {
            return Some(self.value);
        }
        if account_balance_usd <= 0.0 || !account_balance_usd.is_finite() {
            return None;
        }
        Some(account_balance_usd * self.value / 100.0)
    }

    /// How the limit reads back to the user.
    pub fn describe(&self) -> String {
        if self.percent {
            format!("{}%", trim_number(self.value))
        } else {
            format!("${}", trim_number(self.value))
        }
    }
}

fn trim_number(value: f64) -> String {
    if (value - value.round()).abs() < f64::EPSILON {
        format!("{}", value.round() as i64)
    } else {
        format!("{value:.2}")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RiskLimits {
    /// Blocks every new opening order. Reduce-only still passes.
    pub kill_switch: bool,
    /// Largest notional (qty x reference price) a single opening order may have.
    pub max_order_notional: Limit,
    /// Largest total position notional allowed after the order fills.
    pub max_position_notional: Limit,
    /// Symbols that may be traded at all. Empty means "no allowlist configured".
    pub symbol_allowlist: Vec<String>,
    /// Largest account leverage allowed when opening.
    pub max_leverage: f64,
    /// Stops opening once realized loss today reaches this much.
    pub daily_loss: Limit,
    /// Rejects signals older than this. Guards against replayed backlog after
    /// a long disconnect.
    pub max_signal_age_secs: i64,
}

impl Default for RiskLimits {
    fn default() -> Self {
        Self {
            kill_switch: false,
            max_order_notional: Limit::off(),
            max_position_notional: Limit::off(),
            symbol_allowlist: Vec::new(),
            max_leverage: 0.0,
            daily_loss: Limit::off(),
            max_signal_age_secs: 0,
        }
    }
}

/// The mark price of one traded symbol.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SymbolPrice {
    pub symbol: String,
    pub price: f64,
}

impl RiskContext {
    /// The mark price to value `symbol` at, falling back to the single
    /// reference price when the symbol has no entry of its own.
    pub fn price_for(&self, symbol: &str) -> f64 {
        self.reference_prices
            .iter()
            .find(|entry| entry.symbol.eq_ignore_ascii_case(symbol))
            .map(|entry| entry.price)
            .unwrap_or(self.reference_price)
    }
}

/// Live account facts the gate compares limits against.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RiskContext {
    /// Fallback mark price, used when the order's symbol has no entry in
    /// [`RiskContext::reference_prices`].
    pub reference_price: f64,
    /// Mark price per symbol. An order must be valued at its own symbol's
    /// price: sizing a 2 ETH order off the BTC mark overstates its notional
    /// thirtyfold, and the reverse understates it — one spuriously trips a cap
    /// and the other silently waves an oversized order through.
    pub reference_prices: Vec<SymbolPrice>,
    /// Combined notional of every open position, 0 when flat. This is an
    /// account-wide rail, so it must span all books, not just one.
    pub open_position_notional_usd: f64,
    /// Account leverage currently in effect.
    pub leverage: f64,
    /// Realized PnL since midnight UTC. Negative is a loss.
    pub realized_pnl_today_usd: f64,
    /// Account balance, the basis for percentage limits.
    pub account_balance_usd: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OrderIntent {
    pub symbol: String,
    pub qty: f64,
    /// Reduce-only orders are exits and bypass the opening-risk gates.
    pub reduce_only: bool,
}

/// Checks one order intent against the configured limits.
///
/// `Ok(())` means the order may proceed. The `Err` string is user-facing and
/// says which rail tripped and by how much.
pub fn evaluate(
    limits: &RiskLimits,
    context: &RiskContext,
    intent: &OrderIntent,
) -> Result<(), String> {
    if !limits.symbol_allowlist.is_empty()
        && !limits
            .symbol_allowlist
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(&intent.symbol))
    {
        return Err(format!(
            "Risk limit: {} is not on the symbol allowlist ({})",
            intent.symbol,
            limits.symbol_allowlist.join(", ")
        ));
    }

    if !intent.qty.is_finite() || intent.qty <= 0.0 {
        return Err("Risk limit: order quantity must be a positive number".to_string());
    }

    // Everything below restrains opening risk only. An exit must always be
    // possible, so reduce-only stops here.
    if intent.reduce_only {
        return Ok(());
    }

    if limits.kill_switch {
        return Err(
            "Risk limit: kill switch is engaged; new positions are blocked (closing still works)"
                .to_string(),
        );
    }

    let reference_price = context.price_for(&intent.symbol);
    let notional = intent.qty * reference_price;
    if !limits.max_order_notional.is_off() {
        if reference_price <= 0.0 {
            return Err(
                "Risk limit: no mark price available to size-check this order".to_string(),
            );
        }
        let Some(cap) = limits.max_order_notional.resolve(context.account_balance_usd) else {
            return Err(format!(
                "Risk limit: per-order cap is {} of balance but the account balance is unknown",
                limits.max_order_notional.describe()
            ));
        };
        if notional > cap {
            return Err(format!(
                "Risk limit: order notional ${notional:.2} exceeds the {} per-order cap (${cap:.2})",
                limits.max_order_notional.describe()
            ));
        }
    }

    if !limits.max_position_notional.is_off() {
        if reference_price <= 0.0 {
            return Err(
                "Risk limit: no mark price available to check total exposure".to_string(),
            );
        }
        let Some(cap) = limits.max_position_notional.resolve(context.account_balance_usd) else {
            return Err(format!(
                "Risk limit: exposure cap is {} of balance but the account balance is unknown",
                limits.max_position_notional.describe()
            ));
        };
        let projected = context.open_position_notional_usd + notional;
        if projected > cap {
            return Err(format!(
                "Risk limit: total exposure ${projected:.2} would exceed the {} cap (${cap:.2})",
                limits.max_position_notional.describe()
            ));
        }
    }

    if limits.max_leverage > 0.0 && context.leverage > limits.max_leverage {
        return Err(format!(
            "Risk limit: account leverage {:.1}x exceeds the {:.1}x cap",
            context.leverage, limits.max_leverage
        ));
    }

    if !limits.daily_loss.is_off() {
        let Some(cap) = limits.daily_loss.resolve(context.account_balance_usd) else {
            return Err(format!(
                "Risk limit: daily loss cap is {} of balance but the account balance is unknown",
                limits.daily_loss.describe()
            ));
        };
        let loss = -context.realized_pnl_today_usd;
        if loss >= cap {
            return Err(format!(
                "Risk limit: today's realized loss ${loss:.2} has reached the {} daily cap (${cap:.2})",
                limits.daily_loss.describe()
            ));
        }
    }

    Ok(())
}

/// Rejects a signal that has aged past the configured cutoff.
pub fn evaluate_signal_age(
    limits: &RiskLimits,
    message_timestamp_ms: i64,
    now_ms: i64,
) -> Result<(), String> {
    if limits.max_signal_age_secs <= 0 || message_timestamp_ms <= 0 {
        return Ok(());
    }
    let age_secs = (now_ms - message_timestamp_ms) / 1000;
    if age_secs > limits.max_signal_age_secs {
        return Err(format!(
            "Risk limit: signal is {age_secs}s old, past the {}s cutoff",
            limits.max_signal_age_secs
        ));
    }
    Ok(())
}

// --- process-wide state, set from the UI layer -----------------------------

static STATE: OnceLock<Mutex<(RiskLimits, RiskContext)>> = OnceLock::new();

fn state() -> &'static Mutex<(RiskLimits, RiskContext)> {
    STATE.get_or_init(|| Mutex::new((RiskLimits::default(), RiskContext::default())))
}

pub fn set_limits(limits: RiskLimits) {
    if let Ok(mut guard) = state().lock() {
        guard.0 = limits;
    }
}

pub fn limits() -> RiskLimits {
    state()
        .lock()
        .map(|guard| guard.0.clone())
        .unwrap_or_default()
}

pub fn update_context(context: RiskContext) {
    if let Ok(mut guard) = state().lock() {
        guard.1 = context;
    }
}

pub fn context() -> RiskContext {
    state()
        .lock()
        .map(|guard| guard.1.clone())
        .unwrap_or_default()
}

/// Allowlist-only gate for protective orders (take-profit, stop-loss, cancel).
/// Their size caps are meaningless — a plan that closes the whole position
/// carries quantity 0 — but a symbol the user never allowlisted is still a bug
/// worth stopping.
pub fn check_symbol(symbol: &str) -> Result<(), String> {
    let limits = limits();
    if limits.symbol_allowlist.is_empty()
        || limits
            .symbol_allowlist
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(symbol))
    {
        return Ok(());
    }
    Err(format!(
        "Risk limit: {symbol} is not on the symbol allowlist ({})",
        limits.symbol_allowlist.join(", ")
    ))
}

/// Gate used by the WEEX submit path.
pub fn check_order(symbol: &str, qty: f64, reduce_only: bool) -> Result<(), String> {
    let (limits, context) = match state().lock() {
        Ok(guard) => (guard.0.clone(), guard.1.clone()),
        // A poisoned lock means a panic left the limits unreadable. Refuse to
        // open rather than trade unguarded.
        Err(_) if !reduce_only => {
            return Err("Risk limit: limits are unavailable; refusing to open".to_string())
        }
        Err(_) => return Ok(()),
    };
    evaluate(
        &limits,
        &context,
        &OrderIntent {
            symbol: symbol.to_string(),
            qty,
            reduce_only,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn intent(qty: f64) -> OrderIntent {
        OrderIntent {
            symbol: "BTCUSDT".to_string(),
            qty,
            reduce_only: false,
        }
    }

    fn context() -> RiskContext {
        RiskContext {
            reference_price: 60_000.0,
            reference_prices: Vec::new(),
            open_position_notional_usd: 0.0,
            leverage: 5.0,
            realized_pnl_today_usd: 0.0,
            account_balance_usd: 7_000.0,
        }
    }

    #[test]
    fn default_limits_allow_existing_behaviour() {
        let result = evaluate(&RiskLimits::default(), &context(), &intent(1.0));
        assert!(result.is_ok(), "{result:?}");
    }

    #[test]
    fn blocks_symbol_outside_allowlist() {
        let limits = RiskLimits {
            symbol_allowlist: vec!["BTCUSDT".to_string()],
            ..Default::default()
        };
        let mut intent = intent(0.1);
        intent.symbol = "DOGEUSDT".to_string();
        assert!(evaluate(&limits, &context(), &intent)
            .unwrap_err()
            .contains("allowlist"));
    }

    #[test]
    fn allowlist_check_is_case_insensitive() {
        let limits = RiskLimits {
            symbol_allowlist: vec!["btcusdt".to_string()],
            ..Default::default()
        };
        assert!(evaluate(&limits, &context(), &intent(0.1)).is_ok());
    }

    #[test]
    fn blocks_oversized_order_by_notional() {
        let limits = RiskLimits {
            max_order_notional: Limit::usd(1_000.0),
            ..Default::default()
        };
        // 0.1 BTC at 60k = $6,000.
        assert!(evaluate(&limits, &context(), &intent(0.1))
            .unwrap_err()
            .contains("per-order cap"));
        // 0.01 BTC at 60k = $600.
        assert!(evaluate(&limits, &context(), &intent(0.01)).is_ok());
    }

    #[test]
    fn blocks_when_total_exposure_would_exceed_cap() {
        let limits = RiskLimits {
            max_position_notional: Limit::usd(10_000.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.open_position_notional_usd = 7_000.0;
        // Adding $6,000 to $7,000 breaches $10,000.
        assert!(evaluate(&limits, &ctx, &intent(0.1))
            .unwrap_err()
            .contains("total exposure"));
    }

    #[test]
    fn refuses_to_size_check_without_a_mark_price() {
        let limits = RiskLimits {
            max_order_notional: Limit::usd(1_000.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.reference_price = 0.0;
        assert!(evaluate(&limits, &ctx, &intent(0.1))
            .unwrap_err()
            .contains("no mark price"));
    }

    #[test]
    fn blocks_when_leverage_exceeds_cap() {
        let limits = RiskLimits {
            max_leverage: 3.0,
            ..Default::default()
        };
        assert!(evaluate(&limits, &context(), &intent(0.01)).is_err());
    }

    #[test]
    fn blocks_after_daily_loss_limit_is_reached() {
        let limits = RiskLimits {
            daily_loss: Limit::usd(200.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.realized_pnl_today_usd = -250.0;
        assert!(evaluate(&limits, &ctx, &intent(0.01))
            .unwrap_err()
            .contains("daily cap"));

        ctx.realized_pnl_today_usd = -150.0;
        assert!(evaluate(&limits, &ctx, &intent(0.01)).is_ok());
    }

    #[test]
    fn profit_never_trips_the_daily_loss_limit() {
        let limits = RiskLimits {
            daily_loss: Limit::usd(200.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.realized_pnl_today_usd = 5_000.0;
        assert!(evaluate(&limits, &ctx, &intent(0.01)).is_ok());
    }

    #[test]
    fn a_percentage_cap_scales_with_the_account() {
        // The whole point: one setting that holds from $7k to $1M.
        let limits = RiskLimits {
            max_order_notional: Limit::percent(15.0),
            ..Default::default()
        };

        // At $7,000, 15% is $1,050 — 0.1 BTC ($6,000) is far too big.
        let mut small = context();
        small.account_balance_usd = 7_000.0;
        assert!(evaluate(&limits, &small, &intent(0.1)).is_err());
        // 0.01 BTC = $600, comfortably inside.
        assert!(evaluate(&limits, &small, &intent(0.01)).is_ok());

        // At $1,000,000, 15% is $150,000 — the same 0.1 BTC now passes, with
        // no setting changed.
        let mut large = context();
        large.account_balance_usd = 1_000_000.0;
        assert!(evaluate(&limits, &large, &intent(0.1)).is_ok());
        // 3 BTC = $180,000 still trips it.
        assert!(evaluate(&limits, &large, &intent(3.0)).is_err());
    }

    #[test]
    fn a_percentage_daily_loss_cap_scales_too() {
        let limits = RiskLimits {
            daily_loss: Limit::percent(8.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.account_balance_usd = 100_000.0; // 8% = $8,000

        ctx.realized_pnl_today_usd = -7_000.0;
        assert!(evaluate(&limits, &ctx, &intent(0.01)).is_ok());
        ctx.realized_pnl_today_usd = -8_500.0;
        assert!(evaluate(&limits, &ctx, &intent(0.01)).is_err());
    }

    #[test]
    fn a_percentage_cap_blocks_when_the_balance_is_unknown() {
        // Refusing to open beats opening unmeasured.
        let limits = RiskLimits {
            max_order_notional: Limit::percent(15.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.account_balance_usd = 0.0;
        assert!(evaluate(&limits, &ctx, &intent(0.01))
            .unwrap_err()
            .contains("balance is unknown"));
    }

    #[test]
    fn an_unknown_balance_still_lets_a_position_be_closed() {
        let limits = RiskLimits {
            max_order_notional: Limit::percent(1.0),
            daily_loss: Limit::percent(1.0),
            ..Default::default()
        };
        let mut ctx = context();
        ctx.account_balance_usd = 0.0;
        let exit = OrderIntent {
            symbol: "BTCUSDT".to_string(),
            qty: 5.0,
            reduce_only: true,
        };
        assert!(evaluate(&limits, &ctx, &exit).is_ok());
    }

    #[test]
    fn limits_resolve_and_describe_in_both_forms() {
        assert_eq!(Limit::usd(5000.0).resolve(7_000.0), Some(5000.0));
        assert_eq!(Limit::percent(15.0).resolve(7_000.0), Some(1_050.0));
        assert_eq!(Limit::percent(15.0).resolve(0.0), None);
        assert_eq!(Limit::off().resolve(7_000.0), None);
        assert_eq!(Limit::usd(5000.0).describe(), "$5000");
        assert_eq!(Limit::percent(15.0).describe(), "15%");
        assert_eq!(Limit::percent(12.5).describe(), "12.50%");
        assert!(Limit::off().is_off());
        assert!(Limit::usd(-3.0).is_off());
    }

    #[test]
    fn kill_switch_blocks_opening() {
        let limits = RiskLimits {
            kill_switch: true,
            ..Default::default()
        };
        assert!(evaluate(&limits, &context(), &intent(0.01))
            .unwrap_err()
            .contains("kill switch"));
    }

    #[test]
    fn every_rail_still_lets_a_position_be_closed() {
        let limits = RiskLimits {
            kill_switch: true,
            max_order_notional: Limit::usd(1.0),
            max_position_notional: Limit::usd(1.0),
            symbol_allowlist: vec!["BTCUSDT".to_string()],
            max_leverage: 1.0,
            daily_loss: Limit::usd(1.0),
            max_signal_age_secs: 1,
        };
        let mut ctx = context();
        ctx.realized_pnl_today_usd = -10_000.0;
        ctx.open_position_notional_usd = 50_000.0;
        let exit = OrderIntent {
            symbol: "BTCUSDT".to_string(),
            qty: 5.0,
            reduce_only: true,
        };
        assert!(evaluate(&limits, &ctx, &exit).is_ok());
    }

    #[test]
    fn allowlist_still_applies_to_exits() {
        // A reduce-only order on an unexpected symbol is a bug, not an exit.
        let limits = RiskLimits {
            symbol_allowlist: vec!["BTCUSDT".to_string()],
            ..Default::default()
        };
        let exit = OrderIntent {
            symbol: "ETHUSDT".to_string(),
            qty: 1.0,
            reduce_only: true,
        };
        assert!(evaluate(&limits, &context(), &exit).is_err());
    }

    #[test]
    fn rejects_non_positive_or_non_finite_quantities() {
        let limits = RiskLimits::default();
        assert!(evaluate(&limits, &context(), &intent(0.0)).is_err());
        assert!(evaluate(&limits, &context(), &intent(-1.0)).is_err());
        assert!(evaluate(&limits, &context(), &intent(f64::NAN)).is_err());
        assert!(evaluate(&limits, &context(), &intent(f64::INFINITY)).is_err());
    }

    #[test]
    fn stale_signals_are_rejected_once_a_cutoff_is_set() {
        let limits = RiskLimits {
            max_signal_age_secs: 300,
            ..Default::default()
        };
        let now = 1_700_000_000_000;
        assert!(evaluate_signal_age(&limits, now - 60_000, now).is_ok());
        assert!(evaluate_signal_age(&limits, now - 600_000, now).is_err());
    }

    #[test]
    fn signal_age_is_unrestricted_by_default() {
        let now = 1_700_000_000_000;
        assert!(evaluate_signal_age(&RiskLimits::default(), now - 86_400_000, now).is_ok());
    }

    #[test]
    fn an_order_is_valued_at_its_own_symbols_price() {
        // The multi-asset trap: valuing a 2 ETH order at the BTC mark makes it
        // look like a $126k order and trips a cap it should clear.
        let limits = RiskLimits {
            max_order_notional: Limit::usd(10_000.0),
            ..Default::default()
        };
        let context = RiskContext {
            reference_price: 63_000.0,
            reference_prices: vec![
                SymbolPrice {
                    symbol: "BTCUSDT".to_string(),
                    price: 63_000.0,
                },
                SymbolPrice {
                    symbol: "ETHUSDT".to_string(),
                    price: 1_877.0,
                },
            ],
            ..Default::default()
        };

        // 2 ETH at 1877 = $3,754 — under the cap.
        let eth = OrderIntent {
            symbol: "ETHUSDT".to_string(),
            qty: 2.0,
            reduce_only: false,
        };
        assert!(
            evaluate(&limits, &context, &eth).is_ok(),
            "an ETH order must be valued at the ETH mark"
        );

        // 2 BTC at 63000 = $126,000 — over it.
        let btc = OrderIntent {
            symbol: "BTCUSDT".to_string(),
            qty: 2.0,
            reduce_only: false,
        };
        assert!(evaluate(&limits, &context, &btc).is_err());
    }

    #[test]
    fn an_unknown_symbol_falls_back_to_the_single_reference_price() {
        let context = RiskContext {
            reference_price: 63_000.0,
            reference_prices: Vec::new(),
            ..Default::default()
        };
        assert_eq!(context.price_for("BTCUSDT"), 63_000.0);
        assert_eq!(context.price_for("SOLUSDT"), 63_000.0);
    }

    #[test]
    fn symbol_price_lookup_ignores_case() {
        let context = RiskContext {
            reference_price: 1.0,
            reference_prices: vec![SymbolPrice {
                symbol: "ETHUSDT".to_string(),
                price: 1_877.0,
            }],
            ..Default::default()
        };
        assert_eq!(context.price_for("ethusdt"), 1_877.0);
    }
}
