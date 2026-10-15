#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="zimg"
VERSION="${ZIMG_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix build_dir
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    rm -rf "$build_dir" && mkdir -p "$build_dir"
    cd "$build_dir"

    "${SRC_DIR}/configure" \
        --prefix="$prefix" \
        --host="$HOST_TRIPLE" \
        --enable-shared \
        --disable-static

    make -j"$JOBS"
    make install
}

download_and_verify "$ZIMG_URL" "$ZIMG_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"

# GitHub release tarballs for zimg don't include a pre-generated configure script
( cd "$SRC_DIR" && ./autogen.sh )

apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
