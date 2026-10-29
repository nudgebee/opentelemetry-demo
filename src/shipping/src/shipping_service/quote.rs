// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

use core::fmt;
use opentelemetry::global;
use opentelemetry::metrics::Counter;
use opentelemetry_instrumentation_actix_web::ClientExt;
use std::sync::LazyLock;
use std::{collections::HashMap, env};

use anyhow::{Context, Result};
use opentelemetry::{trace::get_active_span, KeyValue};
use std::time::Duration;
use tracing::{info, warn};

use super::shipping_types::Quote;

static ITEMS_SHIPPED_COUNTER: LazyLock<Counter<u64>> = LazyLock::new(|| {
    global::meter("otel_demo.shipping.quote")
        .u64_counter("demo.shipping.items_shipped")
        .build()
});

pub async fn create_quote_from_count(count: u32) -> Result<Quote, tonic::Status> {
    let f = match request_quote(count).await {
        Ok(float) => float,
        Err(err) => {
            let msg = format!("{}", err);
            return Err(tonic::Status::unknown(msg));
        }
    };

    ITEMS_SHIPPED_COUNTER.add(count as u64, &[]);

    Ok(get_active_span(|span| {
        let q = create_quote_from_float(f);
        if span.is_recording() {
            let cost = format!("{}", q);
            span.add_event(
                "shipping.quote.received".to_string(),
                vec![KeyValue::new("demo.shipping.cost.total", cost.clone())],
            );
            span.set_attribute(KeyValue::new("demo.shipping.cost.total", cost));
        }
        q
    }))
}

async fn execute_quote_request(
    client: &awc::Client,
    quote_service_addr: &str,
    reqbody: &HashMap<&str, u32>,
) -> Result<f64, anyhow::Error> {
    let mut response = client
        .post(quote_service_addr)
        .timeout(Duration::from_secs(3))
        .trace_request()
        .send_json(reqbody)
        .await
        .map_err(|err| anyhow::anyhow!("Failed to call quote service: {err}"))?;

    let bytes = response
        .body()
        .await
        .context("Failed to read response body from quote service")?;

    let resp = std::str::from_utf8(&bytes)
        .context("Failed to parse quote service response as UTF-8")?
        .to_owned();

    let f = resp
        .parse::<f64>()
        .context("Failed to parse quote value as f64")?;

    Ok(f)
}

async fn request_quote(count: u32) -> Result<f64, anyhow::Error> {
    let client = awc::Client::builder()
        .timeout(Duration::from_secs(3))
        .finish();
    let quote_service_addr: String = format!(
        "{}{}",
        env::var("QUOTE_ADDR")
            .unwrap_or_else(|_| "http://quote:8090".to_string())
            .parse::<String>()
            .expect("Invalid quote service address"),
        "/getquote"
    );

    info!(
        name: "shipping.quote.requested",
        quote_service_addr = quote_service_addr.as_str(),
        "Requesting quote"
    );

    let mut reqbody = HashMap::new();
    reqbody.insert("numberOfItems", count);

    let max_retries = 3;
    let mut last_err = None;

    for attempt in 1..=max_retries {
        match execute_quote_request(&client, &quote_service_addr, &reqbody).await {
            Ok(val) => return Ok(val),
            Err(err) => {
                warn!(
                    attempt = attempt,
                    max_retries = max_retries,
                    error = %err,
                    "Failed to get quote, retrying..."
                );
                last_err = Some(err);
                if attempt < max_retries {
                    actix_web::rt::time::sleep(Duration::from_millis(100 * attempt as u64)).await;
                }
            }
        }
    }

    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("Failed to call quote service after {max_retries} attempts")))
}

pub fn create_quote_from_float(value: f64) -> Quote {
    Quote {
        dollars: value.floor() as u64,
        cents: ((value * 100_f64) as u32) % 100,
    }
}

impl fmt::Display for Quote {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}.{}", self.dollars, self.cents)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_quote_from_float() {
        let quote = create_quote_from_float(10.99);
        assert_eq!(quote.dollars, 10);
        assert_eq!(quote.cents, 99);

        let quote = create_quote_from_float(0.01);
        assert_eq!(quote.dollars, 0);
        assert_eq!(quote.cents, 1);

        let quote = create_quote_from_float(100.00);
        assert_eq!(quote.dollars, 100);
        assert_eq!(quote.cents, 0);
    }

    #[test]
    fn test_quote_display() {
        let quote = Quote {
            dollars: 10,
            cents: 99,
        };
        assert_eq!(format!("{}", quote), "10.99");

        let quote = Quote {
            dollars: 0,
            cents: 1,
        };
        assert_eq!(format!("{}", quote), "0.1");
    }

    #[actix_web::test]
    async fn test_request_quote_unavailable_endpoint() {
        std::env::set_var("QUOTE_ADDR", "http://127.0.0.1:59999");
        let result = request_quote(5).await;
        assert!(result.is_err());
    }
}
