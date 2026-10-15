#!/bin/bash
# Shared helpers sourced by every build-*.sh script.

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ROOT_DIR="$(cd "${_COMMON_DIR}/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET="11.0"
export ARCHS="${ARCHS:-arm64 x86_64}"
export SOURCES_DIR="${ROOT_DIR}/sources"
export BUILD_DIR="${ROOT_DIR}/build"
export INSTALL_DIR="${ROOT_DIR}/install"
export OUTPUT_DIR="${ROOT_DIR}/output"
export MACOS_SDK="$(xcrun --show-sdk-path)"
JOBS=$(sysctl -n hw.ncpu)

if [ -z "${LIBOGG_VERSION:-}" ]; then
    source "${_COMMON_DIR}/../versions.env"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_step() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------

# download_and_verify <url> <sha256> <filename>
# Downloads to $SOURCES_DIR if not cached; verifies SHA256 either way.
download_and_verify() {
    local url="$1" expected_sha256="$2" filename="$3"
    local dest="${SOURCES_DIR}/${filename}"

    mkdir -p "$SOURCES_DIR"

    if [ -f "$dest" ]; then
        local actual_sha256
        actual_sha256=$(shasum -a 256 "$dest" | awk '{print $1}')
        if [ "$actual_sha256" = "$expected_sha256" ]; then
            log_step "Cached: ${filename}"
            return 0
        fi
        log_step "SHA256 mismatch on cached ${filename} — re-downloading"
        rm -f "$dest"
    fi

    log_step "Downloading: ${filename}"
    curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url"

    local actual_sha256
    actual_sha256=$(shasum -a 256 "$dest" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo "ERROR: SHA256 mismatch for ${filename}" >&2
        echo "  Expected: ${expected_sha256}" >&2
        echo "  Got:      ${actual_sha256}" >&2
        rm -f "$dest"
        exit 1
    fi
    log_step "Verified: ${filename}"
}

# ---------------------------------------------------------------------------
# Source extraction
# ---------------------------------------------------------------------------

# extract_source <filename> <dir-name>
# Extracts SOURCES_DIR/<filename> into SOURCES_DIR/<dir-name>.
# Idempotent: skips extraction if the directory already exists.
# Handles any top-level directory name inside the archive.
extract_source() {
    local filename="$1" dir_name="$2"
    local src_dir="${SOURCES_DIR}/${dir_name}"

    rm -rf "$src_dir"
    log_step "Extracting: ${filename}"
    local tarball="${SOURCES_DIR}/${filename}"
    local tmp_dir="${SOURCES_DIR}/.tmp_extract_$$"
    mkdir -p "$tmp_dir"

    case "$filename" in
        *.tar.gz|*.tgz)  tar -xzf "$tarball" -C "$tmp_dir" ;;
        *.tar.xz)        tar -xJf "$tarball" -C "$tmp_dir" ;;
        *.tar.bz2)       tar -xjf "$tarball" -C "$tmp_dir" ;;
        *.zip)           unzip -q  "$tarball" -d "$tmp_dir" ;;
        *)
            echo "ERROR: Unknown archive format: ${filename}" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac

    # Move the single top-level entry to the canonical location,
    # regardless of what it was named inside the archive.
    local entries=("${tmp_dir}"/*)
    if [ ${#entries[@]} -ne 1 ] || [ ! -d "${entries[0]}" ]; then
        echo "ERROR: Expected exactly one top-level directory in ${filename}" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    mv "${entries[0]}" "$src_dir"
    rm -rf "$tmp_dir"
    log_step "Extracted to: ${src_dir}"
}

# ---------------------------------------------------------------------------
# Patch application
# ---------------------------------------------------------------------------

# apply_patches <dep-name> <source-dir>
# Applies all *.patch files from patches/<dep-name>/ in sorted order.
apply_patches() {
    local dep_name="$1" src_dir="$2"
    local patches_dir="${ROOT_DIR}/patches/${dep_name}"

    [ -d "$patches_dir" ] || return 0

    local patches=("${patches_dir}"/*.patch)
    # glob expands to literal path if no matches
    [ -e "${patches[0]}" ] || return 0

    for patch_file in "${patches[@]}"; do
        log_step "Applying: $(basename "$patch_file")"
        patch --forward -d "$src_dir" -p1 < "$patch_file"
    done
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# get_prefix <arch>  →  $INSTALL_DIR/<arch>
get_prefix() {
    echo "${INSTALL_DIR}/$1"
}

# get_build_dir <dep-name> <arch>  →  $BUILD_DIR/<dep-name>/<arch>
get_build_dir() {
    echo "${BUILD_DIR}/$1/$2"
}

# get_host_triple <arch>  →  autotools host triple string
get_host_triple() {
    case "$1" in
        arm64)  echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin"  ;;
        *) echo "ERROR: Unknown arch: $1" >&2; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Per-arch compiler environment
# ---------------------------------------------------------------------------

# setup_arch_env <arch>
# Exports CFLAGS, CXXFLAGS, OBJCFLAGS, LDFLAGS, PKG_CONFIG_PATH, HOST_TRIPLE.
# Call this at the top of each build_for_arch() function.
setup_arch_env() {
    local arch="$1"
    local prefix
    prefix="$(get_prefix "$arch")"

    local base_flags="-arch ${arch} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${MACOS_SDK}"

    export CFLAGS="${base_flags} -O2"
    export CXXFLAGS="${base_flags} -O2"
    export OBJCFLAGS="${base_flags} -O2"
    export LDFLAGS="${base_flags}"
    export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"
    export HOST_TRIPLE="$(get_host_triple "$arch")"

    mkdir -p "${prefix}/lib/pkgconfig"
}

# ---------------------------------------------------------------------------
# Meson build helper
# ---------------------------------------------------------------------------

# meson_setup <build_dir> <src_dir> <arch> [extra meson args...]
# Selects --native-file vs --cross-file based on whether arch == host arch,
# clears CFLAGS/LDFLAGS so they don't duplicate the machine-file c_args,
# and sets PKG_CONFIG_PATH for the target prefix.
meson_setup() {
    local build_dir="$1" src_dir="$2" arch="$3"
    shift 3
    local prefix
    prefix="$(get_prefix "$arch")"
    local machine_file="${ROOT_DIR}/extra/meson-${arch}-darwin.ini"
    local native_arch
    native_arch="$(uname -m)"

    local machine_flag
    if [ "$arch" = "$native_arch" ]; then
        machine_flag="--native-file=${machine_file}"
    else
        machine_flag="--cross-file=${machine_file}"
    fi

    rm -rf "$build_dir"

    # Clear compiler env vars — the machine file sets -arch and -mmacosx-version-min;
    # leaving CFLAGS/LDFLAGS would cause each flag to appear twice.
    local _cflags="${CFLAGS:-}" _cxxflags="${CXXFLAGS:-}" _ldflags="${LDFLAGS:-}"
    unset CFLAGS CXXFLAGS OBJCFLAGS LDFLAGS

    PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" \
    meson setup "$build_dir" "$src_dir" \
        "$machine_flag" \
        --prefix="$prefix" \
        --default-library=shared \
        --buildtype=release \
        "$@"

    [ -n "$_cflags"   ] && export CFLAGS="$_cflags"
    [ -n "$_cxxflags" ] && export CXXFLAGS="$_cxxflags"
    [ -n "$_ldflags"  ] && export LDFLAGS="$_ldflags"
}

# ---------------------------------------------------------------------------
# CMake build helper
# ---------------------------------------------------------------------------

# cmake_configure <build_dir> <src_dir> <arch> [extra cmake args...]
cmake_configure() {
    local build_dir="$1" src_dir="$2" arch="$3"
    shift 3
    local prefix
    prefix="$(get_prefix "$arch")"

    rm -rf "$build_dir"
    cmake -S "$src_dir" -B "$build_dir" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$MACOS_SDK" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_FIND_ROOT_PATH="${prefix};${MACOS_SDK}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DCMAKE_FIND_FRAMEWORK=LAST \
        "$@"
}
