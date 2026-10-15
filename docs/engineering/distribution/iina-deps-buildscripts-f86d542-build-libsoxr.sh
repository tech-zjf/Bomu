#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="soxr"
VERSION="${LIBSOXR_VERSION}"
TARBALL="soxr-${VERSION}-Source.tar.xz"
SRC_DIR="${SOURCES_DIR}/soxr-${VERSION}-Source"

build_for_arch() {
    local arch="$1"
    local prefix build_dir
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== libsoxr ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DWITH_OPENMP=OFF \
        -DWITH_LSR_BINDINGS=OFF

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$LIBSOXR_URL" "$LIBSOXR_SHA256" "$TARBALL"
extract_source "$TARBALL" "soxr-${VERSION}-Source"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
