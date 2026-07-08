use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderSide {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderRequest {
    pub symbol: String,
    pub side: OrderSide,
    pub quantity: f64,
    pub reduce_only: bool,
    pub client_order_id: Option<String>,
}

impl OrderRequest {
    pub fn market(symbol: &str, side: OrderSide, quantity: f64) -> Self {
        Self {
            symbol: symbol.to_string(),
            side,
            quantity,
            reduce_only: false,
            client_order_id: None,
        }
    }

    pub fn reduce_only(mut self) -> Self {
        self.reduce_only = true;
        self
    }
}

pub fn position_side(request: &OrderRequest) -> &'static str {
    match (request.side, request.reduce_only) {
        (OrderSide::Buy, false) => "LONG",
        (OrderSide::Sell, false) => "SHORT",
        (OrderSide::Buy, true) => "SHORT",
        (OrderSide::Sell, true) => "LONG",
    }
}
