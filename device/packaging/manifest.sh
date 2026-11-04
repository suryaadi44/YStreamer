#!/bin/sh
# Writes the manifest.json devices look for: manifest.sh <file.deb>... <base-url>
# Each package and its .sig (from sign.sh) must then be served at <base-url>/
# The notes are the version's section of CHANGELOG.md
#
# One package per architecture: the Pi and the ROCK 3A both run Debian 13
# and share the arm64 one
set -e
[ $# -ge 2 ] || {
    echo "usage: manifest.sh <file.deb>... <base-url>" >&2
    exit 2
}
CHANGELOG=$(dirname "$0")/../../CHANGELOG.md
# The last argument
for BASE; do :; done
BASE=${BASE%/}
OUT=$(dirname "$1")/manifest.json
LIST=$(mktemp)
# A failure leaves the last good manifest in place
trap 'rm -f "$OUT.tmp" "$LIST"' EXIT
while [ $# -gt 1 ]; do
    DEB=$1
    shift
    printf '%s\t%s\t%s\t%s\n' "$(dpkg-deb -f "$DEB" Version)" "$(dpkg-deb -f "$DEB" Architecture)" \
        "$BASE/$(basename "$DEB")" "$(cat "$DEB.sig")" >>"$LIST"
done
python3 - "$LIST" "$CHANGELOG" >"$OUT.tmp" <<'PY'
import json, re, sys
listing, changelog = sys.argv[1:]
packages = {}
versions = set()
for line in open(listing):
    full, arch, url, signature = line.rstrip("\n").split("\t")
    version = full.partition("-")[0]
    versions.add(version)
    if arch in packages:
        sys.exit(f"Two packages for {arch}")
    packages[arch] = {"url": url, "signature": signature}
if len(versions) != 1:
    sys.exit(f"The packages aren't all the same version: {sorted(versions)}")
version = versions.pop()
notes = ""
for section in re.split(r"^## ", open(changelog).read(), flags=re.M)[1:]:
    heading, _, body = section.partition("\n")
    if heading.split()[0].strip("[]") == version:
        notes = body.strip()
if not notes:
    sys.exit(f"CHANGELOG.md has no section for {version}")
json.dump({"version": version, "notes": notes, "packages": packages}, sys.stdout, indent=2)
PY
mv "$OUT.tmp" "$OUT"
echo "$OUT"
