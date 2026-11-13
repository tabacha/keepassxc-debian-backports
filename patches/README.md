# Eigene Patches

Es gibt zwei Arten von Patches:

| Verzeichnis | Wirkt auf | Angewendet mit |
|---|---|---|
| `packaging/*.patch` | das `debian/`-Verzeichnis (z.B. `debian/rules`, `debian/control`) | `patch -p1 --fuzz=0`, alphabetisch |
| `patches/` + `patches/series` | den Quellcode von KeePassXC, beide Suites | quilt, als `debian/patches/kpxc-backports/*` |
| `patches/stable/`, `patches/snapshot/` | den Quellcode, nur diese Suite | quilt, nach den gemeinsamen |

Alle Patches werden **ohne Fuzz** angewendet. Passt ein Patch nicht mehr exakt, bricht
der Build ab. Im Snapshot ist das das Signal, dass Upstream die Stelle geändert hat oder
den Fix schon enthält.

Quellcode-Patches landen im Source-Paket (`debian/patches/kpxc-backports/`) und werden
im `debian/changelog` aufgeführt. Sie sind also für alle Nutzer des Repos nachvollziehbar.

## Neuen Quellcode-Patch erstellen

```bash
# Source-Paket lokal erzeugen (oder Artifact aus der CI laden)
scripts/local-build.sh snapshot      # oder: nur der erste Schritt reicht
cd "$(mktemp -d)" && dpkg-source -x /pfad/zu/out/snapshot/source/keepassxc_*.dsc src && cd src

export QUILT_PATCHES=debian/patches
quilt push -a
quilt new kpxc-backports/0001-kurzbeschreibung.patch
quilt edit src/pfad/zur/datei.cpp
quilt refresh
quilt header -e     # DEP-3-Header ausfüllen, siehe unten
cp debian/patches/kpxc-backports/0001-kurzbeschreibung.patch <repo>/patches/
echo 0001-kurzbeschreibung.patch >> <repo>/patches/series
```

Danach im Repo **`REVISION` hochzählen** (die PR-Prüfung verlangt das) und einen PR öffnen.
Der PR baut und testet beide Suites.

## DEP-3-Header (Pflicht)

```
Description: Kurzbeschreibung in einer Zeile
 Längere Begründung: welches Problem, warum hier und nicht upstream.
Author: Name <mail>
Origin: upstream, https://github.com/keepassxreboot/keepassxc/commit/<sha>
Bug: https://github.com/keepassxreboot/keepassxc/issues/<nr>
Forwarded: https://github.com/keepassxreboot/keepassxc/pull/<nr> | not-needed | no
Last-Update: JJJJ-MM-TT
```

## Patch wieder entfernen

Datei löschen, Zeile aus der `series` entfernen, `REVISION` hochzählen.
Ist ein Fix in einer neuen Upstream-Version enthalten, fällt das spätestens beim
Snapshot-Build auf, weil sich der Patch dann nicht mehr anwenden lässt.
