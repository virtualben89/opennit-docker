# OpenNIT – Docker image

**English** · [Deutsch](README.de.md)

Unofficial Docker image for [OpenNIT](https://opennit.de), the self-hosted IT
documentation. It replaces the native `install.sh`: Apache + PHP 8.4 (mod_php) in the
image, MariaDB as a separate container, initial setup runs automatically on first start.

> **Note:** This project is not affiliated with the OpenNIT project. It packages the
> unmodified release from the official update server (channel “stable”). Please report
> bugs in OpenNIT itself there, bugs in the container here.

The image is rebuilt automatically as soon as a new OpenNIT version is released
(checked daily at 6:00 German time) and is published in the GitHub Container Registry:

| Tag | Content |
|---|---|
| `:1.2.2` | exactly this version |
| `:1.2` | latest 1.2.x (bug fixes only) |
| `:1` / `:latest` | latest 1.x |
| `:sha-ce7e633` | exactly this upstream commit |

Every new version gets a [GitHub release](../../releases) with its changelog section.
Releases with manual steps carry a warning. OpenNIT itself is available in German and
English; its changelog is written in German only.

### Security

- **Slim image:** the compilers and build tools of the PHP base image are removed after
  the extensions are compiled, and no MariaDB client is included. All Debian security
  updates are applied at build time.
- **Weekly security scan:** every Monday the workflow scans the published image with
  [Trivy](https://trivy.dev). If package updates have become available for HIGH/CRITICAL
  vulnerabilities, the same OpenNIT version is rebuilt with current system packages and
  published under the same tags (without a new release). `update.sh` reports this as a
  “security rebuild”.
- Every build is scanned again afterwards; the result is shown in the workflow run summary.
- Remaining findings affect Debian packages for which Debian does not (yet) provide a fix
  (e.g. curl, libxml2) and which PHP needs at runtime.

Check it yourself:

```bash
docker run --rm aquasec/trivy:0.76.2 image --severity HIGH,CRITICAL ghcr.io/virtualben89/opennit:1
```

## Installation

No need to clone the repository, three files are enough:

```bash
mkdir opennit && cd opennit
base=https://raw.githubusercontent.com/virtualben89/opennit-docker/main
curl -fsSL -O $base/docker-compose.yml -O $base/update.sh
curl -fsSL $base/.env.example -o .env && chmod +x update.sh
nano .env                 # set OPENNIT_IMAGE, APP_URL, ADMIN_EMAIL and passwords
docker compose up -d
docker compose logs -f app
```

Then log in at `APP_URL` with `ADMIN_EMAIL` / `ADMIN_PASSWORD`. `ADMIN_PASSWORD` is only
needed for the initial setup and can be removed from `.env` afterwards. The interface
language can be switched in OpenNIT itself.

The compose file always uses the prebuilt image from the registry. You can build your own
image with `docker build -t opennit:custom .` and use it via `OPENNIT_IMAGE=opennit:custom`.
`update.sh` does not work in that case, because it pulls the image from the registry.

Bind mounts (e.g. `/srv/opennit/storage`) work instead of the named volumes, and without
`ports` the container can sit behind a reverse proxy (see [HTTPS](#https)).

## Updates

```bash
./update.sh            # checks, shows the changelog, backs up, applies
./update.sh --check    # check only (exit 10 = update available)
```

`update.sh` prints German messages if the locale is German (`LANG=de_DE.UTF-8`) and English
otherwise. Set `OPENNIT_LANG=en` or `de` to choose explicitly.

`update.sh` does the following:

1. Pulls the new image. The running container stays untouched.
2. Shows all changelog sections since the installed version.
3. Warns if a section “Wichtig für dieses Update” (important for this update) or
   “Vor dem Einspielen lesen” (read before applying) is present.
4. Backs up the database (dump) and the files (`persist`, `storage`, `uploads`) to
   `./backups/` and keeps the previous image as `opennit-rollback:<version>-<time>`.
5. Starts the new version and waits until it is healthy.
6. Keeps 7 backups and 3 rollback images.

Some steps named in the changelog are handled by the image itself: `composer install`,
new `storage` folders and the database migrations. Anything beyond that (e.g. reviewing
roles, redeploying agent scripts) remains manual work.

**Automatically via cron**, e.g. at night:

```cron
30 3 * * *  cd /opt/opennit && ./update.sh -y >> backups/update.log 2>&1
```

With `-y` the script aborts with exit 2 if the update contains manual steps. Apply those
updates interactively. `-y --force` skips this check as well.

A plain `docker compose up -d --pull always` also updates OpenNIT, including the database
migrations – but without a backup, without a rollback image and without a warning about
manual steps.

Do **not** use the built-in updater in the OpenNIT web interface: its changes only end up
in the container and are lost on the next restart.

### Rollback

Every backup directory contains a `ROLLBACK.txt` with ready-to-run commands: restore the
database dump, start the old image, restore files if needed. OpenNIT cannot roll back
schema migrations by itself, so old image and old database always belong together.

## Persistent data

| Volume | Content |
|---|---|
| `db` | MariaDB |
| `storage` | `storage/` (files, logs, installation marker) |
| `uploads` | `public/uploads/` |
| `persist` | OpenNIT `.env` with **APP_KEY** and `config/runtime.php` |

**Without the APP_KEY from `persist/.env`, encrypted data is lost.** The `update.sh`
backups contain it. They are stored with mode 600 in `./backups/` and should also be
backed up off the server.

## HTTPS

Put the container behind a reverse proxy (Traefik, Caddy, nginx) and set
`APP_URL=https://…`. If it was installed with `http://`, adjust the OpenNIT `.env`:

```bash
docker compose cp app:/var/www/opennit/persist/.env ./opennit.env
# change APP_URL to https://…, remove the line SESSION_SECURE=false
docker compose cp ./opennit.env app:/var/www/opennit/persist/.env && docker compose restart app
rm opennit.env
```

## License

AGPL-3.0, like OpenNIT itself (see [LICENSE](LICENSE)). The complete OpenNIT source code
is included in the image under `/var/www/opennit` and is available from
[opennit.de](https://opennit.de).
