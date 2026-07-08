use serde::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock};

use crate::{
    interpreter::{interpret, Action, InterpreterState},
    patterns::{default_rules, match_first},
    scaling::{scale_order, ScaleInput, ScaledOrder},
    weex, Size,
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
    Btc,
    Usdt,
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

pub use crate::weex::PriceTick;

pub async fn weex_public_price_stream(sink: crate::frb_generated::StreamSink<PriceTick>) {
    weex::stream_public_price(
        "BTCUSDT".to_string(),
        "wss://ws-spot.weex.com/v3/ws/public".to_string(),
        sink,
    )
    .await;
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
            let error = if value.error_message.is_empty() {
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

pub fn scale_manual_order(request: ManualScaleRequest) -> ApiResultScaledOrder {
    let size = match request.unit {
        ManualSizeUnit::Btc => Size::Btc(request.amount),
        ManualSizeUnit::Usdt => Size::Usd(request.amount),
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
