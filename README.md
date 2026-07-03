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

   This is a manual, per-session load — the module is **not** installed to
   load automatically at boot (no DKMS/`modules-load.d` setup). A reboot
   reverts to the stock driver until you `insmod` again.

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

## Known issues / limitations

- **No reboot persistence.** The activation flag is reset to off on every
  module load (fresh `atomic_t`), and the module itself isn't installed to
  auto-load at boot. Restoring privacy state after a reboot needs an
  external mechanism (e.g. a udev rule + state file) — not implemented
  yet.
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

## License

GPL-2.0 (see [`LICENSE`](LICENSE)) — inherited from the upstream
`uvcvideo` driver this is a derivative work of. Per-file
`SPDX-License-Identifier` headers are preserved from upstream.
