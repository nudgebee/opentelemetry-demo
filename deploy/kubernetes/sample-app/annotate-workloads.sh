#!/usr/bin/env bash
#
# annotate-workloads.sh -- tell NudgeBee which source code and which infrastructure
# repo each demo workload belongs to.
#
# WHY THIS IS A SCRIPT AND NOT HELM VALUES
#   NudgeBee reads these annotations from the *Deployment* object. The upstream
#   opentelemetry-demo chart can only set `podAnnotations`, which land on the pod
#   template and are never visible as workload annotations -- there is no
#   `deploymentAnnotations` value to use. So this has to be applied after
#   `helm install`, and re-applied after every `helm upgrade`, which is why the
#   script is idempotent and safe to re-run.
#
# WHAT THE ANNOTATIONS DO
#   workloads.nudgebee.com/git.repo   Source repo for the running service. This is
#   workloads.nudgebee.com/git.hash   what lets NudgeBee's code agent clone the
#                                     code and do code-level root-cause analysis --
#                                     e.g. an OOMKill on `recommendation` coming
#                                     back with the actual leaking cache in
#                                     recommendation_server.py rather than just
#                                     "container exceeded its memory limit".
#
#   ci.nudgebee.com/git.repo          Infrastructure repo + the Helm values file
#   ci.nudgebee.com/git.branch        inside it. This is what NudgeBee opens
#   ci.nudgebee.com/helm.values.filePath  rightsizing pull requests against. Point
#                                     it at YOUR fork -- NudgeBee cannot open a PR
#                                     against a repo you do not control.
#
# THE HASH MUST MATCH THE RUNNING IMAGES
#   If git.hash points at code that is not what is actually deployed, the code
#   agent will confidently cite functions that do not exist in the running binary.
#   That is worse than having no annotation at all. By default this script uses the
#   commit of the checkout it is run from; override with --code-commit if you
#   deployed something else.
#
# Usage:
#   ./annotate-workloads.sh --ci-repo https://github.com/<you>/opentelemetry-demo.git
#
#   --namespace         NS    demo namespace                (default: demo)
#   --code-repo         URL   source repo for the services
#                             (default: https://github.com/nudgebee/opentelemetry-demo.git)
#   --code-commit       SHA   commit matching the deployed images
#                             (default: git rev-parse HEAD of this checkout)
#   --ci-repo           URL   your fork, for rightsizing PRs. Omitted = skip the
#                             ci.nudgebee.com/* annotations entirely.
#   --ci-branch         NAME  branch to open PRs against     (default: main)
#   --ci-values-path    PATH  values file inside --ci-repo
#                             (default: deploy/kubernetes/sample-app/values.yaml)
#   --include           LIST  comma-separated Deployments to annotate, overriding
#                             the built-in demo-service list
#   --all                     annotate every Deployment in the namespace. NOT
#                             recommended: it tags third-party workloads (jaeger,
#                             grafana, opensearch, kafka) with the demo's repo,
#                             pointing the code agent at source that does not
#                             build them.
#   --dry-run                 print the kubectl commands instead of running them
#   -h, --help                show this help
#
set -euo pipefail

NAMESPACE="demo"
CODE_REPO="https://github.com/nudgebee/opentelemetry-demo.git"
CODE_COMMIT=""
CI_REPO=""
CI_BRANCH="main"
CI_VALUES_PATH="deploy/kubernetes/sample-app/values.yaml"
INCLUDE=""
ANNOTATE_ALL="false"
DRY_RUN="false"

# Demo services that are actually built from source in this repo (each has a
# Dockerfile under src/). Deliberately excludes the third-party components the
# chart also deploys -- jaeger, grafana, opensearch, prometheus, valkey, postgres --
# because their source does not live here and pointing the code agent at this repo
# for them would produce confident nonsense.
DEMO_SERVICES="accounting ad agent cart chatbot checkout currency email flagd-ui fraud-detection frontend frontend-proxy image-provider load-generator mcp payment product-catalog quote recommendation shipping"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace)      NAMESPACE="${2:-}";      shift 2 ;;
    --code-repo)      CODE_REPO="${2:-}";      shift 2 ;;
    --code-commit)    CODE_COMMIT="${2:-}";    shift 2 ;;
    --ci-repo)        CI_REPO="${2:-}";        shift 2 ;;
    --ci-branch)      CI_BRANCH="${2:-}";      shift 2 ;;
    --ci-values-path) CI_VALUES_PATH="${2:-}"; shift 2 ;;
    --include)        INCLUDE="${2:-}";        shift 2 ;;
    --all)            ANNOTATE_ALL="true";     shift   ;;
    --dry-run)        DRY_RUN="true";          shift   ;;
    -h|--help)        usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v kubectl >/dev/null || die "kubectl not found"
