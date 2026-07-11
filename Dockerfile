# =============================================================================
# RoCE / GPUDirect / NCCL benchmark image  (prebuilt NVIDIA base)
#
# Based on NVIDIA's CUDA Ubuntu image so CUDA, NCCL and OpenMPI all come
# PREBUILT (apt) -> no slow source compiles. Only the two benchmark suites are
# built, because nobody packages them: perftest is rebuilt WITH CUDA (the stock
# package has no GPUDirect), and nccl-tests is always `make`'d from source
# (NVIDIA ships the NCCL library, not the test binaries).
#
# The base is a PREBUILT NVIDIA x86 image; `--platform linux/amd64` pulls x86.
#
# This is the SHARED image for the whole repo (both the RoCE and node-perf
# subjects use it), so it lives at the repo root -- build with the root as the
# context ("."). It clones its sources from git, so the context holds no build
# inputs; any dir works, but "." keeps it unambiguous.
#
# DEFAULT = the ARM-Mac-buildable combo (CUDA 12.6 + perftest v4.5-0.20). That
# perftest's CUDA path is cuda_loader.c (dlopen, pure gcc) -> no nvcc -> it cross-
# compiles under x86 QEMU on an ARM Mac, and it still runs on the CUDA-13 / 580
# driver via backward compat. NCCL needs no perftest, so this default fully works
# for NCCL + the NIC/latency suite. Plain build (from the repo root):
#   podman build --platform linux/amd64 -t <img> .
#
# CUDA-13-NATIVE GPUDirect (newer perftest compiles src/cuda_kernels.cu with nvcc,
# which segfaults under QEMU) -> BUILD ON x86 (GPU node / oc BuildConfig / x86 VM):
#   podman build \
#     --build-arg CUDA_IMAGE=nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04 \
#     --build-arg PERFTEST_REF=master -t <img> .
#
# Final image contains the full Phase-1 + NCCL toolset:
#   - perftest (plain)   /usr/bin/ib_*           NIC tests, runs on any node
#   - perftest (CUDA)    /opt/perftest-cuda/bin  GPUDirect (--use_cuda), GPU nodes
#   - nccl-tests SOURCE  /opt/nccl-tests          built on first use on a GPU node
#   - NCCL + OpenMPI (apt)  mpirun                cross-node collective launcher
#   - openssh               sshd/ssh              mpirun transport between pods
#   - python plotting    matplotlib + numpy       report Job
# Driver libcuda.so.1 is provided by the GPU node at runtime (not shipped).
# =============================================================================
ARG CUDA_IMAGE=nvcr.io/nvidia/cuda:12.6.2-devel-ubuntu22.04
FROM ${CUDA_IMAGE}

# v4.5-0.20 cross-builds on an ARM Mac (no nvcc). For a CUDA-13-native GPUDirect
# build on x86, override CUDA_IMAGE to a 13.0.x base + PERFTEST_REF=master.
ARG PERFTEST_REF=v4.5-0.20
ARG NCCL_TESTS_REF=master
ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Everything PREBUILT from apt: RDMA stack, NCCL, OpenMPI, python plotting, ssh,
# plus the toolchain + headers needed to build perftest/nccl-tests.
# -----------------------------------------------------------------------------
# Package groups:
#   RDMA stack + headers : rdma-core ibverbs-utils ibverbs-providers infiniband-diags
#                          rdmacm-utils (rping) + libibverbs/rdmacm/ibumad/pci -dev
#   MPI (prebuilt)       : openmpi-bin libopenmpi-dev
#   build toolchain      : build-essential git autoconf automake libtool pkg-config
#   RDMA/net diagnostics : ethtool pciutils(lspci) numactl hwloc(lstopo) mstflint
#                          iproute2(ip/ss/rdma) net-tools ping arping traceroute mtr
#                          tcpdump nc curl wget dig/nslookup iperf3 qperf
#   shell + report + ssh : ssh jq hostname gawk less vim procps python3+matplotlib+numpy
#   node benchmarks      : sysbench(cpu/memory) fio(disk)  -- used by the node-perf subject
RUN apt-get update && apt-get install -y --no-install-recommends \
        rdma-core ibverbs-utils ibverbs-providers infiniband-diags rdmacm-utils \
        libibverbs-dev librdmacm-dev libibumad-dev libpci-dev \
        openmpi-bin libopenmpi-dev \
        build-essential git autoconf automake libtool pkg-config ca-certificates \
        ethtool pciutils numactl hwloc mstflint \
        iproute2 net-tools iputils-ping iputils-arping traceroute mtr-tiny \
        tcpdump netcat-openbsd curl wget bind9-dnsutils \
        iperf3 qperf \
        sysbench fio \
        openssh-server openssh-client jq hostname gawk less vim-tiny procps \
        python3 python3-matplotlib python3-numpy \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd && ssh-keygen -A \
    && mkdir -p /etc/ssh/ssh_config.d \
    && printf 'Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n' \
         > /etc/ssh/ssh_config.d/10-nccl.conf

# -----------------------------------------------------------------------------
# perftest: plain (-> /usr/bin) and CUDA/GPUDirect (-> /opt/perftest-cuda).
# CUDA_H_PATH enables --use_cuda; libcuda stub at lib64/stubs satisfies the link.
# -----------------------------------------------------------------------------
RUN git clone --depth 1 --branch "${PERFTEST_REF}" https://github.com/linux-rdma/perftest /tmp/perftest \
    && cd /tmp/perftest && ./autogen.sh \
    && ./configure --prefix=/usr \
    && make -j"$(nproc)" && make install \
    && make distclean \
    && ./configure --prefix=/opt/perftest-cuda CUDA_H_PATH=/usr/local/cuda/include/cuda.h \
         LDFLAGS="-L/usr/local/cuda/lib64 -L/usr/local/cuda/lib64/stubs" \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/perftest

# -----------------------------------------------------------------------------
# nccl-tests SOURCE only. nvcc (CUDA device compiler) segfaults under x86
# emulation, so it can't be cross-built on an ARM Mac. The binaries are built on
# first use on a GPU node (native nvcc) by nccl_one_vs_many.sh.
# -----------------------------------------------------------------------------
RUN git clone --depth 1 --branch "${NCCL_TESTS_REF}" https://github.com/NVIDIA/nccl-tests /opt/nccl-tests

ENV CUDA_BIN_DIR=/opt/perftest-cuda/bin \
    MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
    PATH=/opt/nccl-tests/build:/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu/openmpi/lib:$LD_LIBRARY_PATH

CMD ["sleep", "infinity"]
