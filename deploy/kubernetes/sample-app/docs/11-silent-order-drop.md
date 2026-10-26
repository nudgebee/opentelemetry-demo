# Scenario K: Orders silently missing from the ledger

**Change:** an accounting release starts skipping "replayed" orders |
**Service:** `accounting` | **Detected by:** orders placed vs orders recorded,
and ledger freshness | **Status:** expected, not yet measured

Every dashboard stays green. checkout keeps returning OK at normal latency,
Kafka delivers every message, accounting reads all of them and logs no error,
and nothing restarts. A share of the orders simply never reaches the
accounting database. No error rate, latency or saturation rule can see it,
because nothing is failing. The only signal is in the data: fewer orders come
out of the pipeline than went in.

## What it does

The release adds a replay guard to accounting
(`IsReplay` in [`src/accounting/Consumer.cs`](../../../../src/accounting/Consumer.cs)):
an order that repeats a recent order inside `ORDER_REPLAY_WINDOW_SECONDS` is
skipped without a database round trip. The bug is the key it compares on: the
shipping address, not the order ID. Two different orders to the same address
inside the window look like a replay, so the second one is dropped. The skip
is logged at Debug, which is below the service's log level, so the logs show
nothing at all.

How much is lost depends on the window and on traffic. The load generator
ships to 9 addresses at about 3.4 orders a minute (simulated, not measured):

| `ORDER_REPLAY_WINDOW_SECONDS` | Orders missing |
| --- | --- |
| 60 | ~27% |
| 120 | ~43% |
| 600 | ~79% |
| 3600 | ~96%, the ledger stops growing once all 9 addresses are seen |

The default load is the right one: more traffic only raises the share lost.

## Signals

Two rules in
[`alerts/otel-demo-ledger-alerts.yaml`](../alerts/otel-demo-ledger-alerts.yaml),
both on `accounting`, the stage whose output is short:

- **`OtelDemoOrdersLostInAccounting`**: more than 10% of the orders
  accounting read in the last 15 minutes were neither written nor skipped as
  duplicates. The value is the fraction lost.
- **`OtelDemoOrderLedgerStale`**: the newest order in the ledger was placed
  more than 10 minutes ago while checkout is still placing orders.

They read four accounting metrics added for this scenario:

| Metric | Meaning |
| --- | --- |
| `demo_accounting_orders_consumed` | orders read from Kafka (in) |
| `demo_accounting_orders_recorded` | orders written to the database (out) |
| `demo_accounting_orders_duplicates` | redeliveries of orders already written (knowingly discarded) |
| `demo_accounting_orders_newest_recorded_time` | placement time of the newest order written |

Consumed minus recorded minus duplicates is what accounting lost without a
trace. The check is per stage on purpose. Comparing checkout's PlaceOrder
count with the ledger end to end looks more natural, but the two counters
come from different processes, so a gap in metric ingestion lands on one and
not the other. On a cluster whose collector was shedding load, that ratio
swung between -270% and +81% with nothing wrong and fired four times; the
in-stage ratio stayed at exactly 0. Orders lost before accounting are not
covered; a total stall is, by the freshness rule.

Expected timeline at a 120 s window (from the arithmetic -- replace with
measured times after the first run):

| Time | What you see |
| --- | --- |
| T+0 | Deployment `accounting` changes (new env var, pod rolls) |
| T+0 onwards | checkout OK, latency normal, no errors anywhere |
| T+3-4 | missing share over 15 minutes crosses 10% |
| T+9 | `OtelDemoOrdersLostInAccounting` fires |

## Prerequisites

- An accounting image built from this fork at or after the commit that added
  the replay guard. The stock image has neither the env var nor the metrics.
  Check: `demo_accounting_orders_recorded` exists for `namespace="demo"`.
- The ledger rules applied **well before** the run:

  ```bash
  kubectl -n <rules-namespace> apply -f alerts/otel-demo-ledger-alerts.yaml
  ```

- At rest, the lost share is exactly 0:

  ```promql
  sum(increase(demo_accounting_orders_consumed{namespace="demo"}[15m]))
    - sum(increase(demo_accounting_orders_recorded{namespace="demo"}[15m]))
    - sum(increase(demo_accounting_orders_duplicates{namespace="demo"}[15m]))
  ```

## Run it

```bash
kubectl -n demo set env deploy/accounting ORDER_REPLAY_WINDOW_SECONDS=120
kubectl -n demo rollout status deploy/accounting
```

This is a Deployment change, not a `fault.sh` object, so it does **not** expire
on its own. Note the time and undo it when you are done.

Objective check -- the ledger falls behind checkout while nothing errors:

```bash
kubectl -n demo exec deploy/astronomy-db -- \
  psql -U astronomy_user -d astronomy_db -c 'select count(*) from accounting."order"'
```

Run it twice a few minutes apart and compare the growth with
`demo_accounting_orders_consumed` over the same minutes.

For the freshness rule, use a window long enough that every address is
already in it: `ORDER_REPLAY_WINDOW_SECONDS=3600`. After roughly the first 25
orders nothing new is written, and `OtelDemoOrderLedgerStale` fires about 12
minutes later.

## Undo

```bash
kubectl -n demo rollout undo deploy/accounting                          # the real fix
kubectl -n demo set env deploy/accounting ORDER_REPLAY_WINDOW_SECONDS-  # same effect
```

The orders skipped while it ran are gone: they were consumed and their offsets
committed. Recovering them means replaying the topic from an earlier offset,
which is the part of the story a real incident would spend most of its time
on.

## What a good investigation says

- **What changed:** the accounting Deployment, minutes before the gap opened
  (the new env var is in the diff).
- **Is it isolated:** checkout, Kafka and the database are healthy; every
  message is consumed, fewer are written. No errors in accounting's logs.
- **Getting worse:** the share lost, and how many orders that is so far.
- **Cause:** the replay guard keys on shipping address, so distinct orders to
  the same address inside the window are dropped as replays.
- **Action:** roll back the release; then replay the topic for the window it
  ran, since the skipped orders were never written.
