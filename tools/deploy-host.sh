#!/usr/bin/env bash
# Put a host binary on the station, and prove it came back.
#
# ⚠️ THIS REPLACES `cp` AND A GROWING PILE OF .bak FILES. /opt/hamdeck-go/bin
# accumulated TEN stacked backups in one night - 0.4.0 through 0.7.3 - with no
# deploy command, no rollback command, and no check after the restart beyond a
# human reading the journal. That is the whole procedure this file replaces.
#
# ⚠️ AND IT ROLLS BACK BY ITSELF. A host that does not come up is not something
# to discover the next time somebody wants to use the radio; the previous binary
# goes straight back and the script says so. The station is the point, not the
# deploy.
#
#   tools/deploy-host.sh                 build from HEAD and deploy
#   tools/deploy-host.sh --rollback      put the previous binary back
set -uo pipefail
cd "$(dirname "$0")/.."

RIG_HOST="${HAMDECK_RIG_HOST:-192.168.40.64}"
BIN=/opt/hamdeck-go/bin/hamdeck-host
PREV=/opt/hamdeck-go/bin/hamdeck-host.previous
SSH="ssh -o ConnectTimeout=10 $RIG_HOST"

say() { printf '  %s\n' "$1"; }

# health <what> - is the host answering, and with which version?
health() {
    curl -fsS -m 6 "http://$RIG_HOST:5102/api/health" 2>/dev/null
}

if [ "${1:-}" = "--rollback" ]; then
    $SSH "test -f $PREV" || { echo "there is no previous binary to go back to" >&2; exit 1; }
    $SSH "cp $PREV $BIN && sudo systemctl restart hamdeck-go" || exit 1
    sleep 5
    if h=$(health); then
        say "rolled back. now: $(echo "$h" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["version"], "| rig:", d["rig"], "| connected:", d["rig_connected"])')"
        exit 0
    fi
    echo "ROLLED BACK AND IT IS STILL NOT ANSWERING - the problem is not the binary" >&2
    exit 1
fi

# ⚠️ THE VERSION COMES FROM THE TAG, and a dirty tree is refused. A host that
# reports a version you cannot check out is a host nobody can reason about when
# something goes wrong at 3am.
if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty - commit before deploying to the station" >&2
    exit 1
fi
VER=$(git describe --tags --exact-match 2>/dev/null || git describe --tags 2>/dev/null || echo "0.0.0-untagged")
say "building $VER"
go build -ldflags "-X main.version=${VER#v}" -o /tmp/hamdeck-host.deploy ./cmd/hamdeck-host || exit 1

BEFORE=$(health | python3 -c 'import sys,json; print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "not answering")
say "station is on $BEFORE"

# ⚠️ Keep exactly ONE previous binary, always overwritten. Ten dated backups is
# not a rollback plan, it is a pile - nobody knows which one was good.
$SSH "test -f $BIN && cp $BIN $PREV" 2>/dev/null
scp -q -o ConnectTimeout=10 /tmp/hamdeck-host.deploy "$RIG_HOST:/tmp/hamdeck-host.new" || exit 1
$SSH "install -m 755 /tmp/hamdeck-host.new $BIN && sudo systemctl restart hamdeck-go" || exit 1

# ⚠️ THE GATE. Not "did systemctl return 0" - whether the host ANSWERS, whether
# it is the version just built, and whether it found the radio. A host that comes
# up with no rig is a failed deploy even though the process is running.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    h=$(health) && break
done
if [ -z "${h:-}" ]; then
    say "it did not answer after the restart - rolling back"
    exec "$0" --rollback
fi

python3 - "$h" "${VER#v}" <<'PY' || { echo "  rolling back"; exec "$0" --rollback; }
import json, sys
d = json.loads(sys.argv[1]); want = sys.argv[2]
print(f"  now: {d['version']} | rig: {d['rig']} | connected: {d['rig_connected']}")
bad = []
if d["version"] != want and want != "0.0.0-untagged":
    bad.append(f"it reports {d['version']}, not the {want} just built")
if not d.get("rig_connected"):
    bad.append("it came up WITHOUT the radio")
for b in bad:
    print("  FAILED:", b)
sys.exit(1 if bad else 0)
PY
say "deployed. previous binary kept at $PREV - tools/deploy-host.sh --rollback"
