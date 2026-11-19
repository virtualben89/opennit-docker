#!/usr/bin/env bash
# OpenNIT update: pull the new image, show the changelog, back up, apply.
# OpenNIT-Update: neues Image holen, Changelog zeigen, Backup ziehen, einspielen.
#
#   ./update.sh             interactive (shows changelog, asks) / interaktiv
#   ./update.sh --check     check only – exit 0 = up to date, 10 = update available
#   ./update.sh -y          no questions (cron); exits with 2 if the changelog lists
#                           manual steps / bricht bei manuellen Schritten mit Exit 2 ab
#   ./update.sh -y --force  no questions, even with manual steps / auch dann
#
# Environment: BACKUP_DIR (./backups)  KEEP_BACKUPS (7)  KEEP_ROLLBACK_IMAGES (3)
#              SKIP_FILE_BACKUP=1  back up only database and persist/ (no storage/, uploads/)
#              OPENNIT_LANG=de|en  output language (default: from LANG, otherwise English)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

YES=0 FORCE=0 CHECK=0
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        --force)  FORCE=1 ;;
        --check)  CHECK=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option / Unbekannte Option: $a (--help)" >&2; exit 1 ;;
    esac
done

BACKUP_DIR=${BACKUP_DIR:-./backups}
KEEP_BACKUPS=${KEEP_BACKUPS:-7}
KEEP_ROLLBACK_IMAGES=${KEEP_ROLLBACK_IMAGES:-3}

# Language: OPENNIT_LANG, else the locale (de_* → German), else English
case "${OPENNIT_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
    de*) L=de ;;
    *)   L=en ;;
