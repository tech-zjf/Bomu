#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="freetype"
VERSION="${FREETYPE_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.xz"
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

    # --without-harfbuzz breaks the freetype↔harfbuzz circular dependency.
    # harfbuzz will be built after freetype and will pick up freetype.
    "${SRC_DIR}/configure" \
        --prefix="$prefix" \
        --host="$HOST_TRIPLE" \
        --enable-shared \
        --disable-static \
        --without-harfbuzz \
        --without-png \
        --without-brotli \
        --without-bzip2 \
        --with-zlib

    make -j"$JOBS"
    make install
}

download_and_verify "$FREETYPE_URL" "$FREETYPE_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
