FROM registry.redhat.io/openshift4/ose-operator-registry-rhel9:v5.0 as builder

ADD catalog/ /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

FROM registry.redhat.io/openshift4/ose-operator-registry-rhel9:v5.0

ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

COPY --from=builder /configs /configs
COPY --from=builder /tmp/cache /tmp/cache

LABEL operators.operatorframework.io.index.configs.v1=/configs
