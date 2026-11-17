# OpenNIT – Docker-Image

[English](README.md) · **Deutsch**

Inoffizielles Docker-Image für [OpenNIT](https://opennit.de), die self-hosted
IT-Dokumentation. Es ersetzt das native `install.sh`: Apache + PHP 8.4 (mod_php) im
Image, MariaDB als eigener Container, Grundeinrichtung beim ersten Start automatisch.

> **Hinweis:** Dieses Projekt steht in keiner Verbindung zum OpenNIT-Projekt. Es verpackt
> das unveränderte Paket vom offiziellen Update-Server (Kanal „stable“). Fehler in
> OpenNIT selbst bitte dort melden, Fehler im Container hier.

Das Image wird automatisch neu gebaut, sobald eine neue OpenNIT-Version erscheint
(Prüfung täglich um 6:00 Uhr), und liegt in der GitHub Container Registry:

| Tag | Inhalt |
|---|---|
| `:1.2.2` | genau diese Version |
| `:1.2` | neueste 1.2.x (nur Bugfixes) |
| `:1` / `:latest` | neueste 1.x |
| `:sha-ce7e633` | exakt dieser Upstream-Commit |

Gebaut wird über GitHub Actions oder wahlweise auf eigener Hardware über einen
[Self-hosted Runner](runner/README.md#deutsch).

Zu jeder neuen Version gibt es ein [GitHub-Release](../../releases) mit dem
Changelog-Abschnitt. Releases mit manuellen Schritten tragen eine Warnung.

### Sicherheit

- **Schlankes Image:** Compiler und Build-Werkzeuge des PHP-Basis-Images werden nach dem
  Kompilieren der Erweiterungen entfernt, auf einen MariaDB-Client wird verzichtet. Beim
  Bauen werden alle Debian-Sicherheitsupdates eingespielt.
- **Wöchentlicher Sicherheitsscan:** Jeden Montag prüft der Workflow das veröffentlichte
  Image mit [Trivy](https://trivy.dev). Gibt es für HIGH/CRITICAL-Lücken inzwischen
  Paket-Updates, wird dieselbe OpenNIT-Version mit aktuellen Systempaketen neu gebaut und
  unter denselben Tags veröffentlicht (ohne neues Release). `update.sh` zeigt das als
  „Sicherheits-Neubau“ an.
- Jeder Build wird anschließend erneut gescannt; das Ergebnis steht in der
  Zusammenfassung des Workflow-Laufs.
- Verbleibende Treffer betreffen Debian-Pakete, für die Debian (noch) keinen Fix
  bereitstellt (z. B. curl, libxml2) und die PHP zur Laufzeit benötigt.

Selbst prüfen:

```bash
docker run --rm aquasec/trivy:0.76.2 image --severity HIGH,CRITICAL ghcr.io/virtualben89/opennit:1
```

## Installation

Ein Klon des Repos ist nicht nötig, drei Dateien reichen:

```bash
mkdir opennit && cd opennit
base=https://raw.githubusercontent.com/virtualben89/opennit-docker/main
curl -fsSL -O $base/docker-compose.yml -O $base/update.sh
curl -fsSL $base/.env.example -o .env && chmod +x update.sh
nano .env                 # OPENNIT_IMAGE, APP_URL, ADMIN_EMAIL und Passwörter setzen
docker compose up -d
docker compose logs -f app
```

Danach unter `APP_URL` mit `ADMIN_EMAIL` / `ADMIN_PASSWORD` anmelden. `ADMIN_PASSWORD`
wird nur bei der Ersteinrichtung gebraucht und kann danach aus der `.env` entfernt werden.

Das Compose-File nutzt immer das fertige Image aus der Registry. Ein eigenes Image lässt
sich mit `docker build -t opennit:eigen .` bauen und über `OPENNIT_IMAGE=opennit:eigen`
einbinden. `update.sh` funktioniert dann nicht, weil es das Image aus der Registry holt.

Statt der benannten Volumes gehen auch Bind-Mounts (z. B. `/srv/opennit/storage`), ohne
`ports` lässt sich der Container hinter einen Reverse Proxy hängen (siehe [HTTPS](#https)).

## Updates

```bash
./update.sh            # prüft, zeigt den Changelog, sichert, spielt ein
./update.sh --check    # nur prüfen (Exit 10 = Update verfügbar)
```

Die Ausgaben von `update.sh` sind deutsch, wenn die Locale deutsch ist (`LANG=de_DE.UTF-8`),
sonst englisch. Fest einstellen lässt sich das mit `OPENNIT_LANG=de` bzw. `en`.

`update.sh` macht Folgendes:

1. Holt das neue Image. Der laufende Container bleibt dabei unverändert.
2. Zeigt alle Changelog-Abschnitte seit der installierten Version.
3. Warnt, wenn ein Abschnitt „Wichtig für dieses Update“ oder „Vor dem Einspielen lesen“
   vorkommt.
4. Sichert die Datenbank (Dump) und die Dateien (`persist`, `storage`, `uploads`) nach
   `./backups/` und hält das bisherige Image als `opennit-rollback:<version>-<zeit>` vor.
5. Startet die neue Version und wartet, bis sie gesund ist.
6. Behält 7 Backups und 3 Rollback-Images.

Einige Schritte, die der Changelog nennt, erledigt das Image selbst: `composer install`,
neue `storage`-Ordner und die Datenbank-Migrationen. Was darüber hinausgeht (z. B. Rollen
prüfen, Agent-Skripte neu verteilen), bleibt Handarbeit.

**Automatisch per Cron**, z. B. nachts:

```cron
30 3 * * *  cd /opt/opennit && ./update.sh -y >> backups/update.log 2>&1
```

Mit `-y` bricht das Skript mit Exit 2 ab, wenn das Update manuelle Schritte enthält.
Diese Updates spielst du dann interaktiv ein. `-y --force` überspringt auch diese Prüfung.

Ein schlichtes `docker compose up -d --pull always` aktualisiert OpenNIT ebenfalls,
inklusive Datenbank-Migrationen – aber ohne Backup, ohne Rollback-Image und ohne Warnung vor
manuellen Schritten.

Den eingebauten Updater in der OpenNIT-Weboberfläche **nicht** verwenden: Seine
Änderungen landen nur im Container und gehen beim nächsten Neustart verloren.

### Rollback

Jedes Backup-Verzeichnis enthält eine `ROLLBACK.txt` mit den fertigen Befehlen:
Datenbank-Dump einspielen, altes Image starten, bei Bedarf Dateien zurückspielen.
OpenNIT kann Schema-Migrationen nicht selbst zurückdrehen, deshalb gehören altes Image
und alte Datenbank immer zusammen.

## Persistente Daten

| Volume | Inhalt |
|---|---|
| `db` | MariaDB |
| `storage` | `storage/` (Dateien, Logs, Installationsmarker) |
| `uploads` | `public/uploads/` |
| `persist` | OpenNIT-`.env` mit **APP_KEY** und `config/runtime.php` |

**Ohne den APP_KEY aus `persist/.env` sind verschlüsselte Daten verloren.** Die
`update.sh`-Backups enthalten ihn. Die Dateien liegen mit Rechten 600 in `./backups/`
und sollten zusätzlich außerhalb des Servers gesichert werden.

## HTTPS

Den Container hinter einen Reverse Proxy (Traefik, Caddy, nginx) stellen und
`APP_URL=https://…` setzen. Wurde mit `http://` installiert, die OpenNIT-`.env` anpassen:

```bash
docker compose cp app:/var/www/opennit/persist/.env ./opennit.env
# APP_URL auf https://… ändern, Zeile SESSION_SECURE=false entfernen
docker compose cp ./opennit.env app:/var/www/opennit/persist/.env && docker compose restart app
rm opennit.env
```

## Lizenz

AGPL-3.0, wie OpenNIT selbst (siehe [LICENSE](LICENSE)). Der vollständige Quelltext von
OpenNIT liegt im Image unter `/var/www/opennit` und ist über
[opennit.de](https://opennit.de) erhältlich.
