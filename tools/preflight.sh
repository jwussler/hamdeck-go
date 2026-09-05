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
# ⚠️ BEFORE THE COMPILERS, because it is cheap and because it is the check that
# would have stopped three installers shipping with Flutter's logo on them.
check "the app carries the HamDeck mark" python3 tools/check_branding.py

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
# ⚠️ The bundle the SCREENSHOT and E2E tools drive. It carries the operating
# surface, is built only here, and is never served - see main() and
# tools/check_web_is_admin_only.py.
check "the operating surface builds for the test tools" \
    bash -c 'cd client && flutter build web --release --dart-define=HAMDECK_SHOOT=true -o build/web-shoot'
# ⚠️ AFTER the build, because it inspects the artifact, not the source.
check "the browser gets admin only, no operating" python3 tools/check_web_is_admin_only.py
check "the linux panel compiles" bash -c 'cd client && flutter build linux --release'

if [ "$QUICK" != "quick" ]; then
    step "does it actually work"
    # ⚠️ Screenshots prove it DRAWS; this proves the controls reach the radio.
    check "every control reaches the rig" python3 tools/panel_e2e.py
    check "the panel renders in every state" python3 tools/shoot_panel.py /tmp/preflight-shots

    step "the boundaries"
    # A throwaway host on a spare port, so these need no station.
    #
    # ⚠️ THE PORT IS CHOSEN, NOT ASSUMED, AND THE HOST IS PROVEN TO BE OURS.
    # This was pinned to 5919, which tools/win_drive.sh also uses for its
    # simulator's control port. Run the two together and this host silently
    # failed to bind, both checks then authenticated against the OTHER host, and
    # preflight reported "nothing answers without a session: HTTP 401" - a
    # security check failing loudly for a reason that had nothing to do with
    # security. Twice. A port that might be taken is not a spare port.
    PFPORT=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    STORE=$(mktemp -u --suffix=-users.json)
    echo 'preflight-only' | ./hamdeck-host --users "$STORE" users set preflight >/dev/null 2>&1
    ./hamdeck-host --users "$STORE" --port "$PFPORT" --control-port $((PFPORT-1)) --radio "" >/dev/null 2>&1 &
    HOSTPID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        curl -fsS "http://127.0.0.1:$PFPORT/api/health" >/dev/null 2>&1 && break
    done
    # ⚠️ And it must be the host we just started - not something else that
    # happened to answer on that port. A stranger answering is the failure above.
    check "the throwaway host is ours, not whatever answered" \
        bash -c "kill -0 $HOSTPID 2>/dev/null && curl -fsS http://127.0.0.1:$PFPORT/api/health >/dev/null"
    check "nothing answers without a session" \
        env HAMDECK_PASSWORD=preflight-only python3 tools/check_auth.py http://127.0.0.1:$PFPORT preflight
    check "every C++ route has a Go route" \
        env HAMDECK_PASSWORD=preflight-only python3 tools/parity.py http://127.0.0.1:$PFPORT preflight --allow-control
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
