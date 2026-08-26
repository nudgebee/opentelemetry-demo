#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# scenario.sh -- turn otel-demo failure scenarios on and off, and prove flagd is
# actually serving what you think it is.
#
# Usage:
#   ./scenario.sh --list                 show every flag and its variants
#   ./scenario.sh --status               show which flags are currently on
#   ./scenario.sh <flag> [variant]       enable (variant defaults to "on")
#   ./scenario.sh <flag> off             disable
#   ./scenario.sh --check <flag>         ask flagd what it is SERVING for this flag
#   ./scenario.sh --targeting <flag>     show the flag's targeting rule and whether
#                                        it can ever be enabled at all
#   ./scenario.sh --reset                turn every fault flag off
#
#   --namespace NS                       demo namespace (default: demo, or $DEMO_NAMESPACE)
#
# ---------------------------------------------------------------------------
# WHY THIS IS NOT JUST `kubectl patch configmap`
# ---------------------------------------------------------------------------
# flagd reads /etc/flagd/demo.flagd.json from an **emptyDir**, which an init
# container seeds from the `flagd-config` ConfigMap **only at pod startup**.
# Patching the ConfigMap therefore changes nothing until flagd restarts, which is
# the single most common reason a scenario "does not work".
#
# The `flagd-ui` sidecar mounts that same emptyDir, so this script writes the new
# file through the sidecar (atomic rename, so flagd never reads a half-written
# file) and flagd's fsnotify watcher hot-reloads within a second or two.
#
# It ALSO patches the ConfigMap, so the change survives a pod restart. Both are
# needed: the live write for "now", the ConfigMap for "after the next restart".
#
# ---------------------------------------------------------------------------
# WHEN A SCENARIO SEEMS TO DO NOTHING, USE --check FIRST
# ---------------------------------------------------------------------------
# `--check` queries flagd's OFREP endpoint directly, so you can tell three very
# different situations apart:
#
#   * flagd serves the wrong value      -> the write did not land; re-run
#   * flagd serves the right value but
#     the app behaves normally          -> the SERVICE is not reading it. Usually a
#                                          type mismatch between the flag and the
#                                          client (a service built against an older
#                                          demo version calling GetBooleanValue on a
#                                          flag whose variants are now numbers will
#                                          silently receive the default), or a flagd
#                                          provider version that returns defaults
#                                          without logging an error.
#   * flagd serves the right value and
#     the app misbehaves                -> the scenario is working; if NudgeBee shows
#                                          nothing, THAT is the real finding.
#
# Never conclude "NudgeBee missed it" without ruling out the middle case.
#
set -euo pipefail

NS="${DEMO_NAMESPACE:-demo}"
CM="flagd-config"
KEY="demo.flagd.json"
LIVE_PATH="/app/data/demo.flagd.json"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '4,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'; }

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

command -v kubectl >/dev/null || die "kubectl not found"
command -v python3 >/dev/null || die "python3 not found"

flagd_pod() {
  local p
  p="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=flagd \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
  [ -n "$p" ] || die "no running flagd pod in namespace '$NS'"
  echo "$p"
}

# Read the file flagd is ACTUALLY using (the emptyDir copy), not the ConfigMap.
# They can differ, and when they do the emptyDir is what matters.
live_json() {
  kubectl -n "$NS" exec "$(flagd_pod)" -c flagd-ui -- cat "$LIVE_PATH"
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;

  --list)
    live_json | python3 -c '
import json,sys
for k,v in sorted(json.load(sys.stdin)["flags"].items()):
    print("%-30s %s" % (k, list(v.get("variants",{}).keys())))
'
    exit 0 ;;

  --status)
    live_json | python3 -c '
import json,sys
flags=json.load(sys.stdin)["flags"]
on=[]
for k,v in sorted(flags.items()):
    cur=v.get("defaultVariant")
    mark="  ON " if cur not in ("off",) else "     "
    print("%s%-30s -> %s" % (mark,k,cur))
    if cur not in ("off",): on.append(k)
