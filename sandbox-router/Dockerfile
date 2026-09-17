# Build the sandbox-router binary as a static distroless image. Build context
# MUST be the repo root because the binary imports internal/ from the shared
# Go module — dev/tools/push-images is patched to pass `--context .` for
# this Dockerfile.
FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/go-toolset:1.26.7-1791479310 AS builder

LABEL name="agent-sandbox/agent-sandbox-router"
LABEL com.redhat.component="agent-sandbox-router-container"
LABEL io.k8s.display-name="Agent Sandbox router"
LABEL io.k8s.description="Request router for agent sandbox workloads"
LABEL description="Request router for agent sandbox workloads"
LABEL summary="Request router for agent sandbox workloads"
LABEL maintainer="Red Hat"
LABEL version="0.9.0"
LABEL release="1"
LABEL vendor="Red Hat, Inc."
LABEL url="https://access.redhat.com/"
LABEL distribution-scope=public
LABEL io.openshift.tags=""
LABEL cpe="cpe:/a:redhat:confidential_compute_attestation:1.130::el9"

# Declare TARGETARCH to make it available in this build stage.
ARG TARGETARCH

# Version info injected via build args (e.g. docker build --build-arg GIT_VERSION=...).
ARG GIT_VERSION=unknown
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

WORKDIR /workspace

# Download dependencies first to leverage layer caching.
COPY go.mod go.sum ./
RUN go mod download

# Copy the code the binary needs. Top-level sandbox-router/ for the
# router itself, internal/ for version stamping and OTel setup, and
# api/ + extensions/api/ because internal/metrics references the CRD
# types for sandbox-resource-shaped span attributes.
COPY sandbox-router/ ./sandbox-router/
COPY api/ ./api/
COPY extensions/api/ ./extensions/api/
COPY internal/ ./internal/

# Build the binary with size and version-info optimizations.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
    -ldflags="-s -w \
        -X sigs.k8s.io/agent-sandbox/internal/version.gitVersion=${GIT_VERSION} \
        -X sigs.k8s.io/agent-sandbox/internal/version.gitSHA=${GIT_SHA} \
        -X sigs.k8s.io/agent-sandbox/internal/version.buildDate=${BUILD_DATE}" \
    -o /tmp/sandbox-router ./sandbox-router/cmd

# Final image: distroless static so we ship only the binary plus minimal runtime.
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /tmp/sandbox-router /sandbox-router

# Document the default ports the binary listens on. Operators can override
# via --http-bind-address / --https-bind-address / --metrics-bind-address /
# --health-probe-bind-address.
EXPOSE 8080 8443 9090 8081

ENTRYPOINT ["/sandbox-router"]
