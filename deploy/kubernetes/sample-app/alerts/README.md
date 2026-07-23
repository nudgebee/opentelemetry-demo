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
kubectl apply -f deploy/kubernetes/sample-app/alerts/
```

`PrometheusRule` is used rather than VictoriaMetrics' own `VMRule` because it
works with both stacks: prometheus-operator consumes it directly, and the
VictoriaMetrics operator watches `PrometheusRule` and converts each one into
an equivalent `VMRule` automatically. That was verified on our cluster by
applying a throwaway `PrometheusRule` and watching the matching `VMRule`
appear within seconds.

Both files pin `namespace: victoria`, which is where the VictoriaMetrics
operator runs in our environment. Change it to whichever namespace your
operator or Prometheus watches. If the rule selector is empty it picks up
every rule object in the namespaces it may read, so no extra labels are
needed; otherwise match the selector.

## What is here, and why it is split in two

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
