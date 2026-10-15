#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="luajit"
# LuaJIT uses a rolling commit rather than versioned releases
COMMIT="${LUAJIT_COMMIT}"
TARBALL="${DEP_NAME}-${COMMIT}.tar.gz"

build_for_arch() {
    local arch="$1"
    local prefix src_dir
    prefix="$(get_prefix "$arch")"
    # Each arch gets its own in-source copy because LuaJIT's build system
    # does not support out-of-tree builds and leaves state in the source tree.
    src_dir="${BUILD_DIR}/${DEP_NAME}-${arch}"

    log_step "=== ${DEP_NAME} ${COMMIT} — ${arch} ==="
    setup_arch_env "$arch"

    rm -rf "$src_dir"
    cp -R "${SOURCES_DIR}/${DEP_NAME}-${COMMIT}" "$src_dir"

    local target_cflags="-arch ${arch} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
    local native_arch; native_arch="$(uname -m)"

    if [ "$arch" = "$native_arch" ]; then
        # Native build — straightforward
        make -C "$src_dir" -j"$JOBS" \
            MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
            XCFLAGS="${target_cflags}" \
            PREFIX="$prefix" \
            DEFAULT_CC=clang \
            amalg
    else
        # Cross-compile. macOS has no arch-prefixed toolchain, so CROSS stays
        # empty (clang cross-compiles via -arch). The host tools (minilua,
        # buildvm) must stay native, so the target -arch goes only through
        # TARGET_FLAGS; CFLAGS/LDFLAGS (exported with -arch by setup_arch_env)
        # are blanked here so they don't leak into the host build.
        make -C "$src_dir" -j"$JOBS" \
            MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
            CC="clang" \
            HOST_CC="clang" \
            CFLAGS="" \
            LDFLAGS="" \
            TARGET_FLAGS="${target_cflags}" \
            PREFIX="$prefix" \
            amalg
    fi

    make -C "$src_dir" install PREFIX="$prefix"
}

download_and_verify "$LUAJIT_URL" "$LUAJIT_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${COMMIT}"
apply_patches "$DEP_NAME" "${SOURCES_DIR}/${DEP_NAME}-${COMMIT}"

for arch in $ARCHS; do build_for_arch "$arch"; done
