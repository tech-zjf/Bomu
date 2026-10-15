#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="svt-av1"
VERSION="${SVT_AV1_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix build_dir
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DBUILD_APPS=OFF \
        -DBUILD_TESTING=OFF

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$SVT_AV1_URL" "$SVT_AV1_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
