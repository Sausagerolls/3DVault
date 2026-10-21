#!/bin/sh
# Runs the API and the background worker. Drops to PUID:PGID when given so
# files written to the NAS shares belong to the right user.
set -e

RUN=""
if [ -n "$PUID" ] && [ -n "$PGID" ] && [ "$(id -u)" = "0" ]; then
  chown -R "$PUID:$PGID" /data
  chown "$PUID:$PGID" /library /inbox 2>/dev/null || true
  RUN="setpriv --reuid=$PUID --regid=$PGID --clear-groups"
fi
umask "${UMASK:-002}"

# Keep the worker alive; it is safe to restart at any time.
(
  while true; do
    $RUN python -m app.worker || echo "worker exited ($?), restarting in 5s"
    sleep 5
  done
) &

exec $RUN uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips='*' --timeout-keep-alive 75
