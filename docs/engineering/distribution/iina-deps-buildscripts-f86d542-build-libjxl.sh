#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libjxl"
VERSION="${LIBJXL_VERSION}"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

clone_source() {
    if [ -d "$SRC_DIR" ]; then
        log_step "Already cloned: ${DEP_NAME} v${VERSION}"
        return 0
    fi
    log_step "Cloning: ${DEP_NAME} v${VERSION}"
    git clone --recurse-submodules --depth 1 \
        --branch "v${VERSION}" \
        "${LIBJXL_REPO}" \
        "$SRC_DIR"
}

build_for_arch() {
    local arch="$1"
    local prefix build_dir
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DJPEGXL_ENABLE_TOOLS=OFF \
        -DJPEGXL_ENABLE_JPEGLI=OFF \
        -DJPEGXL_ENABLE_DEVTOOLS=OFF \
        -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DJPEGXL_ENABLE_FUZZERS=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_DOXYGEN=OFF \
        -DJPEGXL_ENABLE_JNI=OFF \
        -DJPEGXL_ENABLE_SKCMS=OFF \
        -DJPEGXL_ENABLE_OPENEXR=OFF \
        -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_CXX_STANDARD=17

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

clone_source
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
