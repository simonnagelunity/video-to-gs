# Base: official COLMAP image (Ubuntu + COLMAP head with CUDA SIFT support).
# Pinned for reproducibility — bump occasionally.
FROM colmap/colmap:20260427.6785

ENV DEBIAN_FRONTEND=noninteractive

# Add ffmpeg (frame extraction) and Vulkan runtime (Brush uses wgpu → Vulkan on Linux).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        libvulkan1 \
        mesa-vulkan-drivers \
        vulkan-tools \
        ca-certificates \
        curl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Brush v0.3.0 Linux x86_64 release binary.
ARG BRUSH_VERSION=v0.3.0
RUN mkdir -p /opt/video2gs && cd /tmp \
    && curl -fL -o brush.tar.xz \
        "https://github.com/ArthurBrussee/brush/releases/download/${BRUSH_VERSION}/brush-app-x86_64-unknown-linux-gnu.tar.xz" \
    && tar -xJf brush.tar.xz \
    && mv brush-app-x86_64-unknown-linux-gnu/brush_app /opt/video2gs/brush_app \
    && chmod +x /opt/video2gs/brush_app \
    && rm -rf /tmp/brush*

ENV BRUSH_BIN=/opt/video2gs/brush_app

COPY entrypoint.sh /opt/video2gs/entrypoint.sh
RUN chmod +x /opt/video2gs/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/opt/video2gs/entrypoint.sh"]
