#!/usr/bin/env bash
# OpenNIT-Update: neues Image holen, Changelog zeigen, Backup ziehen, einspielen.
#
#   ./update.sh             interaktiv (zeigt Changelog, fragt nach)
#   ./update.sh --check     nur prüfen – Exit 0 = aktuell, 10 = Update verfügbar
#   ./update.sh -y          ohne Rückfrage (Cron); bricht mit Exit 2 ab, wenn das
#                           Update laut Changelog manuelle Schritte erfordert
#   ./update.sh -y --force  ohne Rückfrage, auch bei manuellen Schritten
#
# Umgebung: BACKUP_DIR (./backups)  KEEP_BACKUPS (7)  KEEP_ROLLBACK_IMAGES (3)
#           SKIP_FILE_BACKUP=1  sichert nur DB und persist/ (ohne storage/, uploads/)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

YES=0 FORCE=0 CHECK=0
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        --force)  FORCE=1 ;;
        --check)  CHECK=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $a (siehe --help)" >&2; exit 1 ;;
    esac
done

BACKUP_DIR=${BACKUP_DIR:-./backups}
KEEP_BACKUPS=${KEEP_BACKUPS:-7}
KEEP_ROLLBACK_IMAGES=${KEEP_ROLLBACK_IMAGES:-3}

if [ -t 1 ]; then B=$'\033[1m'; BL=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; R=$'\033[0m'
else B=""; BL=""; G=""; Y=""; RD=""; R=""; fi
say()  { printf '%s›%s %s\n' "$BL" "$R" "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$R" "$*"; }
warn() { printf '%s▲%s %s\n' "$Y" "$R" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RD" "$1" "$R" >&2; exit "${2:-1}"; }
dc()   { docker compose "$@"; }

# --- Ausgangslage ------------------------------------------------------------
IMAGE=$(dc config --images | awk '!/mariadb/ && !x {print; x=1}')
[ -n "$IMAGE" ] || die "Image des app-Dienstes nicht ermittelbar (docker compose config)."

APP_CID=$(dc ps -q app)
[ -n "$APP_CID" ] || die "Der app-Container läuft nicht – zuerst: docker compose up -d"
OLD_ID=$(docker inspect -f '{{.Image}}' "$APP_CID")
CUR=$(dc exec -T app cat VERSION 2>/dev/null | tr -d '[:space:]' || true)

# Laufendes Image vor dem Pull markieren: danach ist es (containerd-Image-Store)
# nicht mehr über seine ID ansprechbar und taugt sonst nicht mehr als Rollback.
PRE_TAG="opennit-rollback:vor-update"
NOTES=""
cleanup() {
    [ -n "$NOTES" ] && rm -f "$NOTES"
    [ -n "$PRE_TAG" ] && docker rmi "$PRE_TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker tag "$OLD_ID" "$PRE_TAG" 2>/dev/null || PRE_TAG=""

say "Installiert: ${B}${CUR:-unbekannt}${R} · prüfe ${IMAGE} …"
dc pull -q app
NEW_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
if [ "$NEW_ID" = "$OLD_ID" ]; then
    ok "OpenNIT ist aktuell (${CUR:-?})."
    exit 0
fi
NEW=$(docker run --rm --entrypoint cat "$IMAGE" VERSION | tr -d '[:space:]')
NEW_SHA=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE" 2>/dev/null || true)

if [ "$CHECK" = 1 ]; then
    echo "Update verfügbar: ${CUR:-?} → $NEW${NEW_SHA:+ (${NEW_SHA:0:7})}"
    exit 10
fi

# --- Changelog ----------------------------------------------------------------
NOTES=$(mktemp)
# Alle Abschnitte oberhalb der installierten Version; ist sie unbekannt, nur den neuesten.
# (awk liest bis zum Ende statt "exit" – sonst bricht die Pipe und pipefail greift)
docker run --rm --entrypoint cat "$IMAGE" CHANGELOG.md | awk -v cur="$CUR" '
    done { next }
    /^## \[/ {
        if (cur != "" && index($0, "## [" cur "]") == 1) { done = 1; next }
        if ($0 ~ /^## \[Unreleased\]/) { skip = 1; next }
        skip = 0; n++
        if (cur == "" && n > 1) { done = 1; next }
    }
    n && !skip' > "$NOTES"

printf '\n%sUpdate: %s → %s%s%s\n\n' "$B" "${CUR:-?}" "$NEW" "${NEW_SHA:+ (${NEW_SHA:0:7})}" "$R"
if [ ! -s "$NOTES" ]; then
    case "$(docker image inspect -f '{{index .Config.Labels "de.opennit.build-reason"}}' "$IMAGE" 2>/dev/null)" in
        security) say "Gleiche Versionsnummer – Sicherheits-Neubau mit aktuellen Systempaketen (OpenNIT unverändert)." ;;
        image)    say "Gleiche Versionsnummer – Änderungen am Container-Image (OpenNIT unverändert)." ;;
        *)        say "Gleiche Versionsnummer, neuerer Build (ohne eigenen Changelog-Eintrag)." ;;
    esac
