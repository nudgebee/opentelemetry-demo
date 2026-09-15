# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Build stage: compile a custom k6 binary that includes the OTel extension.
# k6 v2 requires Go 1.25; xk6 is the official k6 extension build tool.
FROM docker.io/library/golang:1.27.1-bookworm@sha256:648f440f42a0958804efb24df176f806f9d353b41f1c0627f666428e40310f6b AS builder

# xk6 is the build tool, not part of the runtime image; pin to a known-good
# release independent of the k6 version being built below.
RUN go install go.k6.io/xk6/cmd/xk6@v1.4.7

WORKDIR /build

# Copy the extension source before running xk6 so it can be provided as a
# local module via the --with flag rather than fetched from a remote registry.
COPY ./src/load-generator/xk6-otel ./xk6-otel

RUN xk6 build v2.1.0 \
    --with github.com/open-telemetry/opentelemetry-demo/src/load-generator/xk6-otel=./xk6-otel \
    --output ./k6

# Runtime on Grafana's k6 browser image for a working headless Chromium
# (Debian's Chromium crashes on startup). Its stock k6 lacks the xk6-otel
# extension script.js needs, so overwrite it with the build from above.
FROM docker.io/grafana/k6:2.2.0-with-browser@sha256:defdc0a3e70c46bce010bfc10dedc03e335cc7febe01f6359552fe72827c2aa2

COPY --from=builder /build/k6 /usr/bin/k6

WORKDIR /home/k6
COPY ./src/load-generator/script.js .
COPY ./src/load-generator/people.json .
COPY --chmod=755 ./src/load-generator/entrypoint.sh .

# entrypoint.sh wraps k6 to support flagd-driven VU restarts
ENTRYPOINT ["./entrypoint.sh"]
