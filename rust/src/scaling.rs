use serde::{Deserialize, Serialize};

use crate::interpreter::Size;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct ScaleInput {
    pub master_balance_usd: f64,
    pub my_balance_usd: f64,
    pub mark_price: f64,
    pub qty_step: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ScaledOrder {
    pub ratio: f64,
    pub qty_btc: f64,
    pub notional_usd: f64,
}

pub fn scale_order(size: Size, input: ScaleInput) -> anyhow::Result<ScaledOrder> {
    anyhow::ensure!(
        input.master_balance_usd > 0.0,
        "master balance must be positive"
    );
    anyhow::ensure!(input.my_balance_usd >= 0.0, "my balance cannot be negative");
    anyhow::ensure!(input.mark_price > 0.0, "mark price must be positive");

    let ratio = input.my_balance_usd / input.master_balance_usd;
    let (raw_qty, target_notional_usd) = match size {
        Size::Usd(usd) => {
            let notional = usd * ratio;
            (notional / input.mark_price, notional)
        }
        Size::Btc(btc) => {
            let qty = btc * ratio;
            (qty, qty * input.mark_price)
        }
        Size::Pct(_) | Size::FullClose => anyhow::bail!("close sizing requires open position qty"),
    };
    let qty_btc = round_down(raw_qty, input.qty_step);
    Ok(ScaledOrder {
        ratio,
        qty_btc,
        notional_usd: target_notional_usd,
    })
}

pub fn scale_close(position_qty_btc: f64, pct: f64, qty_step: f64) -> anyhow::Result<f64> {
    anyhow::ensure!(position_qty_btc >= 0.0, "position qty cannot be negative");
    anyhow::ensure!((0.0..=1.0).contains(&pct), "close pct must be 0..1");
    Ok(round_down(position_qty_btc * pct, qty_step))
}

fn round_down(value: f64, step: f64) -> f64 {
    if step <= 0.0 {
        value
    } else {
        (value / step).floor() * step
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calc_dart_golden_usd_position() {
        let input = ScaleInput {
            master_balance_usd: 10_000.0,
            my_balance_usd: 179.0,
            mark_price: 62_000.0,
            qty_step: 0.000001,
        };
        let scaled = scale_order(Size::Usd(31_000.0), input).unwrap();
        assert!((scaled.notional_usd - 554.90).abs() < 0.01);
    }

    #[test]
    fn btc_size_scales_by_balance_ratio() {
        let input = ScaleInput {
            master_balance_usd: 10_000.0,
            my_balance_usd: 200.0,
            mark_price: 50_000.0,
            qty_step: 0.0001,
        };
        let scaled = scale_order(Size::Btc(0.5), input).unwrap();
        assert_eq!(scaled.qty_btc, 0.01);
        assert_eq!(scaled.notional_usd, 500.0);
    }
}
