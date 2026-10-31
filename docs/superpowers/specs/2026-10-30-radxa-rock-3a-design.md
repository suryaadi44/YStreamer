# Radxa ROCK 3A support

## Intent

YStreamer runs on the Raspberry Pi 4 only. The owner has a working Rust
receiver for DJI Goggles 2 on the Radxa ROCK 3A (the `notcosmo` project,
bring-up log and fixtures in that repo), and wants YStreamer to run on the same
board: the goggles link over the board's OTG port, and the video on HDMI
through the Rockchip hardware, installed from the package the way the Pi is.

Everything board-specific in this design comes from that bring-up, which was
verified on real hardware (Radxa rsdk r2 bookworm image, kernel 6.1 rk2410,
Goggles 2 with an O4 Pro air unit). Nothing here has been run on a ROCK 3A
yet; the verification steps at the end say how.

## Goals

- The USB gadget binds on the ROCK 3A's dwc3 controller (`fcc00000.usb`), with
  the hardware OTG switch on DEVICE, and the goggles enumerate it as an Android
  accessory the way they do on the Pi.
- HDMI output decodes with the Rockchip MPP decoder (`mppvideodec`) and shows on
  a display plane that takes NV12; the logo keeps its own plane.
- USB cameras encode with the Rockchip encoder (`mpph264enc`) when present.
- The package installs on Radxa's bookworm image with `install.sh`, and the
  built-in updater keeps it on the right build afterwards.
- Nothing Pi-specific misfires on the ROCK 3A: in particular the factory-reset
  GPIO pin, which on another board could be wired to anything.
- A documented way to build the bookworm package on a Mac (Docker), and a docs
  page for the board.

## Non-goals

- A ready-made SD card image for the ROCK 3A. The Radxa image plus `install.sh`
  is the install path.
- The in-process MPP backend `notcosmo` has. GStreamer's `mppvideodec` is what
  the bring-up measured at 12-15% of a core; good enough, and it keeps one
  pipeline for both boards.
- H.265 from the goggles (YStreamer is H.264 end to end).
- The record button and reset pin on the ROCK 3A's header: the pin numbering
  is another board's. They are off there, not remapped.
- Wi-Fi hot-spot on the ROCK 3A: the board has no radio without an M.2 module.
  NetworkManager handles whatever is fitted; nothing changes.
- Translations of the new docs page (`es`, `uk`): English only for now.

## Anti-goals

- Changing what the Pi does. Every board-specific branch picks the Pi's current
  behaviour on a Pi; the tests pin that.
- Guessing a plane id, decoder name or UDC name. They are discovered at run
  time, so another Rockchip board or kernel has a chance to work.

## Constraints

- Radxa's image is Debian 12 bookworm: glibc 2.36, GStreamer 1.22. The release
  package is built on trixie and does not install there. A second package is
  needed, with revision `1~bookworm`.
- `gstreamer1.0-rockchip1` (which carries `mppvideodec`/`mpph264enc`) and
  `librockchip-mpp1` only exist in Radxa's `rk3568-bookworm` repository, which
  the image already has in its sources.
- On RK3568 the primary and "Smart" planes are RGB-only, and plane 72
  (`Esmart0`) is typed *Cursor*. The NV12 overlay is 112 (`Esmart1-win0`).
  `kmssink` left to itself picks plane 96 and refuses NV12, so the plane has to
  be chosen.
- `mppvideodec` drops every buffer that has no timestamp. The HDMI `appsrc`
  must stamp its buffers.
- The dwc3 controller is super-speed capable. With only full- and high-speed
  descriptors, the gadget must say `max_speed = high-speed`, or a USB 3 host
  sees no configuration at all.
- Radxa's `radxa-otgutils` can bind its own gadget (`ecm.usb0` + `ffs.adb`) to
  the UDC at boot on some images. YStreamer must unbind it, and the package
  should stop the service that creates it.
- The image boots to a desktop (GDM). It has to boot to the console for
  YStreamer to hold the screen; `install.sh` already warns about a desktop.
- The Goggles 2 send no AOA control requests on this link (zero SETUP records
  in the bring-up), so the ep0 handling stays as it is.

