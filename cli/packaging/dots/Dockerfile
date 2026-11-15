# syntax=docker/dockerfile:1.7
#
# Self-hosted ChatGPT Dots bridge for Inline.
# Build from the repository root:
#   docker build -f cli/packaging/dots/Dockerfile -t inline-dots .
#
# The image holds the Inline CLI and the Codex CLI. Codex owns the ChatGPT
# login (`codex login --device-auth`); the bridge reads its token from the
# Codex app-server in memory and never writes it anywhere.

FROM rust:1.96.0-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p inline-cli --bin inline \
    && install -m 0755 target/release/inline /usr/local/bin/inline

FROM node:22-bookworm-slim
# Pin Codex for reproducible images; bump alongside Inline releases. Any
# version at or above Inline's Codex floor (0.146.0) works.
ARG CODEX_VERSION=0.146.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tini \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin inline \
    && mkdir -p /data \
    && chown inline:inline /data
COPY --from=build /usr/local/bin/inline /usr/local/bin/inline
COPY cli/packaging/dots/entrypoint.sh /usr/local/bin/inline-dots
USER inline
ENV HOME=/data \
    INLINE_DATA_DIR=/data/inline \
    CODEX_HOME=/data/codex \
    INLINE_DISABLE_AUTOUPDATE=1
VOLUME ["/data"]
ENTRYPOINT ["tini", "--", "/usr/local/bin/inline-dots"]
CMD ["run"]
