# uvcvideo-privacy

An out-of-tree, patched fork of the Linux kernel's `uvcvideo` USB Video Class
driver that adds a software-only privacy switch: when active, it serves a
pre-made still image instead of the real camera feed, entirely inside the
kernel, with no cooperation required from userspace applications.

Unlike the hardware privacy shutter or GPIO-based privacy switch some
webcams have, this works on cameras that don't have one — the substitution
happens after the real image sensor data has already been decoded, right
before the frame is handed back to whatever application is reading
`/dev/video0`.

## How it works

- A new, purely-virtual V4L2 control, `privacy_stub`, is added to the
  camera's control list. It never touches the real UVC/USB control
  transport — it's backed entirely by a `atomic_t` flag inside the driver.
- Toggle it with `v4l2-ctl -d /dev/video0 -c privacy_stub=1` (or `=0`).
- When active, every completed video frame has its buffer contents replaced
  with a pre-generated still image matching the camera's current resolution
  and pixel format, right before the buffer is handed to the V4L2 queue
  (`uvc_queue_buffer_complete()` in `uvc_queue.c`). The real USB transfer
  and decode path run completely untouched — only the finished buffer's
  bytes are swapped, so timing/protocol behavior is unaffected.
- Stub images are loaded via the kernel's `request_firmware()` mechanism
  from `/lib/firmware/uvc_privacy/`, on activation (and released on
  deactivation) — not compiled into the module, and not held in memory
  while inactive.

See [`docs/DESIGN.md`](docs/DESIGN.md) for the detailed implementation
notes (why this hook point, why activate/deactivate-triggered loading,
locking, fail-closed behavior, and a bug found and fixed during testing).

## Tested hardware

- Webcam: "USB2.0 FHD UVC WebCam", USB ID `3277:0010`
- Kernel: `7.0.0-27-generic` (Ubuntu)
- Formats confirmed working: MJPG and YUYV, at all 8 resolutions the
  camera advertises (see below)

This is a personal-use patch built against one specific device and kernel
version. It is **not** a general-purpose patch for arbitrary UVC webcams —
it should apply cleanly to most cameras using the standard `uvcvideo`
control/entity machinery, but has only been validated on the hardware
above.

## Build

Requires the matching kernel headers package (`linux-headers-$(uname -r)`).

```sh
make
```

Produces `uvcvideo.ko`. This mirrors `drivers/media/usb/uvc/Makefile` from
the kernel source tree exactly, so it builds the same set of objects as the
in-tree driver.

To regenerate `compile_commands.json` for editor tooling (clangd, VS Code
IntelliSense, etc.) after making changes:

```sh
make -C /lib/modules/$(uname -r)/build M=$(pwd) compile_commands.json
```

## Install

### Option A: DKMS (recommended — survives reboots and kernel updates)

This is the normal, permanent install: DKMS builds against your running
kernel now, and automatically rebuilds against any future kernel package
upgrade via its APT hook, so the module keeps working without manual
intervention.

Before installing, **back up the stock module** you're about to shadow —
cheap insurance, not because removal is expected to fail:

```sh
sudo mkdir -p /var/backups/uvcvideo-privacy
sudo cp /lib/modules/$(uname -r)/kernel/drivers/media/usb/uvc/uvcvideo.ko.zst \
    /var/backups/uvcvideo-privacy/uvcvideo.ko.zst.stock-$(uname -r)
```

Then:

```sh
sudo ln -s "$(pwd)" /usr/src/uvcvideo-privacy-1.1.1-privacy1
sudo dkms add -m uvcvideo-privacy -v 1.1.1-privacy1
sudo dkms build -m uvcvideo-privacy -v 1.1.1-privacy1
sudo dkms install -m uvcvideo-privacy -v 1.1.1-privacy1
```

This also installs the firmware assets automatically (via `dkms.conf`'s
`POST_INSTALL` hook, `dkms-postinstall.sh`) — no separate firmware-copy
step needed with this path.

`dkms install` places the built module at
`/lib/modules/$(uname -r)/updates/dkms/uvcvideo.ko`, which the standard
Debian/Ubuntu module search order checks *before* the in-tree
`kernel/` directory — so `modprobe uvcvideo` and normal USB hotplug both
resolve to this build instead of stock, with the *same* module name
(deliberately — see `docs/DESIGN.md` for why this was chosen over shipping
under a different module name). Verify precedence without touching the
currently-loaded module:

