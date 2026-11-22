# Basalt (https://github.com/jesdga95/basalt) ships a Dockerfile, but this one
# is kept: it drops the runtime image's CUDA forward-compatibility libraries,
# which make every CUDA call fail on GeForce cards, and keeps `bin/basalt` as
# the entrypoint the services' argv assumes. The engine builds for sm_120
# only, and `basalt serve` runs the Python server from the source tree's
# `.venv`, so the runtime stage keeps the tree.

FROM nvidia/cuda:13.4.3-devel-ubuntu24.04 AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends cmake ninja-build g++ python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      "-DBASALT_MODELS=qwen4exp;inkling2" \
    && cmake --build build --target basalt basalt-probe basalt-bench basalt-vision \
    && rm -rf build

FROM nvidia/cuda:13.4.3-runtime-ubuntu24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
# The runtime image's forward-compatibility libraries only work on datacenter
# GPUs; on a GeForce card every CUDA call fails with them present.
RUN rm -rf /usr/local/cuda-13.4/compat /usr/local/cuda-13/compat /usr/local/cuda/compat
COPY --from=build /src /src
WORKDIR /src
RUN python3 -m venv .venv && .venv/bin/pip install --no-cache-dir -r requirements.txt
STOPSIGNAL SIGTERM
ENTRYPOINT ["/src/bin/basalt"]
CMD ["--help"]
