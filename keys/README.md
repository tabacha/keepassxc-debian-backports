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

Im Wurzelverzeichnis eines Klons dieses Repos ausführen. `OUT` muss **außerhalb**
des Repos liegen; dort landen die geheimen Dateien.

```bash
OUT=~/keepassxc-keys            # später auf USB-Stick/Offline-Medium verschieben
umask 077                       # geheime Dateien nur für dich lesbar
mkdir -p "$OUT"

for SUITE in stable snapshot; do
  export GNUPGHOME=$(mktemp -d)
  nopass=(--batch --pinentry-mode loopback --passphrase '')

  # Primärschlüssel: nur zum Zertifizieren, läuft nicht ab, bleibt offline
  gpg "${nopass[@]}" --quick-gen-key "KeePassXC Debian Backports ($SUITE)" ed25519 cert never
  FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')

  # Signing-Subkey mit Ablaufdatum – nur der kommt in die CI
  gpg "${nopass[@]}" --quick-add-key "$FPR" ed25519 sign 2y
  SUBFPR=$(gpg --list-keys --with-colons "$FPR" | awk -F: '/^sub/{s=1;next} s&&/^fpr/{print $10; exit}')

  # Öffentlicher Schlüssel + Fingerprint ins Repo
  gpg --armor --export "$FPR" > "keys/repo-$SUITE.asc"
  sed -i "s/^SIGNING_FPR_${SUITE^^}=.*/SIGNING_FPR_${SUITE^^}=\"$FPR\"/" config.env

  # NUR den Subkey exportieren (das "!" ist wichtig) – ohne Passphrase, für das GitHub-Secret
  gpg "${nopass[@]}" --armor --export-secret-subkeys "${SUBFPR}!" > "$OUT/$SUITE-signing-subkey.asc"

  # ERST JETZT eine Passphrase setzen und das Voll-Backup exportieren
  gpg --passwd "$FPR"
  gpg --armor --export-secret-keys "$FPR" > "$OUT/$SUITE-FULL-BACKUP.asc"
  cp "$GNUPGHOME/openpgp-revocs.d/$FPR.rev" "$OUT/$SUITE-revoke.asc"

  gpgconf --kill all; rm -rf "$GNUPGHOME"; unset GNUPGHOME
done
ls -l "$OUT"; git diff --stat
```

So liegt die Passphrase des Backups nie in GitHub, und der CI-Subkey ist
unabhängig davon. Wer dem Subkey trotzdem eine Passphrase geben will, legt sie als
zweites Secret `REPO_SIGNING_PASSPHRASE` in dieselbe Environment. Viel Sicherheit
bringt das nicht, weil beides am selben Ort liegt.

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
