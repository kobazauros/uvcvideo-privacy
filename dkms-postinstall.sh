#!/bin/sh
# Run by dkms (as root) after every install/rebuild, per dkms.conf's
# POST_INSTALL. Installs the privacy stub firmware assets - independent of
# kernel version, so this is safe to re-run on every kernel-upgrade rebuild.
set -e

SRC_DIR="$(dirname "$0")/privacy_stubs"
DEST_DIR="/lib/firmware/uvc_privacy"

mkdir -p "$DEST_DIR"
cp -f "$SRC_DIR"/*.jpg "$SRC_DIR"/*.yuyv "$DEST_DIR"/
