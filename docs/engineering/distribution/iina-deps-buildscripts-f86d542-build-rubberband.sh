#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="rubberband"
VERSION="${RUBBERBAND_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.bz2"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    meson_setup "$build_dir" "$SRC_DIR" "$arch" \
        -Dfft=vdsp \
        -Dresampler=builtin \
        -Dcmdline=disabled

    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install
}

download_and_verify "$RUBBERBAND_URL" "$RUBBERBAND_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
