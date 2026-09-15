ARG BASE_REGISTRY
ARG BASE_REPO
ARG BASE_TAG

FROM ${BASE_REGISTRY}/${BASE_REPO}:${BASE_TAG}

# Install additional packages needed for kernel building.
# libtraceevent-devel is required to build perf (tools/perf).
RUN dnf reinstall -y flex \
    && dnf install -y libtraceevent-devel \
    && dnf clean all

WORKDIR /root
