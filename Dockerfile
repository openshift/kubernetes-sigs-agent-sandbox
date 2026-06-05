# Build go binaries
# See https://github.com/golang/go/issues/69255#issuecomment-2523276831
FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/go-toolset:1.26.3-1780434037 AS builder

# Declare TARGETARCH to make it available in this build stage
ARG TARGETARCH

# Version info injected via build args (e.g. docker build --buildarg GIT_VERSION=...)
ARG GIT_VERSION=unknown
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

USER root
WORKDIR /workspace

# Download dependencies first to leverage layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy the code source needed
COPY api/ ./api/
COPY cmd/ ./cmd/
COPY controllers/ ./controllers/
COPY extensions/ ./extensions/
COPY internal/ ./internal/

# Build the binary with optimizations
RUN CGO_ENABLED=1 GOOS=linux GOARCH=${TARGETARCH} go build \
    -ldflags="-s -w -X sigs.k8s.io/agent-sandbox/internal/version.gitVersion=${GIT_VERSION} -X sigs.k8s.io/agent-sandbox/internal/version.gitSHA=${GIT_SHA} -X sigs.k8s.io/agent-sandbox/internal/version.buildDate=${BUILD_DATE}" \
    -o /workspace/agent-sandbox-controller ./cmd/agent-sandbox-controller


# The controller image
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.7-1778072020

COPY --from=builder /workspace/agent-sandbox-controller /agent-sandbox-controller

ENTRYPOINT ["/agent-sandbox-controller"]
