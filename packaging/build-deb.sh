#!/usr/bin/env bash
# Build the two Debian packages: the station host, and the desktop panel.
#
# ⚠️ TWO PACKAGES, NOT ONE, AND THE NAMES SAY WHICH IS WHICH. The C++ project
# learned this the expensive way: installers called hamdeck-win.exe were being
# downloaded by an operator who wanted the CLIENT and got the host. The name is
# the deliverable - somebody chooses from a list of filenames, not from a
# paragraph explaining them.
set -euo pipefail
VER="${1:?usage: build-deb.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
mkdir -p "$OUT"

# ── the host ────────────────────────────────────────────────────────────────
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/hamdeck-go/bin" "$STAGE/lib/systemd/system"
# ⚠️ ONE VERSION LINE, ASSERTED INSIDE THE ARTIFACT. A .deb whose filename says
# 0.2.0 and whose binary answers "0.0.0-untagged" is the version confusion this
# project has already paid for once - the C++ host reported 0.1.0 while its
# clients shipped 0.1.33, and the version is the first thing anybody asks for
# when something is wrong. The filename is not evidence; the binary is.
got="$("$ROOT/hamdeck-host" --version | awk '{print $NF}')"
if [ "$got" != "$VER" ]; then
    echo "REFUSING: the host binary reports $got but this package would be called $VER."
    echo "Build it with:  go build -ldflags \"-X main.version=$VER\" -o hamdeck-host ./cmd/hamdeck-host"
    exit 1
fi
cp "$ROOT/hamdeck-host" "$STAGE/opt/hamdeck-go/bin/hamdeck-host"
chmod 755 "$STAGE/opt/hamdeck-go/bin/hamdeck-host"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: hamdeck-go-host
Version: $VER
Section: comm
Priority: optional
Architecture: amd64
Maintainer: WA0O <hamdeck@wa0o.com>
Description: HamDeck station host (Go)
 CAT control, receive and transmit audio, PTT with a transmit watchdog,
 antenna tuner and recording for a remote amateur radio station.
EOF
cp "$ROOT/packaging/hamdeck-go.service" "$STAGE/lib/systemd/system/hamdeck-go.service"
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# ⚠️ ENABLED BUT NOT STARTED. There is no account yet and no radio named, so
# starting here would produce a service that fails on first boot and an operator
# who thinks the package is broken. The message says what to do next - and it is
# the SAME command used to recover a forgotten password later, which is the point
# of there being only one.
systemctl daemon-reload || true
mkdir -p /etc/hamdeck-go
if [ ! -f /etc/hamdeck-go/users.json ]; then
    echo "HamDeck: create the first account with:"
    echo "  sudo /opt/hamdeck-go/bin/hamdeck-host users set <username>"
    echo "It is prompted for a password, becomes the administrator, and may transmit."
    echo "The same command resets a forgotten password later - the running host"
    echo "picks it up within seconds, with no restart."
    echo
    echo "Then name your radio in /lib/systemd/system/hamdeck-go.service and run:"
    echo "  sudo systemctl enable --now hamdeck-go"
fi
EOF
chmod 755 "$STAGE/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$STAGE" "$OUT/hamdeck-go-host_${VER}_amd64.deb" >/dev/null
rm -rf "$STAGE"

# ── the panel ───────────────────────────────────────────────────────────────
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/hamdeck-panel" "$STAGE/usr/share/applications" "$STAGE/usr/bin"
cp -r "$ROOT/client/build/linux/x64/release/bundle/." "$STAGE/opt/hamdeck-panel/"
ln -s /opt/hamdeck-panel/hamdeck_panel "$STAGE/usr/bin/hamdeck-panel"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: hamdeck-panel
Version: $VER
Section: comm
Priority: optional
Architecture: amd64
Maintainer: WA0O <hamdeck@wa0o.com>
Depends: libgtk-3-0, libasound2t64 | libasound2, pulseaudio-utils
Description: HamDeck desktop panel
 Desktop client for a HamDeck station host: frequency, mode, band, the antenna
 tuner, receive audio and push to talk.
EOF
cat > "$STAGE/usr/share/applications/hamdeck-panel.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=HamDeck Panel
Comment=Remote control for an amateur radio station
Exec=/opt/hamdeck-panel/hamdeck_panel
Icon=hamdeck-panel
Terminal=false
Categories=HamRadio;Network;
EOF
dpkg-deb --build --root-owner-group "$STAGE" "$OUT/hamdeck-panel_${VER}_amd64.deb" >/dev/null
rm -rf "$STAGE"

ls -lh "$OUT"/*.deb
