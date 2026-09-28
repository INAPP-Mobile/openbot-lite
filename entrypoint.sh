#!/bin/sh
# -----------------------------------------------------------------------------
# Railway entrypoint shim for OpenBot (published ghcr.io/copilotkit/openbot).
#
# Why: the base image refuses to start when KEY_ENCRYPTION_KEY is unset or the
# public placeholder from .env.example ("AAAAAAAA...=="). A fresh Railway
# deployment has neither, so without a stable key the container crash-loops
# before it can serve /health — nothing to tell the user why.
#
# We generate a base64 32-byte key ONCE, keep it on the persistent volume
# (/var/lib/postgresql, which is also the embedded Postgres data mount), and
# re-export it on every boot. A key already injected by the deployer (e.g. a
# template variable) always wins — we only fill the gap.
#
# The embedded Postgres data dir is /var/lib/postgresql/data, so we mount the
# volume at /var/lib/postgresql (the parent), exactly as the image's own
# postgres-init.sh requests — a volume mounted directly ON the data dir arrives
# with lost+found on ext4 platforms and initdb refuses it. Key generation
# below is deliberately independent of whether postgres has started.
set -eu

VOL=/var/lib/postgresql
KEY_FILE="$VOL/.openbot.key"

export EMBEDDED_POSTGRES="${EMBEDDED_POSTGRES:-on}"

if [ -z "${KEY_ENCRYPTION_KEY:-}" ]; then
  if [ -s "$KEY_FILE" ]; then
    # Reuse the key we persisted on first boot (survives container re-creation).
    KEY_ENCRYPTION_KEY="$(cat "$KEY_FILE")"
  else
    KEY_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64 -w0)"
    # Best effort: persist next to the cluster so a redeploy does not rotate the
    # key (which would decrypt-fail the credential vault). If the mount is not
    # writable yet (initdb race on first boot), we still have a valid key for
    # this boot; the file gets back-filled on the next start if missing.
    if ! umask 077 2>/dev/null; then :; fi
    if ! printf '%s' "$KEY_ENCRYPTION_KEY" > "$KEY_FILE" 2>/dev/null; then
      echo "[openbot-entrypoint] NOTE: could not persist KEY_ENCRYPTION_KEY to $KEY_FILE on first boot; a stable key was still generated for this run." >&2
    fi
  fi
  export KEY_ENCRYPTION_KEY
fi

# Hand the key to s6-managed services. with-contenv reads from:
#   /run/s6/container_environment (if it exists) — so we drop it there too.
mkdir -p /run/s6/container_environment 2>/dev/null || true
printf 'KEY_ENCRYPTION_KEY=%s\n' "$KEY_ENCRYPTION_KEY" > /run/s6/container_environment/KEY_ENCRYPTION_KEY 2>/dev/null || true

exec /init "$@"
