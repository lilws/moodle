#!/bin/bash
# Copyright Broadcom, Inc. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0

# shellcheck disable=SC1091

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

# Load Moodle environment
. /opt/bitnami/scripts/moodle-env.sh

# Load libraries
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libservice.sh
. /opt/bitnami/scripts/libwebserver.sh

# Catch SIGTERM signal and stop all child processes
_forwardTerm() {
    warn "Caught signal SIGTERM, passing it to child processes..."
    pgrep -P $$ | xargs kill -TERM 2>/dev/null
    wait
    exit $?
}
trap _forwardTerm TERM

# Start cron
if am_i_root; then
    info "** Starting cron **"
    if ! cron_start; then
        error "Failed to start cron. Check that it is installed and its configuration is correct."
        exit 1
    fi
else
    warn "Cron will not be started because of running as a non-root user"
fi

# ==== One-time Composer (bundled) ====
APP="/opt/bitnami/moodle"
LOCK="$APP/composer.lock"
HASHFILE="$APP/.composer_lock.sha256"

# wait (briefly) for first-time install to finish (config.php appears)
for i in $(seq 1 180); do
  [ -f "$APP/config.php" ] && break
  sleep 1
done

if [ -f "$APP/composer.json" ] && command -v composer >/dev/null 2>&1; then
  NEED=0
  # (1) vendor missing → need
  [ ! -d "$APP/vendor" ] && NEED=1
  # (2) lockfile changed → need
  if [ "$NEED" -eq 0 ] && [ -f "$LOCK" ]; then
    NEW="$(sha256sum "$LOCK" | awk '{print $1}')"
    OLD="$(cat "$HASHFILE" 2>/dev/null || true)"
    [ "$NEW" != "$OLD" ] && NEED=1
  fi

  if [ "$NEED" -eq 1 ]; then
    echo "==> [composer] installing/updating dependencies (bundled composer)…"
    export COMPOSER_HOME="$APP/.composer" COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1
    install -d -m 775 "$COMPOSER_HOME"
    chown -R daemon:daemon "$COMPOSER_HOME" || true

    # run as web user so permissions match
    if su -s /bin/bash -c "cd \"$APP\" && composer install --no-dev --classmap-authoritative --optimize-autoloader --no-interaction --no-progress" daemon; then
      if [ -f "$LOCK" ]; then
        sha256sum "$LOCK" | awk '{print $1}' > "$HASHFILE"
        chown daemon:daemon "$HASHFILE" || true
      fi
      chown -R daemon:daemon "$APP/vendor" || true
      echo "==> [composer] done."
    else
      echo "==> [composer] failed; will retry next boot."
    fi
  else
    echo "==> [composer] skip (vendor up-to-date)."
  fi
else
  # Either no composer.json or bundled composer not present — do nothing
  :
fi
# ==== end One-time Composer ====


# Start Apache
if [[ -f "/opt/bitnami/scripts/nginx-php-fpm/run.sh" ]]; then
    exec "/opt/bitnami/scripts/nginx-php-fpm/run.sh"
else
    exec "/opt/bitnami/scripts/$(web_server_type)/run.sh"
fi
