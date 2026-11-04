#!/bin/sh
# Installs YStreamer on a Raspberry Pi that already runs Raspberry Pi OS, or
# on a Radxa ROCK 3A running Armbian trixie (vendor kernel):
#
#   curl -fsSL https://ystreamer.yarosfpv.com/install.sh | sudo sh
#
# Options, after `sh -s --` when piped:
#   --check   look the device over and verify the download, install nothing
#   --yes, -y don't ask before installing, or about a device that isn't supported
set -eu

MANIFEST_URL=${YSTREAMER_UPDATE_URL:-https://ystreamer.yarosfpv.com/update/manifest.json}
# The same key as update-key.pub, which the installed updater checks against
PUBLIC_KEY="PGdZ5XTTQ6j+TeKZfSTFty0xEbNqowNBXr4A9zPQvlo="
UPDATES=/var/lib/ystreamer/update
BOOT_CONFIG=/boot/firmware/config.txt
# The ROCK 3A's video decoder and encoder: Rockchip MPP and its GStreamer
# plugin, which Armbian doesn't carry, from Radxa's repository. The Pi's are
# in its kernel
ROCKCHIP_PACKAGES="librockchip-mpp1 librga2 gstreamer1.0-rockchip1"
RADXA_KEY=/etc/apt/keyrings/ystreamer-radxa.asc
RADXA_SOURCE=/etc/apt/sources.list.d/ystreamer-radxa.sources
RADXA_PIN=/etc/apt/preferences.d/ystreamer-radxa
# 1 when this script adds Radxa's repository itself; check_device decides
RADXA_REPO=
# pi, rockchip, or empty for anything else; check_device sets it
BOARD=

CHECK_ONLY=
ASSUME_YES=
for arg in "$@"; do
    case $arg in
    --check) CHECK_ONLY=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    *)
        echo "Unknown option $arg" >&2
        exit 2
        ;;
    esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# Asks on the terminal, since stdin is the script itself when piped from curl
confirm() {
    [ -z "$ASSUME_YES" ] || return 0
    [ -z "$CHECK_ONLY" ] || return 0
    if ! (: </dev/tty) 2>/dev/null; then
        die "${1:+$1 }Run again with --yes (or -y) to go ahead without being asked."
    fi
    printf '%s%s [y/N] ' "${1:+$1 }" "${2:-Continue anyway?}" >/dev/tty
    read -r answer </dev/tty
    case $answer in
    y | Y | yes) ;;
    *) die "Stopped." ;;
    esac
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "This needs $1, which isn't installed."
}

# A desktop that starts at boot holds the screen, so ours never gets it
boots_into_desktop() {
    [ "$(systemctl get-default 2>/dev/null)" = graphical.target ] &&
        systemctl is-enabled --quiet display-manager.service 2>/dev/null
}

desktop_warning() {
    say "WARNING: this system starts a desktop, which keeps the HDMI output for itself."
    say "YStreamer won't be able to show video on the screen. Switch the desktop off:"
    if [ "$BOARD" = pi ]; then
        say "use Raspberry Pi OS Lite, or sudo raspi-config (System Options > Boot)."
    else
        say "sudo systemctl set-default multi-user.target, then reboot."
    fi
}

# apt sources for Radxa's repository other than the one this script writes
radxa_sources() {
    grep -lsF radxa-repo.github.io /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null |
        grep -vxF "$RADXA_SOURCE" || true
}

