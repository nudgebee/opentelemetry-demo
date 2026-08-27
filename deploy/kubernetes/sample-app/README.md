# Testing NudgeBee with the OpenTelemetry demo

Break a realistic microservice application on purpose, then watch NudgeBee
detect it, explain it, and propose the fix.

Roughly 30 minutes end to end, most of it waiting for Helm.

Everything below was measured against a live cluster, including the parts that
do **not** work. Where a scenario produces nothing, this guide says so and says
why -- a demo that quietly fails is worse than one that plainly does.

---

## What you get

The [OpenTelemetry Astronomy Shop](https://github.com/open-telemetry/opentelemetry-demo)
is a 20-service e-commerce app in nine languages, fully instrumented, with
built-in feature flags that inject real faults: a database outage, a memory
leak, a slow dependency, failing payments.

That last part is why it is a good NudgeBee test. The failures are genuine --
real OOM kills, real gRPC errors, real database latency -- but they are
reproducible on demand and switch off cleanly.

---

## Before you start

| Requirement | Notes |
| --- | --- |
| Kubernetes cluster | v1.27+, ~4 spare CPU / 8 GiB. Anything smaller and the demo itself is your bottleneck. |
| Helm 3 | |
| NudgeBee account | [app.nudgebee.com](https://app.nudgebee.com) or self-hosted |
| NudgeBee agent installed | See the section below -- **read the gotchas, several are silent** |

---

## 1. Install the NudgeBee agent

Follow the [agent install docs](https://docs.nudgebee.com/docs/installation/agent/installation/).
Four things bite people, all verified on a fresh install:

**If you already run Prometheus, your alerts are not wired.** The docs say
"already have Prometheus? you just need its URL" -- true for metrics, which are
*queried*, never shipped. But it also means you skipped the values file that
configures Alertmanager, so nothing routes alerts to NudgeBee. You will need the
receiver in [`alertmanager-receiver.yaml`](./alertmanager-receiver.yaml).

**If you did not name the release `nudgebee-agent` in namespace
`nudgebee-agent`, your alerts go nowhere.** The agent's `kube-prometheus-stack-values.yaml`
hardcodes `http://nudgebee-agent-runner.nudgebee-agent.svc/api/alerts`, while the
chart names the Service `<release>-runner`. Check yours:

```bash
kubectl get svc -A | grep runner
```

**If a node-exporter already exists, the new one cannot schedule.**
kube-prometheus-stack's node-exporter wants hostPort 9100. The documented
`--set nodeExporter.service.targetPort=9101` only changes the Service and does
not help. Use:

```bash
--set prometheus-node-exporter.hostNetwork=false \
--set prometheus-node-exporter.service.port=9101 \
--set prometheus-node-exporter.service.targetPort=9101
```

**Self-hosted NudgeBee: set the collector endpoint explicitly.**
`runner.nudgebee.endpoint` defaults to `https://collector.nudgebee.com`. The
Helm command the UI generates does not override it, so a self-hosted install
silently sends data to the SaaS:

```bash
--set runner.nudgebee.endpoint="https://collector.<your-nudgebee-host>"
```

**Prove alerts can reach NudgeBee before going further.** If a scenario later
produces nothing, you want to already know the transport is not the reason:

```bash
kubectl -n <agent-ns> port-forward svc/<release>-runner 8080:80
curl -sS -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/api/alerts \
  -H 'Content-Type: application/json' \
  -d '{"version":"4","status":"firing","alerts":[{"status":"firing",
       "labels":{"alertname":"SmokeTest","severity":"warning","namespace":"demo"},
       "annotations":{"summary":"ignore me"},"startsAt":"2026-01-01T00:00:00Z"}]}'
```

`202` means the path works. Separately, once Alertmanager is wired you should
see a **`Watchdog`** event in NudgeBee -- that alert exists purely to certify
Alertmanager delivery, so its presence is proof the pipe is healthy. Conversely
`AlertmanagerFailedToSendAlerts` means your receiver URL is wrong.

---

## 2. Install the demo

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --namespace demo --create-namespace \
  -f deploy/kubernetes/sample-app/values.yaml
```

`values.yaml` is not cosmetic. It sets CPU limits so throttling is measurable,
tightens memory so leaks reach OOM in minutes rather than hours, wires a
readiness probe, and drops the metric export interval from 60s to 15s -- which is
what takes detection from ~8 minutes to ~2.5.

Wait for green, then confirm the shop works:

```bash
kubectl -n demo port-forward deploy/frontend-proxy 8080:8080
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  'http://localhost:8080/api/products?currencyCode=USD'   # expect 200, <1s
```

---

## 3. Install the alert rules

The upstream chart ships no alerting. Without these NudgeBee sees metrics and
traces but never receives an alert, so none of the incident, correlation or
root-cause behaviour has anything to work with.

```bash
./deploy/kubernetes/sample-app/alerts/apply-alerts.sh \
  --demo-namespace demo \
  --rules-namespace <where-your-prometheus-operator-watches> \
  --release-label <your-kube-prometheus-stack-release>
```

`--release-label` is not optional on a default kube-prometheus-stack. It sets
`ruleSelectorNilUsesHelmValues: true`, meaning Prometheus loads only rules
labelled with its own release name. Without the label the rules apply cleanly,
`kubectl` says `configured`, and Prometheus never loads them. Verify in
Prometheus under **Status -> Rules**, not by trusting the apply.

---

## 4. Annotate the workloads

This is what lets NudgeBee read your source code during an investigation.

```bash
./deploy/kubernetes/sample-app/annotate-workloads.sh \
  --namespace demo \
  --code-commit <the commit your images were built from>
```

The commit must match the running images. A mismatched hash makes the code agent
cite functions that do not exist in the running binary -- worse than no code
analysis at all. Re-run after every `helm upgrade`; the upstream chart can only
set pod annotations, and NudgeBee reads Deployment annotations.

To also get automated rightsizing pull requests, fork this repo and add
`--ci-repo https://github.com/<you>/opentelemetry-demo.git`.

---

## 5. Break something

```bash
S=./deploy/kubernetes/sample-app/scenario.sh
$S --list                      # every flag and its variants
$S postgresFailure on          # break the product catalog's database
$S --check postgresFailure     # confirm flagd is really serving it
$S --reset                     # all faults off
$S --drain http://localhost:9090   # reset AND wait for alerts to clear
```

Use `--drain`, not `--reset`, **between** scenarios. Investigations read
traces from around the alert, so a fault that was erroring a minute ago ends
up in the next scenario's evidence -- we hit exactly that, and it turned a
clean result into `Root Cause: Undetermined`.

`--check` matters. It asks flagd what it is actually serving, which separates
three situations you otherwise cannot tell apart: the write did not land, the
flag is served but the service ignores it, or everything works and NudgeBee
genuinely saw nothing. Only the third is a finding.

**Leave the fault running** until the investigation *and* any Nubi follow-up
have finished. NudgeBee inspects live state; reset too early and it will
correctly report that nothing is wrong now, having missed what already happened.

---

## The scenarios worth demoing

Five scenarios produce a signal. The three below are the headline ones;
**full step-by-step walkthroughs with screenshots for all five are in
[`docs/`](./docs/README.md)**, including the two payment scenarios that are
detected indirectly.

Full catalogue, including what does not work, in [`scenarios.yaml`](./scenarios.yaml).

### A. Database outage -- root cause and blast radius

Full walkthrough: [`docs/01-database-outage.md`](./docs/01-database-outage.md)

```bash
$S postgresFailure on
```

Every product query fails; the storefront returns HTTP 500. About 2.5 minutes
later, alerts fire on **product-catalog** (the cause) and **checkout** (a
caller). Open either from **Troubleshoot -> Events -> Investigate**.

What the RCA gave us, unedited:

> The 100% failure rate on product-catalog was caused by activation of the
> `postgresFailure` feature flag... returning `13 INTERNAL: PostgreSQL unavailable`
>
> Pod CPU utilization remained negligible at ~0.001-0.002 cores, ruling out
> resource exhaustion.
>
> **Related Alerts Check** -- checkout: *Confirmed -- checkout calls product-catalog
> during PlaceOrder; failures cascaded to checkout starting 29 seconds later.*

Note what that is doing: naming the trigger, quoting the error, actively ruling
out a wrong hypothesis with evidence, and tying a second alert to the first with
a measured offset.

### B. Memory leak -- crash analysis down to the line

Full walkthrough: [`docs/02-memory-leak.md`](./docs/02-memory-leak.md)

```bash
$S emailMemoryLeak 10000x
$S loadGeneratorVUs 50          # more orders = faster leak
```

The email service OOMKills in under 30 seconds and enters CrashLoopBackOff 75
seconds after that. This one needs no alert rules at all -- the kernel OOM
killer is the signal, so it is the most deterministic scenario in the set.

Expect the RCA to blame the 100Mi memory limit rather than the leak. Its
evidence is anon-RSS at the moment of the kill, which is circular -- measured
baseline with the leak off is ~55Mi, so the limit is fine. Do not raise it;
see the
[walkthrough](./docs/02-memory-leak.md#expect-the-rca-to-blame-the-memory-limit).

Scored **69 / P1**, and the report shows its own arithmetic:

> Intrinsic Base 62 | Environment `non_prod` -8 |
> Blast Radius `single_workload` 0 |
> Correlation `likely_root_cause` +15 | Confidence 0.9

It also assembles the incident, correlating the CrashLoopBackOff 75 seconds later
as *"a direct downstream failure caused by container restart loops following the
OOM kill"*.

Do not run this together with `paymentFailure`: checkout charges the card before
sending the confirmation email, so a payment failure starves the leak of traffic.

### C. Slow dependency -- the alert that names the cause

Full walkthrough: [`docs/03-slow-dependency.md`](./docs/03-slow-dependency.md)

```bash
$S postgresSlow 6sec
```

Product queries go from ~0.8s to ~6.8s using real database time. Fired in
**2m25s** as `OtelDemoPostgresQueryLatencyHigh`, carrying `db_system_name`.

This is the correlation story. Symptom rules only ever alert on a slow
dependency's *callers*, so a slow database looks like several slow services with
nothing naming the cause. The dependency rule closes that gap.

Use `6sec` to fire both rules. The dependency rule
(`OtelDemoPostgresQueryLatencyHigh`) triggers at a **100ms** mean, so `1sec`
also fires it; only `OtelDemoHighLatency` (HTTP p95 > 5s) needs `6sec`.

### D and E. The payment scenarios -- detected on the caller

```bash
$S paymentFailure 100%          # docs/04-payment-failure.md
$S paymentUnreachable on        # docs/05-payment-unreachable.md
```

Both fire `OtelDemoGRPCServerErrorRate` on **checkout**, never on `payment` --
`payment` emits no gRPC server metrics, so no rule can fire against it. Good
for demonstrating blast-radius reasoning, provided you say that up front.

Do not run `paymentFailure` alongside `emailMemoryLeak`: checkout charges the
card before sending the confirmation email, so it starves the leak of traffic.

---

## Solving it from the Events / Nubi page

Detection is the start. The loop is:

1. **Troubleshoot -> Events** -- filter to `ns: demo`. Alert-based events group
   caller and callee; repeat triggers of the same scenario group into the
   existing event rather than creating a new one.
2. **Investigate** -- Root Cause, Evidence, Affected Components, Recommended
   Actions, plus the tasks that produced them.
3. **Ask a follow up** -- this is where code analysis happens. **It is not
   automatic.** The alert investigation runs about ten tasks -- timeline, labels,
   dependencies, metrics, traces, threshold tuning, resource check -- and none of
   them reads source. You have to ask.

   Try: *"Using the annotated source repository for this workload, show me the
   exact file and lines that cause this."*

   Nubi checks the workload's annotations, clones the repo, greps it, and reads
   the file. On our run it returned `main.go:208`, `main.go:215` and `main.go:221`
   -- all three verified correct against the real source at that commit.

4. **Generate Remediation** -> **Fix it** -- turns the analysis into an action,
   e.g. raising a memory limit, with approval before anything is applied.

---

## When a scenario produces nothing

Work down this list in order. Most "NudgeBee missed it" reports are one of the
first three.

| Check | How |
| --- | --- |
| Is the flag really served? | `scenario.sh --check <flag>` |
| Did the fault actually happen? | `curl` the storefront, or `kubectl get pod` for OOM |
| Can alerts reach NudgeBee? | the `curl` in step 1; look for `Watchdog` |
| Are rules loaded? | Prometheus **Status -> Rules** -- not just `kubectl get prometheusrule` |
| Is the service even instrumented? | see below |

**Only `ad`, `checkout` and `product-catalog` emit gRPC server metrics.**
`cart`, `payment`, `currency`, `shipping`, `recommendation`, `quote` and `email`
emit none, so no error-rate rule can ever fire for them regardless of how hard
their flag fails. Those failures are visible only on the *caller*. This is a
property of the demo's instrumentation, not of NudgeBee.

Three flags are known no-ops and are documented as such in `scenarios.yaml`:
`cartFailure` (numeric since demo 3.0.0 while older cart builds read it as a
boolean, so OpenFeature silently returns the default), `adFailure` (the ad
service cannot re-establish its flagd connection after a restart), and
`productCatalogFailure` (its upstream targeting rule returns "off" on both
branches, so it can never be enabled -- `scenario.sh --targeting` reports this).

---

## Clean up

```bash
$S --reset                        # always do this on a shared cluster
helm uninstall otel-demo -n demo
kubectl delete namespace demo
```
