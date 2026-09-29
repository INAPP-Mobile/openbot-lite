# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# OpenBot Lite — Railway template
#
# OpenBot (CopilotKit) is an open-source "AI coworker" runtime: a single
# container that pairs a web UI + AG-UI/Intelligence API with persistent,
# policy-gated bot "computers". This template ships the official multi-service
# image (server + built-in agents) pinned to a release tag, plus a tiny
# entrypoint shim that (1) auto-generates a stable KEY_ENCRYPTION_KEY on the
# persistent volume and (2) enables the embedded Postgres (pgvector) so the
# whole stack runs in ONE container — the "Lite" shape.
#
# Base image is the published, self-contained OpenBot build (Ubuntu 24.04, bun,
# s6-overlay, embedded Postgres 16 + pgvector, Chromium for bot computers).
# https://github.com/CopilotKit/OpenBot
# -----------------------------------------------------------------------------
FROM ghcr.io/copilotkit/openbot:v0.0.15

# The shim runs as the image's entrypoint. It is deliberately small and only
# adds what a Railway deployment needs that the base does not already do:
#   - a stable, non-placeholder KEY_ENCRYPTION_KEY (persisted on the volume)
#   - EMBEDDED_POSTGRES=on so no companion database service is required
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The base image's own healthcheck (bun fetch on 127.0.0.1:3001/health) already
# exists; re-declare it so the docker-format build keeps it visible to tooling.
EXPOSE 3001
ENV NODE_ENV=production \
    PORT=3001 \
    EMBEDDED_POSTGRES=on

ENTRYPOINT ["/entrypoint.sh"]
