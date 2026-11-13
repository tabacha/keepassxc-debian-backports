#!/bin/bash
# Installiert die Werkzeuge für einen CI-Schritt im debian:trixie-Container.
# Usage: install-deps.sh <source|binary|smoke|publish>
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q --no-install-recommends)

case ${1:-} in
    source)  pkgs=(ca-certificates curl jq dpkg-dev devscripts quilt patch xz-utils
                   gnupg gpgv libwww-perl liblwp-protocol-https-perl libfile-dirlist-perl) ;;
    binary)  pkgs=(ca-certificates dpkg-dev build-essential fakeroot lintian devscripts) ;;
    smoke)   pkgs=(ca-certificates) ;;
    publish) pkgs=(ca-certificates apt-utils gnupg gpgv git xz-utils) ;;
    *) echo "usage: $0 <source|binary|smoke|publish>" >&2; exit 2 ;;
esac

apt-get update -q
"${APT[@]}" install "${pkgs[@]}"
