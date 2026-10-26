#!/bin/bash
# ==============================================================================
# build_freerdp_mac.sh
# 
# Builds universal (arm64 + x86_64) static libraries for FreeRDP 3.x and OpenSSL 3.x
# for Chicken Fork on macOS.
#
# Output:
#   cotvnc/freerdp/include/ (headers for FreeRDP, WinPR, OpenSSL)
#   cotvnc/freerdp/lib/     (libfreerdp3.a, libfreerdp-client3.a, libwinpr3.a,
#                            libssl.a, libcrypto.a)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/cotvnc/freerdp"
WORK_DIR="${WORK_DIR:-/tmp/chicken_rdp_build}"

OPENSSL_VERSION="${OPENSSL_VERSION:-4.1.0}"
FREERDP_TAG="${FREERDP_TAG:-3.32.2}"

export MACOSX_DEPLOYMENT_TARGET="11.0"

# Detect CMake
if [ -x "/opt/local/bin/cmake" ]; then
    CMAKE="/opt/local/bin/cmake"
elif command -v cmake >/dev/null 2>&1; then
    CMAKE="$(command -v cmake)"
else
    echo "Error: cmake not found. Please install CMake or ensure it is in /opt/local/bin or PATH." >&2
    exit 1
fi

echo "Using CMake: ${CMAKE} ($("${CMAKE}" --version | head -n1))"
echo "Target output: ${OUTPUT_DIR}"
echo "Working directory: ${WORK_DIR}"

mkdir -p "${WORK_DIR}"
mkdir -p "${OUTPUT_DIR}/include"
mkdir -p "${OUTPUT_DIR}/lib"

# ==============================================================================
# 1. Build Universal OpenSSL 3.x
# ==============================================================================
OPENSSL_SRC_DIR="${WORK_DIR}/openssl-${OPENSSL_VERSION}"
OPENSSL_TAR="${WORK_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_INSTALL_ARM64="${WORK_DIR}/openssl-install-arm64"
OPENSSL_INSTALL_X86_64="${WORK_DIR}/openssl-install-x86_64"
OPENSSL_UNIVERSAL="${WORK_DIR}/openssl-universal"

if [ ! -f "${OUTPUT_DIR}/lib/libssl.a" ] || [ ! -f "${OUTPUT_DIR}/lib/libcrypto.a" ]; then
    if [ ! -d "${OPENSSL_SRC_DIR}" ]; then
        if [ ! -f "${OPENSSL_TAR}" ]; then
            echo "Downloading OpenSSL ${OPENSSL_VERSION}..."
            curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" -o "${OPENSSL_TAR}" \
              || curl -fsSL "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -o "${OPENSSL_TAR}"
        fi
        echo "Extracting OpenSSL ${OPENSSL_VERSION}..."
        tar -xzf "${OPENSSL_TAR}" -C "${WORK_DIR}"
    fi

    echo "Building OpenSSL for arm64..."
    mkdir -p "${WORK_DIR}/openssl-build-arm64"
    pushd "${WORK_DIR}/openssl-build-arm64" >/dev/null
    "${OPENSSL_SRC_DIR}/Configure" darwin64-arm64-cc no-shared no-tests no-unit-test no-docs \
        --prefix="${OPENSSL_INSTALL_ARM64}" \
        --openssldir="${OPENSSL_INSTALL_ARM64}" \
        -mmacosx-version-min=11.0 -fPIC
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
    popd >/dev/null

    echo "Building OpenSSL for x86_64..."
    mkdir -p "${WORK_DIR}/openssl-build-x86_64"
    pushd "${WORK_DIR}/openssl-build-x86_64" >/dev/null
    "${OPENSSL_SRC_DIR}/Configure" darwin64-x86_64-cc no-shared no-tests no-unit-test no-docs \
        --prefix="${OPENSSL_INSTALL_X86_64}" \
        --openssldir="${OPENSSL_INSTALL_X86_64}" \
        -mmacosx-version-min=11.0 -fPIC
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
    popd >/dev/null

    echo "Creating Universal OpenSSL libraries..."
    mkdir -p "${OPENSSL_UNIVERSAL}/lib"
    mkdir -p "${OPENSSL_UNIVERSAL}/include"
    rm -rf "${OUTPUT_DIR}/include/openssl" "${OUTPUT_DIR}/lib/libssl.a" "${OUTPUT_DIR}/lib/libcrypto.a"
    cp -R "${OPENSSL_INSTALL_ARM64}/include/"* "${OPENSSL_UNIVERSAL}/include/"
    lipo -create "${OPENSSL_INSTALL_ARM64}/lib/libssl.a" "${OPENSSL_INSTALL_X86_64}/lib/libssl.a" -output "${OUTPUT_DIR}/lib/libssl.a"
    lipo -create "${OPENSSL_INSTALL_ARM64}/lib/libcrypto.a" "${OPENSSL_INSTALL_X86_64}/lib/libcrypto.a" -output "${OUTPUT_DIR}/lib/libcrypto.a"
    cp "${OUTPUT_DIR}/lib/libssl.a" "${OPENSSL_UNIVERSAL}/lib/"
    cp "${OUTPUT_DIR}/lib/libcrypto.a" "${OPENSSL_UNIVERSAL}/lib/"

    cp -R "${OPENSSL_UNIVERSAL}/include/"* "${OUTPUT_DIR}/include/"
    echo "Universal OpenSSL built successfully."
