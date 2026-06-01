FROM brew.registry.redhat.io/rh-osbs/openshift-ose-operator-registry-rhel9:v4.22 as builder

ADD catalog/ /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

FROM brew.registry.redhat.io/rh-osbs/openshift-ose-operator-registry-rhel9:v4.22

ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

COPY --from=builder /configs /configs
COPY --from=builder /tmp/cache /tmp/cache

LABEL operators.operatorframework.io.index.configs.v1=/configs