## The image, as published

Checked against the `rsdk-r2` release of
[radxa-build/rock-3a](https://github.com/radxa-build/rock-3a) (2026-05-09,
`rock-3a_bookworm_kde_r2`), the only variant Radxa still supports and the one
the bring-up used:

- Debian 12 bookworm; `linux-image-rock-3a` 6.1.84-15 (rk2410-nocsf); glibc
  2.36-9+deb12u13; GStreamer 1.22.9 with plugins base, good, bad, ugly and
  libav; `gstreamer1.0-rockchip1` 1.14-4, `librockchip-mpp1` 1.5.0-1 and
  `libv4l-rkmpp` 1.7.0-1 preinstalled; `network-manager`, `avahi-daemon`,
  `dnsmasq-base`, `udisks2`, `wpasupplicant`, `iw` present, so the package's
  `Depends` resolve without downloads.
- GDM is the selected display manager (sddm is installed but not selected);
  the system boots to `graphical.target`.
- `radxa-otgutils` 0.3.3 and `adbd` are installed. Its units are templated
  per controller: `radxa-adbd@`, `radxa-ecm@`, `radxa-ncm@` (alias
  `radxa-usbnet@`), plus `radxa-adbd-monitor@` from the helper package, which
  restarts the ADB gadget whenever the controller reaches "configured". The
  gadget it builds is named after the controller (`fcc00000.usb`). None is
  enabled by default; `rsetup` can enable them.
- Radxa ships `rk3568-dwc3-{host,otg,peripheral}` overlays, selectable in
  `rsetup`; `otg` ("controlled by hardware switch") is the default for the
  ROCK 3A, and the device tree's compatible is `radxa,rock-3a`.
- The card has a FAT partition labelled `config`, automounted at `/config`,
  where Radxa's first-boot `before.txt` lives: the ROCK 3A's equivalent of the
  Pi's boot partition for the reset marker file.

## Design

### Board detection (`system/board.rs`)

`Board::detect()` reads `/proc/device-tree/model` and `compatible` once:

- `RaspberryPi` when the model starts with "Raspberry Pi".
- `Rockchip` when `compatible` mentions `rockchip,` or the model contains
  "ROCK".
- `Other` otherwise.

It is a hint, not a gate: the codec and plane choices below go by what the
system actually has. The board decides only what has no runtime probe: the
reset pin, and which message to print when the gadget can't start.

### Codecs (`output/codec.rs`)

Chosen from the GStreamer registry at start, in this order:

| Role         | Preferred            | Then           | Else        |
| ------------ | -------------------- | -------------- | ----------- |
| H.264 decode | `v4l2h264dec` (Pi)   | `mppvideodec`  | `avdec_h264`|
| H.264 encode | `v4l2h264enc` (Pi)   | `mpph264enc`   | software    |

The HDMI pipeline substitutes the decoder; the SPS level patch (a Pi decoder
limit) runs only for `v4l2h264dec`. The UVC source's `Encoder::Hardware`
attempt uses the encoder found, and is skipped when there is none, so the
software attempt comes next as today.

`mpph264enc` takes `bps`, `gop` and `profile`; the pipeline string is
per-encoder.

### USB gadget (`input/gadget.rs`)

