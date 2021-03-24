FROM ubuntu:20.04

# dependencies for the script
RUN apt-get update && \
    apt-get install -y build-essential libncurses5-dev gcc libssl-dev bc bison \
                       libelf-dev flex git curl tar hashalot ccache rsync && \
    apt-get clean

# Sparse
ARG SPARSE_URL="https://mirrors.edge.kernel.org/pub/software/devel/sparse/dist/sparse-0.6.3.tar.xz"
ARG SPARSE_TARBALL="sparse.tar.xz"
ARG SPARSE_SHA="d4f6dbad8409e8e20a19f164b2c16f1edf76438ff77cf291935fde081b61a899  ${SPARSE_TARBALL}"

RUN cd /tmp && \
    curl -L "${SPARSE_URL}" -o "${SPARSE_TARBALL}" && \
    echo "${SPARSE_SHA}" | sha256sum --check && \
    tar xJf "${SPARSE_TARBALL}" && \
    cd "sparse-"* && \
        make && \
        make PREFIX=/usr install && \
        cd .. && \
    rm -rf "${SPARSE_TARBALL}" "sparse-"*

# CCache for quicker builds but still with default colours
ENV PATH "/usr/lib/ccache:${PATH}"
ENV CCACHE_COMPRESS "true"
ENV GCC_COLORS "error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"
# The home dir of the host is not the same as the one of the docker environment
ENV CCACHE_DIR "/github/workspace/.ccache"
# Remove the timestamp to improve CCache hit
ENV KBUILD_BUILD_TIMESTAMP "0"

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
