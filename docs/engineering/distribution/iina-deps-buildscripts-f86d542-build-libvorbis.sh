#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libvorbis"
VERSION="${LIBVORBIS_VERSION}"
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

    "${SRC_DIR}/configure" \
        --prefix="$prefix" \
        --host="$HOST_TRIPLE" \
        --enable-shared \
        --disable-static

    # libvorbis configure unconditionally injects -force_cpusubtype_ALL on Darwin
    # for PowerPC Altivec; modern Apple ld rejects this flag.
    find "$build_dir" -name "Makefile" -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} +

    make -j"$JOBS"
    make install
}

download_and_verify "$LIBVORBIS_URL" "$LIBVORBIS_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
