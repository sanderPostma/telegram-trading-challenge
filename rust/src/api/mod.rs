use serde::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock};

use crate::{
    interpreter::{interpret, Action, Asset, Direction, InterpreterState},
    patterns::{
        close_target_should_fire as patterns_close_target_should_fire, default_rules,
        extract_close_target_range, extract_master_balance as patterns_extract_master_balance,
        match_actions, match_first, merge_pattern_documents, parse_pattern_document,
    },
    scaling::{scale_order, ScaleInput, ScaledOrder},
    telegram, weex, Size,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateView {
    pub monitor_running: bool,
    pub simulation_mode: bool,
    pub auto_approve: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultString {
    pub ok: bool,
    pub value: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultAction {
    pub ok: bool,
    pub value: Option<Action>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultActions {
    pub ok: bool,
    pub value: Option<Vec<Action>>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultScaledOrder {
    pub ok: bool,
    pub value: Option<ScaledOrder>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultWeexAccountReconciliation {
    pub ok: bool,
    pub value: Option<weex::WeexAccountReconciliation>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultWeexMarketOrderAck {
    pub ok: bool,
    pub value: Option<weex::WeexMarketOrderAck>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultWeexOrderStatus {
    pub ok: bool,
    pub value: Option<weex::WeexOrderStatus>,
    pub error: Option<String>,
}

/// An action reserved in the dedup store that never reached a final status.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingAction {
    pub dedup_key: String,
    pub channel_id: i64,
    pub message_id: i64,
    pub action_ordinal: u32,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultPendingActions {
    pub ok: bool,
    pub value: Option<Vec<PendingAction>>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResultTelegramLoginStatus {
    pub ok: bool,
    pub value: Option<telegram::TelegramLoginStatus>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeriesPoint {
    pub timestamp_ms: i64,
    pub value: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChartData {
    pub balance: Vec<SeriesPoint>,
    pub equity: Vec<SeriesPoint>,
    pub pnl: Vec<SeriesPoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManualScaleRequest {
    pub amount: f64,
    pub unit: ManualSizeUnit,
    pub master_balance_usd: f64,
    pub my_balance_usd: f64,
    pub mark_price: f64,
    pub qty_step: f64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManualSizeUnit {
    /// A base-asset quantity, in units of whichever asset the order is for.
    Coin,
    Usdt,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct CloseTarget {
    pub low: f64,
    pub high: f64,
}

const CHART_HISTORY_LIMIT: usize = 1_440;

static CHART_HISTORY: OnceLock<Mutex<ChartData>> = OnceLock::new();

fn chart_history() -> &'static Mutex<ChartData> {
    CHART_HISTORY.get_or_init(|| Mutex::new(ChartData::default()))
}

fn push_point(series: &mut Vec<SeriesPoint>, point: SeriesPoint) {
    if let Some(last) = series.last_mut() {
        if last.timestamp_ms == point.timestamp_ms {
            *last = point;
            return;
        }
    }
    series.push(point);
    if series.len() > CHART_HISTORY_LIMIT {
        let remove_count = series.len() - CHART_HISTORY_LIMIT;
        series.drain(0..remove_count);
    }
}

/// Contract facts for one tradable asset, so the UI never restates them.
///
/// These used to be hardcoded on both sides of the bridge — `0.0001` appeared
/// in a dozen Dart literals — which meant the two could drift silently and
/// misround real orders.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetSpec {
    pub asset: Asset,
    pub symbol: String,
    pub display: String,
    pub qty_step: f64,
    pub price_step: f64,
    pub min_order_size: f64,
}

/// Every asset this build can trade, in display order.
pub fn asset_specs() -> Vec<AssetSpec> {
    Asset::ALL
        .into_iter()
        .map(|asset| AssetSpec {
            asset,
            symbol: asset.symbol().to_string(),
            display: asset.display().to_string(),
            qty_step: asset.qty_step(),
            price_step: asset.price_step(),
            min_order_size: asset.min_order_size(),
        })
        .collect()
}

/// Resolves a WEEX symbol back to an asset, for reconciling exchange payloads.
pub fn asset_for_symbol(symbol: String) -> Option<Asset> {
    Asset::from_symbol(&symbol)
}

pub use crate::telegram::{TelegramActionStatus, TelegramClientRequest, TelegramMessageEvent};
pub use crate::weex::PriceTick;

pub async fn weex_public_price_stream(
    asset: Asset,
    sink: crate::frb_generated::StreamSink<PriceTick>,
) {
    weex::stream_public_price(
        asset.symbol().to_string(),
        "wss://ws-contract.weex.com/v3/ws/public".to_string(),
        sink,
    )
    .await;
}

pub async fn telegram_message_stream(
    request: telegram::TelegramClientRequest,
    sink: crate::frb_generated::StreamSink<telegram::TelegramMessageEvent>,
) {
    telegram::stream_channel_messages(request, sink).await;
}

pub async fn telegram_request_code(
    request: telegram::TelegramClientRequest,
) -> ApiResultTelegramLoginStatus {
    match telegram::request_code(request).await {
        Ok(value) => ApiResultTelegramLoginStatus {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultTelegramLoginStatus {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn telegram_sign_in(code: String) -> ApiResultTelegramLoginStatus {
    match telegram::sign_in(code).await {
        Ok(value) => ApiResultTelegramLoginStatus {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultTelegramLoginStatus {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn telegram_check_password(password: String) -> ApiResultTelegramLoginStatus {
    match telegram::check_password(password).await {
        Ok(value) => ApiResultTelegramLoginStatus {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultTelegramLoginStatus {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub fn telegram_finalize_action(
    state_path: String,
    dedup_key: String,
    status: telegram::TelegramActionStatus,
    order_id: Option<String>,
) -> ApiResultString {
    match telegram::finalize_action(state_path, dedup_key, status, order_id) {
        Ok(()) => ApiResultString {
            ok: true,
            value: Some("ok".to_string()),
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

// --- credentials at rest ---------------------------------------------------

/// Seals `credentials_json` into `<dir>/credentials.enc`.
pub fn secrets_save(dir: String, credentials_json: String) -> ApiResultString {
    match crate::secrets::save_credentials(std::path::Path::new(&dir), &credentials_json) {
        Ok(()) => ApiResultString {
            ok: true,
            value: Some("ok".to_string()),
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

/// Opens `<dir>/credentials.enc`. `value` is null when nothing is stored or the
/// blob cannot be opened on this install.
pub fn secrets_load(dir: String) -> ApiResultString {
    match crate::secrets::load_credentials(std::path::Path::new(&dir)) {
        Ok(value) => ApiResultString {
            ok: true,
            value,
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub fn secrets_purge(dir: String) -> ApiResultString {
    match crate::secrets::purge_credentials(std::path::Path::new(&dir)) {
        Ok(()) => ApiResultString {
            ok: true,
            value: Some("ok".to_string()),
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

/// Tightens permissions on the data directory and the secrets inside it.
pub fn secrets_harden(dir: String) -> ApiResultString {
    match crate::secrets::harden_directory(std::path::Path::new(&dir)) {
        Ok(()) => ApiResultString {
            ok: true,
            value: Some("ok".to_string()),
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

// --- risk limits -----------------------------------------------------------

pub use crate::risk::{RiskContext, RiskLimits};

pub fn risk_set_limits(limits: RiskLimits) {
    crate::risk::set_limits(limits);
}

pub fn risk_limits() -> RiskLimits {
    crate::risk::limits()
}

/// Feeds the gate the live account facts it compares limits against.
pub fn risk_update_context(context: RiskContext) {
    crate::risk::update_context(context);
}

pub fn risk_context() -> RiskContext {
    crate::risk::context()
}

/// Dry-runs the gate so the UI can warn before an order is ever sent.
/// `value` is null when the order passes; otherwise it is the rejection reason.
pub fn risk_preview_order(symbol: String, qty: f64, reduce_only: bool) -> ApiResultString {
    match crate::risk::check_order(&symbol, qty, reduce_only) {
        Ok(()) => ApiResultString {
            ok: true,
            value: None,
            error: None,
        },
        Err(reason) => ApiResultString {
            ok: false,
            value: Some(reason.clone()),
            error: Some(reason),
        },
    }
}

/// `value` is null when the signal is fresh enough, otherwise the reason.
pub fn risk_check_signal_age(message_timestamp_ms: i64, now_ms: i64) -> ApiResultString {
    match crate::risk::evaluate_signal_age(&crate::risk::limits(), message_timestamp_ms, now_ms) {
        Ok(()) => ApiResultString {
            ok: true,
            value: None,
            error: None,
        },
        Err(reason) => ApiResultString {
            ok: false,
            value: Some(reason.clone()),
            error: Some(reason),
        },
    }
}

// --- crash recovery --------------------------------------------------------

/// Actions that were reserved but never finalized, newest first. Each is an
/// order we may or may not have placed.
pub fn dedup_pending_actions(state_path: String) -> ApiResultPendingActions {
    match crate::dedup::DedupStore::load(std::path::Path::new(&state_path)) {
        Ok(store) => {
            let mut value: Vec<PendingAction> = store
                .pending_actions()
                .into_iter()
                .map(|(key, record)| PendingAction {
                    dedup_key: key.0,
                    channel_id: record.channel_id,
                    message_id: record.message_id,
                    action_ordinal: record.action_ordinal,
                    updated_at_ms: record.updated_at.timestamp_millis(),
                })
                .collect();
            value.sort_by_key(|action| std::cmp::Reverse(action.updated_at_ms));
            ApiResultPendingActions {
                ok: true,
                value: Some(value),
                error: None,
            }
        }
        Err(error) => ApiResultPendingActions {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

/// Asks the exchange what became of one `client_order_id`.
///
/// An error means "could not determine" — never retry on the strength of it.
/// `ok` with `found: false` means the exchange has no such order.
pub async fn weex_lookup_order(
    request: weex::WeexAccountRequest,
    client_order_id: String,
) -> ApiResultWeexOrderStatus {
    match weex::lookup_order_by_client_id(request, client_order_id).await {
        Ok(value) => ApiResultWeexOrderStatus {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultWeexOrderStatus {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn weex_reconcile_account(
    request: weex::WeexAccountRequest,
) -> ApiResultWeexAccountReconciliation {
    match weex::reconcile_account(request).await {
        Ok(value) => ApiResultWeexAccountReconciliation {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultWeexAccountReconciliation {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn weex_submit_market_order(
    request: weex::WeexMarketOrderRequest,
) -> ApiResultWeexMarketOrderAck {
    match weex::submit_market_order(request).await {
        Ok(value) if value.success => ApiResultWeexMarketOrderAck {
            ok: true,
            value: Some(value),
            error: None,
        },
        Ok(value) => {
            let error = if value.error_message.is_empty() && value.error_code.is_empty() {
                if value.order_id.is_empty() {
                    "WEEX order rejected: no order id or rejection reason was returned".to_string()
                } else {
                    format!(
                        "WEEX order rejected for order {} without a rejection reason",
                        value.order_id
                    )
                }
            } else if value.error_message.is_empty() {
                format!("WEEX order rejected {}", value.error_code)
            } else {
                format!(
                    "WEEX order rejected {}: {}",
                    value.error_code, value.error_message
                )
            };
            ApiResultWeexMarketOrderAck {
                ok: false,
                value: Some(value),
                error: Some(error),
            }
        }
        Err(error) => ApiResultWeexMarketOrderAck {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn weex_submit_algo_order(
    request: weex::WeexAlgoOrderRequest,
) -> ApiResultWeexMarketOrderAck {
    match weex::submit_algo_order(request).await {
        Ok(value) if value.success => ApiResultWeexMarketOrderAck {
            ok: true,
            value: Some(value),
            error: None,
        },
        Ok(value) => ApiResultWeexMarketOrderAck {
            ok: false,
            error: Some(weex_rejection_message(&value)),
            value: Some(value),
        },
        Err(error) => ApiResultWeexMarketOrderAck {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn weex_submit_tp_sl_order(
    request: weex::WeexTpSlOrderRequest,
) -> ApiResultWeexMarketOrderAck {
    match weex::submit_tp_sl_order(request).await {
        Ok(value) if value.success => ApiResultWeexMarketOrderAck {
            ok: true,
            value: Some(value),
            error: None,
        },
        Ok(value) => ApiResultWeexMarketOrderAck {
            ok: false,
            error: Some(weex_rejection_message(&value)),
            value: Some(value),
        },
        Err(error) => ApiResultWeexMarketOrderAck {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub async fn weex_cancel_algo_order(
    request: weex::WeexCancelAlgoRequest,
) -> ApiResultWeexMarketOrderAck {
    match weex::cancel_algo_order(request).await {
        Ok(value) if value.success => ApiResultWeexMarketOrderAck {
            ok: true,
            value: Some(value),
            error: None,
        },
        Ok(value) => ApiResultWeexMarketOrderAck {
            ok: false,
            error: Some(weex_rejection_message(&value)),
            value: Some(value),
        },
        Err(error) => ApiResultWeexMarketOrderAck {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

/// TAKE_PROFIT or STOP_LOSS for a target price against an open position.
pub fn weex_tp_sl_plan_type(
    direction: crate::interpreter::Direction,
    trigger_price: f64,
    mark_price: f64,
) -> String {
    weex::tp_sl_plan_type(direction, trigger_price, mark_price).to_string()
}

pub fn record_chart_snapshot(timestamp_ms: i64, balance: f64, equity: f64, cumulative_pnl: f64) {
    if timestamp_ms <= 0
        || !balance.is_finite()
        || !equity.is_finite()
        || !cumulative_pnl.is_finite()
    {
        return;
    }

    let mut history = chart_history()
        .lock()
        .expect("chart history mutex should not be poisoned");
    push_point(
        &mut history.balance,
        SeriesPoint {
            timestamp_ms,
            value: balance,
        },
    );
    push_point(
        &mut history.equity,
        SeriesPoint {
            timestamp_ms,
            value: equity,
        },
    );
    push_point(
        &mut history.pnl,
        SeriesPoint {
            timestamp_ms,
            value: cumulative_pnl,
        },
    );
}

pub fn get_chart_data() -> ChartData {
    chart_history()
        .lock()
        .expect("chart history mutex should not be poisoned")
        .clone()
}

pub fn get_balance_history() -> Vec<SeriesPoint> {
    get_chart_data().balance
}

pub fn get_equity_history() -> Vec<SeriesPoint> {
    get_chart_data().equity
}

pub fn get_pnl_history() -> Vec<SeriesPoint> {
    get_chart_data().pnl
}

pub fn extract_close_target(text: String) -> Option<CloseTarget> {
    extract_close_target_range(&text).map(|(low, high)| CloseTarget { low, high })
}

pub fn extract_master_balance(text: String) -> Option<f64> {
    patterns_extract_master_balance(&text)
}

pub fn close_target_should_fire(direction: Direction, price: f64, low: f64, high: f64) -> bool {
    patterns_close_target_should_fire(direction, price, low, high)
}

pub fn classify_message(text: String) -> ApiResultAction {
    let rules = default_rules();
    match match_first(&text, &rules) {
        Ok(hit) => ApiResultAction {
            ok: true,
            value: Some(interpret(&text, hit, &InterpreterState::default())),
            error: None,
        },
        Err(error) => ApiResultAction {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub fn classify_message_actions(text: String) -> ApiResultActions {
    let rules = default_rules();
    classify_message_actions_with_rules(text, rules, &InterpreterState::default())
}

pub fn default_patterns_yaml() -> String {
    crate::patterns::default_rules_yaml().to_string()
}

pub fn validate_patterns_yaml(patterns_yaml: String) -> ApiResultString {
    match parse_pattern_document(&patterns_yaml) {
        Ok(_) => ApiResultString {
            ok: true,
            value: Some("ok".to_string()),
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub fn merge_patterns_yaml(base_yaml: String, local_yaml: String) -> ApiResultString {
    match merge_pattern_documents(&base_yaml, &local_yaml) {
        Ok(value) => ApiResultString {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultString {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

/// Classifies a message against `patterns_yaml`.
///
/// `active_assets` are the books with open exposure. They matter because a
/// message that names no asset ("REDUCED 25%") inherits one — and when more
/// than one book is live that reference is ambiguous, so the action comes back
/// with no asset and needs manual review rather than a guess.
pub fn classify_message_actions_with_patterns(
    text: String,
    patterns_yaml: String,
    active_assets: Vec<Asset>,
    last_asset: Option<Asset>,
) -> ApiResultActions {
    let state = InterpreterState {
        active_assets,
        last_asset,
        ..Default::default()
    };
    match parse_pattern_document(&patterns_yaml) {
        Ok(rules) => classify_message_actions_with_rules(text, rules, &state),
        Err(error) => ApiResultActions {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

fn classify_message_actions_with_rules(
    text: String,
    rules: Vec<crate::patterns::PatternRule>,
    state: &InterpreterState,
) -> ApiResultActions {
    match match_actions(&text, &rules) {
        Ok(hits) => {
            let actions = if hits.is_empty() {
                vec![interpret(&text, None, state)]
            } else {
                hits.into_iter()
                    .map(|hit| interpret(&text, Some(hit), state))
                    .collect()
            };
            ApiResultActions {
                ok: true,
                value: Some(actions),
                error: None,
            }
        }
        Err(error) => ApiResultActions {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

fn weex_rejection_message(value: &weex::WeexMarketOrderAck) -> String {
    if value.error_message.is_empty() && value.error_code.is_empty() {
        if value.order_id.is_empty() {
            "WEEX order rejected: no order id or rejection reason was returned".to_string()
        } else {
            format!(
                "WEEX order rejected for order {} without a rejection reason",
                value.order_id
            )
        }
    } else if value.error_message.is_empty() {
        format!("WEEX order rejected {}", value.error_code)
    } else {
        format!(
            "WEEX order rejected {}: {}",
            value.error_code, value.error_message
        )
    }
}

pub fn scale_manual_order(request: ManualScaleRequest) -> ApiResultScaledOrder {
    let size = match request.unit {
        ManualSizeUnit::Coin => Size::Coin(request.amount),
        ManualSizeUnit::Usdt => Size::Usdt(request.amount),
    };
    match scale_order(
        size,
        ScaleInput {
            master_balance_usd: request.master_balance_usd,
            my_balance_usd: request.my_balance_usd,
            mark_price: request.mark_price,
            qty_step: request.qty_step,
        },
    ) {
        Ok(value) => ApiResultScaledOrder {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => ApiResultScaledOrder {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    }
}

pub fn weex_sign_preview(
    secret: String,
    timestamp: i64,
    method: String,
    path: String,
    query: String,
    body: String,
) -> ApiResultString {
    ApiResultString {
        ok: true,
        value: Some(weex::sign(
            &secret, timestamp, &method, &path, &query, &body,
        )),
        error: None,
    }
}

pub fn hello() -> String {
    "trading_challenge_core ready".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[test]
    fn chart_snapshots_are_recorded_and_updated() {
        let timestamp_ms = Utc::now().timestamp_millis();

        record_chart_snapshot(timestamp_ms, 2_000.0, 2_010.0, 0.0);
        record_chart_snapshot(timestamp_ms, 2_005.0, 2_015.0, 5.0);

        let data = get_chart_data();
        let balance = data
            .balance
            .iter()
            .find(|point| point.timestamp_ms == timestamp_ms)
            .expect("balance point should exist");
        let equity = data
            .equity
            .iter()
            .find(|point| point.timestamp_ms == timestamp_ms)
            .expect("equity point should exist");
        let pnl = data
            .pnl
            .iter()
            .find(|point| point.timestamp_ms == timestamp_ms)
            .expect("pnl point should exist");

        assert_eq!(balance.value, 2_005.0);
        assert_eq!(equity.value, 2_015.0);
        assert_eq!(pnl.value, 5.0);
    }
}
