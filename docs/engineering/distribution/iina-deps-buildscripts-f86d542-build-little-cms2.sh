#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="little-cms2"
VERSION="${LITTLE_CMS2_VERSION}"
TARBALL="lcms2-${VERSION}.tar.gz"
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
        --disable-static \
        --without-jpeg \
        --without-tiff \
        --without-zlib

    make -j"$JOBS"
    make install
}

# The archive top-level dir is lcms2-<version>; extract_source renames to our canonical name
download_and_verify "$LITTLE_CMS2_URL" "$LITTLE_CMS2_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
