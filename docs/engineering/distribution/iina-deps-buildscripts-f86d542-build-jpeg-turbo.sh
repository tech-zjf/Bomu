#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="jpeg-turbo"
VERSION="${JPEG_TURBO_VERSION}"
TARBALL="libjpeg-turbo-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DENABLE_SHARED=ON \
        -DENABLE_STATIC=OFF \
        -DWITH_TURBOJPEG=OFF \
        -DCMAKE_INSTALL_DEFAULT_LIBDIR=lib

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$JPEG_TURBO_URL" "$JPEG_TURBO_SHA256" "$TARBALL"
# The archive top-level dir is libjpeg-turbo-<version>; rename to our canonical name
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
