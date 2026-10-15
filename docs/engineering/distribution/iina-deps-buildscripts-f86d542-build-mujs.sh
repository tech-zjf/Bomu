#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="mujs"
VERSION="${MUJS_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix src_dir
    prefix="$(get_prefix "$arch")"
    # mujs has no out-of-tree build support; use per-arch source copy
    src_dir="${BUILD_DIR}/${DEP_NAME}-${arch}"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    rm -rf "$src_dir"
    cp -R "$SRC_DIR" "$src_dir"

    make -C "$src_dir" -j"$JOBS" \
        CC=clang \
        CFLAGS="${CFLAGS}" \
        LDFLAGS="${LDFLAGS}" \
        prefix="$prefix" \
        VERSION="${VERSION}" \
        release

    make -C "$src_dir" prefix="$prefix" install
    make -C "$src_dir" prefix="$prefix" install-shared
    rm -f "${prefix}/lib/libmujs.a"
}

download_and_verify "$MUJS_URL" "$MUJS_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
