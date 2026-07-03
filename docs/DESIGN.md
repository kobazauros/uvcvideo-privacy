# Design notes

This document explains the *why* behind the implementation, including a
couple of design decisions that changed from the original plan once the
actual driver code was examined, and a real bug found and fixed during
testing.

## Phase 1: the `privacy_stub` control

Modeled directly on the existing GPIO-privacy virtual-entity mechanism
already in `uvcvideo` (`UVC_EXT_GPIO_UNIT`) — the driver already has a
pattern for a "virtual" control backed by driver state instead of a real
USB control transport, used for cameras with a hardware privacy shutter
GPIO. This patch reuses that exact pattern for a new, software-only unit,
extended with a `set_cur` callback (GPIO only implements `get_cur`, since a
real privacy shutter is read-only hardware state; `privacy_stub` must be
writable).

Implementation, file by file:

- **`uvcvideo.h`**: `UVC_EXT_PRIVACY_STUB_UNIT` (virtual entity type),
  `UVC_EXT_PRIVACY_STUB_UNIT_ID` (virtual entity ID — chosen so it masks to
  `0` under `& 0xff`, matching GPIO's `0x100`; a real entity ID will never
  be `0` per the UVC spec, so this can never collide with a real entity's
  hardware ID. An earlier attempt using `0x101` masked to `1` and
  collided with the camera's real Camera Terminal ID, producing a spurious
  "Found multiple Units with ID 1" warning in `dmesg`), `UVC_GUID_EXT_PRIVACY_STUB`,
  `UVC_CT_PRIVACY_STUB_CONTROL`, `V4L2_CID_UVC_PRIVACY_STUB`, and
  `extern atomic_t uvc_privacy_stub_active`. Added a `set_cur` function
  pointer and a `stub { bControlSize, bmControls }` union member to
  `struct uvc_entity`, and `struct uvc_entity *privacy_stub_unit` to
  `struct uvc_device` (mirrors `gpio_unit`).

- **`uvc_driver.c`**: defines the `atomic_t` storage.
  `uvc_privacy_stub_get_cur()`/`set_cur()`/`get_info()` operate purely on
  the atomic and the cached firmware state — no USB transfer is ever
  issued for this control. `uvc_privacy_stub_parse()` allocates the
  virtual entity unconditionally during probe (unlike GPIO, there's no
  hardware presence to check), called right after `uvc_gpio_parse()`.

  **The one easy-to-miss step**: the entity must also be explicitly linked
  into the video chain's entity list
  (`list_add_tail(&dev->privacy_stub_unit->chain, &chain->entities)` in
  `uvc_scan_device()`, mirroring what GPIO does right next to it) — being
  on `dev->entities` alone is not enough for `uvc_ctrl_init_chain()` to
  see it and register its controls. Missing this step was why the control
  didn't show up in `v4l2-ctl --list-ctrls` on the first attempt.

- **`uvc_ctrl.c`**: a control-info table entry
  (`SET_CUR | GET_CUR | RESTORE`), a V4L2 mapping entry (needs an explicit
  `.name` field, since `V4L2_CID_UVC_PRIVACY_STUB` isn't a standard V4L2
  control ID — unlike `V4L2_CID_PRIVACY`, V4L2 core has no built-in name
  for it), a `UVC_EXT_PRIVACY_STUB_UNIT` branch in
  `uvc_ctrl_init_chain()`'s `bmControls` dispatch, and a
  `ctrl->entity->set_cur` branch mirroring the existing `get_cur` check in
  `uvc_ctrl_commit_entity()`'s `SET_CUR` dispatch path — the one place
  GPIO's read-only pattern didn't have an existing hook to copy from,
  since GPIO never issues `SET_CUR`.