[ -n "$NAMESPACE" ] || die "--namespace cannot be empty"
[ -n "$CODE_REPO" ] || die "--code-repo cannot be empty"

# Resolve the commit if not given. Falling back to a guess would be worse than
# failing: a wrong hash sends the code agent to the wrong source.
if [ -z "$CODE_COMMIT" ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    CODE_COMMIT="$(git rev-parse HEAD)"
    if ! git diff --quiet HEAD 2>/dev/null; then
      echo "warning: this checkout has uncommitted changes, so ${CODE_COMMIT:0:12} does not" >&2
      echo "         fully describe your working tree. If the deployed images were built from" >&2
      echo "         those changes, pass the real commit with --code-commit." >&2
    fi
  else
    die "not inside a git checkout and --code-commit was not given; cannot determine the source commit"
  fi
fi

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' not found"

# Work out which Deployments to touch.
#
# Read into the array with a while-loop rather than `mapfile`: mapfile is bash 4+,
# and macOS still ships bash 3.2 as /bin/bash, so anyone running this on a Mac
# would otherwise hit "mapfile: command not found".
PRESENT=()
while IFS= read -r _line; do
  [ -n "$_line" ] && PRESENT+=("$_line")
done < <(kubectl -n "$NAMESPACE" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ ${#PRESENT[@]} -gt 0 ] || die "no Deployments found in namespace '$NAMESPACE'"

TARGETS=()
if [ "$ANNOTATE_ALL" = "true" ]; then
  TARGETS=("${PRESENT[@]}")
elif [ -n "$INCLUDE" ]; then
  IFS=',' read -r -a WANTED <<< "$INCLUDE"
  for w in "${WANTED[@]}"; do
    w="$(echo "$w" | tr -d '[:space:]')"
    [ -n "$w" ] || continue
    if printf '%s\n' "${PRESENT[@]}" | grep -qx "$w"; then
      TARGETS+=("$w")
    else
      echo "warning: --include named '$w' but no such Deployment in '$NAMESPACE'; skipping" >&2
    fi
  done
else
  for s in $DEMO_SERVICES; do
    if printf '%s\n' "${PRESENT[@]}" | grep -qx "$s"; then
      TARGETS+=("$s")
    fi
  done
fi

[ ${#TARGETS[@]} -gt 0 ] || die "nothing to annotate (no matching Deployments in '$NAMESPACE')"

ANNOTATIONS=(
  "workloads.nudgebee.com/git.repo=${CODE_REPO}"
  "workloads.nudgebee.com/git.hash=${CODE_COMMIT}"
)
if [ -n "$CI_REPO" ]; then
  ANNOTATIONS+=(
    "ci.nudgebee.com/git.repo=${CI_REPO}"
    "ci.nudgebee.com/git.branch=${CI_BRANCH}"
    "ci.nudgebee.com/helm.values.filePath=${CI_VALUES_PATH}"
  )
fi

echo "namespace      : $NAMESPACE"
echo "code repo      : $CODE_REPO"
echo "code commit    : $CODE_COMMIT"
if [ -n "$CI_REPO" ]; then
  echo "ci repo        : $CI_REPO (branch $CI_BRANCH, values $CI_VALUES_PATH)"
else
  echo "ci repo        : (not set -- rightsizing PRs disabled; pass --ci-repo to enable)"
fi
echo "deployments    : ${#TARGETS[@]} of ${#PRESENT[@]} in namespace"
echo

for d in "${TARGETS[@]}"; do
  # --overwrite makes re-runs after `helm upgrade` a no-op rather than an error.
  if [ "$DRY_RUN" = "true" ]; then
    echo "kubectl -n $NAMESPACE annotate deployment/$d --overwrite ${ANNOTATIONS[*]}"
  else
    kubectl -n "$NAMESPACE" annotate "deployment/$d" --overwrite "${ANNOTATIONS[@]}" >/dev/null
    echo "  annotated $d"
  fi
done

if [ "$DRY_RUN" != "true" ]; then
  echo
  echo "Done. NudgeBee picks these up on its next workload sync (a few minutes)."
  echo "Verify in the UI under Infra > Apps & Infra > Applications > <service> > Details > Annotations."
fi