else
    echo "Using existing OpenSSL static libraries in ${OUTPUT_DIR}/lib."
    mkdir -p "${OPENSSL_UNIVERSAL}/lib" "${OPENSSL_UNIVERSAL}/include"
    cp "${OUTPUT_DIR}/lib/libssl.a" "${OPENSSL_UNIVERSAL}/lib/"
    cp "${OUTPUT_DIR}/lib/libcrypto.a" "${OPENSSL_UNIVERSAL}/lib/"
    cp -R "${OUTPUT_DIR}/include/"* "${OPENSSL_UNIVERSAL}/include/"
fi

# ==============================================================================
# 2. Build Universal FreeRDP 3.x
# ==============================================================================
FREERDP_SRC_DIR="${WORK_DIR}/FreeRDP"
FREERDP_BUILD_DIR="${WORK_DIR}/freerdp-build-universal"

if [ ! -d "${FREERDP_SRC_DIR}" ]; then
    echo "Cloning FreeRDP ${FREERDP_TAG}..."
    git clone --depth 1 --branch "${FREERDP_TAG}" https://github.com/FreeRDP/FreeRDP.git "${FREERDP_SRC_DIR}" \
      || git clone --depth 1 https://github.com/FreeRDP/FreeRDP.git "${FREERDP_SRC_DIR}"
else
    echo "Updating FreeRDP source repository to ${FREERDP_TAG}..."
    git -C "${FREERDP_SRC_DIR}" checkout "${FREERDP_TAG}" 2>/dev/null \
      || (git -C "${FREERDP_SRC_DIR}" fetch --depth 1 origin tag "${FREERDP_TAG}" 2>/dev/null && git -C "${FREERDP_SRC_DIR}" checkout "${FREERDP_TAG}") \
      || true
fi

echo "Cleaning previous FreeRDP build directory..."
rm -rf "${FREERDP_BUILD_DIR}"
mkdir -p "${FREERDP_BUILD_DIR}"

echo "Removing prior in-tree FreeRDP headers and libraries from ${OUTPUT_DIR}..."
rm -rf "${OUTPUT_DIR}/include/freerdp" \
       "${OUTPUT_DIR}/include/freerdp3" \
       "${OUTPUT_DIR}/include/winpr" \
       "${OUTPUT_DIR}/include/winpr3" \
       "${OUTPUT_DIR}/lib"/libfreerdp*.a \
       "${OUTPUT_DIR}/lib"/libwinpr*.a \
       "${OUTPUT_DIR}/bin" \
       "${OUTPUT_DIR}/share" \
       "${OUTPUT_DIR}/lib/cmake" \
       "${OUTPUT_DIR}/lib/pkgconfig" \
       "${OUTPUT_DIR}/lib/freerdp3"

echo "Configuring FreeRDP for Universal (arm64 + x86_64) static build..."
pushd "${FREERDP_BUILD_DIR}" >/dev/null