elif [ -t 1 ] && [ "$YES" = 0 ] && command -v less >/dev/null && [ "$(wc -l < "$NOTES")" -gt 40 ]; then
    less -R "$NOTES"
else
    cat "$NOTES"; echo
fi

if grep -qE '^### .*(Wichtig für dieses Update|Vor dem Einspielen)' "$NOTES"; then
    warn "${B}Dieses Update enthält manuelle Schritte${R} – Abschnitt „Wichtig für dieses Update“"
    warn "bzw. „Vor dem Einspielen lesen“ im Changelog oben beachten."
    warn "composer install, neue storage-Ordner und DB-Migrationen erledigt das Image selbst."
    if [ "$YES" = 1 ] && [ "$FORCE" = 0 ]; then
        die "Abbruch (-y ohne --force). Bitte interaktiv ausführen: ./update.sh" 2
    fi
fi

if [ "$YES" = 0 ]; then
    read -r -p "Update jetzt einspielen (vorher wird gesichert)? [j/N] " ans
    [[ "${ans,,}" =~ ^(j|ja|y|yes)$ ]] || die "Abgebrochen – nichts verändert." 0
fi

# --- Backup -------------------------------------------------------------------
umask 077
TS=$(date +%Y%m%d-%H%M%S)
DIR="$BACKUP_DIR/$TS-${CUR:-unbekannt}"
mkdir -p "$DIR"
say "Sichere Datenbank nach $DIR …"
dc exec -T db sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction \
    --routines --triggers --events --add-drop-database --databases "$MARIADB_DATABASE"' \
    | gzip > "$DIR/db.sql.gz"
zgrep -q "CREATE TABLE" "$DIR/db.sql.gz" || die "Datenbank-Dump ist leer – Update abgebrochen."

PATHS="persist"
[ "${SKIP_FILE_BACKUP:-0}" = 1 ] || PATHS="persist storage public/uploads"
say "Sichere Dateien ($PATHS) …"
# shellcheck disable=SC2086
dc exec -T app tar czf - --exclude=storage/cache $PATHS > "$DIR/files.tar.gz"

if [ -n "$PRE_TAG" ]; then
    ROLLBACK_TAG="opennit-rollback:${CUR:-unbekannt}-$TS"
    docker tag "$PRE_TAG" "$ROLLBACK_TAG"
else
    # Fallback: das versionierte Tag in der Registry
    ROLLBACK_TAG="${IMAGE%:*}:${CUR:-x.y.z}"
    warn "Laufendes Image lokal nicht mehr adressierbar – Rollback über $ROLLBACK_TAG."
fi
cat > "$DIR/ROLLBACK.txt" <<EOF
Rollback auf OpenNIT ${CUR:-?} (Stand vor dem Update am $TS)
Im Verzeichnis $(pwd) ausführen:

  docker compose stop app scheduler
  zcat $DIR/db.sql.gz | docker compose exec -T db sh -c 'exec mariadb -uroot -p"\$MARIADB_ROOT_PASSWORD"'
  OPENNIT_IMAGE=$ROLLBACK_TAG docker compose up -d --no-build app scheduler
  # Dateien nur bei Bedarf zurückspielen:
  docker compose exec -T app tar xzf - < $DIR/files.tar.gz

Danach OPENNIT_IMAGE in .env auf eine feste Version setzen (z. B. :${CUR:-x.y.z}),
damit das nächste update.sh nicht sofort wieder aktualisiert.
EOF
ok "Backup fertig: $DIR ($(du -sh "$DIR" | cut -f1))"

# --- Einspielen ---------------------------------------------------------------
say "Starte OpenNIT $NEW …"
dc up -d --no-build app scheduler
status=""
for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q app)" 2>/dev/null || echo starting)
    [ "$status" = healthy ] && break
    [ "$status" = unhealthy ] && break
    sleep 3
done
if [ "$status" != healthy ]; then
    dc logs --tail 40 app >&2 || true
    die "OpenNIT ist nach dem Update nicht gesund (Status: $status). Rollback-Anleitung: $DIR/ROLLBACK.txt"
fi
ok "OpenNIT $(dc exec -T app cat VERSION | tr -d '[:space:]') läuft."

# --- Aufräumen ----------------------------------------------------------------
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????-*' | sort -r \
    | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -rf
docker image ls opennit-rollback --format '{{.Tag}}' \
    | awk -F- '{print $(NF-1) $NF, $0}' | sort -r | cut -d' ' -f2 \
    | tail -n +"$((KEEP_ROLLBACK_IMAGES + 1))" | xargs -r -I{} docker rmi -f "opennit-rollback:{}" >/dev/null
docker image prune -f >/dev/null
