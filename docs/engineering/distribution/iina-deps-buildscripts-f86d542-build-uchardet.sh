#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="uchardet"
VERSION="${UCHARDET_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.xz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DBUILD_STATIC=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$UCHARDET_URL" "$UCHARDET_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
