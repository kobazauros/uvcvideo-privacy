#!/bin/sh
# Restores privacy_stub state when the camera's video-capture node appears
# (normal boot, or any later USB re-enumeration - unplug/replug,
# suspend/resume). Triggered by 99-uvcvideo-privacy-restore.rules.
#
# The state file is written by the ASUS-Fn-Buttons project's
# asus-camera.sh on every hotkey toggle, not by this driver - see
# docs/DESIGN.md.
STATE_FILE="/etc/asus-fn-buttons/state/camera"

[ -r "$STATE_FILE" ] || exit 0

STATE=$(cat "$STATE_FILE")

if [ "$STATE" = "1" ]; then
	/usr/bin/v4l2-ctl -d /dev/video0 -c privacy_stub=1
fi
