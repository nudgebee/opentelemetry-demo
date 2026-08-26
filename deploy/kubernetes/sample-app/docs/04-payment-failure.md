# Scenario D: Payment failure

**Flag:** `paymentFailure=100%` | **Service:** `payment` |
**Detected on:** `checkout` | **Status:** verified, detected indirectly

The scenario that teaches how to read an alert that fires on the *wrong*
service. Use it to demo blast-radius reasoning -- not to promise coverage of
`payment`.

## Read this first

**The alert fires on `checkout`, never on `payment`.**

`payment` emits no gRPC server metrics at all, so no error-rate rule can fire
against it directly, no matter how hard it fails. The failure is visible only
on its caller.

This is a property of the demo's instrumentation, not a NudgeBee limitation --
`cart`, `payment`, `currency`, `shipping`, `recommendation`, `quote` and
`email` are all in the same position. Only `ad`, `checkout` and
`product-catalog` emit gRPC server metrics.

Say this out loud when demoing. An audience that notices the alert names
`checkout` while you are talking about `payment` will assume something is
broken unless you get there first.

## What it does

Every card charge fails, so `PlaceOrder` fails. `checkout` calls `payment`
during `PlaceOrder`, so `checkout`'s gRPC server error rate climbs and the
rule fires against it.

## Run it

```bash
S=./deploy/kubernetes/sample-app/scenario.sh

$S paymentFailure 100%
$S --check paymentFailure
```

The variant is a **percentage**, not a boolean. `100%` makes every charge
fail; lower values produce a partial error rate that may not cross the alert
threshold.

Objective check -- orders should fail at checkout:

```bash
kubectl -n demo logs -l app.kubernetes.io/name=checkout --tail=50 \
  | grep -i 'payment\|failed'
```

## Do not run this with emailMemoryLeak

`checkout` calls `chargeCard` **before** `sendOrderConfirmation`. A payment
failure aborts the order before `email` is ever invoked, so the leak gets no
traffic and Scenario B will silently never fire.

`scenarios.yaml` records this under `conflicts_with`. It is the one flag
combination in the set that actively cancels another scenario out.

## What you should see

One alert, `OtelDemoGRPCServerErrorRate`, on **checkout**, against
`oteldemo.CheckoutService/PlaceOrder`.

Open it from **Troubleshoot -> All Events -> Triage Inbox**, filtering
**Event Type** to the `OtelDemo*` rules.

## What to look for in the RCA

The interesting question is whether the investigation walks *past* the alerting
service to the real culprit. Read the **Root Cause** and **Affected
Components** sections and check whether they name `payment` -- the service the
alert does not mention -- rather than stopping at `checkout`.

That is the whole point of this scenario: the alert says `checkout`, the
answer is `payment`, and the trace data is what bridges them.

Good follow-up questions for **Ask a follow up**:

> Which downstream dependency of checkout is actually failing, and what
> error is it returning?

> Using the annotated source repository, show me where checkout calls the
> payment service during PlaceOrder.

## Clean up

```bash
$S paymentFailure off
```

Confirm the `checkout` alert resolves before starting another scenario. A
`paymentFailure` run that is still firing will keep the same `checkout` alert
active and get miscredited to whatever you run next -- see
[Scenario E](./05-payment-unreachable.md), which fires the identical alert.

Because it is the identical alert, it is also the identical dedup fingerprint:
run E after D and E will **reuse D's RCA** instead of producing its own. Pick
one of the two per session.