```sh
modinfo uvcvideo | head -6   # filename: should show .../updates/dkms/...
```

Swap the running module for the DKMS-installed one (same pipewire-stopping
caveat as below applies):

```sh
sudo rmmod uvcvideo
sudo modprobe uvcvideo
```

**Rollback**, if ever needed — this fully reverts to stock, instantly:

```sh
sudo dkms remove uvcvideo-privacy/1.1.1-privacy1 --all
sudo depmod -a
sudo modprobe uvcvideo
```

Editing the driver afterwards means bumping `PACKAGE_VERSION` in
`dkms.conf`, `dkms remove`-ing the old version, then `add`/`build`/`install`
again with the new one — DKMS tracks source by version, not by watching
the working tree live.

### Option B: manual, session-scoped (for quick iteration while developing)

1. Install the stub images as firmware assets:

   ```sh
   sudo mkdir -p /lib/firmware/uvc_privacy
   sudo cp privacy_stubs/*.jpg privacy_stubs/*.yuyv /lib/firmware/uvc_privacy/
   ```

2. Swap out the stock driver for the patched one. **Stop anything holding
   the camera open first** (see [Known issues](#known-issues) below —
   `rmmod` will fail with "in use" otherwise):

   ```sh
   systemctl --user stop pipewire.socket pipewire-pulse.socket \
       pipewire.service pipewire-pulse.service wireplumber.service
   sudo rmmod uvcvideo
   sudo insmod ./uvcvideo.ko
   systemctl --user start pipewire.socket pipewire-pulse.socket \
       pipewire.service pipewire-pulse.service wireplumber.service
   ```

   This load does **not** survive a reboot or a kernel update — use Option
   A for that. This path is only for quickly testing a change without
   going through a DKMS version bump each time.

## Usage

```sh
# turn the privacy stub on
v4l2-ctl -d /dev/video0 -c privacy_stub=1

# turn it off
v4l2-ctl -d /dev/video0 -c privacy_stub=0

# check current state
v4l2-ctl -d /dev/video0 --get-ctrl privacy_stub
```

Any application reading `/dev/video0` (browsers, video call apps, `cheese`,
GNOME Camera, etc.) will see the stub image while active, with no
awareness that anything changed — it's just frame content from their point
of view.

## Generating your own stub images

The 16 files under `privacy_stubs/` (8 resolutions × `.jpg`/`.yuyv`) are
loaded by filename: `stub_<width>x<height>.<jpg|yuyv>`. To generate your
own set from a source image, using `ffmpeg`:

```sh
SRC=your-picture.jpg
for res in 160x120 176x144 320x240 352x288 640x480 800x600 1280x720 1920x1080; do
    w=${res%x*}; h=${res#*x}

    # compressed stub, used when the camera is streaming MJPG/JPEG
    ffmpeg -y -i "$SRC" -vf "scale=${w}:${h}" -q:v 2 "privacy_stubs/stub_${res}.jpg"

    # raw stub, used when the camera is streaming YUYV 4:2:2
    # (must be exactly width * height * 2 bytes, no container/header)
    ffmpeg -y -i "$SRC" -vf "scale=${w}:${h}" -pix_fmt yuyv422 -f rawvideo "privacy_stubs/stub_${res}.yuyv"
done
```

The driver only checks file size loosely (it copies
`min(firmware_size, buffer_size)` bytes) but a `.yuyv` file that isn't
exactly `width * height * 2` bytes will produce a visibly wrong/corrupted
image, since there's no format header to correct for a mismatch.

If your camera advertises a resolution not in this list, check with:

```sh
v4l2-ctl -d /dev/video0 --list-formats-ext
```

and generate an additional pair for it — no code changes needed, the
loader builds the filename dynamically from whatever format/resolution is
currently negotiated.

## Reboot / login persistence

The activation flag itself is a fresh `atomic_t` on every module load — it
has no memory of what it was before shutdown, so without anything else, a
reboot would always come back up with the real feed live regardless of
what state you left it in. Two independent mechanisms close that gap:

- **`99-uvcvideo-privacy-restore.rules`** (installed to
  `/etc/udev/rules.d/`) + **`uvc-privacy-restore.sh`** (installed to
  `/usr/local/sbin/`) — fires whenever `/dev/video0` appears (boot, or any
  later USB re-enumeration: unplug/replug, suspend/resume), reads
  `/etc/asus-fn-buttons/state/camera`, and re-applies `privacy_stub` if it
  says `1`.
- A companion systemd `--user` service in the separate `ASUS-Fn-Buttons`
  project (a different local project — the hotkey/LED-indicator scripts
  for this laptop's ASUS-specific hardware buttons, not part of this
  repo) restores both the camera and mic-mute LEDs at every login, and
  redundantly re-applies `privacy_stub` and mic-mute as a safety net —
  needed because `/sys` LED brightness values have no persistence of
  their own (confirmed empirically; this is true of everything under
  `/sys`, not a quirk of this specific LED), and because the udev rule
  above only fires when the camera device itself (re-)appears, not on
  every login within the same boot session.

Both mechanisms read from the same state file
(`/etc/asus-fn-buttons/state/camera`), written by that project's
`asus-camera.sh` on every hotkey toggle — this repo only owns applying
that state to the `privacy_stub` control, not capturing it in the first
place. See `docs/DESIGN.md` for the full design (including why a state
file rather than reading the LED value back, and why the two triggers are
necessarily different: a kernel uevent vs. a PipeWire/session-level
concern for the mic side).

Install (once you've built/installed the driver itself):

```sh
sudo cp uvc-privacy-restore.sh /usr/local/sbin/uvc-privacy-restore.sh
sudo chmod 755 /usr/local/sbin/uvc-privacy-restore.sh
sudo chown root:root /usr/local/sbin/uvc-privacy-restore.sh
sudo cp 99-uvcvideo-privacy-restore.rules /etc/udev/rules.d/99-uvcvideo-privacy-restore.rules
sudo udevadm control --reload-rules
sudo mkdir -p /etc/asus-fn-buttons/state
```

This is manually installed for now, not yet part of the DKMS package —
see the note in `docs/DESIGN.md` about deferring a proper combined
installer until after more testing.

## Known issues / limitations

- **The activation flag is global, not per-device.** If you have more than
  one camera using this patched driver simultaneously, toggling privacy
  affects all of them together — there's a single module-wide `atomic_t`,
  not one per `struct uvc_device`. Not a practical issue on a single-webcam
  laptop.
- **Fail-closed behavior for MJPG is not a clean black frame.** If privacy
  is somehow active with no stub currently loaded (e.g. right after a
  device reconnect, before the next toggle), the driver blanks the buffer
  with zeros rather than serving the real frame — safe (nothing real
  leaks), but an all-zero buffer isn't valid JPEG, so MJPG consumers show
  a broken/no-signal state rather than a clean black picture. YUYV streams
  render as a proper black frame in this situation, since raw formats
  don't need markers.
- **`rmmod` fails with "Module uvcvideo is in use" while pipewire holds the
  camera open** — this is normal kernel module refcounting protecting an
  open device, not a bug, but on a pipewire-managed desktop you need to
  stop pipewire's `.socket` units too, not just the `.service` units
  (`systemctl --user stop pipewire.socket pipewire-pulse.socket
  pipewire.service pipewire-pulse.service wireplumber.service`) — the
  socket units otherwise respawn the services and keep the device open.
- **Only one exclusive consumer of the camera at a time.** Confirmed this
  is inherent to the stock driver + pipewire's camera portal architecture,
  not something this patch changes — a second app trying to open the
  camera while another holds it gets a "cannot play stream" error.
- **Rapid toggling has real cost.** Each activation does a real, blocking
  `request_firmware()` disk read; each deactivation releases it. A script
  or hotkey handler that toggles the control repeatedly without debouncing
  will cause visible stalls/flicker in whatever app is actively streaming
  at the time — this is expected given the load-on-activate design, not a
  driver bug (see `docs/TESTING.md` for how this was diagnosed).

## Testing

See [`docs/TESTING.md`](docs/TESTING.md) for the full manual test matrix
this patch has been run through.

## Author

The privacy-stub patch (everything described in this README and
`docs/DESIGN.md`) is by Konstantin Bantov <k.doguzov@gmail.com>. The
`uvcvideo` driver this is forked from is by Laurent Pinchart
<laurent.pinchart@ideasonboard.com> and the Linux media subsystem
contributors — both are credited as separate `MODULE_AUTHOR()` entries in
the built module (`modinfo uvcvideo`), original author first.

## License

GPL-2.0 (see [`LICENSE`](LICENSE)) — inherited from the upstream
`uvcvideo` driver this is a derivative work of. Per-file
`SPDX-License-Identifier` headers are preserved from upstream.
