FROM ubuntu:25.04

# dependencies for the script
RUN apt-get update && \
    apt-get install -y build-essential libncurses5-dev gcc libssl-dev bc bison \
                       libelf-dev flex git curl tar hashalot ccache rsync \
                       python3-ply python3-git codespell shellcheck && \
    apt-get clean

# Sparse
# Do not forget to change the version and SHA in mptcp-upstream-virtme-docker
ARG SPARSE_GIT_URL="git://git.kernel.org/pub/scm/devel/sparse/sparse.git"
ARG SPARSE_GIT_SHA="09411a7a5127516a0741eb1bd8762642fa9197ce" # include a fix for 'unreplaced' issues and llvm 16 (not used)

RUN cd /tmp && \
    git clone "${SPARSE_GIT_URL}" sparse && \
    cd "sparse" && \
        git checkout "${SPARSE_GIT_SHA}" && \
        make -j"$(nproc)" -l"$(nproc)" && \
        make PREFIX=/usr install && \
        cd .. && \
    rm -rf "sparse"

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
