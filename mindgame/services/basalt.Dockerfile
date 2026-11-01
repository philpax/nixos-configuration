# Basalt (https://github.com/jesdga95/basalt) ships no Dockerfile; this one is
# added to the pinned source by mindgame/services/ananke.nix. The engine
# builds for sm_120 only, and `basalt serve` runs the Python server from the
# source tree's `.venv`, so the runtime stage keeps the tree.

FROM nvidia/cuda:13.1.2-devel-ubuntu24.04 AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends cmake ninja-build g++ python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --target basalt basalt-probe basalt-bench \
    && rm -rf build

FROM nvidia/cuda:13.1.2-runtime-ubuntu24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
# The runtime image's forward-compatibility libraries only work on datacenter
# GPUs; on a GeForce card every CUDA call fails with them present.
RUN rm -rf /usr/local/cuda-13.1/compat /usr/local/cuda-13/compat /usr/local/cuda/compat
COPY --from=build /src /src
WORKDIR /src
RUN python3 -m venv .venv && .venv/bin/pip install --no-cache-dir -r requirements.txt
STOPSIGNAL SIGTERM
ENTRYPOINT ["/src/bin/basalt"]
CMD ["--help"]
