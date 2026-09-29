#!/command/with-contenv sh
# Migrations, for the embedded database only. Supersedes the base image's
# migrate.sh by inserting a readiness gate before the connection attempt.
#
# WHY
#   s6 marks the long-run postgres service "up" the moment the postmaster
#   process is forked — not when it accepts connections. The oneshot migrate
#   service then runs immediately and its first query lands while the server
#   is still recovering: `FATAL: the database system is starting up (57P03)`.
#   migrate exits 1, s6-rc reports "unable to start service migrate", and api
#   (dependent) never starts — the fresh-deploy shows Online but /health is a
#   502. On every first/cold boot of EMBEDDED_POSTGRES=on.
#
# FIX
#   Block here (where the connection actually happens) until
#   pg_isready reports the server is accept-ready. Bounded so a genuinely
#   broken database still surfaces as a hard failure with evidence, never as
#   a silent hang. Everything else is byte-for-byte the base script.
set -eu
[ "${EMBEDDED_POSTGRES:-off}" = "on" ] || exit 0

BIN=/usr/lib/postgresql/16/bin
if [ -x "$BIN/pg_isready" ]; then
  n=0
  until "$BIN/pg_isready" -q -h 127.0.0.1 -p 5432 -U openbot; do
    n=$((n + 1))
    if [ "$n" -ge 240 ]; then
      echo "migrate: pg_isready not ok after 240s; postgres may be stuck." >&2
      s6-setuidgid postgres "$BIN/pg_ctl" -D /var/lib/postgresql/data status 2>&1 | cat || true
      exit 1
    fi
    sleep 1
  done
fi

cd /app/server
export HOME=/home/apiuser
exec s6-setuidgid apiuser /usr/local/bin/bun scripts/migrate.ts
