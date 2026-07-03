# Manual test matrix

There's no automated test suite for this (it's a kernel driver exercising
real USB hardware) — this is the checklist that was run manually against
the tested hardware, kept here as a regression checklist for future
changes. All of it passed on the tested hardware/kernel combination (see
`README.md`).

## A. Baseline

1. `privacy_stub` control appears in `v4l2-ctl -d /dev/video0 --list-ctrls`
   and round-trips: `-c privacy_stub=1` then `--get-ctrl privacy_stub`
   reads back `1`; same for `0`.
2. Stub image visibly replaces the real feed in a real camera app (tested:
   GNOME Camera/cheese) with `privacy_stub=1`; real feed returns at `=0`.
3. Same behavior confirmed through pipewire → browser (WebRTC camera
   access), not just direct V4L2 consumers.

## B. Format/resolution coverage

4. Forced resolution switch (`v4l2-ctl --set-fmt-video=width=640,height=480,pixelformat=MJPG`)
   while privacy active: confirmed the *different* stub loaded (visually
   distinguishable — 16:9 vs 4:3 aspect ratio between 1920x1080 and
   640x480), no load errors in `dmesg`.
5. YUYV raw format at 640x480: previewed with
   `ffplay -f v4l2 -input_format yuyv422 -video_size 640x480 -i /dev/video0`
   — image rendered correctly, not corrupted/green. Confirms the raw
   (non-JPEG) substitution path independently from the MJPG path.

## C. Negative / robustness

6. Missing-firmware negative test: `sudo mv /lib/firmware/uvc_privacy
   /lib/firmware/uvc_privacy.bak`, then `-c privacy_stub=1` — must fail
   loudly (`VIDIOC_S_EXT_CTRLS: failed: No such file or directory`,
   nonzero exit code), matching `dmesg` warning
   (`Privacy stub: failed to load ... (-2)`), and the control must stay at
   `0` (not silently report "active" while the real feed keeps flowing).
   Restoring the directory and retrying must succeed immediately, no
   module reload needed.
7. Rapid toggle stress test: 20x on/off in a row via a tight shell loop
   while an app is actively streaming — no kernel warnings, no lockup, no
   failed `SET_CTRL` calls. (Also see the "known non-issue" in
   `docs/DESIGN.md` about what a rapid, *uncontrolled* toggle source
   looks like and why it's not a driver bug.)
8. Simulated disconnect/reconnect via sysfs unbind/bind on the interface
   (`echo -n "<bus-id>" | sudo tee /sys/bus/usb/drivers/uvcvideo/unbind`,
   then `.../bind`) — clean `dmesg` both directions, no crash. Confirmed:
   the activation flag (`atomic_t`, module-global) survives the
   reconnect, but the per-device cached firmware does not (fresh
   `kzalloc`'d `struct uvc_device`) — the fresh device correctly fails
   closed (blanks frames) rather than leaking real video, until manually
   re-toggled to force a fresh load. See the known limitations in
   `README.md`.
9. `rmmod` while privacy is active and the camera is in use: correctly
   **blocked** ("Module uvcvideo is in use") while pipewire held the
   device — this is expected kernel refcounting protecting an open
   device, not a driver bug. After stopping pipewire's `.socket` units as
   well as its `.service` units, `rmmod` succeeded cleanly (exit 0, clean
   `dmesg`, no crash/warning) — this exercises the disconnect-path
   `uvc_privacy_stub_unload_fw()` cleanup releasing a still-active
   firmware reference.

## D. Platform-behavior baseline (not a patch-specific test)

10. Compared against the *stock*, unpatched in-tree driver: confirmed
    "only one exclusive consumer of the camera at a time" (a second app
    gets "cannot play stream"; reclaiming the camera after being
    preempted can even crash the first app) is inherent to this
    platform's pipewire/portal architecture, not something this patch
    introduces or changes. This patch doesn't touch access/locking
    semantics at all. Also used the same stock-driver A/B swap to
    conclusively rule out a suspected app-launch delay as being caused by
    this patch — the delay was reproduced identically with the stock
    driver, in the same session, proving it was leftover pipewire/session
    state unrelated to any code here (see `docs/DESIGN.md`'s "known
    non-issue" section for how a *different*, superficially similar delay
    symptom was separately root-caused to a hotkey script debounce bug —
    these are two distinct findings from two different investigations,
    not the same thing).

## Reproducing the module swap used throughout

```sh
systemctl --user stop pipewire.socket pipewire-pulse.socket \
    pipewire.service pipewire-pulse.service wireplumber.service
sleep 1
sudo rmmod uvcvideo
sudo insmod ./uvcvideo.ko          # or: sudo modprobe uvcvideo   for the stock driver
systemctl --user start pipewire.socket pipewire-pulse.socket \
    pipewire.service pipewire-pulse.service wireplumber.service
```

If `rmmod` fails with "Module uvcvideo is in use" even after stopping the
three `.service` units, stop the `.socket` units too — they respawn the
services and keep the device open otherwise.