- **`uvc_entity.c`**: the media-controller subsystem
  (`drivers/media/mc/mc-device.c`) warns on registration if an entity's
  `function` field is `MEDIA_ENT_F_V4L2_SUBDEV_UNKNOWN` ("Entity type for
  entity ... was not initialized!"). Our type initially fell into
  `uvc_mc_init_entity()`'s `default:` case, which sets exactly that value.
  GPIO shares this same fallback but never triggers the warning in
  practice, because cameras without privacy-shutter hardware never
  allocate a GPIO entity at all (`uvc_gpio_parse()` returns early) — a
  latent warning in the upstream default case that had simply never been
  exercised. Fixed by adding our type to the existing
  `UVC_VC_PROCESSING_UNIT`/`UVC_VC_EXTENSION_UNIT` case
  (`MEDIA_ENT_F_PROC_VIDEO_PIXEL_FORMATTER`, "for lack of a better option"
  — the same idiom already used there for other non-hardware-mapped
  units).

## Phase 2: frame substitution

Two decisions here departed deliberately from the original pre-implementation sketch.

### Hook point: `uvc_queue_buffer_complete()`, not the packet decoder

The original plan assumed hooking into the per-USB-packet decode path
(`uvc_video_decode_data()`/the async copy work in `uvc_video.c`). Once
actually reading that code, it turned out to just `memcpy` arbitrary
packet-sized fragments from the URB buffer into the video buffer — no
knowledge of frame boundaries, format, or resolution at that level.
Splicing stub bytes in there would mean re-deriving frame pacing from the
stub image instead of the real USB stream (fragile: a pre-generated JPEG's
byte count essentially never matches the real camera's packet cadence for
a given frame, so you'd have to either pad with invalid trailing bytes or
truncate real packets, both of which risk corrupting the FID/EOF-based
frame-completion state machine).

Instead: `uvc_queue_buffer_complete()` in `uvc_queue.c` runs once per
**completed** frame, already has stream/format context via
`uvc_queue_to_stream()`, and is the single choke point right before
`vb2_buffer_done()` hands the buffer to userspace. The real USB
transfer/decode happens completely untouched, preserving all UVC protocol
timing; only the finished buffer's content gets swapped afterward.

This function is shared with the metadata queue (`stream->meta.queue`), so
the substitution is guarded with
`queue->queue.type == V4L2_BUF_TYPE_VIDEO_CAPTURE` before calling
`uvc_queue_to_stream()` — that helper's `container_of` assumes the pointer
passed in is `&stream->queue` specifically, and would silently compute a
bogus `struct uvc_streaming *` if given the metadata queue's pointer
instead.

### Firmware loading: on activate/deactivate, not preload-all or lazy-on-format

Three options were considered: preload all resolution/format combinations
at device probe, lazily load on `S_FMT` (format negotiation), or load on
activation and release on deactivation. Preloading everything would hold
~7MB of raw YUYV assets in kernel memory for the device's entire lifetime
regardless of whether privacy is ever used. Lazy-on-`S_FMT` was ruled out
initially because it seemed to need locking against concurrent format
negotiation — except V4L2/UVC capture devices only ever have one
negotiated format active at a time (confirmed on this hardware: even with
multiple apps open, only one holds the actual streaming session; the rest
get "device busy" — see `docs/TESTING.md`), so that concern turned out to
be moot. **Load-on-activate / release-on-deactivate** was chosen anyway,
since it keeps memory usage at zero except while the feature is actually
in use, and ties naturally to the one place the driver already knows
"privacy just turned on."

`uvc_privacy_stub_set_cur()` in `uvc_driver.c`: on activate, calls
`uvc_privacy_stub_load_fw()` and only flips `uvc_privacy_stub_active` to 1
if the load succeeds — so `SET_CTRL` fails loudly (a real ioctl error)
rather than silently reporting "active" while the real feed keeps
flowing. On deactivate, the atomic is cleared *before* the firmware is
freed (ordering matters for the locking below).

### Locking

`uvc_queue_buffer_complete()` can run from URB-completion (softirq/atomic)
context, while `v4l2-ctl -c privacy_stub=...` runs in process context —
without synchronization, that's a real use-after-free hazard on
`dev->privacy_stub_fw`. A `spinlock_t privacy_stub_lock` on
`struct uvc_device` (initialized in probe) is held with `_irqsave` across
both the pointer swap in load/unload and the `memcpy`/`memset` in the hot
path, so a concurrent free can never observe (or race with) an in-flight
copy.

### Fail-closed default

If privacy is active but no firmware is currently loaded for the buffer's
queue (shouldn't normally happen given the above design, but kept as
defense-in-depth — the main case it actually matters is right after a
device reconnect, see below), `uvc_queue_buffer_complete()` does
`memset(buf->mem, 0, buf->bytesused)` instead of ever passing through the
real frame.

**Caveat found via testing**: for MJPG, an all-zero buffer is not a valid
JPEG (no SOI marker) — decoders reject it outright ("No JPEG data found in
image") rather than rendering a clean black frame. Functionally safe
(nothing real ever leaks) but cosmetically it shows as broken/no-signal,
not a nice black picture. YUYV streams render as a proper black frame in
the same situation, since raw formats don't need markers. Not fixed — this
only matters in the narrow window between a device reconnect and the next
manual re-toggle; a possible future polish item is embedding a tiny valid
black JPEG instead of `memset`-ing to zero.

## Bug found via testing: stale stub after format renegotiation

Activating privacy *before* opening any camera app caches the stub against
whatever format the driver defaults to at probe time (in practice,
1920x1080 MJPG on this camera — the first format/frame entry parsed from
the descriptor). But pipewire/GStreamer's `v4l2src` negotiates its own
format via `VIDIOC_S_FMT` once an app actually opens the device, which can
differ from the probe-time default. Since the original design only
reloaded the stub on activate/deactivate, the cached stub went stale
relative to the newly negotiated format: `uvc_queue_buffer_complete()`
blindly copied wrongly-sized/wrong-format bytes into the buffer, producing
a black/broken frame in the app until the control was manually toggled off
and back on.

**Fix**: `uvc_privacy_stub_load_fw()`/`uvc_privacy_stub_unload_fw()` were
made non-static (prototypes in `uvcvideo.h`) and hooked into
`uvc_ioctl_s_fmt()` in `uvc_v4l2.c`, right after `stream->cur_format`/
`cur_frame` are committed: if privacy is currently active, reload
immediately against the new format; if that reload fails (e.g. no stub
exists for the newly negotiated resolution), explicitly unload the
now-stale cached entry rather than leave a mismatched one in place — this
falls back to the safe blank-frame path instead of serving garbage.

Verified fixed by reproducing the exact original scenario (activate, then
open the camera app fresh, with no manual re-toggle) and confirming the
correct stub shows immediately.

## Known non-issue: rapid toggling causes visible delay/flicker

Investigated during testing as a possible regression from the fix above,
traced back to an unrelated hardware hotkey script
(`ASUS-Fn-Buttons/asus-camera.sh`, a separate project) that reads an LED
sysfs state and flips `privacy_stub` to the opposite value with no
debounce guard. If the underlying ACPI/WMI hotkey event fires the script
more than once per physical keypress (a known class of EC/BIOS quirk),
each spurious re-fire reads whatever the *previous* invocation just wrote
and flips it back — producing a tight, evenly-spaced activate/deactivate
ping-pong. Confirmed via temporary `dev_info()` logging showing distinct
`v4l2-ctl` PIDs firing every ~0.3s. Each activation is a real, blocking
`request_firmware()` call by design (see above), so a rapid toggle storm
while an app is actively pulling frames causes real, visible stalls. This
is expected behavior given the load-on-activate design, not a driver bug
— the fix belongs in the hotkey script (add a debounce guard), not here.
