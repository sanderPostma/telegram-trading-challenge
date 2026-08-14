use base64::Engine;
use chrono::Utc;
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use reqwest::{
    header::{HeaderMap, HeaderValue, CONTENT_TYPE},
    Method,
};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use std::time::Duration as StdDuration;
use tokio::time::{sleep, timeout, Duration};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::header::USER_AGENT, Message},
};

use crate::execution::{position_side, OrderRequest, OrderSide};
use crate::interpreter::Direction;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct WeexCredentials {
    pub api_key: String,
    pub api_secret: String,
    pub passphrase: String,
}

#[derive(Debug, Clone)]
pub struct WeexConfig {
    pub symbol: String,
    pub qty_step: f64,
    pub price_step: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceTick {
    pub symbol: String,
    pub price: Option<f64>,
    pub bid: Option<f64>,
    pub ask: Option<f64>,
    pub source: String,
    pub event_time_ms: Option<i64>,
    pub received_at_ms: i64,
    pub ok: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexAccountRequest {
    pub api_key: String,
    pub api_secret: String,
    pub passphrase: String,
    pub symbol: String,
    pub base_url: String,
    pub recent_lookback_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexMarketOrderRequest {
    pub api_key: String,
    pub api_secret: String,
    pub passphrase: String,
    pub symbol: String,
    pub base_url: String,
    pub side: String,
    pub qty: f64,
    pub reduce_only: bool,
    pub client_order_id: String,
    pub qty_step: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexAlgoOrderRequest {
    pub api_key: String,
    pub api_secret: String,
    pub passphrase: String,
    pub symbol: String,
    pub base_url: String,
    pub side: String,
    pub qty: f64,
    pub trigger_price: f64,
    pub limit_price: f64,
    pub order_type: String,
    pub client_algo_id: String,
    pub qty_step: f64,
    pub price_step: f64,
}

/// A take-profit (or stop-loss) attached to an open position. Unlike an algo
/// order it carries no side of its own: the exchange closes whatever is open on
/// `position_side` when `trigger_price` is reached, so it stays correct as the
/// position is added to or partially reduced.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexTpSlOrderRequest {
    pub api_key: String,
    pub api_secret: String,
    pub passphrase: String,
    pub symbol: String,
    pub base_url: String,
    /// LONG or SHORT: the position this plan protects.
    pub position_side: String,
    /// TAKE_PROFIT or STOP_LOSS.
    pub plan_type: String,
    pub trigger_price: f64,
    /// 0 closes the entire position — the scalping default.
    pub qty: f64,
    pub client_algo_id: String,
    pub qty_step: f64,
    pub price_step: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexCancelAlgoRequest {
    pub api_key: String,
    pub api_secret: String,
    pub passphrase: String,
    pub symbol: String,
    pub base_url: String,
    pub order_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexMarketOrderAck {
    pub order_id: String,
    pub client_order_id: Option<String>,
    pub success: bool,
    pub error_code: String,
    pub error_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexAccountBalance {
    pub asset: String,
    pub wallet_balance: f64,
    pub available_balance: f64,
    pub unrealized_pnl: f64,
    pub equity: f64,
    pub used_margin: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexPositionSnapshot {
    pub symbol: String,
    pub direction: String,
    pub qty: f64,
    pub entry_price: f64,
    pub mark_price: f64,
    pub notional_usdt: f64,
    pub unrealized_pnl_usdt: f64,
    pub leverage: f64,
    pub liquidation_price: Option<f64>,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexExecutionSnapshot {
    pub exec_id: String,
    pub order_id: String,
    /// The contract this fill belongs to. Needed once more than one book can
    /// be open: without it, reconciliation cannot tell an ETH fill from a BTC
    /// one and would apply both to the same position.
    pub symbol: String,
    pub side: String,
    pub position_side: String,
    pub kind: String,
    pub direction: String,
    pub price: f64,
    pub qty: f64,
    pub notional_usdt: f64,
    pub realized_pnl_usdt: f64,
    pub fee_usdt: f64,
    pub timestamp_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexAccountReconciliation {
    pub balance: WeexAccountBalance,
    pub position: WeexPositionSnapshot,
    pub recent_executions: Vec<WeexExecutionSnapshot>,
    pub timestamp_ms: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContractBalance {
    asset: String,
    #[serde(default)]
    balance: String,
    #[serde(default)]
    available_balance: String,
    #[serde(default)]
    frozen: String,
    #[serde(default)]
    unrealize_pnl: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContractPosition {
    symbol: String,
    #[serde(default)]
    side: String,
    #[serde(default)]
    size: String,
    #[serde(default)]
    open_value: String,
    #[serde(default)]
    leverage: String,
    #[serde(default)]
    updated_time: i64,
    #[serde(default)]
    unrealize_pnl: String,
    #[serde(default)]
    liquidate_price: String,
}

#[derive(Debug, Deserialize)]
struct ContractTicker {
    #[serde(default, rename = "markPrice")]
    mark_price: String,
    #[serde(default)]
    last: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContractTrade {
    id: Value,
    order_id: Value,
    #[serde(default)]
    symbol: String,
    #[serde(default)]
    price: String,
    #[serde(default)]
    qty: String,
    #[serde(default)]
    quote_qty: String,
    #[serde(default)]
    realized_pnl: String,
    #[serde(default)]
    commission: String,
    #[serde(default)]
    time: i64,
    #[serde(default)]
    side: String,
    #[serde(default)]
    position_side: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContractOrderAck {
    #[serde(default)]
    order_id: Value,
    #[serde(default)]
    client_order_id: Value,
    #[serde(default)]
    client_algo_id: Value,
    #[serde(default)]
    success: Option<bool>,
    #[serde(default)]
    error_code: Value,
    #[serde(default)]
    error_message: Value,
}

impl Default for WeexConfig {
    fn default() -> Self {
        Self {
            symbol: "BTCUSDT".to_string(),
            qty_step: 0.0001,
            price_step: 0.1,
        }
    }
}

pub fn sign(
    secret: &str,
    timestamp: i64,
    method: &str,
    path: &str,
    query: &str,
    body: &str,
) -> String {
    let prehash = if query.is_empty() {
        format!("{timestamp}{method}{path}{body}")
    } else {
        format!("{timestamp}{method}{path}?{query}{body}")
    };
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC init");
    mac.update(prehash.as_bytes());
    base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes())
}

pub async fn reconcile_account(
    request: WeexAccountRequest,
) -> anyhow::Result<WeexAccountReconciliation> {
    let client = SignedRestClient::new(request)?;
    let balance = client.fetch_balance().await?;
    let mark_price = client.fetch_mark_price().await.unwrap_or(0.0);
    let position = client.fetch_position(mark_price).await?;
    let mut recent_executions = client.fetch_recent_executions().await.unwrap_or_default();
    let final_signed_qty = match position.direction.as_str() {
        "long" => position.qty,
        "short" => -position.qty,
        _ => 0.0,
    };
    classify_executions(&mut recent_executions, final_signed_qty);

    Ok(WeexAccountReconciliation {
        balance,
        position,
        recent_executions,
        timestamp_ms: Utc::now().timestamp_millis(),
    })
}

pub async fn submit_market_order(
    request: WeexMarketOrderRequest,
) -> anyhow::Result<WeexMarketOrderAck> {
    let client = SignedRestClient::new(WeexAccountRequest {
        api_key: request.api_key,
        api_secret: request.api_secret,
        passphrase: request.passphrase,
        symbol: request.symbol,
        base_url: request.base_url,
        recent_lookback_ms: 7 * 24 * 60 * 60 * 1000,
    })?;
    let side = if request.side.eq_ignore_ascii_case("buy") {
        OrderSide::Buy
    } else if request.side.eq_ignore_ascii_case("sell") {
        OrderSide::Sell
    } else {
        anyhow::bail!("WEEX market order side must be buy or sell");
    };
    if request.qty <= 0.0 || !request.qty.is_finite() {
        anyhow::bail!("WEEX market order quantity must be positive");
    }
    // The last gate before the exchange. Everything upstream — Telegram
    // parsing, scaling, manual entry — funnels through here.
    if let Err(reason) =
        crate::risk::check_order(&client.request.symbol, request.qty, request.reduce_only)
    {
        anyhow::bail!(reason);
    }
    let mut order = OrderRequest::market(&client.request.symbol, side, request.qty);
    order.client_order_id = Some(sanitize_client_order_id(&request.client_order_id));
    if request.reduce_only {
        order = order.reduce_only();
    }
    let body = market_order_body(&order, request.qty_step);
    let ack: ContractOrderAck = client.post("/capi/v3/order", body).await?;
    let order_id = json_id_to_string(&ack.order_id);
    let error_code = json_scalar_to_string(&ack.error_code);
    let error_message = json_scalar_to_string(&ack.error_message);
    let success = ack.success.unwrap_or_else(|| {
        !order_id.is_empty() && (error_code.is_empty() || error_code == "0" || error_code == "200")
    });
    Ok(WeexMarketOrderAck {
        order_id,
        client_order_id: json_optional_id_to_string(&ack.client_order_id),
        success,
        error_code,
        error_message,
    })
}

pub async fn submit_algo_order(
    request: WeexAlgoOrderRequest,
) -> anyhow::Result<WeexMarketOrderAck> {
    let client = SignedRestClient::new(WeexAccountRequest {
        api_key: request.api_key,
        api_secret: request.api_secret,
        passphrase: request.passphrase,
        symbol: request.symbol,
        base_url: request.base_url,
        recent_lookback_ms: 7 * 24 * 60 * 60 * 1000,
    })?;
    let side = parse_order_side(&request.side)?;
    if request.qty <= 0.0 || !request.qty.is_finite() {
        anyhow::bail!("WEEX conditional order quantity must be positive");
    }
    if request.trigger_price <= 0.0 || !request.trigger_price.is_finite() {
        anyhow::bail!("WEEX conditional order trigger price must be positive");
    }
    if request.limit_price <= 0.0 || !request.limit_price.is_finite() {
        anyhow::bail!("WEEX conditional limit price must be positive");
    }
    let order_type = request.order_type.trim().to_ascii_uppercase();
    if !matches!(order_type.as_str(), "STOP" | "TAKE_PROFIT") {
        anyhow::bail!("WEEX conditional limit order type must be STOP or TAKE_PROFIT");
    }
    if let Err(reason) = crate::risk::check_symbol(&client.request.symbol) {
        anyhow::bail!(reason);
    }

    let body = algo_order_body(
        &client.request.symbol,
        side,
        request.qty,
        request.trigger_price,
        request.limit_price,
        &order_type,
        &request.client_algo_id,
        request.qty_step,
        request.price_step,
    );
    let ack: ContractOrderAck = client.post("/capi/v3/algoOrder", body).await?;
    let order_id = json_id_to_string(&ack.order_id);
    let error_code = json_scalar_to_string(&ack.error_code);
    let error_message = json_scalar_to_string(&ack.error_message);
    let success = ack.success.unwrap_or_else(|| {
        !order_id.is_empty() && (error_code.is_empty() || error_code == "0" || error_code == "200")
    });
    Ok(WeexMarketOrderAck {
        order_id,
        client_order_id: json_optional_id_to_string(&ack.client_order_id)
            .or_else(|| json_optional_id_to_string(&ack.client_algo_id)),
        success,
        error_code,
        error_message,
    })
}

/// Places a take-profit/stop-loss plan against an open position.
/// `POST /capi/v3/placeTpSlOrder`. Quantity 0 (the default) closes the whole
/// position at market when the trigger is reached.
pub async fn submit_tp_sl_order(
    request: WeexTpSlOrderRequest,
) -> anyhow::Result<WeexMarketOrderAck> {
    let client = SignedRestClient::new(WeexAccountRequest {
        api_key: request.api_key,
        api_secret: request.api_secret,
        passphrase: request.passphrase,
        symbol: request.symbol,
        base_url: request.base_url,
        recent_lookback_ms: 7 * 24 * 60 * 60 * 1000,
    })?;
    let position_side = normalize_position_side(&request.position_side)?;
    let plan_type = request.plan_type.trim().to_ascii_uppercase();
    if !matches!(plan_type.as_str(), "TAKE_PROFIT" | "STOP_LOSS") {
        anyhow::bail!("WEEX TP/SL plan type must be TAKE_PROFIT or STOP_LOSS");
    }
    if request.trigger_price <= 0.0 || !request.trigger_price.is_finite() {
        anyhow::bail!("WEEX TP/SL trigger price must be positive");
    }
    if request.qty < 0.0 || !request.qty.is_finite() {
        anyhow::bail!("WEEX TP/SL quantity must be zero (whole position) or positive");
    }
    if let Err(reason) = crate::risk::check_symbol(&client.request.symbol) {
        anyhow::bail!(reason);
    }

    let body = tp_sl_order_body(
        &client.request.symbol,
        position_side,
        &plan_type,
        request.trigger_price,
        request.qty,
        &request.client_algo_id,
        request.qty_step,
        request.price_step,
    );
    let payload: Value = client.post("/capi/v3/placeTpSlOrder", body).await?;
    Ok(ack_from_payload(payload)?)
}

/// What the exchange knows about one `client_order_id`.
///
/// `found: false` is a positive statement — the exchange answered and has no
/// such order, so it never landed. An `Err` from [`lookup_order_by_client_id`]
/// means the opposite: we could not find out, and nothing should be retried on
/// the strength of it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeexOrderStatus {
    pub found: bool,
    pub order_id: String,
    pub client_order_id: Option<String>,
    /// Exchange status verbatim (NEW, PARTIALLY_FILLED, FILLED, CANCELED,
    /// REJECTED), uppercased. Empty when the order is absent.
    pub status: String,
    pub filled_qty: f64,
    pub avg_price: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContractOrderDetail {
    #[serde(default)]
    order_id: Value,
    #[serde(default)]
    client_order_id: Value,
    #[serde(default)]
    status: String,
    #[serde(default)]
    executed_qty: String,
    #[serde(default)]
    avg_price: String,
}

/// Asks WEEX what happened to an order we submitted but never got an answer
/// for — the crash-during-submit case. `GET /capi/v3/order`.
pub async fn lookup_order_by_client_id(
    request: WeexAccountRequest,
    client_order_id: String,
) -> anyhow::Result<WeexOrderStatus> {
    let client_order_id = sanitize_client_order_id(&client_order_id);
    if client_order_id.is_empty() {
        anyhow::bail!("WEEX order lookup requires a client order id");
    }
    let client = SignedRestClient::new(request)?;
    let detail: ContractOrderDetail = client
        .get(
            "/capi/v3/order",
            &[
                ("symbol", client.request.symbol.clone()),
                ("origClientOrderId", client_order_id.clone()),
            ],
        )
        .await?;

    let order_id = json_id_to_string(&detail.order_id);
    if order_id.is_empty() && detail.status.trim().is_empty() {
        return Ok(WeexOrderStatus {
            found: false,
            order_id: String::new(),
            client_order_id: Some(client_order_id),
            status: String::new(),
            filled_qty: 0.0,
            avg_price: 0.0,
        });
    }

    Ok(WeexOrderStatus {
        found: true,
        order_id,
        client_order_id: json_optional_id_to_string(&detail.client_order_id)
            .or(Some(client_order_id)),
        status: detail.status.trim().to_ascii_uppercase(),
        filled_qty: parse_f64_lossy(&detail.executed_qty).abs(),
        avg_price: parse_f64_lossy(&detail.avg_price),
    })
}

/// Cancels a conditional (trigger / TP / SL) order by exchange order id.
/// `DELETE /capi/v3/algoOrder`.
pub async fn cancel_algo_order(
    request: WeexCancelAlgoRequest,
) -> anyhow::Result<WeexMarketOrderAck> {
    let order_id = request.order_id.trim().to_string();
    if order_id.is_empty() {
        anyhow::bail!("WEEX cancel requires a conditional order id");
    }
    let client = SignedRestClient::new(WeexAccountRequest {
        api_key: request.api_key,
        api_secret: request.api_secret,
        passphrase: request.passphrase,
        symbol: request.symbol,
        base_url: request.base_url,
        recent_lookback_ms: 7 * 24 * 60 * 60 * 1000,
    })?;
    let body = json!({
        "symbol": client.request.symbol,
        "orderId": order_id,
    });
    let payload: Value = client.delete("/capi/v3/algoOrder", body).await?;
    Ok(ack_from_payload(payload)?)
}

/// Whether a target price is a take-profit or a stop-loss for an open position.
/// WEEX rejects a TAKE_PROFIT whose trigger sits on the wrong side of the
/// market, and a channel target can land either side: "TP SET 64450" is a
/// take-profit for a LONG below it, but a stop for a LONG already above it.
pub fn tp_sl_plan_type(direction: Direction, trigger_price: f64, mark_price: f64) -> &'static str {
    let in_profit = match direction {
        Direction::Long => trigger_price > mark_price,
        Direction::Short => trigger_price < mark_price,
    };
    if in_profit {
        "TAKE_PROFIT"
    } else {
        "STOP_LOSS"
    }
}

fn normalize_position_side(value: &str) -> anyhow::Result<&'static str> {
    match value.trim().to_ascii_uppercase().as_str() {
        "LONG" => Ok("LONG"),
        "SHORT" => Ok("SHORT"),
        other => anyhow::bail!("WEEX position side must be LONG or SHORT, got {other:?}"),
    }
}

/// Reads an order acknowledgement from a response that may be a bare object or
/// a single-element array (`placeTpSlOrder` answers with an array).
fn ack_from_payload(payload: Value) -> anyhow::Result<WeexMarketOrderAck> {
    let value = payload
        .as_array()
        .and_then(|items| items.first().cloned())
        .unwrap_or(payload);
    let ack: ContractOrderAck = serde_json::from_value(value)?;
    let order_id = json_id_to_string(&ack.order_id);
    let error_code = json_scalar_to_string(&ack.error_code);
    let error_message = json_scalar_to_string(&ack.error_message);
    let success = ack.success.unwrap_or_else(|| {
        !order_id.is_empty() && (error_code.is_empty() || error_code == "0" || error_code == "200")
    });
    Ok(WeexMarketOrderAck {
        order_id,
        client_order_id: json_optional_id_to_string(&ack.client_order_id)
            .or_else(|| json_optional_id_to_string(&ack.client_algo_id)),
        success,
        error_code,
        error_message,
    })
}

fn parse_order_side(side: &str) -> anyhow::Result<OrderSide> {
    if side.eq_ignore_ascii_case("buy") {
        Ok(OrderSide::Buy)
    } else if side.eq_ignore_ascii_case("sell") {
        Ok(OrderSide::Sell)
    } else {
        anyhow::bail!("WEEX order side must be buy or sell")
    }
}

struct SignedRestClient {
    http: reqwest::Client,
    request: WeexAccountRequest,
}

impl SignedRestClient {
    fn new(mut request: WeexAccountRequest) -> anyhow::Result<Self> {
        request.api_key = request.api_key.trim().to_string();
        request.api_secret = request.api_secret.trim().to_string();
        request.passphrase = request.passphrase.trim().to_string();
        request.symbol = if request.symbol.trim().is_empty() {
            "BTCUSDT".to_string()
        } else {
            request.symbol.trim().to_uppercase()
        };
        request.base_url = if request.base_url.trim().is_empty() {
            "https://api-contract.weex.com".to_string()
        } else {
            request.base_url.trim().trim_end_matches('/').to_string()
        };
        if request.api_key.is_empty()
            || request.api_secret.is_empty()
            || request.passphrase.is_empty()
        {
            anyhow::bail!("WEEX API key, secret, and passphrase are required for reconciliation");
        }
        if request.recent_lookback_ms <= 0 {
            request.recent_lookback_ms = 7 * 24 * 60 * 60 * 1000;
        }
        Ok(Self {
            http: reqwest::Client::builder()
                .timeout(StdDuration::from_secs(10))
                .user_agent("trading-challenge-copytrader/1.0")
                .build()?,
            request,
        })
    }

    async fn fetch_balance(&self) -> anyhow::Result<WeexAccountBalance> {
        let balances: Vec<ContractBalance> = self.get("/capi/v3/account/balance", &[]).await?;
        let balance = balances
            .iter()
            .find(|b| b.asset.eq_ignore_ascii_case("USDT"))
            .or_else(|| balances.first())
            .ok_or_else(|| anyhow::anyhow!("WEEX returned no futures balances"))?;
        let wallet_balance = parse_f64_lossy(&balance.balance);
        let available_balance = parse_f64_lossy(&balance.available_balance);
        let unrealized_pnl = parse_f64_lossy(&balance.unrealize_pnl);
        Ok(WeexAccountBalance {
            asset: balance.asset.clone(),
            wallet_balance,
            available_balance,
            unrealized_pnl,
            equity: wallet_balance + unrealized_pnl,
            used_margin: parse_f64_lossy(&balance.frozen),
        })
    }

    async fn fetch_position(&self, mark_price: f64) -> anyhow::Result<WeexPositionSnapshot> {
        let positions: Vec<ContractPosition> = self
            .get(
                "/capi/v3/account/position/singlePosition",
                &[("symbol", self.request.symbol.clone())],
            )
            .await?;
        let active = positions
            .iter()
            .filter(|p| parse_f64_lossy(&p.size).abs() > 0.0)
            .max_by(|a, b| {
                parse_f64_lossy(&a.size)
                    .partial_cmp(&parse_f64_lossy(&b.size))
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        let Some(pos) = active else {
            return Ok(WeexPositionSnapshot {
                symbol: self.request.symbol.clone(),
                direction: "flat".to_string(),
                qty: 0.0,
                entry_price: 0.0,
                mark_price,
                notional_usdt: 0.0,
                unrealized_pnl_usdt: 0.0,
                leverage: 0.0,
                liquidation_price: None,
                updated_at_ms: Utc::now().timestamp_millis(),
            });
        };
        let qty = parse_f64_lossy(&pos.size).abs();
        let notional = parse_f64_lossy(&pos.open_value).abs();
        let entry_price = if qty > 0.0 && notional > 0.0 {
            notional / qty
        } else {
            0.0
        };
        let direction = match pos.side.to_uppercase().as_str() {
            "LONG" => "long",
            "SHORT" => "short",
            _ => "flat",
        };
        Ok(WeexPositionSnapshot {
            symbol: pos.symbol.clone(),
            direction: direction.to_string(),
            qty: qty,
            entry_price,
            mark_price,
            notional_usdt: notional,
            unrealized_pnl_usdt: parse_f64_lossy(&pos.unrealize_pnl),
            leverage: parse_f64_lossy(&pos.leverage),
            liquidation_price: parse_optional_f64(&pos.liquidate_price),
            updated_at_ms: pos.updated_time,
        })
    }

    async fn fetch_mark_price(&self) -> anyhow::Result<f64> {
        let ticker: ContractTicker = self
            .get(
                "/capi/v3/market/ticker",
                &[("symbol", self.request.symbol.clone())],
            )
            .await?;
        let mark = parse_f64_lossy(&ticker.mark_price);
        if mark > 0.0 {
            Ok(mark)
        } else {
            Ok(parse_f64_lossy(&ticker.last))
        }
    }

    async fn fetch_recent_executions(&self) -> anyhow::Result<Vec<WeexExecutionSnapshot>> {
        let now = Utc::now().timestamp_millis();
        let mut trades = Vec::new();
        let lookback_start = (now - self.request.recent_lookback_ms).max(0);
        let max_window_ms = 7 * 24 * 60 * 60 * 1000 - 1;
        let mut end = now;
        while end > lookback_start && trades.len() < 500 {
            let start = lookback_start.max(end - max_window_ms);
            let mut chunk: Vec<ContractTrade> = self
                .get(
                    "/capi/v3/userTrades",
                    &[
                        ("symbol", self.request.symbol.clone()),
                        ("startTime", start.to_string()),
                        ("endTime", end.to_string()),
                        ("limit", "100".to_string()),
                    ],
                )
                .await?;
            trades.append(&mut chunk);
            if start == lookback_start {
                break;
            }
            end = start - 1;
        }
        let mut executions = trades
            .into_iter()
            .map(|trade| {
                let price = parse_f64_lossy(&trade.price);
                let qty = parse_f64_lossy(&trade.qty).abs();
                let quote_qty = parse_f64_lossy(&trade.quote_qty).abs();
                WeexExecutionSnapshot {
                    exec_id: json_id_to_string(&trade.id),
                    order_id: json_id_to_string(&trade.order_id),
                    symbol: trade.symbol.to_uppercase(),
                    side: if trade.side.eq_ignore_ascii_case("BUY") {
                        "buy".to_string()
                    } else {
                        "sell".to_string()
                    },
                    position_side: trade.position_side.to_lowercase(),
                    kind: "unknown".to_string(),
                    direction: "flat".to_string(),
                    price,
                    qty: qty,
                    notional_usdt: if quote_qty > 0.0 {
                        quote_qty
                    } else {
                        price * qty
                    },
                    realized_pnl_usdt: parse_f64_lossy(&trade.realized_pnl),
                    fee_usdt: parse_f64_lossy(&trade.commission),
                    timestamp_ms: trade.time,
                }
            })
            .collect::<Vec<_>>();
        executions.sort_by_key(|e| e.timestamp_ms);
        Ok(executions)
    }

    async fn get<T: DeserializeOwned>(
        &self,
        path: &str,
        params: &[(&str, String)],
    ) -> anyhow::Result<T> {
        self.request(Method::GET, path, params, None).await
    }

    async fn post<T: DeserializeOwned>(&self, path: &str, body: Value) -> anyhow::Result<T> {
        self.request(Method::POST, path, &[], Some(body)).await
    }

    async fn delete<T: DeserializeOwned>(&self, path: &str, body: Value) -> anyhow::Result<T> {
        self.request(Method::DELETE, path, &[], Some(body)).await
    }

    async fn request<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        params: &[(&str, String)],
        body: Option<Value>,
    ) -> anyhow::Result<T> {
        let query = params
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>()
            .join("&");
        let body_str = body
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?
            .unwrap_or_default();
        let url = if query.is_empty() {
            format!("{}{}", self.request.base_url, path)
        } else {
            format!("{}{}?{}", self.request.base_url, path, query)
        };

        let mut last_error = None;
        for attempt in 0..3 {
            let timestamp = Utc::now().timestamp_millis();
            let signature = sign(
                &self.request.api_secret,
                timestamp,
                method.as_str(),
                path,
                &query,
                &body_str,
            );
            let response = self
                .http
                .request(method.clone(), &url)
                .headers(auth_headers(
                    &self.request.api_key,
                    &self.request.passphrase,
                    timestamp,
                    &signature,
                    method != Method::GET,
                ))
                .body(body_str.clone())
                .send()
                .await;

            match response {
                Ok(response) => {
                    let status = response.status();
                    let text = response.text().await.unwrap_or_default();
                    if status.is_success() {
                        let value: Value = serde_json::from_str(&text)?;
                        if api_ok(&value) {
                            return decode_payload(value);
                        }
                        return Err(anyhow::anyhow!("WEEX API error: {text}"));
                    }
                    if status.is_server_error() && attempt < 2 {
                        last_error = Some(format!("HTTP {}: {}", status.as_u16(), text));
                    } else {
                        return Err(anyhow::anyhow!("WEEX HTTP {}: {}", status.as_u16(), text));
                    }
                }
                Err(error) if attempt < 2 => {
                    last_error = Some(error.to_string());
                }
                Err(error) => return Err(error.into()),
            }
            sleep(Duration::from_millis(250 * (attempt + 1))).await;
        }

        Err(anyhow::anyhow!(
            "WEEX request failed after retries: {}",
            last_error.unwrap_or_else(|| "unknown error".to_string())
        ))
    }
}

fn auth_headers(
    api_key: &str,
    passphrase: &str,
    timestamp: i64,
    signature: &str,
    include_content_type: bool,
) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert("ACCESS-KEY", HeaderValue::from_str(api_key).unwrap());
    headers.insert("ACCESS-SIGN", HeaderValue::from_str(signature).unwrap());
    headers.insert(
        "ACCESS-TIMESTAMP",
        HeaderValue::from_str(&timestamp.to_string()).unwrap(),
    );
    headers.insert(
        "ACCESS-PASSPHRASE",
        HeaderValue::from_str(passphrase).unwrap(),
    );
    if include_content_type {
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    }
    headers
}

fn api_ok(value: &Value) -> bool {
    value.get("code").is_none_or(|code| {
        code.as_i64() == Some(0)
            || code.as_i64() == Some(200)
            || code.as_str() == Some("0")
            || code.as_str() == Some("200")
    })
}

fn decode_payload<T: DeserializeOwned>(value: Value) -> anyhow::Result<T> {
    if let Some(data) = value.get("data") {
        serde_json::from_value(data.clone()).or_else(|_| serde_json::from_value(value))
    } else {
        serde_json::from_value(value)
    }
    .map_err(Into::into)
}

fn classify_executions(executions: &mut [WeexExecutionSnapshot], final_signed_qty: f64) {
    let returned_delta = executions.iter().fold(0.0_f64, |sum, execution| {
        sum + if execution.side == "buy" {
            execution.qty
        } else {
            -execution.qty
        }
    });
    let mut signed_qty = final_signed_qty - returned_delta;
    for execution in executions {
        let delta = if execution.side == "buy" {
            execution.qty
        } else {
            -execution.qty
        };
        let before = signed_qty;
        let after = signed_qty + delta;
        let before_abs = before.abs();
        let after_abs = after.abs();
        let before_sign = before.signum();
        let after_sign = after.signum();

        let (kind, direction) = if before_abs <= f64::EPSILON {
            ("enter", sign_direction(delta))
        } else if before_sign == delta.signum() && after_abs > before_abs {
            ("add", sign_direction(before))
        } else if after_abs <= f64::EPSILON {
            ("close", sign_direction(before))
        } else if before_sign == after_sign && after_abs < before_abs {
            ("reduce", sign_direction(before))
        } else {
            ("enter", sign_direction(after))
        };

        execution.kind = kind.to_string();
        execution.direction = direction.to_string();
        signed_qty = if after_abs <= 0.00000001 { 0.0 } else { after };
    }
}

fn sign_direction(value: f64) -> &'static str {
    if value < 0.0 {
        "short"
    } else {
        "long"
    }
}

fn parse_f64_lossy(value: &str) -> f64 {
    value.parse::<f64>().unwrap_or(0.0)
}

fn parse_optional_f64(value: &str) -> Option<f64> {
    let parsed = parse_f64_lossy(value);
    if parsed > 0.0 {
        Some(parsed)
    } else {
        None
    }
}

fn json_id_to_string(value: &Value) -> String {
    json_scalar_to_string(value)
}

fn json_optional_id_to_string(value: &Value) -> Option<String> {
    let text = json_scalar_to_string(value);
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn json_scalar_to_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        Value::Bool(value) => value.to_string(),
        _ => value.to_string().trim_matches('"').to_string(),
    }
}

fn sanitize_client_order_id(value: &str) -> String {
    let cleaned = value
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(36)
        .collect::<String>();
    if cleaned.is_empty() {
        format!("tc-{}", Utc::now().timestamp_millis())
    } else {
        cleaned
    }
}

pub fn market_order_body(request: &OrderRequest, qty_step: f64) -> serde_json::Value {
    let side = match request.side {
        OrderSide::Buy => "BUY",
        OrderSide::Sell => "SELL",
    };
    json!({
        "symbol": request.symbol,
        "side": side,
        "positionSide": position_side(request),
        "type": "MARKET",
        "quantity": format_step(request.quantity, qty_step),
        "newClientOrderId": request.client_order_id.clone().unwrap_or_else(|| "tc-manual".to_string()),
    })
}

pub fn algo_order_body(
    symbol: &str,
    side: OrderSide,
    quantity: f64,
    trigger_price: f64,
    limit_price: f64,
    order_type: &str,
    client_algo_id: &str,
    qty_step: f64,
    price_step: f64,
) -> serde_json::Value {
    let order = OrderRequest::market(symbol, side, quantity);
    let side = match side {
        OrderSide::Buy => "BUY",
        OrderSide::Sell => "SELL",
    };
    json!({
        "symbol": symbol,
        "side": side,
        "positionSide": position_side(&order),
        "type": order_type,
        "quantity": format_step(quantity, qty_step),
        "price": format_step(limit_price, price_step),
        "triggerPrice": format_step(trigger_price, price_step),
        "clientAlgoId": sanitize_client_order_id(client_algo_id),
    })
}

/// Builds the `placeTpSlOrder` body. `quantity` is omitted when zero, which is
/// how the exchange is told to close the entire position — the plan then stays
/// correct even if the position is added to before the trigger fires.
pub fn tp_sl_order_body(
    symbol: &str,
    position_side: &str,
    plan_type: &str,
    trigger_price: f64,
    quantity: f64,
    client_algo_id: &str,
    qty_step: f64,
    price_step: f64,
) -> serde_json::Value {
    let mut body = json!({
        "symbol": symbol,
        "clientAlgoId": sanitize_client_order_id(client_algo_id),
        "planType": plan_type,
        "triggerPrice": format_step(trigger_price, price_step),
        "positionSide": position_side,
    });
    if quantity > 0.0 {
        body["quantity"] = json!(format_step(quantity, qty_step));
    }
    body
}

pub async fn stream_public_price(
    symbol: String,
    ws_public_url: String,
    sink: crate::frb_generated::StreamSink<PriceTick>,
) {
    let mut retry_delay = Duration::from_secs(3);
    loop {
        match stream_public_price_once(&symbol, &ws_public_url, &sink).await {
            Ok(()) => retry_delay = Duration::from_secs(3),
            Err(error) => {
                let _ = sink.add(PriceTick::error(&symbol, error.to_string()));
                sleep(retry_delay).await;
                retry_delay = (retry_delay * 2).min(Duration::from_secs(30));
            }
        }
    }
}

async fn stream_public_price_once(
    symbol: &str,
    ws_public_url: &str,
    sink: &crate::frb_generated::StreamSink<PriceTick>,
) -> anyhow::Result<()> {
    let mut request = ws_public_url.into_client_request()?;
    request.headers_mut().insert(
        USER_AGENT,
        HeaderValue::from_static("trading-challenge-copytrader/1.0"),
    );
    let (mut ws, _) = timeout(Duration::from_secs(10), connect_async(request)).await??;
    timeout(
        Duration::from_secs(10),
        ws.send(Message::Text(
            json!({
                "method": "SUBSCRIBE",
                "params": [
                    format!("{symbol}@ticker"),
                    format!("{symbol}@depth15"),
                    format!("{symbol}@trade")
                ],
                "id": 1
            })
            .to_string()
            .into(),
        )),
    )
    .await??;

    loop {
        let message = timeout(Duration::from_secs(45), ws.next())
            .await?
            .ok_or_else(|| anyhow::anyhow!("WEEX public WebSocket ended"))??;
        match message {
            Message::Text(text) => {
                if is_ping(&text) {
                    ws.send(Message::Text(
                        r#"{"method":"PONG","id":1}"#.to_string().into(),
                    ))
                    .await?;
                    continue;
                }
                if let Some(error) = subscription_error(&text) {
                    anyhow::bail!("WEEX public WebSocket subscription rejected: {error}");
                }
                if let Some(tick) = parse_price_tick(symbol, &text) {
                    if sink.add(tick).is_err() {
                        anyhow::bail!("Dart price stream closed");
                    }
                }
            }
            Message::Ping(payload) => ws.send(Message::Pong(payload)).await?,
            Message::Close(_) => anyhow::bail!("WEEX public WebSocket closed"),
            _ => {}
        }
    }
}

fn is_ping(text: &str) -> bool {
    serde_json::from_str::<Value>(text).ok().is_some_and(|v| {
        v.get("event").and_then(Value::as_str) == Some("ping")
            || v.get("type").and_then(Value::as_str) == Some("ping")
    })
}

fn subscription_error(text: &str) -> Option<String> {
    let value = serde_json::from_str::<Value>(text).ok()?;
    if value.get("result").and_then(Value::as_bool) != Some(false) {
        return None;
    }
    value
        .get("msg")
        .and_then(Value::as_str)
        .or_else(|| value.get("error").and_then(Value::as_str))
        .map(str::to_owned)
        .or_else(|| Some("unknown subscription error".to_string()))
}

fn parse_price_tick(symbol: &str, text: &str) -> Option<PriceTick> {
    let value = serde_json::from_str::<Value>(text).ok()?;
    let event = value.get("e")?.as_str()?;
    let event_symbol = value.get("s")?.as_str()?;
    if event_symbol != symbol {
        return None;
    }
    let event_time_ms = value.get("E").and_then(Value::as_i64);
    let data = value.get("d")?;

    match event {
        "ticker" | "24hrTicker" => {
            let ticker = first_object(&data).unwrap_or(&data);
            Some(PriceTick {
                symbol: symbol.to_string(),
                price: ticker.get("c").and_then(parse_json_f64),
                bid: ticker.get("b").and_then(parse_json_f64),
                ask: ticker.get("a").and_then(parse_json_f64),
                source: "ticker".to_string(),
                event_time_ms,
                received_at_ms: Utc::now().timestamp_millis(),
                ok: ticker.get("c").and_then(parse_json_f64).is_some(),
                error: None,
            })
        }
        "bookTicker" => {
            let book = first_object(&data).unwrap_or(&data);
            let bid = book.get("b").and_then(parse_json_f64);
            let ask = book.get("a").and_then(parse_json_f64);
            let price = match (bid, ask) {
                (Some(b), Some(a)) => Some((b + a) / 2.0),
                _ => None,
            };
            Some(PriceTick {
                symbol: symbol.to_string(),
                price,
                bid,
                ask,
                source: "bookTicker".to_string(),
                event_time_ms,
                received_at_ms: Utc::now().timestamp_millis(),
                ok: price.is_some(),
                error: None,
            })
        }
        "depth" | "depthSnapshot" | "depthUpdate" => {
            let bid = value
                .get("b")
                .and_then(Value::as_array)
                .and_then(|levels| levels.first())
                .and_then(parse_price_level);
            let ask = value
                .get("a")
                .and_then(Value::as_array)
                .and_then(|levels| levels.first())
                .and_then(parse_price_level);
            let price = match (bid, ask) {
                (Some(b), Some(a)) => Some((b + a) / 2.0),
                (Some(b), None) => Some(b),
                (None, Some(a)) => Some(a),
                _ => None,
            };
            Some(PriceTick {
                symbol: symbol.to_string(),
                price,
                bid,
                ask,
                source: event.to_string(),
                event_time_ms,
                received_at_ms: Utc::now().timestamp_millis(),
                ok: price.is_some(),
                error: None,
            })
        }
        "tradeSnapshot" => {
            let price = value
                .get("d")
                .and_then(Value::as_array)
                .and_then(|trades| trades.first())
                .and_then(|trade| trade.get("p"))
                .and_then(parse_json_f64);
            Some(PriceTick {
                symbol: symbol.to_string(),
                price,
                bid: None,
                ask: None,
                source: "tradeSnapshot".to_string(),
                event_time_ms,
                received_at_ms: Utc::now().timestamp_millis(),
                ok: price.is_some(),
                error: None,
            })
        }
        "trade" => {
            let price = first_object(&data)
                .and_then(|trade| trade.get("p"))
                .and_then(parse_json_f64)
                .or_else(|| data.get("p").and_then(parse_json_f64));
            Some(PriceTick {
                symbol: symbol.to_string(),
                price,
                bid: None,
                ask: None,
                source: "trade".to_string(),
                event_time_ms,
                received_at_ms: Utc::now().timestamp_millis(),
                ok: price.is_some(),
                error: None,
            })
        }
        _ => None,
    }
}

fn first_object(value: &Value) -> Option<&Value> {
    value
        .as_array()
        .and_then(|items| items.first())
        .filter(|item| item.is_object())
}

fn parse_price_level(value: &Value) -> Option<f64> {
    value
        .as_array()
        .and_then(|level| level.first())
        .and_then(parse_json_f64)
}

fn parse_json_f64(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.parse::<f64>().ok()))
}

impl PriceTick {
    fn error(symbol: &str, error: String) -> Self {
        Self {
            symbol: symbol.to_string(),
            price: None,
            bid: None,
            ask: None,
            source: "weex_ws".to_string(),
            event_time_ms: None,
            received_at_ms: Utc::now().timestamp_millis(),
            ok: false,
            error: Some(error),
        }
    }
}

pub fn format_step(value: f64, step: f64) -> String {
    if step <= 0.0 {
        return value.to_string();
    }
    // Decimal exchange steps are not exactly representable as f64. The small
    // tolerance preserves an amount already on the advertised step.
    let rounded = ((value / step) + 1e-9).floor() * step;
    let decimals = step_decimal_places(step);
    format!("{rounded:.decimals$}")
}

fn step_decimal_places(step: f64) -> usize {
    let s = format!("{step:.10}");
    s.trim_end_matches('0')
        .split('.')
        .nth(1)
        .map_or(0, str::len)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_qty_down_to_step() {
        assert_eq!(format_step(0.123456, 0.001), "0.123");
        assert_eq!(format_step(62123.987, 0.1), "62123.9");
    }

    #[test]
    fn reduce_only_flips_position_side() {
        let request = OrderRequest::market("BTCUSDT", OrderSide::Buy, 0.1).reduce_only();
        assert_eq!(market_order_body(&request, 0.001)["positionSide"], "SHORT");
    }

    #[test]
    fn builds_position_attached_tp_body() {
        // No quantity: the exchange closes the whole position at the trigger,
        // so the plan survives later adds and partial reduces.
        let body = tp_sl_order_body(
            "BTCUSDT",
            "LONG",
            "TAKE_PROFIT",
            64_450.0,
            0.0,
            "tc-tp-1",
            0.0001,
            0.1,
        );
        assert_eq!(body["symbol"], "BTCUSDT");
        assert_eq!(body["positionSide"], "LONG");
        assert_eq!(body["planType"], "TAKE_PROFIT");
        assert_eq!(body["triggerPrice"], "64450.0");
        assert!(body.get("quantity").is_none());

        // A partial TP carries its size, rounded to the lot step.
        let partial = tp_sl_order_body(
            "BTCUSDT",
            "SHORT",
            "STOP_LOSS",
            64_450.0,
            0.00219,
            "tc-tp-2",
            0.0001,
            0.1,
        );
        assert_eq!(partial["positionSide"], "SHORT");
        assert_eq!(partial["quantity"], "0.0021");
    }

    #[test]
    fn classifies_target_as_take_profit_or_stop_by_direction() {
        // A LONG takes profit above the market and stops below it.
        assert_eq!(
            tp_sl_plan_type(Direction::Long, 64_450.0, 64_000.0),
            "TAKE_PROFIT"
        );
        assert_eq!(
            tp_sl_plan_type(Direction::Long, 63_500.0, 64_000.0),
            "STOP_LOSS"
        );
        // A SHORT is the mirror image.
        assert_eq!(
            tp_sl_plan_type(Direction::Short, 63_500.0, 64_000.0),
            "TAKE_PROFIT"
        );
        assert_eq!(
            tp_sl_plan_type(Direction::Short, 64_450.0, 64_000.0),
            "STOP_LOSS"
        );
    }

    #[test]
    fn reads_ack_from_array_and_object_payloads() {
        // placeTpSlOrder answers with a single-element array.
        let array = ack_from_payload(serde_json::json!([{
            "orderId": 812345678901234900u64,
            "success": true,
            "errorCode": "",
            "errorMessage": ""
        }]))
        .unwrap();
        assert_eq!(array.order_id, "812345678901234900");
        assert!(array.success);

        // Cancel answers with a bare object.
        let object = ack_from_payload(serde_json::json!({
            "orderId": "712345678901234567",
            "success": true
        }))
        .unwrap();
        assert_eq!(object.order_id, "712345678901234567");
        assert!(object.success);
    }

    #[test]
    fn builds_conditional_limit_order_body() {
        let body = algo_order_body(
            "BTCUSDT",
            OrderSide::Sell,
            0.0021,
            64_300.0,
            64_300.0,
            "STOP",
            "tc-123-limit",
            0.0001,
            0.1,
        );
        assert_eq!(body["side"], "SELL");
        assert_eq!(body["positionSide"], "SHORT");
        assert_eq!(body["type"], "STOP");
        assert_eq!(body["quantity"], "0.0021");
        assert_eq!(body["price"], "64300.0");
        assert_eq!(body["triggerPrice"], "64300.0");
    }

    #[test]
    fn parses_order_ack_with_nullable_fields() {
        let ack: ContractOrderAck = serde_json::from_str(
            r#"{
                "orderId": 769695182256865816,
                "clientOrderId": null,
                "success": null,
                "errorCode": null,
                "errorMessage": null
            }"#,
        )
        .unwrap();
        let order_id = json_id_to_string(&ack.order_id);
        let error_code = json_scalar_to_string(&ack.error_code);
        let success = ack.success.unwrap_or_else(|| {
            !order_id.is_empty()
                && (error_code.is_empty() || error_code == "0" || error_code == "200")
        });

        assert_eq!(order_id, "769695182256865816");
        assert_eq!(json_optional_id_to_string(&ack.client_order_id), None);
        assert!(success);
        assert_eq!(json_scalar_to_string(&ack.error_message), "");
    }

    #[test]
    fn signing_is_deterministic() {
        let a = sign(
            "secret",
            1700000000000,
            "GET",
            "/capi/v3/account/balance",
            "",
            "",
        );
        let b = sign(
            "secret",
            1700000000000,
            "GET",
            "/capi/v3/account/balance",
            "",
            "",
        );
        assert_eq!(a, b);
    }

    #[test]
    fn parses_ticker_price_tick() {
        let tick = parse_price_tick(
            "BTCUSDT",
            r#"{"e":"24hrTicker","E":1773295701456,"s":"BTCUSDT","d":{"c":"102500.50","b":"102500.00","a":"102500.50"}}"#,
        )
        .unwrap();
        assert_eq!(tick.price, Some(102500.50));
        assert_eq!(tick.bid, Some(102500.00));
        assert_eq!(tick.ask, Some(102500.50));
        assert!(tick.ok);
    }

    #[test]
    fn parses_contract_ticker_array_price_tick() {
        let tick = parse_price_tick(
            "BTCUSDT",
            r#"{"e":"ticker","E":1783857000000,"s":"BTCUSDT","d":[{"c":"63994.10","m":"63994.00","i":"64016.97"}]}"#,
        )
        .unwrap();
        assert_eq!(tick.price, Some(63994.10));
        assert_eq!(tick.source, "ticker");
        assert!(tick.ok);
    }

    #[test]
    fn parses_depth_snapshot_price_tick() {
        let tick = parse_price_tick(
            "BTCUSDT",
            r#"{"e":"depthSnapshot","E":1783506890648,"s":"BTCUSDT","U":1697088092,"u":1697088096,"l":15,"d":"SNAPSHOT","b":[["62149.98","1.858882"]],"a":[["62150.01","1.996738"]]}"#,
        )
        .unwrap();
        assert_eq!(tick.bid, Some(62149.98));
        assert_eq!(tick.ask, Some(62150.01));
        assert_eq!(tick.price, Some(62149.995));
        assert_eq!(tick.source, "depthSnapshot");
        assert!(tick.ok);
    }

    #[test]
    fn parses_trade_snapshot_price_tick() {
        let tick = parse_price_tick(
            "BTCUSDT",
            r#"{"e":"tradeSnapshot","E":1783506890650,"s":"BTCUSDT","d":[{"T":1783506889726,"t":"10654860-697b-4853-9d78-c59be3f78f8f","p":"62149.99","q":"0.000002","v":"0.12429998","m":true}]}"#,
        )
        .unwrap();
        assert_eq!(tick.price, Some(62149.99));
        assert_eq!(tick.source, "tradeSnapshot");
        assert!(tick.ok);
    }

    #[test]
    fn parses_contract_trade_array_price_tick() {
        let tick = parse_price_tick(
            "BTCUSDT",
            r#"{"e":"trade","E":1783857000000,"s":"BTCUSDT","d":[{"T":1783857000000,"t":123,"p":"63994.10","q":"0.01","v":"639.941","m":false}]}"#,
        )
        .unwrap();
        assert_eq!(tick.price, Some(63994.10));
        assert_eq!(tick.source, "trade");
        assert!(tick.ok);
    }

    #[test]
    fn detects_rejected_public_subscription() {
        assert_eq!(
            subscription_error(r#"{"result":false,"id":1,"msg":"Invalid channel"}"#),
            Some("Invalid channel".to_string())
        );
        assert_eq!(subscription_error(r#"{"result":true,"id":1}"#), None);
    }

    #[test]
    fn classifies_execution_history_into_position_actions() {
        let mut executions = vec![
            test_execution("1", "BUY", 0.10),
            test_execution("2", "BUY", 0.05),
            test_execution("3", "SELL", 0.08),
            test_execution("4", "SELL", 0.07),
        ];

        classify_executions(&mut executions, 0.0);

        assert_eq!(executions[0].kind, "enter");
        assert_eq!(executions[0].direction, "long");
        assert_eq!(executions[1].kind, "add");
        assert_eq!(executions[1].direction, "long");
        assert_eq!(executions[2].kind, "reduce");
        assert_eq!(executions[2].direction, "long");
        assert_eq!(executions[3].kind, "close");
        assert_eq!(executions[3].direction, "long");
    }

    #[test]
    fn classifies_partial_history_from_current_position() {
        let mut executions = vec![test_execution("1", "SELL", 0.05)];

        classify_executions(&mut executions, 0.10);

        assert_eq!(executions[0].kind, "reduce");
        assert_eq!(executions[0].direction, "long");
    }

    fn test_execution(id: &str, side: &str, qty: f64) -> WeexExecutionSnapshot {
        WeexExecutionSnapshot {
            exec_id: id.to_string(),
            symbol: "BTCUSDT".to_string(),
            order_id: id.to_string(),
            side: side.to_lowercase(),
            position_side: if side.eq_ignore_ascii_case("SELL") {
                "short".to_string()
            } else {
                "long".to_string()
            },
            kind: "unknown".to_string(),
            direction: "flat".to_string(),
            price: 100_000.0,
            qty,
            notional_usdt: qty * 100_000.0,
            realized_pnl_usdt: 0.0,
            fee_usdt: 0.0,
            timestamp_ms: id.parse::<i64>().unwrap_or_default(),
        }
    }
}
