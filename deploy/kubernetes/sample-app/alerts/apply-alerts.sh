#!/usr/bin/env bash
#
# apply-alerts.sh -- install the demo's alerting rules into whichever namespace
# your Prometheus (or VictoriaMetrics) operator actually watches.
#
# The rule files in this directory are valid as-is for the common case
# (demo in `demo`, rules object in `victoria`). This script exists for every
# other case, so nobody has to hand-edit PromQL expressions -- the previous
# instructions told readers to `sed` the expressions in place, which is easy to
# get half-right and fails silently: a rule whose namespace selector matches
# nothing never fires and never errors.
#
# Usage:
#   ./apply-alerts.sh [options]
#
#   --demo-namespace   NS   where the demo workloads run; this is the value of the
#                           namespace="..." selector INSIDE each PromQL expression,
#                           i.e. where the metrics come from.   (default: demo)
#   --rules-namespace  NS   where the PrometheusRule objects themselves live; this
#                           must be a namespace your operator is allowed to read.
#                           (default: victoria)
#   --release-label    NAME add `release: NAME` to each rule's labels. REQUIRED for
#                           a default kube-prometheus-stack install -- see below.
#   --dry-run               print the rendered YAML instead of applying it.
#   -h, --help              show this help.
#
# About --release-label:
#   kube-prometheus-stack ships with `ruleSelectorNilUsesHelmValues: true`, which
#   makes Prometheus pick up ONLY PrometheusRule objects labelled with its own Helm
#   release name. Applying an unlabelled rule there looks like it worked -- the
#   object is created, kubectl says configured -- but Prometheus never loads it.
#   If you installed Prometheus the way the NudgeBee agent docs describe:
#
#     helm upgrade --install nudgebee-prometheus prometheus-community/kube-prometheus-stack \
#       --namespace nudgebee-agent ...
#
#   then the matching invocation here is:
#
#     ./apply-alerts.sh --rules-namespace nudgebee-agent --release-label nudgebee-prometheus
#
#   VictoriaMetrics users generally do not need this: the VM operator watches
#   PrometheusRule objects and converts them to VMRule automatically, and its rule
#   selector is usually empty (= match everything it can read).
#
set -euo pipefail

DEMO_NS="demo"
RULES_NS="victoria"
RELEASE_LABEL=""
DRY_RUN="false"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --demo-namespace)  DEMO_NS="${2:-}";       shift 2 ;;
    --rules-namespace) RULES_NS="${2:-}";      shift 2 ;;
    --release-label)   RELEASE_LABEL="${2:-}"; shift 2 ;;
    --dry-run)         DRY_RUN="true";         shift   ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$DEMO_NS" ]  || die "--demo-namespace cannot be empty"
[ -n "$RULES_NS" ] || die "--rules-namespace cannot be empty"

# RFC 1123 label check on both namespaces. Without this, a typo'd flag value
# (e.g. a stray quote) would be silently baked into every PromQL selector and the
# rules would quietly match nothing.
ns_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
[[ "$DEMO_NS"  =~ $ns_re ]] || die "--demo-namespace '$DEMO_NS' is not a valid namespace"
[[ "$RULES_NS" =~ $ns_re ]] || die "--rules-namespace '$RULES_NS' is not a valid namespace"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
RULE_FILES=("$SCRIPT_DIR"/otel-demo-*.yaml)
shopt -u nullglob
[ ${#RULE_FILES[@]} -gt 0 ] || die "no otel-demo-*.yaml rule files found in $SCRIPT_DIR"

command -v kubectl >/dev/null || die "kubectl not found"

# Render:
#  1. rewrite the namespace="demo" selector inside expressions -> --demo-namespace
#  2. drop the hardcoded `  namespace: victoria` metadata line, so the object's
#     namespace comes from `kubectl -n` instead. Dropping it rather than rewriting
#     it keeps this to one anchored substitution and lets kubectl own placement.
#  3. optionally add the `release:` label under the existing metadata.labels block,
#     anchored on the `app: otel-demo` line the rule files already carry.
render() {
  local f
  for f in "${RULE_FILES[@]}"; do
    sed \
      -e "s/namespace=\"demo\"/namespace=\"${DEMO_NS}\"/g" \
      -e '/^  namespace: victoria$/d' \
      "$f" \
    | if [ -n "$RELEASE_LABEL" ]; then
        sed -e "s/^    app: otel-demo$/    app: otel-demo\n    release: ${RELEASE_LABEL}/"
      else
        cat
      fi
    echo "---"
  done
}

if [ "$DRY_RUN" = "true" ]; then
  render
  exit 0
fi

# Fail loudly if the target namespace is absent. kubectl apply would report
# "namespaces not found" anyway, but saying so up front distinguishes "you pointed
# at the wrong namespace" from "your rules did not load".
kubectl get namespace "$RULES_NS" >/dev/null 2>&1 \
  || die "namespace '$RULES_NS' does not exist -- is that really where your Prometheus/VM operator runs?"

render | kubectl apply -n "$RULES_NS" -f -

echo
echo "Applied $(( ${#RULE_FILES[@]} )) rule file(s) to namespace '$RULES_NS', selecting metrics from namespace '$DEMO_NS'."
if [ -z "$RELEASE_LABEL" ]; then
  echo
  echo "NOTE: no --release-label was given. On a default kube-prometheus-stack install"
  echo "      Prometheus will create these objects but never load them. Verify with:"
  echo "        kubectl -n $RULES_NS get prometheusrule"
  echo "      then check the rules actually appear in Prometheus under Status > Rules."
fi