esac
t() { if [ "$L" = de ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

if [ -t 1 ]; then B=$'\033[1m'; BL=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; R=$'\033[0m'
else B=""; BL=""; G=""; Y=""; RD=""; R=""; fi
say()  { printf '%s›%s %s\n' "$BL" "$R" "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$R" "$*"; }
warn() { printf '%s▲%s %s\n' "$Y" "$R" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RD" "$1" "$R" >&2; exit "${2:-1}"; }
dc()   { docker compose "$@"; }
UNKNOWN=$(t unbekannt unknown)

# --- Starting point -----------------------------------------------------------
IMAGE=$(dc config --images | awk '!/mariadb/ && !x {print; x=1}')
[ -n "$IMAGE" ] || die "$(t "Image des app-Dienstes nicht ermittelbar (docker compose config)." \
                            "Could not determine the image of the app service (docker compose config).")"

APP_CID=$(dc ps -q app)
[ -n "$APP_CID" ] || die "$(t "Der app-Container läuft nicht – zuerst: docker compose up -d" \
                              "The app container is not running – first run: docker compose up -d")"
OLD_ID=$(docker inspect -f '{{.Image}}' "$APP_CID")
CUR=$(dc exec -T app cat VERSION 2>/dev/null | tr -d '[:space:]' || true)

# Tag the running image before the pull: afterwards it can no longer be addressed by
# its ID (containerd image store) and would be useless for a rollback.
PRE_TAG="opennit-rollback:vor-update"
NOTES=""
cleanup() {
    [ -n "$NOTES" ] && rm -f "$NOTES"
    [ -n "$PRE_TAG" ] && docker rmi "$PRE_TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker tag "$OLD_ID" "$PRE_TAG" 2>/dev/null || PRE_TAG=""

say "$(t Installiert Installed): ${B}${CUR:-$UNKNOWN}${R} · $(t prüfe checking) ${IMAGE} …"
dc pull -q app
NEW_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
if [ "$NEW_ID" = "$OLD_ID" ]; then
    ok "$(t "OpenNIT ist aktuell" "OpenNIT is up to date") (${CUR:-?})."
    exit 0
fi
NEW=$(docker run --rm --entrypoint cat "$IMAGE" VERSION | tr -d '[:space:]')
NEW_SHA=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE" 2>/dev/null || true)

if [ "$CHECK" = 1 ]; then
    echo "$(t "Update verfügbar" "Update available"): ${CUR:-?} → $NEW${NEW_SHA:+ (${NEW_SHA:0:7})}"
    exit 10
fi

# --- Changelog ----------------------------------------------------------------
NOTES=$(mktemp)
# All sections above the installed version; if it is unknown, only the newest one.
# (awk reads to the end instead of "exit" – otherwise the pipe breaks and pipefail kicks in)
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
        security) say "$(t "Gleiche Versionsnummer – Sicherheits-Neubau mit aktuellen Systempaketen (OpenNIT unverändert)." \
                           "Same version number – security rebuild with current system packages (OpenNIT unchanged).")" ;;
        image)    say "$(t "Gleiche Versionsnummer – Änderungen am Container-Image (OpenNIT unverändert)." \
                           "Same version number – changes to the container image (OpenNIT unchanged).")" ;;
        *)        say "$(t "Gleiche Versionsnummer, neuerer Build (ohne eigenen Changelog-Eintrag)." \
                           "Same version number, newer build (no changelog entry of its own).")" ;;
    esac
else
    [ "$L" = de ] || say "Changelog of the OpenNIT project (German only):"
    if [ -t 1 ] && [ "$YES" = 0 ] && command -v less >/dev/null && [ "$(wc -l < "$NOTES")" -gt 40 ]; then
        less -R "$NOTES"
    else
        cat "$NOTES"; echo
    fi
fi

# The upstream changelog is German: "Wichtig für dieses Update" / "Vor dem Einspielen lesen"
if grep -qE '^### .*(Wichtig für dieses Update|Vor dem Einspielen)' "$NOTES"; then
    if [ "$L" = de ]; then
        warn "${B}Dieses Update enthält manuelle Schritte${R} – Abschnitt „Wichtig für dieses Update“"
        warn "bzw. „Vor dem Einspielen lesen“ im Changelog oben beachten."
        warn "composer install, neue storage-Ordner und DB-Migrationen erledigt das Image selbst."
    else
        warn "${B}This update requires manual steps${R} – see the section “Wichtig für dieses Update”"
        warn "(important for this update) or “Vor dem Einspielen lesen” (read before applying) above."
        warn "composer install, new storage folders and database migrations are handled by the image."
    fi
    if [ "$YES" = 1 ] && [ "$FORCE" = 0 ]; then
        die "$(t "Abbruch (-y ohne --force). Bitte interaktiv ausführen: ./update.sh" \
                 "Aborted (-y without --force). Please run interactively: ./update.sh")" 2
    fi
fi

if [ "$YES" = 0 ]; then
    read -r -p "$(t "Update jetzt einspielen (vorher wird gesichert)? [j/N] " \
                    "Apply the update now (a backup is made first)? [y/N] ")" ans
    [[ "${ans,,}" =~ ^(j|ja|y|yes)$ ]] || die "$(t "Abgebrochen – nichts verändert." "Cancelled – nothing changed.")" 0
fi

# --- Rescue settings from the container -----------------------------------------
# OpenNIT replaces config/runtime.php (settings, modules) atomically via rename(), which
# swaps the symlink into persist/ for a regular file in the container layer. Images before
# 2026-11-19 did not move it back, so it would be lost on recreate. Copy it to the volume.
RESCUED=$(dc exec -T app sh -c '
    if [ ! -L config ] && [ -f config/runtime.php ] && [ ! -L config/runtime.php ]; then
        cp -p config/runtime.php persist/runtime.php && echo config/runtime.php
    fi
    if [ -f .env ] && [ ! -L .env ]; then cp -p .env persist/.env && echo .env; fi' 2>/dev/null || true)
[ -z "$RESCUED" ] || ok "$(t "Einstellungen aus dem Container gesichert:" \
                             "Rescued settings from the container:") $(echo $RESCUED)"

# --- Backup -------------------------------------------------------------------
umask 077
TS=$(date +%Y%m%d-%H%M%S)
DIR="$BACKUP_DIR/$TS-${CUR:-$UNKNOWN}"
mkdir -p "$DIR"
say "$(t "Sichere Datenbank nach" "Backing up the database to") $DIR …"
dc exec -T db sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction \
    --routines --triggers --events --add-drop-database --databases "$MARIADB_DATABASE"' \
    | gzip > "$DIR/db.sql.gz"
zgrep -q "CREATE TABLE" "$DIR/db.sql.gz" \
    || die "$(t "Datenbank-Dump ist leer – Update abgebrochen." "Database dump is empty – update aborted.")"

PATHS="persist"
[ "${SKIP_FILE_BACKUP:-0}" = 1 ] || PATHS="persist storage public/uploads"
say "$(t "Sichere Dateien" "Backing up files") ($PATHS) …"
# shellcheck disable=SC2086
dc exec -T app tar czf - --exclude=storage/cache $PATHS > "$DIR/files.tar.gz"

if [ -n "$PRE_TAG" ]; then
    ROLLBACK_TAG="opennit-rollback:${CUR:-$UNKNOWN}-$TS"
    docker tag "$PRE_TAG" "$ROLLBACK_TAG"
else
    # Fallback: the versioned tag in the registry
    ROLLBACK_TAG="${IMAGE%:*}:${CUR:-x.y.z}"
    warn "$(t "Laufendes Image lokal nicht mehr adressierbar – Rollback über" \
              "Running image no longer addressable locally – rollback via") $ROLLBACK_TAG."
fi
if [ "$L" = de ]; then
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
else
cat > "$DIR/ROLLBACK.txt" <<EOF
Rollback to OpenNIT ${CUR:-?} (state before the update at $TS)
Run in the directory $(pwd):

  docker compose stop app scheduler
  zcat $DIR/db.sql.gz | docker compose exec -T db sh -c 'exec mariadb -uroot -p"\$MARIADB_ROOT_PASSWORD"'
  OPENNIT_IMAGE=$ROLLBACK_TAG docker compose up -d --no-build app scheduler
  # Restore files only if needed:
  docker compose exec -T app tar xzf - < $DIR/files.tar.gz

Afterwards set OPENNIT_IMAGE in .env to a fixed version (e.g. :${CUR:-x.y.z}),
so the next update.sh does not update again right away.
EOF
fi
ok "$(t "Backup fertig" "Backup done"): $DIR ($(du -sh "$DIR" | cut -f1))"

# --- Apply --------------------------------------------------------------------
say "$(t "Starte OpenNIT" "Starting OpenNIT") $NEW …"
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
    die "$(t "OpenNIT ist nach dem Update nicht gesund (Status: $status). Rollback-Anleitung:" \
             "OpenNIT is not healthy after the update (status: $status). Rollback instructions:") $DIR/ROLLBACK.txt"
fi
ok "OpenNIT $(dc exec -T app cat VERSION | tr -d '[:space:]') $(t läuft. "is running.")"

# --- Cleanup ------------------------------------------------------------------
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????-*' | sort -r \
    | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -rf
docker image ls opennit-rollback --format '{{.Tag}}' \
    | awk -F- '{print $(NF-1) $NF, $0}' | sort -r | cut -d' ' -f2 \
    | tail -n +"$((KEEP_ROLLBACK_IMAGES + 1))" | xargs -r -I{} docker rmi -f "opennit-rollback:{}" >/dev/null
docker image prune -f >/dev/null
