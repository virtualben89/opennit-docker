#!/usr/bin/env bash
# Erststart: führt die Grundeinrichtung (install.php --cli) automatisch aus.
set -euo pipefail
cd "$APP_DIR"

mkdir -p persist storage public/uploads
# Volumes werden nur beim ersten Start aus dem Image befüllt. Neue Verzeichnisse/Dateien
# eines Updates nachziehen, ohne Vorhandenes zu überschreiben.
cp -an /opt/skel-storage/. storage/
cp -an /opt/skel-uploads/. public/uploads/
[ -e persist/.env ] || install -m 640 -o www-data -g www-data /dev/null persist/.env
chown -R www-data:www-data persist storage public/uploads

is_installed() {
    [ -f storage/.installed ] || grep -qsE '^[[:space:]]*APP_KEY[[:space:]]*=[[:space:]]*\S' .env
}

if [ "${1:-}" = "apache2-foreground" ] && ! is_installed; then
    : "${DB_HOST:=db}" "${DB_PORT:=3306}"
    : "${DB_NAME:?DB_NAME fehlt}" "${DB_USER:?DB_USER fehlt}" "${DB_PASSWORD:?DB_PASSWORD fehlt}"
    : "${APP_URL:?APP_URL fehlt}" "${ADMIN_EMAIL:?ADMIN_EMAIL fehlt}" "${ADMIN_PASSWORD:?ADMIN_PASSWORD fehlt}"

    echo "[opennit] Warte auf Datenbank $DB_HOST:$DB_PORT …"
    # Verbindungstest per PHP/PDO – kommt ohne mariadb-client im Image aus
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
    [ "$db_ok" = 1 ] || { echo "[opennit] Datenbank $DB_HOST:$DB_PORT nach 120 s nicht erreichbar." >&2; exit 1; }

    echo "[opennit] Grundeinrichtung …"
    OPENNIT_DB_PASSWORD="$DB_PASSWORD" OPENNIT_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    su -s /bin/bash www-data -c "php public/install.php --cli \
        --db-host='$DB_HOST' --db-port='$DB_PORT' --db-name='$DB_NAME' --db-user='$DB_USER' \
        --app-url='$APP_URL' --admin-email='$ADMIN_EMAIL'"

    # Ohne HTTPS würde der Browser das Secure-Cookie nicht senden -> Login scheitert.
    if [[ "$APP_URL" == http://* ]] && ! grep -q '^SESSION_SECURE=' .env; then
        [ -n "$(tail -c1 .env)" ] && printf '\n' >> .env
        printf 'SESSION_SECURE=false\n' >> .env
    fi
    echo "[opennit] Einrichtung abgeschlossen – Login mit $ADMIN_EMAIL unter $APP_URL"
fi

# install.php steckt in jedem neuen Image wieder drin – nach der Einrichtung entfernen.
is_installed && rm -f public/install.php

# Versionsstand des Images vermerken, damit die Update-Prüfung passt.
[ -s /opt/opennit.sha ] && install -o www-data -g www-data -m 644 /opt/opennit.sha storage/.version

exec "$@"