# Radxa's rk3568-bookworm suite, which has MPP built for this chip; its
# packages install on trixie. The pin keeps everything else of Radxa's out,
# kernels and system packages above all. Writing the files again changes
# nothing
add_radxa_repo() {
    install -d -m 755 /etc/apt/keyrings
    # Radxa's signing keys, 2025 (which signs the repository now) and 2026:
    #   4AEC 3372 35A9 7EDD 397E  3DCD 67A4 74DD 4040 2951
    #   B70F 2845 D972 A6BE 9F30  836E 0862 F29C 32EF 42C7
    # When Radxa signs with a newer one, a YStreamer release replaces these
    cat >"$RADXA_KEY" <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
UItCG2dt63whSGLxhfMFsgVpepAQ1W3ZEQ==
=S9f0
-----END PGP PUBLIC KEY BLOCK-----
KEY
    chmod 644 "$RADXA_KEY"
    cat >"$RADXA_SOURCE" <<EOF
Types: deb
URIs: https://radxa-repo.github.io/rk3568-bookworm
Suites: rk3568-bookworm
Components: main
Signed-By: $RADXA_KEY
EOF
    cat >"$RADXA_PIN" <<EOF
Package: *
Pin: origin radxa-repo.github.io
Pin-Priority: -1

Package: $ROCKCHIP_PACKAGES
Pin: origin radxa-repo.github.io
Pin-Priority: 500
EOF
}

check_device() {
    arch=$(dpkg --print-architecture 2>/dev/null) || die "This isn't a Debian-based system."
    [ "$arch" = arm64 ] ||
        die "YStreamer needs a 64-bit (arm64) system; this one is $arch."

    model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
    case $model in
    "Raspberry Pi 4 Model B"*) BOARD=pi ;;
    "Raspberry Pi"*)
        BOARD=pi
        confirm "YStreamer is only tested on the Raspberry Pi 4 Model B; this is $model."
        ;;
    # Spelt both ways, by the 6.1 and the 5.10 kernels
    "Radxa ROCK 3"* | "Radxa ROCK3"*) BOARD=rockchip ;;
    *) confirm "YStreamer is only tested on the Raspberry Pi 4 Model B and the Radxa ROCK 3A; this is ${model:-an unknown device}." ;;
    esac

    codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
    case $BOARD:$codename in
    pi:trixie | rockchip:trixie) ;;
    pi:*) confirm "YStreamer is only tested on Raspberry Pi OS 13 (trixie); this is ${codename:-an unknown release}." ;;
    # The package is built for Debian 13 and doesn't install on an older one
    rockchip:*) die "On the ROCK 3A, YStreamer needs Armbian trixie (Debian 13) with the vendor kernel; this is ${codename:-an unknown release}." ;;
    *) confirm "YStreamer is only tested on Debian 13 (trixie); this is ${codename:-an unknown release}." ;;
    esac

    if [ "$BOARD" = rockchip ]; then
        [ -f /etc/armbian-release ] ||
            confirm "On the ROCK 3A, YStreamer is only tested on Armbian trixie with the vendor kernel; this doesn't look like Armbian."
        # Armbian's mainline kernels have no MPP
        if [ ! -e /dev/mpp_service ]; then
            no_mpp="This kernel has no Rockchip video decoder (/dev/mpp_service), so video would be decoded in software. Armbian's \"vendor\" image for the ROCK 3A has it."
            if [ -n "$CHECK_ONLY" ]; then warn "$no_mpp"; else confirm "$no_mpp"; fi
        fi
        # Radxa's own images already have its repository; a pin of ours would
        # hold back every other package of theirs
        if [ -n "$(radxa_sources)" ]; then
            say "The Rockchip video packages will come from the Radxa repository already set up here."
        else
            RADXA_REPO=1
        fi
        # Host or device is a switch on the board, not a boot setting
        [ -n "$(ls -A /sys/class/udc 2>/dev/null)" ] ||
            warn "No USB device controller: set the board's OTG switch to DEVICE, then reboot, or the goggles can't connect."
    elif [ ! -f "$BOOT_CONFIG" ]; then
        warn "$BOOT_CONFIG is missing, so the USB-C port can't be set up for the goggles."
    fi

    # Applies on the Compute Module 4 only, where it keeps the port a host
    if [ -f "$BOOT_CONFIG" ] && case $model in *"Compute Module 4"*) true ;; *) false ;; esac &&
        grep -q '^otg_mode=1' "$BOOT_CONFIG"; then
        warn "otg_mode=1 in $BOOT_CONFIG keeps the USB port in host mode; remove it for the goggles to connect."
    fi

    # Something else on port 80 would stop the web interface from starting
    if ! systemctl is-active --quiet ystreamer 2>/dev/null &&
        ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; then
        warn "Another program is already listening on port 80, which YStreamer's web interface uses."
    fi
}