"${CMAKE}" "${FREERDP_SRC_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="11.0" \
    -DCMAKE_C_FLAGS="-fPIC" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_CLIENT=ON \
    -DWITH_CLIENT_COMMON=ON \
    -DWITH_CLIENT_MAC=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_RC4=ON \
    -DWITH_CHANNELS=ON \
    -DWITH_CLIENT_CHANNELS=ON \
    -DCHANNEL_CLIPRDR=ON \
    -DCHANNEL_DISP=ON \
    -DCHANNEL_DRDYNVC=ON \
    -DCHANNEL_RDPGFX=ON \
    -DCHANNEL_ENCOMSP=OFF \
    -DCHANNEL_REMDESK=OFF \
    -DCHANNEL_URBDRC=OFF \
    -DCHANNEL_URBDRC_CLIENT=OFF \
    -DCHANNEL_DRIVE=OFF \
    -DCHANNEL_DRIVE_CLIENT=OFF \
    -DCHANNEL_PRINTER=OFF \
    -DCHANNEL_PRINTER_CLIENT=OFF \
    -DCHANNEL_PARALLEL=OFF \
    -DCHANNEL_PARALLEL_CLIENT=OFF \
    -DCHANNEL_SERIAL=OFF \
    -DCHANNEL_SERIAL_CLIENT=OFF \
    -DCHANNEL_SMARTCARD=OFF \
    -DCHANNEL_SMARTCARD_CLIENT=OFF \
    -DCHANNEL_RDPECAM=OFF \
    -DCHANNEL_RDPECAM_CLIENT=OFF \
    -DCHANNEL_RDPDR=ON \
    -DCHANNEL_RDPDR_CLIENT=ON \
    -DCHANNEL_RDPSND=ON \
    -DCHANNEL_RDPSND_CLIENT=ON \
    -DWITH_MACAUDIO=ON \
    -DCHANNEL_AUDIN=OFF \
    -DCHANNEL_AUDIN_CLIENT=OFF \
    -DCHANNEL_TSMF=OFF \
    -DCHANNEL_TSMF_CLIENT=OFF \
    -DCHANNEL_VIDEO=OFF \
    -DCHANNEL_VIDEO_CLIENT=OFF \
    -DCHANNEL_SSHAGENT=OFF \
    -DCHANNEL_TELEMETRY=OFF \
    -DCHANNEL_AINPUT=OFF \
    -DCHANNEL_GEOMETRY=OFF \
    -DCHANNEL_GFXREDIR=OFF \
    -DCHANNEL_LOCATION=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_SAMPLE=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_JSON_DISABLED=ON \
    -DWITH_URIPARSER=OFF \
    -DWITH_AAD=OFF \
    -DWITH_WINPR_TOOLS=OFF \
    -DWITH_MANPAGES=OFF \
    -DWITH_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="${OPENSSL_UNIVERSAL}" \
    -DOPENSSL_INCLUDE_DIR="${OPENSSL_UNIVERSAL}/include" \
    -DOPENSSL_CRYPTO_LIBRARY="${OUTPUT_DIR}/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="${OUTPUT_DIR}/lib/libssl.a" \
    -DWITH_JPEG=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_X11=OFF \
    -DWITH_WAYLAND=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_ALSA=OFF \
    -DCMAKE_INSTALL_PREFIX="${OUTPUT_DIR}"

echo "Compiling FreeRDP Universal static libraries..."
make -j"$(sysctl -n hw.ncpu)"

echo "Installing FreeRDP headers and libraries to ${OUTPUT_DIR}..."
make install

echo "Cleaning extraneous install artifacts..."
rm -rf "${OUTPUT_DIR}/bin" \
       "${OUTPUT_DIR}/share" \
       "${OUTPUT_DIR}/lib/cmake" \
       "${OUTPUT_DIR}/lib/pkgconfig" \
       "${OUTPUT_DIR}/lib/freerdp3" \
       "${OUTPUT_DIR}/lib/libwinpr-tools3.a"

echo "Creating convenience header symlinks..."
ln -sfn freerdp3/freerdp "${OUTPUT_DIR}/include/freerdp"
ln -sfn winpr3/winpr "${OUTPUT_DIR}/include/winpr"

popd >/dev/null

echo "Checking output libraries:"
lipo -info "${OUTPUT_DIR}/lib/libfreerdp"*.a "${OUTPUT_DIR}/lib/libwinpr"*.a "${OUTPUT_DIR}/lib/libssl.a" "${OUTPUT_DIR}/lib/libcrypto.a"

echo "=============================================================================="
echo "FreeRDP 3.x and OpenSSL 3.x universal static libraries successfully built!"
echo "Headers: ${OUTPUT_DIR}/include"
echo "Libs:    ${OUTPUT_DIR}/lib"
echo "=============================================================================="
