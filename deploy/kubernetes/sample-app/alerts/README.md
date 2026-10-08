# Demo alert rules

Alerting rules for the demo, as `PrometheusRule` objects.

The upstream chart deploys the application but no alerting. Without these, a
monitoring platform watching the demo sees metrics and traces but never
receives an alert, so none of the incident, correlation or root-cause
behaviour has anything to work with. They live here so alerting ships with
the rest of the pack instead of being applied by hand and lost whenever a
cluster is rebuilt.

## Applying them

```bash
./deploy/kubernetes/sample-app/alerts/apply-alerts.sh --help
```

`PrometheusRule` is used rather than VictoriaMetrics' own `VMRule` because it
works with both stacks: prometheus-operator consumes it directly, and the
VictoriaMetrics operator watches `PrometheusRule` and converts each one into
an equivalent `VMRule` automatically. Verified by applying a throwaway
`PrometheusRule` and watching the matching `VMRule` appear within seconds.

These files carry no `metadata.namespace`, so the `kubectl -n` you apply them
with decides where the rule objects land. Put them wherever your
prometheus-operator or VictoriaMetrics operator watches. If its rule selector
is empty it picks up every rule object in the namespaces it can read, so no
extra labels are needed; otherwise match the selector -- see `--release-label`.

### Two different namespaces, do not confuse them

`metadata.namespace` (set by `kubectl -n`) is where the rule OBJECT lives.
The `namespace="demo"` selector inside every expression is where the METRICS
come from. They are usually different, and getting the second one wrong is
silent: a rule whose selector matches nothing never fires and never errors.

Use `apply-alerts.sh` rather than editing expressions by hand:

```bash
./apply-alerts.sh --demo-namespace <where-the-demo-runs> \
                  --rules-namespace <where-your-operator-watches> \
                  --release-label <your-kube-prometheus-stack-release>
```

## What is here, and why it is split up

### Symptom rules: `otel-demo-alerts.yaml`

HTTP and gRPC error rates plus HTTP p95 latency, grouped by service, RPC
method and pod. These fire on user-visible damage.

They are deliberately high-cardinality. One failing dependency lights up
every caller in the call graph and produces a burst of alerts, which is what
a real alert storm looks like and what makes the demo's noise-reduction and
correlation story worth showing. Collapsing that at the Alertmanager level
would hide the very thing being demonstrated.

### Dependency rules: `otel-demo-dependency-alerts.yaml`

The symptom rules share one blind spot: they only ever alert on a failing
dependency's *callers*. The dependency itself stays silent, so a slow
database shows up as several slow services with nothing naming the cause,
and correlation has no parent alert to point at.

`OtelDemoPostgresQueryLatencyHigh` closes that by alerting on PostgreSQL
query time itself, measured client-side from the instrumented DB handle, and
carrying `db_system_name` so the alert states which dependency it is about.

Verified against the `postgresSlow` feature flag: healthy gives inactive,
slow gives firing, and recovery returns it to inactive, with
`HTTP503_504_Failures` and `HighP95Latency` appearing on `frontend-proxy` at
the same time as the impacted-service blast radius.

### SLO rules: `otel-demo-slo-alerts.yaml`

Everything above alerts on a service or a dependency. These two alert on a
promise to the customer, measured on `checkout`'s `PlaceOrder` call: 99% of
orders succeed, and 99% of orders finish in under 500 ms.

Each rule reports a burn rate -- how many times faster than allowed the 1%
error budget is being spent -- and fires when it is above 6x over both the
last 30 minutes and the last 5. The long window says the damage is
significant, the short one says it is still happening, so a burst that has
already ended does not fire and the alert clears within minutes of a fix.

`OtelDemoPlaceOrderSuccessSLOAtRisk` was verified against the
`paymentFailure` flag at `10%`. At steady traffic a 10% failure rate takes
about 18 minutes to push the 30-minute window over 6%. On our run it fired
after twelve, because traffic had been raised five-fold two minutes before
the flag, and a window is weighted by the orders in it.
`OtelDemoPlaceOrderLatencySLOAtRisk` was verified against
[Scenario F](../docs/06-undersized-service.md), which is built around it,
and back-tested against a `postgresSlow=1sec` run, where it was true within
six minutes of the flag.

### Forecast rule: `otel-demo-forecast-alerts.yaml`

Every other rule fires on damage that is already happening. A slow climb
never trips any of them, and the first signal is the OOM kill.

`OtelDemoMemoryLimitForecast` fires when a container's memory is on course
to pass 90% of its limit within seven days, and its value is the number of
days left. It is `severity: warning`: nothing is failing yet.

Back-tested against a real twelve-day climb in `astronomy-db` that ended in
an OOM kill, it goes pending 6.6 days before the kill. It has not yet been
seen firing live. The rule file documents the three guards that keep a
straight-line forecast from firing on ordinary wobble.

## Gotcha: do not write a quantile rule on the DB duration metric

`db_client_operation_duration_bucket` is exported with bucket boundaries
`0, 5, 10, 25, ... 10000` while its values are recorded in **seconds**. Every
observation, whether 1ms healthy or 1s degraded, therefore falls into the
first `(0, 5]` bucket, and `histogram_quantile(0.95, ...)` interpolates to a
constant `0.95 * 5 = 4.75` no matter what the database is doing.

A `histogram_quantile(...) > 0.5` rule consequently fires permanently and
never resolves. That is why the rule here uses the mean,
`rate(_sum) / rate(_count)`, whose units are genuinely seconds and which
separates cleanly: roughly `0.001s` healthy against `0.21s` while the
`postgresSlow` scenario is active.

Before adding any quantile rule, check the boundaries actually span the value
range:

```promql
sum by (le) (rate(db_client_operation_duration_bucket{namespace="demo"}[5m]))
```

If every bucket carries the same rate, all observations sit in one bucket and
the quantile is meaningless.
