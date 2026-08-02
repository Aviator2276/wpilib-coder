# WPILib workspace image for Coder — Java robot development + Sim GUI over KasmVNC.
#
# Extends codercom/enterprise-base:ubuntu (noble, user `coder` uid 1000) with:
#   - JDK 17            (WPILib 2026 sourceCompatibility = 17)
#   - KasmVNC           (web-native VNC server; the wpilib-sim module configures/starts it)
#   - X11 + Mesa        (llvmpipe software GL for the GLFW/OpenGL3 sim GUI — no GPU needed)
#   - Gradle RO cache   (WPILib/GradleRIO deps baked into the image layer; shared by all
#                        users via GRADLE_RO_DEP_CACHE at zero per-user volume cost)
#
# Build (multi-arch):
#   docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/wpilib-workspace:2026 --push images/
#
# The seed project under seed/ pins GradleRIO 2026.2.1 (latest on the Gradle plugin
# portal; frcmaven itself is at 2026.2.2 but the plugin lags).

FROM codercom/enterprise-base:ubuntu

ARG TARGETARCH
ARG KASM_VERSION=1.5.0
ENV DEBIAN_FRONTEND=noninteractive

USER root

# --- Runtime dependencies ------------------------------------------------------
# libatomic1: required by WPILib JNI libs (hard failure on arm64 without it).
# feh/xdotool: used by the wpilib-sim module for the placeholder card and window checks.
# No xterm, no browser, no file manager: the VNC session must have nothing to fall
# back to except the sim GUI.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
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

# --- KasmVNC -------------------------------------------------------------------
RUN curl -fsSL \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/kasmvncserver_noble_${KASM_VERSION}_${TARGETARCH}.deb" \
      -o /tmp/kasmvncserver.deb \
  && apt-get update \
  && apt-get install -y --no-install-recommends /tmp/kasmvncserver.deb \
  && rm /tmp/kasmvncserver.deb \
  && rm -rf /var/lib/apt/lists/* \
  && adduser coder ssl-cert

# --- Gradle read-only dependency cache -----------------------------------------
# Build a throwaway GradleRIO project once to resolve every WPILib dependency,
# then expose the populated cache read-only to all users. Gradle resolves from
# GRADLE_RO_DEP_CACHE without copying into the per-user cache.
COPY --chown=coder:coder seed/ /opt/wpilib-seed/project/
# `simulateJavaRelease --dry-run` resolves the simulation-time native zips
# (halsim, opencv, cscore, ...) at configuration time WITHOUT launching the
# robot program — actually executing the task would start a headless robot JVM
# that never exits and wedge the build. The offline dry-run is the guard: it
# fails at configuration if any artifact is missing from the cache.
RUN su coder -c 'cd /opt/wpilib-seed/project \
      && GRADLE_USER_HOME=/opt/wpilib-seed/gradle ./gradlew build -x test --console=plain \
      && GRADLE_USER_HOME=/opt/wpilib-seed/gradle ./gradlew simulateJavaRelease --dry-run --console=plain \
      && GRADLE_USER_HOME=/opt/wpilib-seed/gradle ./gradlew simulateJavaRelease --offline --dry-run --console=plain' \
  # Drop everything except the dependency cache and the wrapper distribution.
  && rm -rf /opt/wpilib-seed/gradle/daemon /opt/wpilib-seed/gradle/kotlin-profile \
            /opt/wpilib-seed/gradle/workers /opt/wpilib-seed/gradle/native \
            /opt/wpilib-seed/gradle/caches/journal-1 \
            /opt/wpilib-seed/project/build /opt/wpilib-seed/project/.gradle \
  && chmod -R a+rX /opt/wpilib-seed

# Deps come from the shared RO cache; the per-user ~/.gradle only ever holds the
# wrapper distribution (~130 MB one-time) and build-local state.
ENV GRADLE_RO_DEP_CACHE=/opt/wpilib-seed/gradle/caches

# Cap Gradle's JVM globally — 3 GB workspaces cannot afford the 1.5 GB default.
RUN mkdir -p /etc/skel/.gradle \
  && printf 'org.gradle.jvmargs=-Xmx768m\norg.gradle.parallel=false\n' \
       > /etc/skel/.gradle/gradle.properties

# Assets used by the wpilib-sim module (placeholder card etc.).
RUN mkdir -p /opt/wpilib-sim && chmod 755 /opt/wpilib-sim
COPY assets/ /opt/wpilib-sim/

USER coder
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-${TARGETARCH:-arm64}
