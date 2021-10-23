FROM ubuntu:20.04

# dependencies for the script
RUN apt-get update && \
    apt-get install -y build-essential libncurses5-dev gcc libssl-dev bc bison \
                       libelf-dev flex git curl tar hashalot ccache rsync \
                       python3-ply python3-git codespell && \
    apt-get clean

# Sparse
# Do not forget to change the version and SHA in mptcp-upstream-virtme-docker
ARG SPARSE_URL="https://mirrors.edge.kernel.org/pub/software/devel/sparse/dist/sparse-0.6.4.tar.xz"
ARG SPARSE_TARBALL="sparse.tar.xz"
ARG SPARSE_SHA="6ab28b4991bc6aedbd73550291360aa6ab3df41f59206a9bde9690208a6e387c  ${SPARSE_TARBALL}"

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
