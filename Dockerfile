# BUILD THE UE4SS FILES
FROM --platform=linux/amd64 debian:bookworm-slim AS ue4ss-files

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    unzip \
    jq \
    gcc-mingw-w64-x86-64 \
    && rm -rf /var/lib/apt/lists/*

# Bundle the latest UE4SS experimental build
RUN url=$(curl -fsSL https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest | \
        jq -r '.assets[].browser_download_url | select(test("/UE4SS_v[^/]*\\.zip$"))' | head -n1) && \
    echo "Bundling UE4SS from ${url}" && \
    mkdir -p /ue4ss && \
    curl -fsSL "$url" -o /ue4ss/UE4SS.zip && \
    unzip -tq /ue4ss/UE4SS.zip dwmapi.dll ue4ss/UE4SS.dll

COPY ./ue4ss-loader /src

RUN x86_64-w64-mingw32-gcc -shared -O2 -s -Wall -o /ue4ss/version.dll /src/version.c /src/version.def

# BUILD THE SERVER IMAGE
FROM --platform=linux/amd64 debian:bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    unzip \
    procps \
    libicu-dev \
    gettext-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install .NET 8 runtime (required for DepotDownloader)
RUN curl -sL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 8.0 --runtime dotnet --install-dir /usr/share/dotnet && \
    ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet && \
    rm /tmp/dotnet-install.sh

# Download DepotDownloader
ARG DEPOT_DOWNLOADER_VERSION=3.4.0
RUN curl -sL "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOT_DOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip" -o /tmp/dd.zip && \
    mkdir -p /depotdownloader && \
    unzip /tmp/dd.zip -d /depotdownloader && \
    chmod +x /depotdownloader/DepotDownloader && \
    rm /tmp/dd.zip

RUN useradd -m -s /bin/bash steam

LABEL maintainer="support@indifferentbroccoli.com" \
      name="indifferentbroccoli/runescape-dragonwilds-server-docker" \
      github="https://github.com/indifferentbroccoli/runescape-dragonwilds-server-docker" \
      dockerhub="https://hub.docker.com/r/indifferentbroccoli/runescape-dragonwilds-server-docker"

ENV HOME=/home/steam \
    DEFAULT_PORT=7777 \
    BEACON_PORT=8888 \
    SERVER_NAME="DragonWildsServer" \
    DEFAULT_WORLD_NAME="MyWorld" \
    OWNER_ID="" \
    ADMIN_PASSWORD="" \
    WORLD_PASSWORD="" \
    MAX_PLAYERS=6 \
    MULTIHOME="" \
    UPDATE_ON_START=true \
    UE4SS_ENABLED=false

COPY ./scripts /home/steam/server/

COPY branding /branding

RUN mkdir -p /home/steam/server-files && \
    chmod +x /home/steam/server/*.sh

WORKDIR /home/steam/server

HEALTHCHECK --start-period=5m \
            CMD pgrep -f "^[^ ]*RSDragonwildsServer-(Linux|Win64)-Shipping" > /dev/null || exit 1

ENTRYPOINT ["/home/steam/server/init.sh"]

# BUILD THE UE4SS IMAGE
FROM base AS ue4ss

# Install Wine 
ARG WINE_VERSION=11.0.0.0~bookworm-1
RUN dpkg --add-architecture i386 && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o /etc/apt/keyrings/winehq-archive.asc && \
    printf '%s\n' \
        'Types: deb' \
        'URIs: https://dl.winehq.org/wine-builds/debian' \
        'Suites: bookworm' \
        'Components: main' \
        'Architectures: amd64 i386' \
        'Signed-By: /etc/apt/keyrings/winehq-archive.asc' \
        > /etc/apt/sources.list.d/winehq-bookworm.sources && \
    apt-get update && apt-get install -y --no-install-recommends \
        winehq-stable="${WINE_VERSION}" \
        wine-stable="${WINE_VERSION}" \
        wine-stable-amd64="${WINE_VERSION}" \
        wine-stable-i386="${WINE_VERSION}" \
        libgnutls30 \
        libfreetype6 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV UE4SS_ENABLED=true \
    WINEPREFIX=/home/steam/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all

# Create the Wine prefix with the native VC++ runtime, Wine's own msvcp140 is incomplete
USER steam
RUN WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init && \
    wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d null /f && \
    curl -fsSL https://aka.ms/vs/17/release/vc_redist.x64.exe -o /tmp/vc_redist.x64.exe && \
    (wine /tmp/vc_redist.x64.exe /install /quiet /norestart || true) && \
    wineserver -w && \
    ! grep -qaE 'Wine (builtin|placeholder) DLL' "$WINEPREFIX/drive_c/windows/system32/msvcp140_atomic_wait.dll" && \
    for dll in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids \
               vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1; do \
        wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d native,builtin /f || exit 1; \
    done && \
    wineserver -w && \
    rm /tmp/vc_redist.x64.exe && \
    # Replace the prefix's copies of Wine's DLLs with symlinks (~1.2GB)
    for pair in system32:x86_64-windows syswow64:i386-windows; do \
        lib="/opt/wine-stable/lib/wine/${pair#*:}"; \
        for f in "$WINEPREFIX/drive_c/windows/${pair%%:*}"/*; do \
            b="$lib/${f##*/}"; \
            if [ -f "$b" ] && cmp -s "$f" "$b"; then ln -sf "$b" "$f"; fi; \
        done; \
    done
USER root

COPY --from=ue4ss-files /ue4ss /ue4ss

# NATIVE IMAGE
FROM base AS native
