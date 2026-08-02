# Spike: validate WPILib simulateJava -> KasmVNC -> browser on 3 GB / 2 vCPU.
# Not the production image; see images/Dockerfile (Phase 3).
FROM ubuntu:24.04

ARG TARGETARCH
ARG KASM_VERSION=1.5.0
ENV DEBIAN_FRONTEND=noninteractive

# JDK 17 (WPILib 2026 sourceCompatibility), X11/Mesa runtime for the GLFW+OpenGL3
# sim GUI (llvmpipe software rendering), and KasmVNC's perl/ssl deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    ca-certificates curl \
    libatomic1 \
    libgl1 libglx-mesa0 libgl1-mesa-dri libegl1 \
    libx11-6 libxext6 libxrender1 libxtst6 libxi6 libxrandr2 \
    libxcursor1 libxinerama1 libxxf86vm1 libxkbcommon0 \
    xauth x11-xkb-utils xkb-data \
    xdotool feh \
    libdatetime-perl libhash-merge-simple-perl libswitch-perl \
    liblist-moreutils-perl libtry-tiny-perl libyaml-tiny-perl \
    libdatetime-timezone-perl ssl-cert \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/kasmvncserver_noble_${KASM_VERSION}_${TARGETARCH}.deb" \
      -o /tmp/kasmvncserver.deb \
  && apt-get update \
  && apt-get install -y --no-install-recommends /tmp/kasmvncserver.deb \
  && rm /tmp/kasmvncserver.deb \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash -u 1001 coder && adduser coder ssl-cert

COPY entry.sh /usr/local/bin/entry.sh
RUN chmod +x /usr/local/bin/entry.sh

USER coder
WORKDIR /home/coder
ENV DISPLAY=:1
EXPOSE 6901

ENTRYPOINT ["/usr/local/bin/entry.sh"]
