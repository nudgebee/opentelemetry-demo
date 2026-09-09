# Real-mechanism failure scenarios

Run these with [`../fault.sh`](../fault.sh). They are separate from
[`../scenario.sh`](../scenario.sh), which drives flagd feature flags.

The difference matters. A flag tells the application to misbehave, so the
application knows the answer and usually puts it in its own telemetry. These
scenarios use real mechanisms — packet delay, CPU contention, extra load — so
nothing in the system knows a scenario is running, and the cause has to be
reasoned about from evidence rather than read off a log line.

Mechanisms are adapted from [coroot/rca-lab](https://github.com/coroot/rca-lab)
(Apache-2.0), which is a full separate lab stack. We port the mechanisms onto the
demo we already run rather than installing it.

```
./fault.sh list
./fault.sh describe mj-01
./fault.sh start mj-01
./fault.sh status
./fault.sh stop mj-01          # optional; they expire on their own
```

## Every scenario expires by itself

A fault left running is worse than one that never ran, so revert must survive the
script dying, the terminal closing, or a laptop going to sleep. Rather than run a
controller to own that lifecycle, every scenario is an object the cluster already
knows how to expire:

| kind | expiry |
|------|--------|
| Chaos Mesh CR | `spec.duration` |
| Job | `activeDeadlineSeconds` |

`stop` is therefore only ever an early exit. **If a run is interrupted, do
nothing** — the fault ends on its own. Confirm with `./fault.sh status`.

## The objects have deliberately boring names

Kubernetes events reach most observability backends, so an object called
`cpu-burner` puts the answer into the telemetry the tool under test is reading,
timestamped to the incident. That turns an analysis test into a reading test.

So the objects are `mj-NN`, and the workloads they create are named for what they
plausibly are (`media-transcoder`, `load-driver`). The mapping from id to
mechanism lives in these files and in `fault.sh describe` — out of band, for
humans. **Do not rename them to something clearer.**

## Chaos Mesh

The `network` scenarios need it; `infra` scenarios do not. Install it
namespace-scoped so it can only inject faults into the demo namespace:

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh --create-namespace --version 2.8.4 \
  --set clusterScoped=false \
  --set controllerManager.targetNamespace=demo \
  --set dashboard.create=false \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock

kubectl apply -f chaos-mesh-namespaced-rbac-fix.yaml
```

The `socketPath` above is right for GKE, EKS and any containerd node. On a
Docker runtime use `--set chaosDaemon.runtime=docker --set
chaosDaemon.socketPath=/var/run/docker.sock`.

### The RBAC fix is not optional

**`chaos-mesh-namespaced-rbac-fix.yaml` is required whenever `clusterScoped=false`.**
chaos-mesh 2.8.x still watches the cluster-scoped `RemoteCluster` CRD in
namespace-scoped mode, but its namespaced RBAC does not grant it. The manager's
cache never finishes syncing, so **no chaos object is ever reconciled**.

This fails in the worst possible way: the API server accepts the CR, `kubectl get`
shows it, and `status.experiment` stays `{}` forever with no error on the object.
The only evidence is a repeating line in the controller-manager log:

```
failed to list *v1alpha1.RemoteCluster: remoteclusters.chaos-mesh.org is forbidden
```

The fix grants read-only access to that one CRD, which has no instances. It does
not widen what Chaos Mesh can act on — injection still comes from the namespaced
RoleBinding the chart creates for the target namespace. No restart is needed;
client-go retries the watch and the cache syncs within about a minute.

## Verifying a scenario did what it claims

Check the *tell*, not just the symptom. Every scenario here is designed so that
the obvious reading is wrong, and the way to confirm it is working is that the
distinguishing signal is present:

| id | symptom (expected everywhere) | tell (what makes it this scenario) |
|----|-------------------------------|------------------------------------|
| mj-01 | caller latency up ~200ms | product-catalog CPU **and DB time** flat |
| mj-02 | intermittent spikes on many services | every dependency healthy; CoreDNS CPU flat |
| mj-03 | checkout latency up | checkout CPU *below* normal — starved, not busy |
| mj-04 | latency/errors at one component | RPS up **everywhere**; only the weakest saturates |

Measured on dev 2026-09-08 for mj-01: frontend mean 4.5ms → 227.8ms, checkout
gRPC client 1.1ms → 99.6ms, product-catalog CPU 0.0066 → 0.0066 cores.
