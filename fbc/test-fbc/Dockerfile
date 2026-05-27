FROM brew.registry.redhat.io/rh-osbs/openshift-ose-operator-registry-rhel9:v4.19 as builder
USER root

RUN dnf install -y go && go install github.com/mikefarah/yq/v4@v4.35.1

WORKDIR /workdir
ADD render.sh icon.png ./
COPY test-fbc ./test-fbc

RUN mkdir -p test-fbc/catalog/agent-sandbox-operator && PATH=/root/go/bin:$PATH ./render.sh test-fbc

RUN cp -r test-fbc/catalog/ /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

FROM brew.registry.redhat.io/rh-osbs/openshift-ose-operator-registry-rhel9:v4.19

ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

COPY --from=builder /configs /configs
COPY --from=builder /tmp/cache /tmp/cache

LABEL operators.operatorframework.io.index.configs.v1=/configs
