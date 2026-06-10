FROM scratch

# Core bundle labels.
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=agent-sandbox-operator
LABEL operators.operatorframework.io.bundle.channels.v1=alpha
LABEL operators.operatorframework.io.metrics.builder=operator-sdk-v1.42.2
LABEL operators.operatorframework.io.metrics.mediatype.v1=metrics+v1
LABEL operators.operatorframework.io.metrics.project_layout=go.kubebuilder.io/v4

# Labels for testing.
LABEL operators.operatorframework.io.test.mediatype.v1=scorecard+v1
LABEL operators.operatorframework.io.test.config.v1=tests/scorecard/

# Required Red Hat container labels.
LABEL name="agent-sandbox/agent-sandbox-operator-bundle"
LABEL com.redhat.component="agent-sandbox-operator-bundle-container"
LABEL io.k8s.display-name="Agent Sandbox operator"
LABEL io.k8s.description="This operator manages agent sandbox workloads"
LABEL description="This operator manages agent sandbox workloads"
LABEL summary="This operator manages agent sandbox workloads"
LABEL maintainer="Red Hat"
LABEL version="0.9"
LABEL release="1"
LABEL vendor="Red Hat, Inc."
LABEL url="https://access.redhat.com/"
LABEL distribution-scope=public
LABEL com.redhat.delivery.operator.bundle=true
LABEL io.openshift.maintainer.product="OpenShift Container Platform"
LABEL io.openshift.maintainer.component="Agent Sandbox"
LABEL cpe="cpe:/a:redhat:confidential_compute_attestation:1.130::el9"

# Copy files to locations specified by labels.
COPY bundle/manifests /manifests/
COPY bundle/metadata /metadata/
COPY bundle/tests/scorecard /tests/scorecard/
