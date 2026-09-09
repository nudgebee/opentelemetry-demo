#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# fault.sh -- run the demo's REAL-MECHANISM failure scenarios.
#
# Usage:
#   ./fault.sh list                  every scenario, its category and summary
#   ./fault.sh describe <id>         mechanism and expected symptoms
#   ./fault.sh start <id>            inject
#   ./fault.sh stop <id>             revert now (they also expire on their own)
#   ./fault.sh stop --all            revert everything this script started
#   ./fault.sh status                what is currently running
#
#   --namespace NS                   demo namespace (default: demo, or $DEMO_NAMESPACE)
#   --context CTX                    kube context (or $KUBE_CONTEXT). Set this.
#
# ---------------------------------------------------------------------------
# HOW THIS DIFFERS FROM scenario.sh
# ---------------------------------------------------------------------------
# scenario.sh flips flagd flags: the application is TOLD to misbehave. That is
# fine for demonstrating a known fault, but it is weak for testing analysis,
# because the application knows the answer and usually says so in its own
# telemetry.
#
# The scenarios here use real mechanisms instead -- packet delay, CPU
# contention, extra load -- so nothing in the system knows a scenario is
# running. The evidence has to be reasoned about rather than read.
#
# ---------------------------------------------------------------------------
# WHY THERE IS NO CONTROLLER
# ---------------------------------------------------------------------------
# A fault left running is worse than a fault that never ran, so revert has to
# survive this script dying, the terminal closing, or the laptop going to sleep.
# The usual answer is an operator that owns the lifecycle. We do not need one:
# every scenario is expressed as an object that expires on its own --
# a Chaos Mesh CR with spec.duration, or a Job with activeDeadlineSeconds.
# The cluster enforces the deadline, so `stop` is only ever an early exit.
#
# The practical consequence: if this script is interrupted, DO NOTHING. The
# fault ends by itself. Check with `status`.
#
# ---------------------------------------------------------------------------
# WHY THE OBJECTS HAVE MEANINGLESS NAMES
# ---------------------------------------------------------------------------
# Kubernetes events reach most observability backends, so an object called
# `cpu-burner` or `network-fault` puts the answer into the telemetry the tool
# under test is reading, timestamped to the incident. That turns an analysis
# test into a reading test.
#
# So the objects are `mj-NN` and their workloads are named for what they
# plausibly are (`media-transcoder`, `load-driver`). The mapping from id to
# mechanism lives in faults/*.yaml and in `describe` -- for humans, out of band.
# Do not rename them to something clearer.
#
set -euo pipefail

NS="${DEMO_NAMESPACE:-demo}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HERE/faults"
LABEL="maintenance.platform/job"

# Never rely on whatever context the operator happens to have selected -- these
# commands degrade workloads, and "wrong cluster" is not a recoverable mistake.
# Set KUBE_CONTEXT (or pass --context) to be explicit.
KCTX="${KUBE_CONTEXT:-}"
kubectl() {
  if [ -n "$KCTX" ]; then command kubectl --context="$KCTX" "$@"
  else command kubectl "$@"; fi
}

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '4,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'; }

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="${2:-}"; shift 2 ;;
    --context)   KCTX="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

command -v kubectl >/dev/null || die "kubectl not found"
[ -d "$DIR" ] || die "no faults/ directory next to this script"

file_for() {
  local id="$1" f
  f="$(find "$DIR" -maxdepth 1 -name "${id}-*.yaml" -o -maxdepth 1 -name "${id}.yaml" 2>/dev/null | head -1)"
  [ -n "$f" ] || die "unknown scenario '$id' (try: $0 list)"
  echo "$f"
}

# Metadata lives in the leading comment block, so the file stays a plain
# kubectl-appliable manifest with no parser and no PyYAML dependency.
meta() { sed -n "s|^# *$2: *||p" "$1" | head -1; }

