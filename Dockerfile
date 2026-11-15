# OpenNIT als Container – Pendant zu install.sh (Apache + mod_php, PHP 8.4)
FROM php:8.4-apache

LABEL org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.url="https://opennit.de" \
      org.opencontainers.image.description="Unofficial Docker image for OpenNIT, self-hosted IT documentation (Apache + PHP 8.4)"

ARG OPENNIT_UPDATE_BASE=https://update.loheide.cloud/opennit
ENV APP_DIR=/var/www/opennit

COPY --from=mlocati/php-extension-installer:2.7 /usr/bin/install-php-extensions /usr/local/bin/
# Erweiterungen kompilieren, danach Sicherheitsupdates einspielen und die Compiler-Werkzeuge
# des Basis-Images ($PHPIZE_DEPS, gcc-*/g++-*/cpp-*, -dev-Pakete, Kernel-Header) wieder
# entfernen – zur Laufzeit unnötig und Quelle vieler CVE-Treffer. Alles in einem RUN,
# damit die Werkzeuge in keiner Image-Schicht zurückbleiben.
# REFRESH ändert sich bei jedem CI-Build und verhindert, dass apt-get upgrade aus dem
# Build-Cache kommt (sonst brächte ein Sicherheits-Neubau keine neuen Pakete).
ARG REFRESH=""
RUN echo "Paketstand: ${REFRESH:-lokal}" \
 && install-php-extensions pdo_mysql gd zip intl opcache @composer \
 && apt-get update \
 && apt-get install -y --no-install-recommends unzip curl \
 && apt-get upgrade -y \
 && apt-get purge -y --auto-remove $PHPIZE_DEPS libc6-dev libcrypt-dev linux-libc-dev rpcsvc-proto \
    $(dpkg-query -W -f '${Package}\n' | grep -E '^(cpp|gcc|g\+\+)(-[0-9]+)?(-[a-z0-9_-]+-linux-gnu)?$|^libstdc\+\+-[0-9]+-dev$') \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && php -m | grep -qix pdo_mysql && php -m | grep -qix gd && php -m | grep -qix intl \
 && a2enmod rewrite headers \
 && mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY php.ini "$PHP_INI_DIR/conf.d/zz-opennit.ini"
COPY vhost.conf /etc/apache2/sites-available/000-default.conf

# OpenNIT-Paket: src/opennit.zip, falls vorhanden (CI lädt es vorab und wertet es aus),
# sonst direkt vom Update-Server (gleiche Quelle wie install.sh, Kanal "stable").
COPY src/ /tmp/src/
RUN set -eux; \
    if [ -f /tmp/src/opennit.zip ]; then mv /tmp/src/opennit.zip /tmp/o.zip; \
    else curl -fsSL -A "OpenNIT-Docker" "$OPENNIT_UPDATE_BASE/zip" -o /tmp/o.zip; fi; \
    rm -rf /tmp/src; mkdir /tmp/o && unzip -q /tmp/o.zip -d /tmp/o; \
    SRC=/tmp/o; [ -f /tmp/o/composer.json ] || SRC="$(find /tmp/o -mindepth 1 -maxdepth 1 -type d)"; \
    # Commit-SHA steckt im Verzeichnisnamen des ZIPs (…-<sha>) – passt garantiert zum Inhalt
    basename "$SRC" | grep -oE '[0-9a-f]{40}$' > /opt/opennit.sha || true; \
    mkdir -p "$APP_DIR" && cp -a "$SRC"/. "$APP_DIR"/; rm -rf /tmp/o /tmp/o.zip; \
    cd "$APP_DIR"; \
    rm -rf CLAUDE.md .claude AGENTS.md .cursor .cursorrules .aider.conf.yml .github/copilot-instructions.md tests; \
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction; \
    rm -f .env; \
    # Verzeichnis-Gerüst sichern: neue Unterordner späterer Releases ins Volume nachziehen
    cp -a storage /opt/skel-storage; cp -a public/uploads /opt/skel-uploads; \
    # Persistente Dateien liegen im Volume /var/www/opennit/persist (Symlinks)
    mkdir -p persist; ln -s persist/.env .env; \
    rm -f config/runtime.php; ln -s ../persist/runtime.php config/runtime.php; \
    chown -R www-data:www-data "$APP_DIR"

COPY entrypoint.sh /usr/local/bin/opennit-entrypoint
RUN chmod +x /usr/local/bin/opennit-entrypoint

WORKDIR /var/www/opennit
VOLUME ["/var/www/opennit/storage", "/var/www/opennit/public/uploads", "/var/www/opennit/persist"]
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s CMD curl -fsS -o /dev/null http://localhost/ || exit 1
ENTRYPOINT ["opennit-entrypoint"]
CMD ["apache2-foreground"]
