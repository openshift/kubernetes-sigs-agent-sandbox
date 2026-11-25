FROM scratch

# Core bundle labels.
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=agent-sandbox-operator
LABEL operators.operatorframework.io.bundle.channels.v1=stable
LABEL operators.operatorframework.io.metrics.builder=operator-sdk-v1.42.2
LABEL operators.operatorframework.io.metrics.mediatype.v1=metrics+v1
LABEL operators.operatorframework.io.metrics.project_layout=go.kubebuilder.io/v4

# Labels for testing.
LABEL operators.operatorframework.io.test.mediatype.v1=scorecard+v1
LABEL operators.operatorframework.io.test.config.v1=tests/scorecard/

# Red Hat container labels. The release pipeline rejects any component whose
# image omits them, and `name` has to match the repository the bundle
# publishes to.
LABEL name="agent-sandbox/agent-sandbox-operator-bundle"
LABEL com.redhat.component="agent-sandbox-operator-bundle-container"
LABEL io.k8s.display-name="Agent Sandbox operator bundle"
LABEL io.k8s.description="OLM bundle for the Agent Sandbox operator"
LABEL description="OLM bundle for the Agent Sandbox operator"
LABEL summary="OLM bundle for the Agent Sandbox operator"
LABEL maintainer="Red Hat"
LABEL version="1.0.9"
LABEL release="1"
LABEL vendor="Red Hat, Inc."
LABEL url="https://access.redhat.com/"
LABEL distribution-scope=public
LABEL io.openshift.tags=""
LABEL cpe="cpe:/a:redhat:confidential_compute_attestation:1.140::el9"

# Copy files to locations specified by labels.
COPY bundle/manifests /manifests/
COPY bundle/metadata /metadata/
COPY bundle/tests/scorecard /tests/scorecard/
