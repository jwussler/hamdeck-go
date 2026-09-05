#!/usr/bin/env bash
# Everything that must pass BEFORE a binary or an installer is built.
#
# ⚠️ THIS EXISTS BECAUSE BASIC FUNCTIONS WERE FOUND BROKEN AFTER SHIPPING. Joe,
# 09/05/2026: "really we should go thru and audit the code and then test it
# before we build the binarys. finding this stuff after we built a few
# binarys/installers on basic needed funtions sucks really." He was right: the
# global PTT key crashed the app on selection, and three installers had already
# been cut and handed over.
#
# ⚠️ EVERY CHECK HERE RUNS HEADLESS, ON THIS MACHINE, AGAINST A SIMULATED RIG.
# Nothing in it needs Windows, a radio, or the operator. If a check cannot be
# made to run here, it does not belong in the release path - it belongs in the
# list of things only he can test, and that list is short on purpose.
#
#   tools/preflight.sh          run everything
#   tools/preflight.sh quick    skip the browser checks (they take ~2 minutes)
set -uo pipefail
cd "$(dirname "$0")/.."

QUICK="${1:-}"
FAILED=()
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
check() {
    local name="$1"; shift
    if "$@" >/tmp/preflight.$$ 2>&1; then
        printf '  ok    %s\n' "$name"
    else
        printf '  FAIL  %s\n' "$name"
        sed 's/^/        /' /tmp/preflight.$$ | tail -15
        FAILED+=("$name")
    fi
    rm -f /tmp/preflight.$$
}

export PATH="$HOME/flutter-sdk/bin:/usr/local/go/bin:$PATH"

step "the host"
check "gofmt leaves nothing to say" bash -c '[ -z "$(gofmt -l internal cmd)" ]'
check "go vet" go vet ./cmd/hamdeck-host/... ./internal/...
check "go test" go test ./cmd/hamdeck-host/... ./internal/...
check "the host builds" go build ./cmd/hamdeck-host

step "the panel"
check "flutter analyze" bash -c 'cd client && flutter analyze lib test'
# ⚠️ The key-mapping test is here because a chooser that offers a key which
# throws inside the hotkey plugin takes the whole app down - which is what
# happened, and it was findable on this machine.
check "flutter test" bash -c 'cd client && flutter test'
# ⚠️ THE WEB BUILD IS A COMPILE-TIME CHECK OF THE PLATFORM SPLIT. dart:ffi does
# not exist there, so an unconditional import fails HERE rather than silently
# shipping a panel the browser cannot load.
check "the web panel compiles" bash -c 'cd client && flutter build web --release'
check "the linux panel compiles" bash -c 'cd client && flutter build linux --release'

if [ "$QUICK" != "quick" ]; then
    step "does it actually work"
    # ⚠️ Screenshots prove it DRAWS; this proves the controls reach the radio.
    check "every control reaches the rig" python3 tools/panel_e2e.py
    check "the panel renders in every state" python3 tools/shoot_panel.py /tmp/preflight-shots

    step "the boundaries"
    # A throwaway host on a spare port, so these need no station.
    STORE=$(mktemp -u --suffix=-users.json)
    echo 'preflight-only' | ./hamdeck-host --users "$STORE" users set preflight >/dev/null 2>&1
    ./hamdeck-host --users "$STORE" --port 5919 --control-port 5918 --radio "" >/dev/null 2>&1 &
    HOSTPID=$!
    sleep 2
    check "nothing answers without a session" \
        env HAMDECK_PASSWORD=preflight-only python3 tools/check_auth.py http://127.0.0.1:5919 preflight
    check "every C++ route has a Go route" \
        env HAMDECK_PASSWORD=preflight-only python3 tools/parity.py http://127.0.0.1:5919 preflight --allow-control
    kill $HOSTPID 2>/dev/null
    rm -f "$STORE"
fi

printf '\n'
if [ ${#FAILED[@]} -eq 0 ]; then
    printf '\033[32mPREFLIGHT PASSED\033[0m — safe to build and tag.\n'
    exit 0
fi
printf '\033[31mPREFLIGHT FAILED\033[0m (%d): %s\n' "${#FAILED[@]}" "${FAILED[*]}"
printf 'Do not cut a binary until these pass.\n'
exit 1
