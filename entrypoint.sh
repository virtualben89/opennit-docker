#!/usr/bin/env bash
# First start: runs the initial setup (install.php --cli) automatically.
set -euo pipefail
cd "$APP_DIR"

mkdir -p persist storage public/uploads
# Volumes are only populated from the image on first start. Add new directories/files
# of an update without overwriting existing ones.
cp -an /opt/skel-storage/. storage/
cp -an /opt/skel-uploads/. public/uploads/
[ -e persist/.env ] || install -m 640 -o www-data -g www-data /dev/null persist/.env
chown -R www-data:www-data persist storage public/uploads

is_installed() {
    [ -f storage/.installed ] || grep -qsE '^[[:space:]]*APP_KEY[[:space:]]*=[[:space:]]*\S' .env
}

if [ "${1:-}" = "apache2-foreground" ] && ! is_installed; then
    : "${DB_HOST:=db}" "${DB_PORT:=3306}"
    : "${DB_NAME:?DB_NAME is not set}" "${DB_USER:?DB_USER is not set}" "${DB_PASSWORD:?DB_PASSWORD is not set}"
    : "${APP_URL:?APP_URL is not set}" "${ADMIN_EMAIL:?ADMIN_EMAIL is not set}" "${ADMIN_PASSWORD:?ADMIN_PASSWORD is not set}"

    echo "[opennit] Waiting for database $DB_HOST:$DB_PORT …"
    # Connection test via PHP/PDO – works without mariadb-client in the image
    db_ok=0
    for _ in $(seq 1 60); do
        if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_PASSWORD="$DB_PASSWORD" php -r '
            try {
                new PDO("mysql:host=" . getenv("DB_HOST") . ";port=" . getenv("DB_PORT"),
                        getenv("DB_USER"), getenv("DB_PASSWORD"), [PDO::ATTR_TIMEOUT => 3]);
                exit(0);
            } catch (Throwable $e) { exit(1); }' 2>/dev/null; then
            db_ok=1; break
        fi
        sleep 2
    done
    [ "$db_ok" = 1 ] || { echo "[opennit] Database $DB_HOST:$DB_PORT not reachable after 120 s." >&2; exit 1; }

    echo "[opennit] Initial setup …"
    OPENNIT_DB_PASSWORD="$DB_PASSWORD" OPENNIT_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    su -s /bin/bash www-data -c "php public/install.php --cli \
        --db-host='$DB_HOST' --db-port='$DB_PORT' --db-name='$DB_NAME' --db-user='$DB_USER' \
        --app-url='$APP_URL' --admin-email='$ADMIN_EMAIL'"

    # Without HTTPS the browser would not send the secure cookie -> login fails.
    if [[ "$APP_URL" == http://* ]] && ! grep -q '^SESSION_SECURE=' .env; then
        [ -n "$(tail -c1 .env)" ] && printf '\n' >> .env
        printf 'SESSION_SECURE=false\n' >> .env
    fi
    echo "[opennit] Setup complete – log in as $ADMIN_EMAIL at $APP_URL"
fi

# Every new image contains install.php again – remove it once installed.
is_installed && rm -f public/install.php

# Record the image's upstream revision so the update check matches.
[ -s /opt/opennit.sha ] && install -o www-data -g www-data -m 644 /opt/opennit.sha storage/.version

exec "$@"
