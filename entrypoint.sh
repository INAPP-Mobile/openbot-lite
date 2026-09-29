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

# --- Persist bot state on the ONE Railway volume (mounted at $VOL) -----------
# Railway allows a SINGLE volume per service, and the embedded Postgres is
# already pinned to /var/lib/postgresql/data, so the one volume mounts there
# (at the PARENT: a volume mounted ON .../data arrives with lost+found on ext4
# and initdb refuses it). The bot's two stateful dirs — /workspace (WORKSPACE_DIR,
# which the base's computer/run hardcodes to /workspace) and /profiles
# (PROFILES_DIR, Chromium logins, the base default) — are baked into the image
# as EMPTY ephemeral dirs on the overlay and reset on every redeploy.
#
# "Lite: ... /data persistence" + "persistent coworker bots" means those two
# dirs must survive a redeploy too. Both are empty at build time, so the
# sanctioned move is to re-point them at subdirs of the one volume via
# symlinks (created here, as root, before /init drops privileges). The base's
# own paths still resolve the bot (WORKSPACE_DIR=/workspace → symlink → volume),
# so no env-override is needed and the base's hardcoded value is not fought.
# initdb only inspects the .../data subdir, so these siblings are safe.
for d in workspace profiles; do
  if [ ! -e "$VOL/$d" ]; then
    mkdir -p "$VOL/$d" 2>/dev/null || true
  fi
  # Bots run as pwuser. Entry point is root (before /init), so we can chown.
  if command -v chown >/dev/null 2>&1 && id pwuser >/dev/null 2>&1; then
    chown -R pwuser:pwuser "$VOL/$d" 2>/dev/null || true
  fi
  # Replace the baked ephemeral dir with a symlink onto the volume. Only act
  # if it is a plain dir (not already a symlink, and not something unexpected).
  if [ -d "/$d" ] && [ ! -L "/$d" ]; then
    rmdir "/$d" 2>/dev/null || true
    ln -s "$VOL/$d" "/$d" 2>/dev/null || true
  elif [ -e "/$d" ] && [ ! -L "/$d" ]; then
    echo "[openbot-entrypoint] WARN: /$d is not an empty dir; leaving it as-is." >&2
  fi
done

KEY_FILE="$VOL/.openbot.key"

export EMBEDDED_POSTGRES="${EMBEDDED_POSTGRES:-on}"

# --- Trusted-origin / sign-in mode gates ------------------------------------
# The app (server/src/config.ts, singleUserAllowed) refuses to start when:
#   * no sign-in provider is configured AND no single-user flag, OR
#   * single-user mode is on AND any declared address it can reach is public.
# Reachability is judged from OPENBOT_PUBLIC_URL, OPENBOT_APP_URL and every
# TRUSTED_ORIGINS entry; UNPARSEABLE counts as public — so a deployer leaving
# a placeholder domain (as .env.example strings do) crash-loops the container.
#
# This shim makes both supported postures work regardless of what the deployer
# left in the environment:
#   * SSO provider configured -> serve at the public domain: anchor
#     BETTER_AUTH_URL/TRUSTED_ORIGINS to it and turn single-user off (with SSO,
#     every-visitor-is-admin is the wrong posture).
#   * No provider             -> single-user mode with loopback declared
#     origins. That is the upstream-documented "one administrator, no sign-in"
#     shape; the browser still reaches the app over whatever URL it is served
#     at (the gate reads the declared addresses, not the network).
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then PUB=https://"$RAILWAY_PUBLIC_DOMAIN"; else PUB=""; fi

have_provider=0
if [ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ] || [ -n "${MICROSOFT_OAUTH_CLIENT_ID:-}" ] || [ -n "${OKTA_OAUTH_CLIENT_ID:-}" ]; then
  have_provider=1
fi

AUTH_SECRET_FILE="$VOL/.openbot.authsecret"
bootstrap_auth_secret() {
  [ -n "${BETTER_AUTH_SECRET:-}" ] && { export BETTER_AUTH_SECRET; return; }
  if [ -s "$AUTH_SECRET_FILE" ]; then
    BETTER_AUTH_SECRET="$(cat "$AUTH_SECRET_FILE")"
  else
    BETTER_AUTH_SECRET="$(head -c 32 /dev/urandom | base64 -w0)"
    printf '%s' "$BETTER_AUTH_SECRET" > "$AUTH_SECRET_FILE" 2>/dev/null || true
  fi
  export BETTER_AUTH_SECRET
  mkdir -p /run/s6/container_environment 2>/dev/null || true
  printf 'BETTER_AUTH_SECRET=%s\n' "$BETTER_AUTH_SECRET" > /run/s6/container_environment/BETTER_AUTH_SECRET 2>/dev/null || true
}

if [ "$have_provider" -eq 1 ]; then
  export OPENBOT_SINGLE_USER=false
  bootstrap_auth_secret
  if [ -n "$PUB" ]; then
    export BETTER_AUTH_URL="${BETTER_AUTH_URL:-$PUB}"
    case ",${TRUSTED_ORIGINS:-}" in
      *",$PUB"*) ;;  # already anchored, keep the caller's extra origins
      *) export TRUSTED_ORIGINS="$PUB${TRUSTED_ORIGINS:+,$TRUSTED_ORIGINS}" ;;
    esac
  fi
  echo "[openbot-entrypoint] SSO mode: single-user off, BETTER_AUTH_URL=$BETTER_AUTH_URL" >&2
else
  export OPENBOT_SINGLE_USER=true
  # Keep the declared list only if it already names a loopback host (that
  # always passes the gate); any public-looking entry — including a leftover
  # placeholder — is replaced with the loopback set the app itself falls back
  # to. Empty TRUSTED_ORIGINS boot-tested clean.
  case " ${TRUSTED_ORIGINS:-} " in
    *localhost*|*127.0.0.1*|*\[::1\]*) : ;;
    *) export TRUSTED_ORIGINS="http://127.0.0.1:3001,http://[::1]:3001,http://localhost:3001" ;;
  esac
fi

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
