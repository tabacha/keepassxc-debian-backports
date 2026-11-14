# keepassxc-debian-backports

Aktuelle [KeePassXC](https://keepassxc.org)-Versionen für **Debian 13 (trixie)** als
signiertes APT-Repository, automatisch gebaut und getestet mit GitHub Actions.

## Installation

```bash
sudo curl -fsSLo /etc/apt/sources.list.d/keepassxc-backports-stable.sources \
  https://tabacha.github.io/keepassxc-debian-backports/keepassxc-backports-stable.sources
sudo apt update
sudo apt install keepassxc-full
```

Die `.sources`-Datei enthält den Signing-Key direkt (`Signed-By:` inline). Ein
separater Keyring ist nicht nötig. Wird der Signing-Key erneuert (spätestens vor
Ablauf, alle zwei Jahre), den `curl`-Befehl einfach erneut ausführen.

`keepassxc-minimal` statt `keepassxc-full` installiert die Variante ohne
Browser-Integration, SSH-Agent und Secret Service.

### Snapshot

Die Snapshot-Suite enthält jeweils das neueste KeePassXC-Release. Sie wird täglich
automatisch gebaut und getestet, aber ohne manuelle Freigabe veröffentlicht.

```bash
sudo curl -fsSLo /etc/apt/sources.list.d/keepassxc-backports-snapshot.sources \
  https://tabacha.github.io/keepassxc-debian-backports/keepassxc-backports-snapshot.sources
```

| Suite | Inhalt | Veröffentlichung |
|---|---|---|
| `trixie-keepassxc` (stable) | Version aus [`VERSION`](VERSION) | nach Review und manueller Freigabe |
| `trixie-keepassxc-snapshot` | neuestes Upstream-Release | täglich automatisch |

Beide Suites haben eigene Signing-Keys.

### Versionen

`2.8.0+dfsg1-1~kpxc13+1` (stable) bzw. `…~kpxc13+0~snapJJJJMMTThhmm` (snapshot).
Bei gleicher Basis ist stable immer höher als snapshot, und beide sind niedriger
als ein späteres reguläres Debian-Paket derselben Version. Ein Wechsel zurück auf
Debians eigene Pakete funktioniert also ohne Downgrade.

### Entfernen

```bash
sudo rm /etc/apt/sources.list.d/keepassxc-backports-*.sources
sudo apt update
```

## Wie gebaut wird

```
snapshot.yml (cron)        stable.yml (push auf main)          pr.yml (Pull Request)
      │                           │                                   │
      ▼                           ▼                                   ▼
 build.yml ── source ── Debian-Source aus trixie/forky/sid (apt prüft Archiv-Signatur)
      │                 oder Upstream-Tarball via uscan (GPG-Signatur, Key gepinnt)
      │                 + packaging/*.patch + patches/ (quilt, fuzz=0)
      ├──── binary ──── amd64 + arm64, unprivilegiert, ctest inkl. GUI-Tests unter Xvfb,
      │                 ≥4 erfolgreiche Testläufe erzwungen, lintian --fail-on error
      └──── smoke ───── frischer Container: Debian-13-Version installieren, DB anlegen,
                        Upgrade, DB lesen, Wechsel auf -minimal
      ▼
 attest.yml ── SLSA-Build-Provenance (nur dieser Job bekommt ein OIDC-Token)
      ▼
 publish.yml ── Environment release/snapshot ── signiert InRelease/Release.gpg,
                prüft Signatur gegen keys/repo-<suite>.asc, erzeugt die .sources-Datei
                mit eingebettetem Key, pusht gh-pages
      ▼
 promote (nur snapshot) ── PR "VERSION → neue Version" für Stable
```

### Sicherheitsprinzipien

- **Keine Secrets im Repo.** Die Signing-Subkeys liegen nur in GitHub-Environments,
  die Primärschlüssel offline ([keys/README.md](keys/README.md)).
- **Build und Signieren sind getrennt.** Die Jobs, die KeePassXC-Code bauen und
  testen, haben keinen Zugriff auf Secrets. Der Publish-Job führt nur Skripte aus
  diesem Repo aus.
- **Stable braucht eine menschliche Freigabe**: PR-Review plus Required Reviewer der
  Environment `release`.
- **Vertrauenskette der Quellen**: Debian-Archiv-Signatur oder Upstream-GPG-Signatur
  mit gepinntem Fingerprint (`UPSTREAM_KEY_FPR` in `config.env`).
- **Alles gepinnt**: Actions auf Commit-SHA, Container-Image auf Digest. Wird in
  jedem PR geprüft (`scripts/check-pins.sh`), Dependabot aktualisiert die Actions.
- **Minimale Token-Rechte**: `permissions: {}` als Default, Schreibrechte nur dort,
  wo nötig.
- **Tests sind Pflicht**: `nocheck` ist verboten, und Debians `|| true` bei den
  CLI/GUI-Tests wird durch drei Wiederholungen mit hartem Fehler ersetzt
  ([packaging/0001-fatal-cli-gui-tests.patch](packaging/0001-fatal-cli-gui-tests.patch)).

## Patches

Siehe [patches/README.md](patches/README.md). Kurz gesagt:

- `packaging/*.patch` ändert das `debian/`-Verzeichnis.
- `patches/series` und `patches/*.patch` sind Quellcode-Patches für beide Suites.
- `patches/stable/` und `patches/snapshot/` gelten nur für die jeweilige Suite.
- Bei gleicher `VERSION` muss jede Änderung daran **`REVISION` hochzählen**, das
  prüft die CI.

## Einrichtung (einmalig)

1. Signing-Keys für stable und snapshot erzeugen, siehe [keys/README.md](keys/README.md).
   `keys/repo-*.asc` committen und die Fingerprints in `config.env` eintragen.
2. In `config.env` `MAINTAINER_NAME` und `MAINTAINER_EMAIL` setzen.
3. GitHub → *Settings*:
   - *Environments*: `release` (Required Reviewer, nur `main`) und `snapshot`
     (nur `main`), jeweils mit Secret `REPO_SIGNING_KEY`.
   - *Branches*: Schutzregel für `main` mit PR-Pflicht und den Required Checks
     `lint`, `build-stable / …` und `build-snapshot / …`.
   - *Actions → General*: „Read repository contents permission“ als Default und
     „Allow GitHub Actions to create … pull requests“ für den Promote-PR.
   - *Pages*: Source „Deploy from a branch“, Branch `gh-pages`, `/` (erst nach dem
     ersten Publish möglich).
4. Workflow **snapshot** manuell starten (*Actions → snapshot → Run workflow*). Danach
   **stable** starten und in der Environment `release` freigeben.

### Bekannte Einschränkung

PRs, die mit dem `GITHUB_TOKEN` erstellt werden (Promote-PR), lösen selbst keine
Workflows aus. Den PR daher einmal schließen und wieder öffnen, damit die
PR-Checks laufen. Alternative: eine GitHub App mit eigenem Token.

## Lokal bauen

```bash
scripts/local-build.sh stable        # oder snapshot; braucht docker oder podman
```

Das Ergebnis liegt unter `out/<suite>/` und entsteht mit denselben Schritten und
demselben Image wie in der CI.

## Image-Digest aktualisieren

Dependabot aktualisiert keine `container:`-Images. Gelegentlich den Digest von
`debian:trixie` neu bestimmen, in `config.env` **und** in allen Workflows ersetzen.
`scripts/check-pins.sh` prüft, dass beides übereinstimmt.
