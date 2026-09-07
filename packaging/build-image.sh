#!/usr/bin/env bash
# Build the container image and REFUSE if the binary inside it does not answer
# with the version the tag claims - the same gate packaging/build-deb.sh runs.
# The filename is not evidence; the binary is.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-$(git -C "$ROOT" describe --tags)}"
docker build -f "$ROOT/packaging/Dockerfile" --build-arg "VERSION=$VER" \
    -t "hamdeck-go:$VER" -t hamdeck-go:latest "$ROOT"
got="$(docker run --rm --entrypoint /opt/hamdeck-go/bin/hamdeck-host \
    "hamdeck-go:$VER" --version | awk '{print $NF}')"
if [ "$got" != "$VER" ]; then
    echo "REFUSING: image tagged $VER contains a binary that reports $got."
    docker rmi "hamdeck-go:$VER" hamdeck-go:latest >/dev/null 2>&1 || true
    exit 1
fi
echo "OK: hamdeck-go:$VER - binary asserts $got"
