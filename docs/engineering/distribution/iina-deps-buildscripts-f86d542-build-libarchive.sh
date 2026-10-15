#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libarchive"
VERSION="${LIBARCHIVE_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.xz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix build_dir
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DENABLE_TEST=OFF \
        -DENABLE_INSTALL=ON \
        -DENABLE_OPENSSL=OFF \
        -DENABLE_LIBB2=OFF \
        -DENABLE_LZO=OFF \
        -DENABLE_LZ4=ON \
        -DENABLE_ZSTD=ON \
        -DENABLE_ZLIB=ON \
        -DENABLE_BZip2=OFF \
        -DENABLE_LIBXML2=OFF \
        -DENABLE_EXPAT=OFF \
        -DCMAKE_PREFIX_PATH="$prefix"

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$LIBARCHIVE_URL" "$LIBARCHIVE_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