- Always `modprobe libcomposite usb_f_fs` (no-ops where built in).
- Write `max_speed = high-speed`. Harmless on dwc2.
- A gadget bound to the controller that is not ours is unbound before ours
  binds (Radxa's `radxa-otgutils`, or anything else). Only another process
  serving *our* gadget (`ystreamer-aoa` bound) is left alone, as now. This
  replaces "leave someone else's bound gadget alone", which on the ROCK 3A
  would mean no link, ever.
- The "no controller" message names the right fix per board: config.txt on
  the Pi, the OTG switch on the ROCK 3A.

Descriptors, VID/PID and strings stay as they are: they work with every
supported goggles and the RC-N2/N3 on the Pi, and the ROCK 3A bring-up showed
the goggles don't look at them beyond the vendor interface.

### HDMI (`output/display.rs`, `output/hdmi.rs`)

- `Display` picks the **video plane**: the first plane, in the kernel's order,
  usable on the CRTC, not of type *Cursor*, that lists NV12. That is what
  `kmssink` would pick on the Pi (the primary plane is first and takes NV12),
  and plane 112 on the RK3568. `kmssink` gets it as `plane-id`.
- The logo plane search skips the video plane explicitly, on top of the
  existing "not in use" check.
- The logo's `zpos` is clamped to the property's range: 10 where it fits (the
  Pi), the top of the range otherwise.
- The `appsrc` gets `do-timestamp=true`. With `sync=false` on the sink this
  changes nothing on the Pi and is what `mppvideodec` needs.
- The error for "no plane for the video" is explicit, so a board whose planes
  can't take NV12 says so instead of failing in `kmssink`'s negotiation.

### Reset pin (`system/reset.rs`)

The 5-second ground check on GPIO 21 runs on a Raspberry Pi only. The reset
file and `ystreamer reset` work everywhere.

### Packaging

- `ystreamer.service`: `After=sys-kernel-config.mount` as well, so configfs is
  there when the gadget is built.
- `postinst`: on a system with `radxa-adbd` units, `systemctl disable --now`
  them, and say so. `postrm` leaves them disabled and prints how to enable
  them again (their earlier state isn't known).
- `Cargo.toml`: `Suggests` the Rockchip packages, with a comment. They can't be
  `Recommends`: apt would still install on the Pi, but the Pi's repositories
  don't have them and the hint would be noise.
- `install.sh`:
  - Accepts "Radxa ROCK 3" models without asking; on Debian 12 only on a
    Rockchip board (it still asks on anything else).
  - On a Rockchip board installs `librockchip-mpp1 gstreamer1.0-rockchip1`
    first, and checks `/sys/class/udc` has a controller (else: set the OTG
    switch to DEVICE, reboot).
  - Picks the package by `<arch>-<codename>` from the manifest when present,
    then `<arch>` as today.
  - Skips the config.txt talk on a board that has none (already the case).
- `manifest.sh` takes several `.deb` files; a package whose revision contains
  `~bookworm` is listed under `arm64-bookworm`, the others under `arm64`.
- `update.rs` looks up `<arch>-<codename>` first, then `<arch>`, so a ROCK 3A
  never downloads the trixie package.
- The bookworm package is built in Docker: `device/packaging/bookworm/`
  (Dockerfile and `build.sh`), `mise run device:deb-bookworm`. The release
  workflow gets a `package-bookworm` job and the manifest step lists both.

### Docs

- `getting-started/radxa-rock-3a.mdx`: hardware, the OTG switch, cabling
  (goggles → USB-C-male-to-USB-A-female OTG adapter → A-to-A cable → the upper
  USB 3 port), power through the board's own USB-C PD input, install steps,
  console boot (`systemctl set-default multi-user.target`), what doesn't apply
  (image, record button, reset pin, Wi-Fi without a module), undo steps.
- Requirements and install-script pages mention the board; README's "What you
  need" gets a line.

## Left to the builder

- Exact wording of messages and docs.
- Test fixtures for the plane chooser (plain structs, no DRM device).
- Whether `mpph264enc` property names match the installed
  `gstreamer1.0-rockchip1 1.14-4`: verify with `gst-inspect-1.0 mpph264enc` on
  the board; the software encoder covers a mismatch.

## Verification

On this Mac: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` in
the bookworm container; `device/packaging/bookworm/build.sh` produces a `.deb`.

On a ROCK 3A (owner), in order:

1. `sudo sh install.sh --check` then the install; `systemctl status ystreamer`.
2. `cat /sys/kernel/config/usb_gadget/ystreamer-aoa/UDC` → `fcc00000.usb`;
   with the goggles on: `/sys/class/udc/fcc00000.usb/state` → `configured`,
   and the log says "Link is live".
3. HDMI shows the stream; the log says which decoder and plane were picked.
   `cat /sys/kernel/debug/dri/0/state` shows the NV12 framebuffer on plane 112.
4. Logo on, HDMI rotation, Fill scaling: picture and logo still right.
5. A USB camera: the log says `mpph264enc` or falls back to software.
6. `ystreamer logs` after a reboot: no "reset" line.
