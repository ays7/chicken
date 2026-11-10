#!/bin/bash
# ==============================================================================
# build_freerdp_mac.sh
# 
# Builds universal (arm64 + x86_64) static libraries for FreeRDP 3.x and OpenSSL 4.x
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
FREERDP_TAG="${FREERDP_TAG:-3.33.1}"

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
# 1. Ensure Universal OpenSSL Static Libraries
# ==============================================================================
OPENSSL_SCRIPT="${SCRIPT_DIR}/build_openssl_mac.sh"

if [ ! -f "${OUTPUT_DIR}/lib/libssl.a" ] || [ ! -f "${OUTPUT_DIR}/lib/libcrypto.a" ] || [ ! -d "${OUTPUT_DIR}/include/openssl" ]; then
    echo "OpenSSL static libraries or headers not found in ${OUTPUT_DIR}."
    echo "Invoking ${OPENSSL_SCRIPT}..."
    OUTPUT_DIR="${OUTPUT_DIR}" WORK_DIR="${WORK_DIR}" OPENSSL_VERSION="${OPENSSL_VERSION}" bash "${OPENSSL_SCRIPT}"
else
    echo "Using existing OpenSSL static libraries in ${OUTPUT_DIR}/lib."
fi

# ==============================================================================
# 2. Build Universal FreeRDP 3.x
# ==============================================================================
if [ -d "/Volumes/Sync/ap/FreeRDP" ]; then
    DEFAULT_FREERDP_SRC="/Volumes/Sync/ap/FreeRDP"
else
    DEFAULT_FREERDP_SRC="${WORK_DIR}/FreeRDP"
fi
FREERDP_SRC_DIR="${FREERDP_SRC_DIR:-${DEFAULT_FREERDP_SRC}}"
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
    -DWITH_APPLE_VIDEOTOOLBOX=ON \
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
    -DOPENSSL_ROOT_DIR="${OUTPUT_DIR}" \
    -DOPENSSL_INCLUDE_DIR="${OUTPUT_DIR}/include" \
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
echo "FreeRDP 3.x and OpenSSL 4.x universal static libraries successfully built!"
echo "Headers: ${OUTPUT_DIR}/include"
echo "Libs:    ${OUTPUT_DIR}/lib"
echo "=============================================================================="
