#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libplacebo"
VERSION="${LIBPLACEBO_VERSION}"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

# Use a recursive clone so the glad2 submodule (needed for OpenGL) is included.
# A tarball from GitLab /-/archive/ does not bundle submodules.
clone_source() {
    if [ -d "$SRC_DIR" ]; then
        log_step "Already cloned: ${DEP_NAME} v${VERSION}"
        return 0
    fi
    log_step "Cloning: ${DEP_NAME} v${VERSION}"
    git clone --recurse-submodules --depth 1 \
        --branch "v${VERSION}" \
        "${LIBPLACEBO_REPO}" \
        "$SRC_DIR"
}

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    meson_setup "$build_dir" "$SRC_DIR" "$arch" \
        -Dvulkan=disabled \
        -Dopengl=enabled \
        -Dd3d11=disabled \
        -Ddemos=false \
        -Dtests=false \
        -Dshaderc=disabled \
        -Dglslang=disabled \
        -Dlcms=enabled

    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install
}

clone_source
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