# The DNS ClusterIP service name differs by distribution (kube-dns on GKE/EKS,
# coredns elsewhere), so resolve it rather than hardcoding one and failing
# silently on the other.
dns_service() {
  local svc
  for svc in kube-dns coredns rke2-coredns-rke2-coredns; do
    if kubectl -n kube-system get svc "$svc" >/dev/null 2>&1; then
      echo "${svc}.kube-system.svc.cluster.local"; return 0
    fi
  done
  die "could not find a DNS service in kube-system -- pass one via DNS_SERVICE" ;
}

# Read the collector endpoint off the demo's own load-generator rather than
# hardcoding one, so a scenario that emits telemetry works on any install.
otel_endpoint() {
  local ep
  ep="$(kubectl -n "$NS" get deploy load-generator \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OTEL_COLLECTOR_NAME")].value}' 2>/dev/null || true)"
  [ -n "$ep" ] || die "could not read OTEL_COLLECTOR_NAME from the load-generator deployment -- pass OTEL_ENDPOINT explicitly"
  echo "http://${ep}:4318"
}

render() {
  local f="$1" dns="${DNS_SERVICE:-}" otel="${OTEL_ENDPOINT:-}"
  if grep -q "__DNS_SERVICE__" "$f"; then
    [ -n "$dns" ] || dns="$(dns_service)"
  fi
  if grep -q "__OTEL_ENDPOINT__" "$f"; then
    [ -n "$otel" ] || otel="$(otel_endpoint)"
  fi
  sed -e "s|__NAMESPACE__|$NS|g" -e "s|__DNS_SERVICE__|$dns|g" -e "s|__OTEL_ENDPOINT__|$otel|g" "$f"
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;

  list)
    printf '%-8s %-9s %s\n' ID CATEGORY SUMMARY
    for f in "$DIR"/*.yaml; do
      [ -e "$f" ] || continue
      # faults/ also holds install helpers (the Chaos Mesh RBAC fix), which are
      # not scenarios. An `id:` header is what makes a file a scenario.
      id="$(meta "$f" id)"
      [ -n "$id" ] || continue
      printf '%-8s %-9s %s\n' "$id" "$(meta "$f" category)" "$(meta "$f" summary)"
    done
    echo
    echo "describe <id> for the mechanism and what it should look like."
    exit 0 ;;

  describe)
    F="$(file_for "${2:-}")"
    # The comment block IS the documentation; print it rather than maintaining
    # a second copy that can drift from the manifest.
    sed -n '/^# id:/,/^[a-zA-Z]/p' "$F" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0 ;;

  start)
    ID="${2:-}"; [ -n "$ID" ] || die "start needs a scenario id (try: $0 list)"
    F="$(file_for "$ID")"
    if [ "$(meta "$F" category)" = network ] && ! kubectl get crd networkchaos.chaos-mesh.org >/dev/null 2>&1; then
      die "this scenario needs Chaos Mesh, which is not installed. See faults/README.md"
    fi
    render "$F" | kubectl -n "$NS" apply -f -
    echo
    echo "Started $ID in namespace '$NS'. It reverts itself when its deadline expires."
    echo "Watch it:   $0 status"
    echo "Stop early: $0 stop $ID"
    exit 0 ;;

  stop)
    TARGET="${2:-}"; [ -n "$TARGET" ] || die "stop needs a scenario id, or --all"
    if [ "$TARGET" = "--all" ]; then
      # Delete by label rather than by file, so objects from a scenario file that
      # has since been edited or deleted still get cleaned up.
      kubectl -n "$NS" delete networkchaos,job -l "$LABEL" --ignore-not-found
      echo "Reverted everything labelled $LABEL in namespace '$NS'."
    else
      F="$(file_for "$TARGET")"
      render "$F" | kubectl -n "$NS" delete --ignore-not-found -f -
      echo "Reverted $TARGET in namespace '$NS'."
    fi
    exit 0 ;;

  status)
    echo "Active scenario objects in namespace '$NS':"
    OUT="$(kubectl -n "$NS" get networkchaos,job -l "$LABEL" 2>/dev/null || true)"
    if [ -z "$OUT" ]; then
      echo "  (none)"
    else
      printf '%s\n' "$OUT" | sed 's/^/  /'
    fi
    exit 0 ;;

  *) die "unknown command '${1}' (try: $0 --help)" ;;
esac
