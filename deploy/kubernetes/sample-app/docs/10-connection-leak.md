# Scenario J: Connection leak after a release

**Change:** a product-catalog release turns on a background price refresh |
**Service:** `product-catalog` | **Early warning:** pool filling up, before
any customer impact | **Status:** measured on a live cluster

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

One connection a minute against a pool of 20. Measured on a live cluster at the
default load (about 4 orders a minute):

| Time | Pool in use | What you see |
| --- | --- | --- |
| T+0 | 1 of 20 | Deployment `product-catalog` changes (new env var, pod rolls); the change is recorded |
| T+5 | 3-5 of 20 | Place Order p95 ~45 ms, unchanged |
| T+9.5 | 7 of 20 | `OtelDemoDBConnectionPoolFillingUp` pending |
| T+12 | 9 of 20 | `OtelDemoDBConnectionPoolFillingUp` fires; latency still normal |
| T+16.5 | 13 of 20 | investigation complete (see below) |
| T+23 | 20 of 20 | product queries wait for a connection; `OtelDemoDBConnectionPoolExhausted` and `OtelDemoDatabaseOperationsStopped` fire; no order completes |

The warning lands about 11 minutes before customers are affected. The Place
Order SLO rules need completed orders to measure, so during a full stall they
stay quiet; they fire only if the stall ends without the fix.

The refresher stops leaking once the pool is full (it waits for a connection
like everything else), so the pool stays at 20 until the pod restarts or the
release is rolled back.

## Setup

Everything below is a one-time setup; after it the scenario is a single
`kubectl set env`.

1. **Image.** product-catalog must run an image built from this fork at or
   after the commit that added `src/product-catalog/pool.go`; the stock image
   ignores both env vars. Cut one with Actions -> "Release images" (version
   e.g. `3.0.0-nudgebee.N`) and set it in [`values.yaml`](../values.yaml)
   under `product-catalog.imageOverride`, or keep the rolling `latest-*` tag.
2. **Pool size.** `DB_MAX_OPEN_CONNS=20` comes from `values.yaml`. Check that
   `db_sql_connection_max_open{service_name="product-catalog"}` reports 20,
   not 0 (an unlimited pool has no utilisation to alert on).
3. **Alert rules.** Apply the pool rules **well before** the run; a rule the
   monitoring platform has not picked up yet gives an investigation nothing
   to trend:

   ```bash
   kubectl -n <rules-namespace> apply -f alerts/otel-demo-pool-alerts.yaml
   ```

4. **Source link.** Point the workloads at the commit that built the image,
   so a code-level investigation reads the `pool.go` that is running:

   ```bash
   ./annotate-workloads.sh --code-commit <commit-of-the-image>
   ```

5. **Quiet period.** Leave the demo untouched for about two hours before the
   run. Earlier changes and alerts show up as "what changed" and "what else
   is firing" and distract from this one.

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

Remove the setting; the pod restarts and every held connection is freed:

```bash
kubectl -n demo set env deploy/product-catalog PRICE_REFRESH_INTERVAL-
```

Prefer this to `kubectl rollout undo`. After a few runs the previous
revision can be one that still has the setting (Kubernetes reuses the
ReplicaSet of an identical pod spec), and the undo silently brings the leak
back.

`kubectl rollout restart` frees the connections too, but the refresher comes
back with the pod and the pool fills again 20 minutes later -- which is worth
showing if the story is "restart buys time, removing the change fixes it".

After the fix the pool drops to 0 within a minute. Orders that were waiting
complete late, so Place Order p95 shows ~10 s for five minutes before
settling back to normal.

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

On the measured run the investigation said all of this except the
time-to-full: it named the env var and when it was added, traced it to
`refreshPrices()` returning without ending its transaction, ruled out an
earlier database alert, noted the same alert had fired before on this
workload, and proposed removing the setting (with the command to put it back)
plus a `defer tx.Rollback()` code fix. It reported the climb rate but not
"the pool is full in about N minutes".