# Prints: version, package URL, signature
read_manifest() {
    python3 - "$1" "$2" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
arch = sys.argv[2]
package = manifest["packages"].get(arch)
if not package:
    sys.exit(f"Version {manifest['version']} has no package for {arch} devices")
print(manifest["version"], package["url"], package["signature"])
PY
}

# Ed25519 over the whole file, as packaging/sign.sh makes it
verify() {
    {
        printf '\060\052\060\005\006\003\053\145\160\003\041\000'
        printf '%s' "$PUBLIC_KEY" | base64 -d
    } | openssl pkey -pubin -inform DER -out "$WORK/key.pem"
    printf '%s' "$2" | base64 -d >"$WORK/signature"
    openssl pkeyutl -verify -pubin -inkey "$WORK/key.pem" -rawin \
        -in "$1" -sigfile "$WORK/signature" >/dev/null 2>&1
}

# The boot settings the package would add, going by the list it carries
missing_boot_settings() {
    [ -f "$BOOT_CONFIG" ] || return 0
    dpkg-deb --fsys-tarfile "$1" | tar -xO ./usr/share/ystreamer/config.txt 2>/dev/null |
        while read -r line; do
            case $line in '' | '#'*) continue ;; esac
            grep -qxF "$line" "$BOOT_CONFIG" || printf '      %s\n' "$line"
        done
}

# Says what's about to change on this system, and waits for a yes
approve() {
    say
    case $change in
    install)
        say "YStreamer $version is ready to install. This will:"
        say "  - install the package and what it needs, such as GStreamer"
        if [ "$BOARD" = rockchip ]; then
            [ -z "$RADXA_REPO" ] ||
                say "  - add Radxa's package repository, limited to the video packages: $ROCKCHIP_PACKAGES"
            say "  - install the Rockchip video packages: $ROCKCHIP_PACKAGES"
        fi
        say "  - start YStreamer now and at every boot, using port 80 and the HDMI output"
        ;;
    reinstall)
        say "YStreamer $version is already installed. Running this again will:"
        say "  - reinstall the same version"
        ;;
    update)
        say "YStreamer $installed is installed. This will:"
        say "  - update it to $version"
        ;;
    downgrade)
        say "WARNING: YStreamer $installed is installed, which is newer than the latest"
        say "release. This will:"
        say "  - go back to $version"
        ;;
    esac
    if [ "$change" != install ]; then
        say "  - restart YStreamer, which finishes an open recording and pauses the"
        say "    streams and the HDMI output for a few seconds"
        say "  - keep its settings, login and recordings"
    fi
    settings=$(missing_boot_settings "$1")
    if [ -n "$settings" ]; then
        say "  - change $BOOT_CONFIG, keeping a copy of the original, by adding:"
        say "$settings"
        say
        say "WARNING: the USB-C port will be reserved for the goggles until YStreamer is"
        say "uninstalled. It can still power the Pi, but nothing else plugged into it will"
        say "work. This takes effect after a reboot."
    elif [ -f "$BOOT_CONFIG" ]; then
        say "  - leave $BOOT_CONFIG as it is: it already has what YStreamer needs"
    fi
    if boots_into_desktop; then
        say
        desktop_warning
    fi
    say
    if [ "$change" = downgrade ]; then
        # --yes covers the usual questions, not quietly going back a version
        (: </dev/tty) 2>/dev/null ||
            die "Going back to an older version has to be confirmed; run this from a terminal."
        ASSUME_YES=
        confirm "" "Go back to $version?"
    else
        confirm "" "Continue?"
    fi
}

for tool in curl python3 openssl base64 dpkg tar; do
    need "$tool"
done
if [ -z "$CHECK_ONLY" ] && [ "$(id -u)" != 0 ]; then
    die "Run this as root, for example with sudo."
