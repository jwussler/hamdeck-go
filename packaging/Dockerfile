# HamDeck station host, containerised.
#
# ⚠️ WHAT A CONTAINER DOES NOT SOLVE, so nobody reaches for it expecting this:
# the host kernel supplies cp210x (CAT) and snd-usb-audio (the codec). A
# container shares that kernel. The 09/06/2026 outage - modules-extra missing
# for a new kernel, 23 h off the air - happens identically to this image on any
# box whose kernel lacks those modules. The image is portable; the DRIVERS are
# a property of whatever machine runs it.
#
# ⚠️ --device binds a device NODE at container create. If the radio is replugged
# and comes back as a different ttyUSB minor, this container keeps a dead
# handle and cannot rescan. See packaging/docker-compose.yml.

FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
# ONE VERSION LINE, TAKEN FROM THE TAG, ASSERTED INSIDE THE ARTIFACT - the same
# rule packaging/build-deb.sh enforces. An image whose tag says one thing and
# whose binary answers "0.0.0-untagged" is the confusion this project already
# paid for once.
ARG VERSION=0.0.0-untagged
# CGO off: github.com/yobert/alsa is pure Go, so the host needs no ALSA
# libraries - only the /dev/snd nodes.
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" \
        -o /out/hamdeck-host ./cmd/hamdeck-host

FROM debian:bookworm-slim
# alsa-utils is not needed to run - it is here so `docker exec ... arecord -l`
# can tell "the codec is missing" from "the host cannot open it", which is the
# exact distinction that took 23 hours to spot on 09/06.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates alsa-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/hamdeck-host /opt/hamdeck-go/bin/hamdeck-host
COPY client/build/web /opt/hamdeck-go/panel
ARG VERSION=0.0.0-untagged
LABEL org.opencontainers.image.version="${VERSION}"
ENTRYPOINT ["/opt/hamdeck-go/bin/hamdeck-host"]
