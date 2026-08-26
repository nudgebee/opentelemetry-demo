# NudgeBee demo environment

A fork of the [OpenTelemetry Astronomy Shop][upstream] set up to break on
purpose, so you can watch an AI SRE platform detect, explain and fix real
production failures.

**-> [Start here: Testing NudgeBee with the OpenTelemetry demo](./deploy/kubernetes/sample-app/README.md)**

About 30 minutes, most of it waiting for Helm.

---

## Why this repo exists

Evaluating an AI SRE tool has a chicken-and-egg problem: you cannot judge how it
handles an incident until you have one, and nobody wants to break production to
find out.

The OpenTelemetry demo solves that. It is a 20-service e-commerce application in
nine languages, fully instrumented, with feature flags that inject genuine
faults -- a database outage, a memory leak, a slow dependency, failing payments.
The failures are real: real OOM kills, real gRPC errors, real database latency.
They are just reproducible on demand and switch off cleanly.

This fork adds what the upstream demo deliberately leaves out, because upstream
is a demonstration of instrumentation rather than of monitoring:

| Added | Why |
| --- | --- |
| **Alert rules** ([`alerts/`](./deploy/kubernetes/sample-app/alerts/)) | Upstream ships none. Without them a monitoring platform sees metrics and traces but never gets an alert, so nothing has anything to work with. |
| **Faster detection** ([`values.yaml`](./deploy/kubernetes/sample-app/values.yaml)) | Metric export moved from 60s to 15s. Cuts detection from ~8 min to ~2.5 -- the dominant factor, not the scrape interval. |
| **Faults that reach Kubernetes** | CPU limits so throttling is measurable, tighter memory so leaks OOM in minutes, a readiness probe wired to the flag that controls it. |
| **Extra fault injection** | `postgresFailure` and `postgresSlow` make the product-catalog database fail or crawl, using real query time. |
| **Source-code annotations** ([`annotate-workloads.sh`](./deploy/kubernetes/sample-app/annotate-workloads.sh)) | Lets NudgeBee clone the repo during an investigation and cite the actual failing lines. |
| **A tested scenario catalogue** ([`scenarios.yaml`](./deploy/kubernetes/sample-app/scenarios.yaml)) | Which scenarios detect, which do not, and why -- measured, not guessed. |

## What a run looks like

Break the product catalog's database:

```bash
./deploy/kubernetes/sample-app/scenario.sh postgresFailure on
```

About two and a half minutes later NudgeBee has the incident, and its root-cause
analysis reads:

> The 100% failure rate on product-catalog was caused by activation of the
> `postgresFailure` feature flag... returning `13 INTERNAL: PostgreSQL unavailable`
>
> Pod CPU utilization remained negligible at ~0.001-0.002 cores, ruling out
> resource exhaustion.
>
> **Related Alerts Check** -- checkout: *Confirmed -- checkout calls product-catalog
> during PlaceOrder; failures cascaded to checkout starting 29 seconds later.*

Then ask Nubi which line is responsible, and it clones the annotated repo and
tells you: `main.go:208`, `main.go:215`, `main.go:221`.

## Honesty about what does not work

The [scenario catalogue](./deploy/kubernetes/sample-app/scenarios.yaml) records
failures as carefully as successes. Of fifteen fault flags, four detect cleanly,
two only via their caller, two are silent no-ops, and seven produce no signal
this stack can see.

Most of that is instrumentation coverage, not the monitoring: only `ad`,
`checkout` and `product-catalog` emit gRPC server metrics at all, so error-rate
rules cannot fire for the other services no matter how hard their flag fails.

Every entry says which it is. A demo that quietly does nothing is worse than one
that plainly fails, because the natural conclusion -- "the tool missed it" -- is
wrong and unfalsifiable.

---

## Relationship to upstream

This is a fork of [open-telemetry/opentelemetry-demo][upstream], tracking it
closely. All application code, the shop itself and the original feature flags are
upstream's work under Apache 2.0; the additions above are confined to
[`deploy/kubernetes/sample-app/`](./deploy/kubernetes/sample-app/) plus small,
documented patches to `cart` and `product-catalog`.

For the demo itself -- architecture, per-service documentation, running it with
Docker Compose, contributing to the OpenTelemetry project -- use upstream's
sources, which remain authoritative:

- [Upstream README][upstream]
- [Demo documentation](https://opentelemetry.io/docs/demo/)
- [Architecture](https://opentelemetry.io/docs/demo/architecture/)
- [Service documentation](https://opentelemetry.io/docs/demo/services/)
- [CHANGELOG](./CHANGELOG.md) | [LICENSE](./LICENSE)

If you want to demonstrate a *different* observability vendor's integration with
this demo, upstream's [fork guidance](https://opentelemetry.io/docs/demo/forking/)
is the right starting point -- not this repo.

[upstream]: https://github.com/open-telemetry/opentelemetry-demo