fi

check_device

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

say "Looking up the latest version..."
curl -fsSL "$MANIFEST_URL" -o "$WORK/manifest.json" ||
    die "Couldn't reach the update server at $MANIFEST_URL."
release=$(read_manifest "$WORK/manifest.json" "$arch") || die "The update server sent something unexpected."
set -- $release
version=$1
url=$2
signature=$3

say "Downloading YStreamer $version..."
DEB=$WORK/ystreamer.deb
curl -fsSL "$url" -o "$DEB" || die "Couldn't download $url."
verify "$DEB" "$signature" ||
    die "The download's signature doesn't match, so it wasn't installed."
[ "$(dpkg-deb -f "$DEB" Package)" = ystreamer ] || die "The download isn't YStreamer."
say "Signature verified."

# What's on the device already decides between installing, updating,
# reinstalling and going back to an older version
installed=$(dpkg-query -W -f='${db:Status-Status} ${Version}' ystreamer 2>/dev/null || true)
case $installed in
"installed "*)
    installed=${installed#installed }
    if dpkg --compare-versions "$installed" eq "$(dpkg-deb -f "$DEB" Version)"; then
        change=reinstall
    elif dpkg --compare-versions "$installed" lt "$(dpkg-deb -f "$DEB" Version)"; then
        change=update
    else
        change=downgrade
    fi
    installed=${installed%-*}
    ;;
*) change=install ;;
esac

if [ -n "$CHECK_ONLY" ]; then
    if boots_into_desktop; then
        desktop_warning
    fi
    case $change in
    install) say "This device is ready for YStreamer $version. Nothing was installed." ;;
    reinstall) say "YStreamer $version is already installed, the latest version. Nothing was changed." ;;
    update) say "YStreamer $installed is installed; running this would update it to $version. Nothing was changed." ;;
    downgrade) say "YStreamer $installed is installed, newer than the latest release ($version). Nothing was changed." ;;
    esac
    exit 0
fi

approve "$DEB"

before=$(cksum 2>/dev/null <"$BOOT_CONFIG" || true)
# _apt can't read our private folder, and apt would only say so
chmod 755 "$WORK"
chmod 644 "$DEB"
say "Installing..."
if [ "$BOARD" = rockchip ]; then
    [ -z "$RADXA_REPO" ] || add_radxa_repo
    # Radxa's repository out of reach shouldn't stop the install
    apt-get update -q ||
        warn "Couldn't update every package list; the Rockchip video packages may not install."
else
    apt-get update -q
fi
if [ "$BOARD" = rockchip ]; then
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y $ROCKCHIP_PACKAGES ||
        warn "Couldn't install $ROCKCHIP_PACKAGES; without them the video is decoded in software."
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "$DEB"

# The updater goes back to current.deb if a later version doesn't start, and
# System → Updates can roll back to previous.deb, as after an update from there
mkdir -p "$UPDATES"
if [ "$change" != reinstall ] && [ -f "$UPDATES/current.deb" ]; then
    mv -f "$UPDATES/current.deb" "$UPDATES/previous.deb"
fi
cp "$DEB" "$UPDATES/current.deb"

# Port 80, or 8080 when something else had 80. Asking for the version means
# the one answering is the one just installed
answering() {
    for port in 80 8080; do
        curl -fs --max-time 2 "http://localhost:$port/health" 2>/dev/null |
            grep -qF "\"version\":\"$version\"" && return 0
    done
    return 1
}
tries=0
until answering; do
    tries=$((tries + 1))
    if [ $tries -ge 30 ]; then
        warn "YStreamer was installed but isn't answering. See: journalctl -u ystreamer"
        exit 1
    fi
    sleep 2
done
address=http://$(hostname).local
[ "$port" = 80 ] || address=$address:$port

say
say "YStreamer $version is running: $address"
if [ "$before" != "$(cksum 2>/dev/null <"$BOOT_CONFIG" || true)" ]; then
    say "Reboot before connecting the goggles: the USB-C port was just set up for them."
fi
