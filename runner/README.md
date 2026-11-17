# Build runner / Build-Runner

**English** · [Deutsch](#deutsch)

Runs the image build on your own hardware instead of GitHub's runners. The workflow,
schedule, releases and the GitHub Container Registry stay as they are – only the job
runs on your machine.

The stack consists of two containers:

- **runner** – the official GitHub Actions runner image plus the GitHub CLI
- **dind** – its own Docker daemon. Build jobs neither see nor touch the host's
  containers (e.g. a running OpenNIT).

Requirements: Docker with Compose, x86_64, about 10 GB of free disk space. The arm64
variant of the image is built via QEMU emulation.

## Setup

```bash
git clone https://github.com/virtualben89/opennit-docker.git
cd opennit-docker/runner

# One-time registration token (valid for 1 hour), alternatively from
# Settings → Actions → Runners → New self-hosted runner
echo "RUNNER_TOKEN=$(gh api -X POST repos/virtualben89/opennit-docker/actions/runners/registration-token --jq .token)" > .env
docker compose up -d --build
docker compose logs -f runner     # wait for "Listening for Jobs"
```

The registration is stored in the `state` volume; `RUNNER_TOKEN` can then be removed
from `.env`.

Then route the workflow to the runner by setting the repository variable `RUNS_ON`:

```bash
gh variable set RUNS_ON -R virtualben89/opennit-docker -b '["self-hosted","opennit-build"]'
```

## Switching back to GitHub's runners

If the server is unavailable, jobs wait for the runner and fail after 24 hours. To build
on GitHub again, delete the variable:

```bash
gh variable delete RUNS_ON -R virtualben89/opennit-docker
```

## Security

The repository is public. A self-hosted runner must never run code from strangers
without review, otherwise anyone could execute commands on your server through a
pull request. Therefore:

- Under *Settings → Actions → General → Fork pull request workflows* the option
  **“Require approval for all external contributors”** is enabled. Only approve
  workflow runs from pull requests after reading their changes.
- The workflow only reacts to its schedule, to manual starts and to pushes to `main`.
- The `dind` container runs privileged. Run the stack only on a host where that is
  acceptable.

## Maintenance

- The runner updates itself. After a container restart it fetches the update again.
- Clean up old build data in the Docker daemon from time to time:
  `docker compose exec dind docker system prune -af`
- Remove the runner: `docker compose down -v`, then delete it under
  *Settings → Actions → Runners*.

---

## Deutsch

Führt den Image-Build auf eigener Hardware statt auf den Runnern von GitHub aus.
Workflow, Zeitplan, Releases und die GitHub Container Registry bleiben unverändert –
nur der Job läuft auf deinem Rechner.

Der Stack besteht aus zwei Containern:

- **runner** – das offizielle Runner-Image von GitHub Actions plus GitHub-CLI
- **dind** – ein eigener Docker-Daemon. Build-Jobs sehen und berühren die Container
  des Hosts nicht (z. B. ein laufendes OpenNIT).

Voraussetzungen: Docker mit Compose, x86_64, etwa 10 GB freier Speicher. Die
arm64-Variante des Images entsteht per QEMU-Emulation.

### Einrichtung

```bash
git clone https://github.com/virtualben89/opennit-docker.git
cd opennit-docker/runner

# Einmaliges Registrierungs-Token (1 Stunde gültig), alternativ über
# Settings → Actions → Runners → New self-hosted runner
echo "RUNNER_TOKEN=$(gh api -X POST repos/virtualben89/opennit-docker/actions/runners/registration-token --jq .token)" > .env
docker compose up -d --build
docker compose logs -f runner     # warten auf "Listening for Jobs"
```

Die Registrierung liegt danach im Volume `state`; `RUNNER_TOKEN` kann aus der `.env`
entfernt werden.

Anschließend den Workflow über die Repo-Variable `RUNS_ON` auf den Runner umstellen:

```bash
gh variable set RUNS_ON -R virtualben89/opennit-docker -b '["self-hosted","opennit-build"]'
```

### Zurück zu den GitHub-Runnern

Ist der Server nicht erreichbar, warten Jobs auf den Runner und scheitern nach
24 Stunden. Um wieder bei GitHub zu bauen, die Variable löschen:

```bash
gh variable delete RUNS_ON -R virtualben89/opennit-docker
```

### Sicherheit

Das Repo ist öffentlich. Ein Self-hosted Runner darf niemals ungeprüft fremden Code
ausführen, sonst könnte jeder über einen Pull-Request Befehle auf deinem Server
ausführen. Deshalb:

- Unter *Settings → Actions → General → Fork pull request workflows* ist
  **„Require approval for all external contributors“** aktiv. Workflow-Läufe aus
  Pull-Requests nur freigeben, nachdem du die Änderungen gelesen hast.
- Der Workflow reagiert nur auf seinen Zeitplan, manuelle Starts und Pushes auf `main`.
- Der `dind`-Container läuft privilegiert. Den Stack nur auf einem Host betreiben, auf
  dem das vertretbar ist.

### Wartung

- Der Runner aktualisiert sich selbst. Nach einem Neustart des Containers lädt er das
  Update erneut.
- Alte Build-Daten im Docker-Daemon gelegentlich aufräumen:
  `docker compose exec dind docker system prune -af`
- Runner entfernen: `docker compose down -v`, danach unter
  *Settings → Actions → Runners* löschen.
