# Scenario J: Connection leak after a release

**Change:** a product-catalog release turns on a background price refresh |
**Service:** `product-catalog` | **Early warning:** pool filling up, before
any customer impact | **Status:** expected, not yet measured

An application-level failure with a warning before the customer feels it.
Nothing is told to fail and no infrastructure is short: a release enables a
small background job that holds on to one database connection every time it
runs. Connections in use climb in a straight line while latency stays flat,
then the pool runs out and every product query waits behind it.

## What it does

product-catalog's pool is capped at 20 connections (`DB_MAX_OPEN_CONNS` in
[`values.yaml`](../values.yaml)); normal traffic uses 1-2. Setting
`PRICE_REFRESH_INTERVAL=60s` starts a refresher that re-reads prices once a
minute inside a read-only transaction. When no price changed -- which is every
run, since nothing changes them -- it returns without committing or rolling
back, so the transaction and its connection are never released
(`refreshPrices` in [`src/product-catalog/pool.go`](../../../../src/product-catalog/pool.go)).
The database shows each one as `idle in transaction`.

One connection a minute against a pool of 20 gives this timeline (expected,
from the arithmetic -- replace with measured times after the first run):

| Time | Pool in use | What you see |
| --- | --- | --- |
| T+0 | 1-2 of 20 | Deployment `product-catalog` changes (new env var, pods roll) |
| T+10 | ~55% | latency still normal |
| T+12 | ~65% | `OtelDemoDBConnectionPoolFillingUp` (warning) fires |
| T+19-20 | 100% | product queries start waiting for a connection |
| T+20+ | 100% | Place Order latency, then errors; the order SLO rules fire |

The refresher stops leaking once the pool is full (it waits for a connection
like everything else), so the pool stays at 20 until the pod restarts or the
release is rolled back.

## Prerequisites

- A product-catalog image built from this fork at or after the commit that
  added `pool.go`. The stock image ignores both env vars.
- `DB_MAX_OPEN_CONNS` applied from `values.yaml`. Check:
  `db_sql_connection_max_open{service_name="product-catalog"}` reports 20, not 0.
- The pool rule applied **well before** the run (a rule the monitoring platform
  has not picked up gives an investigation nothing to trend):

  ```bash
  kubectl -n <rules-namespace> apply -f alerts/otel-demo-pool-alerts.yaml
  ```

## Run it

```bash
kubectl -n demo set env deploy/product-catalog PRICE_REFRESH_INTERVAL=60s
kubectl -n demo rollout status deploy/product-catalog
```

This is a Deployment change, not a `fault.sh` object, so it does **not** expire
on its own. Note the time and undo it when you are done.

Objective check -- held connections climb by about one a minute:

```promql
min_over_time(db_sql_connection_open{service_name="product-catalog", status="inuse"}[2m])
```

## Undo

Either of these ends the leak and frees every held connection:

```bash
kubectl -n demo rollout undo deploy/product-catalog                  # the real fix
kubectl -n demo set env deploy/product-catalog PRICE_REFRESH_INTERVAL-   # same effect
```

`kubectl rollout restart` frees the connections too, but the refresher comes
back with the pod and the pool fills again 20 minutes later -- which is worth
showing if the story is "restart buys time, rollback fixes it".

## What a good investigation says

- **What changed:** the product-catalog Deployment, minutes before the climb
  started (the new env var is in the diff).
- **Is it isolated:** product-catalog only; the database itself is healthy --
  query time normal, few active queries; the held connections are idle in a
  transaction.
- **Getting worse:** connections held climbing about one a minute; at that
  rate the pool is full in about N minutes.
- **Cause:** the price refresh path returns without ending its transaction.
- **Action:** roll back the release (or remove the env var); raising
  `DB_MAX_OPEN_CONNS` only delays the same outcome.
