# Signing-Keys

Es gibt **zwei unabhängige Schlüssel**:

| Datei | Suite | GitHub-Environment | Freigabe |
|---|---|---|---|
| `repo-stable.asc` | `trixie-keepassxc` | `release` | Required Reviewer |
| `repo-snapshot.asc` | `trixie-keepassxc-snapshot` | `snapshot` | automatisch |

Hier liegen **nur die öffentlichen Schlüssel**. Die geheimen Signing-Subkeys liegen
ausschließlich als Environment-Secret `REPO_SIGNING_KEY` in GitHub. Die Primärschlüssel
bleiben offline.

## Schlüssel erzeugen (am besten auf einem Offline-Rechner / Live-System)

Für jede Suite (`stable`, dann `snapshot`):

```bash
SUITE=stable
export GNUPGHOME=$(mktemp -d)

# Primärschlüssel: nur zum Zertifizieren, läuft nicht ab, bleibt offline
gpg --quick-gen-key "KeePassXC Debian Backports ($SUITE)" ed25519 cert never
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')

# Signing-Subkey mit Ablaufdatum – nur der kommt in die CI
gpg --quick-add-key "$FPR" ed25519 sign 2y

# Öffentlichen Schlüssel ins Repo
gpg --armor --export "$FPR" > keys/repo-$SUITE.asc
echo "SIGNING_FPR_${SUITE^^}=\"$FPR\""   # -> in config.env eintragen

# NUR den Subkey exportieren (das "!" hinter dem Subkey-Fingerprint ist wichtig)
SUBFPR=$(gpg --list-keys --with-colons "$FPR" | awk -F: '/^sub/{s=1;next} s&&/^fpr/{print $10; exit}')
gpg --armor --export-secret-subkeys "${SUBFPR}!" > $SUITE-signing-subkey.asc

# Backup des kompletten Schlüssels (inkl. Primärschlüssel) offline sichern,
# z.B. auf zwei USB-Sticks und/oder mit paperkey:
gpg --armor --export-secret-keys "$FPR" > $SUITE-FULL-BACKUP.asc
gpg --output $SUITE-revoke.asc --gen-revoke "$FPR"
```

Optional kann der Subkey eine Passphrase haben. Dann kommt sie als zweites Secret
`REPO_SIGNING_PASSPHRASE` in dieselbe Environment. Viel Sicherheit bringt das nicht,
weil beides am selben Ort liegt.

## In GitHub hinterlegen

1. *Settings → Environments → New environment* `release`
   - *Required reviewers*: du selbst
   - *Deployment branches*: nur `main`
   - Secret `REPO_SIGNING_KEY` = Inhalt von `stable-signing-subkey.asc`
2. Environment `snapshot`
   - *Deployment branches*: nur `main`, keine Reviewer
   - Secret `REPO_SIGNING_KEY` = Inhalt von `snapshot-signing-subkey.asc`
3. `*-signing-subkey.asc` lokal sicher löschen (`shred -u`). `.gitignore` schützt zusätzlich.

## Subkey erneuern (vor Ablauf) oder nach Kompromittierung

```bash
gpg --import $SUITE-FULL-BACKUP.asc           # offline
gpg --quick-set-expire "$FPR" 2y "$SUBFPR"    # verlängern
#   oder bei Kompromittierung: alten Subkey widerrufen, neuen anlegen
gpg --edit-key "$FPR"   # key N / revkey / save;  dann gpg --quick-add-key ...
gpg --armor --export "$FPR" > keys/repo-$SUITE.asc   # aktualisierten Public Key committen
```

Der Primär-Fingerprint bleibt dabei gleich. Nutzer müssen nur die aktualisierte
`.gpg`-Datei neu herunterladen, ihr Trust-Anchor ändert sich nicht.
