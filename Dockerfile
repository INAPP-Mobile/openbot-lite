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
FROM ghcr.io/copilotkit/openbot:v0.1.0

# The shim runs as the image's entrypoint. It is deliberately small and only
# adds what a Railway deployment needs that the base does not already do:
#   - a stable, non-placeholder KEY_ENCRYPTION_KEY (persisted on the volume)
#   - EMBEDDED_POSTGRES=on so no companion database service is required
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The base image's own healthcheck (bun fetch on 127.0.0.1:3001/health) already
# exists, so this template needs no custom healthcheck; EXPOSE keeps the docker
# format visible to tooling.
EXPOSE 3001
ENV NODE_ENV=production \
    PORT=3001 \
    EMBEDDED_POSTGRES=on

# FIX (railway first-boot 502): the base starts its `migrate` oneshot the moment
# s6 forks the postgres longrun service, before the DB accepts connections. The
# first query fails with FATAL: the database system is starting up (57P03),
# migrate exits 1, s6-rc refuses api (a dependent), and /health is a 502.
# Every fresh/cold boot with EMBEDDED_POSTGRES=on hits this.
#
# migrate-wait.sh is byte-for-byte the base /etc/s6-overlay/scripts/migrate.sh
# plus a bounded `pg_isready` readiness gate before the migration runs. It
# replaces only that oneshot script; the longrun postgres service itself is
# left untouched (s6 must keep adopting the postmaster the base way).
COPY migrate-wait.sh /etc/s6-overlay/scripts/migrate.sh
RUN chmod 755 /etc/s6-overlay/scripts/migrate.sh

ENTRYPOINT ["/entrypoint.sh"]
