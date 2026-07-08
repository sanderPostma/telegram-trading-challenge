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
use tokio::time::{sleep, Duration};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::header::USER_AGENT, Message},
};

use crate::execution::{position_side, OrderRequest, OrderSide};

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
    pub qty_btc: f64,
    pub reduce_only: bool,
    pub client_order_id: String,
    pub qty_step: f64,
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
    pub qty_btc: f64,
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
    pub side: String,
    pub position_side: String,
    pub kind: String,
    pub direction: String,
    pub price: f64,
    pub qty_btc: f64,
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
    order_id: Value,
    client_order_id: Option<String>,
    #[serde(default)]
    success: bool,
    #[serde(default)]
    error_code: String,
    #[serde(default)]
    error_message: String,
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
        "long" => position.qty_btc,
        "short" => -position.qty_btc,
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
    if request.qty_btc <= 0.0 || !request.qty_btc.is_finite() {
        anyhow::bail!("WEEX market order quantity must be positive");
    }
    let mut order = OrderRequest::market(&client.request.symbol, side, request.qty_btc);
    order.client_order_id = Some(sanitize_client_order_id(&request.client_order_id));
    if request.reduce_only {
        order = order.reduce_only();
    }
    let body = market_order_body(&order, request.qty_step);
    let ack: ContractOrderAck = client.post("/capi/v3/order", body).await?;
    Ok(WeexMarketOrderAck {
        order_id: json_id_to_string(&ack.order_id),
        client_order_id: ack.client_order_id,
        success: ack.success,
        error_code: ack.error_code,
        error_message: ack.error_message,
    })
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
                qty_btc: 0.0,
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
            qty_btc: qty,
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
                    side: if trade.side.eq_ignore_ascii_case("BUY") {
                        "buy".to_string()
                    } else {
                        "sell".to_string()
                    },
                    position_side: trade.position_side.to_lowercase(),
                    kind: "unknown".to_string(),
                    direction: "flat".to_string(),
                    price,
                    qty_btc: qty,
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
            execution.qty_btc
        } else {
            -execution.qty_btc
        }
    });
    let mut signed_qty = final_signed_qty - returned_delta;
    for execution in executions {
        let delta = if execution.side == "buy" {
            execution.qty_btc
        } else {
            -execution.qty_btc
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
    value
        .as_str()
        .map(ToString::to_string)
        .unwrap_or_else(|| value.to_string().trim_matches('"').to_string())
}

fn sanitize_client_order_id(value: &str) -> String {
    let cleaned = value
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(36)
        .collect::<String>();
    if cleaned.is_empty() {
        format!("tmg-{}", Utc::now().timestamp_millis())
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
        "newClientOrderId": request.client_order_id.clone().unwrap_or_else(|| "tmg-manual".to_string()),
    })
}

pub async fn stream_public_price(
    symbol: String,
    ws_public_url: String,
    sink: crate::frb_generated::StreamSink<PriceTick>,
) {
    loop {
        match stream_public_price_once(&symbol, &ws_public_url, &sink).await {
            Ok(()) => {}
            Err(error) => {
                let _ = sink.add(PriceTick::error(&symbol, error.to_string()));
                sleep(Duration::from_secs(3)).await;
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
    let (mut ws, _) = connect_async(request).await?;
    ws.send(Message::Text(
        json!({
            "method": "SUBSCRIBE",
            "params": [
                format!("{symbol}@ticker"),
                format!("{symbol}@bookTicker"),
                format!("{symbol}@depth15"),
                format!("{symbol}@trade")
            ],
            "id": 1
        })
        .to_string()
        .into(),
    ))
    .await?;

    while let Some(message) = ws.next().await {
        match message? {
            Message::Text(text) => {
                if is_ping(&text) {
                    ws.send(Message::Text(
                        r#"{"method":"PONG","id":1}"#.to_string().into(),
                    ))
                    .await?;
                    continue;
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

    anyhow::bail!("WEEX public WebSocket ended")
}

fn is_ping(text: &str) -> bool {
    serde_json::from_str::<Value>(text)
        .ok()
        .is_some_and(|v| v.get("event").and_then(Value::as_str) == Some("ping"))
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
        "24hrTicker" => Some(PriceTick {
            symbol: symbol.to_string(),
            price: data.get("c").and_then(parse_json_f64),
            bid: data.get("b").and_then(parse_json_f64),
            ask: data.get("a").and_then(parse_json_f64),
            source: "ticker".to_string(),
            event_time_ms,
            received_at_ms: Utc::now().timestamp_millis(),
            ok: true,
            error: None,
        }),
        "bookTicker" => {
            let bid = data.get("b").and_then(parse_json_f64);
            let ask = data.get("a").and_then(parse_json_f64);
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
        "depthSnapshot" | "depthUpdate" => {
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
            let price = data.get("p").and_then(parse_json_f64);
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
    let rounded = (value / step).floor() * step;
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

    fn test_execution(id: &str, side: &str, qty_btc: f64) -> WeexExecutionSnapshot {
        WeexExecutionSnapshot {
            exec_id: id.to_string(),
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
            qty_btc,
            notional_usdt: qty_btc * 100_000.0,
            realized_pnl_usdt: 0.0,
            fee_usdt: 0.0,
            timestamp_ms: id.parse::<i64>().unwrap_or_default(),
        }
    }
}
