FROM ubuntu:25.10

# dependencies for the script
RUN apt-get update && \
    apt-get install -y build-essential libncurses5-dev gcc libssl-dev bc bison \
                       libelf-dev flex git curl tar hashalot ccache rsync \
                       python3-ply python3-git codespell shellcheck && \
    apt-get clean

# Sparse
# Do not forget to change the version and SHA in mptcp-upstream-virtme-docker
ARG SPARSE_GIT_URL="https://kernel.googlesource.com/pub/scm/devel/sparse/sparse.git"
ARG SPARSE_GIT_SHA="fbdde3127b83e6d09e0ba808d7925dd84407f3c6" # include a fix for __builtin_strlen
COPY sparse-fix-__builtin_strlen.patch /opt/
RUN cd /tmp && \
    git clone "${SPARSE_GIT_URL}" sparse && \
    cd "sparse" && \
        git checkout "${SPARSE_GIT_SHA}" && \
        patch -p1 --merge < /opt/sparse-fix-__builtin_strlen.patch && \
        make -j"$(nproc)" -l"$(nproc)" && \
        make PREFIX=/usr install && \
        cd .. && \
    rm -rf "sparse"

# CCache for quicker builds but still with default colours
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_COMPRESS="true"
ENV GCC_COLORS="error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"
# The home dir of the host is not the same as the one of the docker environment
ENV CCACHE_DIR="/github/workspace/.ccache"
# Remove the timestamp to improve CCache hit
ENV KBUILD_BUILD_TIMESTAMP="0"

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