print()
print("active:", ", ".join(on) if on else "(none)")
print("note: loadGeneratorTraffic / loadGeneratorVUs are normal traffic controls, not faults.")
'
    exit 0 ;;

  --check)
    FLAG="${2:-}"; [ -n "$FLAG" ] || die "--check needs a flag name"
    POD="$(flagd_pod)"
    # OFREP (8016) is what flagd is serving right now, which is the only thing that
    # actually matters -- the file on disk is just an input to it.
    LP=18016
    kubectl -n "$NS" port-forward "pod/$POD" ${LP}:8016 >/dev/null 2>&1 &
    PF=$!
    trap 'kill $PF 2>/dev/null || true' EXIT
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      if curl -sf -o /dev/null "http://localhost:${LP}/ofrep/v1/evaluate/flags/${FLAG}" \
           -X POST -H 'Content-Type: application/json' -d '{}' 2>/dev/null; then break; fi
    done
    echo "flagd is serving:"
    RESP="$(curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
      "http://localhost:${LP}/ofrep/v1/evaluate/flags/${FLAG}")" \
      || die "could not evaluate '$FLAG' (is the flag name right?)"
    printf '%s' "$RESP" | python3 -m json.tool 2>/dev/null || die "could not evaluate '$FLAG'"
    echo
    # A TARGETING_MATCH reason means the answer above came from a targeting rule
    # evaluated against an EMPTY context, not from defaultVariant -- so it says
    # little about what the app sees, and the flag may be untoggleable outright.
    # productCatalogFailure ships from upstream with
    #   {"if": [{"==": [{"var":"product_id"},"OLJCESPC7Z"]}, "off", "off"]}
    # where BOTH branches return "off", so it can never evaluate to on no matter
    # what you set defaultVariant to. Without this check that presents as "the
    # flag is on and nothing happened", which is indistinguishable from a
    # monitoring gap.
    if printf '%s' "$RESP" | grep -q '"reason":"TARGETING_MATCH"'; then
      echo "NOTE: this flag has TARGETING rules, so the value above was resolved"
      echo "      against an empty context and is not necessarily what the app"
      echo "      sees. Check the rule before trusting it:"
      echo "        $0 --targeting ${FLAG}"
    fi
    echo "If 'value' looks right but the demo behaves normally, the SERVICE is not"
    echo "reading it -- see the notes at the top of this script. Do not assume the"
    echo "monitoring missed something until you have ruled that out."
    exit 0 ;;

  --targeting)
    FLAG="${2:-}"; [ -n "$FLAG" ] || die "--targeting needs a flag name"
    live_json | FLAG="$FLAG" python3 -c '
import json,os,sys
flag=os.environ["FLAG"]
f=json.load(sys.stdin)["flags"].get(flag)
if f is None: sys.exit("unknown flag: %s" % flag)
print("defaultVariant:", f.get("defaultVariant"))
print("variants      :", f.get("variants"))
t=f.get("targeting")
if not t:
    print("targeting     : none -- defaultVariant is what gets served")
    raise SystemExit
print("targeting     :", json.dumps(t))
variants=set(f.get("variants",{}))
outs=set()
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=="if":
                for br in v:
                    if isinstance(br,str): outs.add(br)
                    else: walk(br)
            else: walk(v)
    elif isinstance(o,list):
        for i in o: walk(i)
walk(t)
reach=sorted(outs & variants)
print("reachable     :", reach)
if reach and set(reach) <= {"off"}:
    print()
    print("DEGENERATE: every branch of this rule returns off, so the flag can")
    print("never be enabled. Setting defaultVariant does nothing -- targeting wins.")
'
    exit 0 ;;

  --reset) FLAG="__RESET__"; VARIANT="off" ;;
  *)       FLAG="$1"; VARIANT="${2:-on}" ;;
esac

CURRENT="$(live_json)"
[ -n "$CURRENT" ] || die "could not read $LIVE_PATH from the flagd-ui sidecar"

NEW_JSON="$(printf '%s' "$CURRENT" | FLAG="$FLAG" VARIANT="$VARIANT" python3 -c '
import json,os,sys
doc=json.load(sys.stdin); flags=doc["flags"]
flag=os.environ["FLAG"]; variant=os.environ["VARIANT"]
# Traffic controls are not faults; --reset must not switch the load generator off,
# or the demo goes quiet and every later scenario looks like it "did nothing".
TRAFFIC={"loadGeneratorTraffic","loadGeneratorVUs"}
if flag=="__RESET__":
    for k,v in flags.items():
        if k in TRAFFIC: continue
        if "off" in v.get("variants",{}): v["defaultVariant"]="off"
else:
    if flag not in flags:
        sys.exit("unknown flag: %s (try --list)" % flag)
    if variant not in flags[flag]["variants"]:
        sys.exit("flag %s has no variant %r; valid: %s" % (flag,variant,list(flags[flag]["variants"])))
    flags[flag]["defaultVariant"]=variant
print(json.dumps(doc,indent=2))
')"

POD="$(flagd_pod)"

# 1) Live write via the shared emptyDir -> effective within ~1s.
printf '%s' "$NEW_JSON" | kubectl -n "$NS" exec -i "$POD" -c flagd-ui -- \
  sh -c "cat > /app/data/.scenario.tmp && mv /app/data/.scenario.tmp $LIVE_PATH"

# 2) Persist to the ConfigMap so a pod restart does not silently revert it.
PATCH="$(FLAG_JSON="$NEW_JSON" python3 -c '
import json,os
print(json.dumps({"data":{"demo.flagd.json":os.environ["FLAG_JSON"]}}))
')"
if kubectl -n "$NS" patch cm "$CM" --type merge -p "$PATCH" >/dev/null 2>&1; then
  PERSIST="ConfigMap $CM updated (survives pod restart)"
else
  PERSIST="WARNING: could not patch ConfigMap $CM -- change is live but will revert on restart"
fi

if [ "$FLAG" = "__RESET__" ]; then
  echo "All fault flags reset to off in namespace '$NS'."
else
  echo "Set $FLAG -> $VARIANT in namespace '$NS'."
fi
echo "$PERSIST"
echo
echo "Confirm flagd is really serving it:  $0 --check ${FLAG#__RESET__}"
