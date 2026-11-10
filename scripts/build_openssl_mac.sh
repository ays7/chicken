#!/bin/bash
# ==============================================================================
# build_openssl_mac.sh
# 
# Builds universal (arm64 + x86_64) static libraries for OpenSSL
# for Chicken Fork on macOS.
#
# Output:
#   cotvnc/freerdp/include/openssl/ (headers)
#   cotvnc/freerdp/lib/libssl.a     (universal static library)
#   cotvnc/freerdp/lib/libcrypto.a  (universal static library)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/cotvnc/freerdp}"
WORK_DIR="${WORK_DIR:-/tmp/chicken_rdp_build}"

OPENSSL_VERSION="${OPENSSL_VERSION:-4.1.0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

echo "=============================================================================="
echo "OpenSSL Universal Static Library Builder"
echo "OpenSSL Version:            ${OPENSSL_VERSION}"
echo "Target output:              ${OUTPUT_DIR}"
echo "Working directory:          ${WORK_DIR}"
echo "macOS Deployment Target:    ${MACOSX_DEPLOYMENT_TARGET}"
echo "Force rebuild:              ${FORCE_REBUILD}"
echo "=============================================================================="

mkdir -p "${WORK_DIR}"
mkdir -p "${OUTPUT_DIR}/include"
mkdir -p "${OUTPUT_DIR}/lib"

# Check if libraries already exist
if [ "${FORCE_REBUILD}" != "1" ] && [ "${FORCE_REBUILD}" != "true" ] && \
   [ -f "${OUTPUT_DIR}/lib/libssl.a" ] && [ -f "${OUTPUT_DIR}/lib/libcrypto.a" ] && \
   [ -d "${OUTPUT_DIR}/include/openssl" ]; then
    echo "Found existing OpenSSL static libraries and headers in ${OUTPUT_DIR}."
    echo "Use FORCE_REBUILD=1 to force re-downloading and re-compiling OpenSSL."
    lipo -info "${OUTPUT_DIR}/lib/libssl.a" "${OUTPUT_DIR}/lib/libcrypto.a"
    exit 0
fi

OPENSSL_SRC_DIR="${WORK_DIR}/openssl-${OPENSSL_VERSION}"
OPENSSL_TAR="${WORK_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_INSTALL_ARM64="${WORK_DIR}/openssl-install-arm64"
OPENSSL_INSTALL_X86_64="${WORK_DIR}/openssl-install-x86_64"

# 1. Download OpenSSL source tarball
if [ ! -d "${OPENSSL_SRC_DIR}" ]; then
    if [ ! -f "${OPENSSL_TAR}" ]; then
        echo "Downloading OpenSSL ${OPENSSL_VERSION}..."
        curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" -o "${OPENSSL_TAR}" \
          || curl -fsSL "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -o "${OPENSSL_TAR}"
    fi
    echo "Extracting OpenSSL ${OPENSSL_VERSION}..."
    tar -xzf "${OPENSSL_TAR}" -C "${WORK_DIR}"
fi

# 2. Build for Apple Silicon (arm64)
echo "Building OpenSSL ${OPENSSL_VERSION} for arm64..."
rm -rf "${WORK_DIR}/openssl-build-arm64" "${OPENSSL_INSTALL_ARM64}"
mkdir -p "${WORK_DIR}/openssl-build-arm64"
pushd "${WORK_DIR}/openssl-build-arm64" >/dev/null
"${OPENSSL_SRC_DIR}/Configure" darwin64-arm64-cc no-shared no-tests no-unit-test no-docs \
    --prefix="${OPENSSL_INSTALL_ARM64}" \
    --openssldir="${OPENSSL_INSTALL_ARM64}" \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}" -fPIC
make -j"$(sysctl -n hw.ncpu)"
make install_sw
popd >/dev/null

# 3. Build for Intel (x86_64)
echo "Building OpenSSL ${OPENSSL_VERSION} for x86_64..."
rm -rf "${WORK_DIR}/openssl-build-x86_64" "${OPENSSL_INSTALL_X86_64}"
mkdir -p "${WORK_DIR}/openssl-build-x86_64"
pushd "${WORK_DIR}/openssl-build-x86_64" >/dev/null
"${OPENSSL_SRC_DIR}/Configure" darwin64-x86_64-cc no-shared no-tests no-unit-test no-docs \
    --prefix="${OPENSSL_INSTALL_X86_64}" \
    --openssldir="${OPENSSL_INSTALL_X86_64}" \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}" -fPIC
make -j"$(sysctl -n hw.ncpu)"
make install_sw
popd >/dev/null

# 4. Create Universal fat libraries and install headers
echo "Creating Universal OpenSSL libraries..."
rm -rf "${OUTPUT_DIR}/include/openssl" "${OUTPUT_DIR}/lib/libssl.a" "${OUTPUT_DIR}/lib/libcrypto.a"
cp -R "${OPENSSL_INSTALL_ARM64}/include/openssl" "${OUTPUT_DIR}/include/"
lipo -create "${OPENSSL_INSTALL_ARM64}/lib/libssl.a" "${OPENSSL_INSTALL_X86_64}/lib/libssl.a" -output "${OUTPUT_DIR}/lib/libssl.a"
lipo -create "${OPENSSL_INSTALL_ARM64}/lib/libcrypto.a" "${OPENSSL_INSTALL_X86_64}/lib/libcrypto.a" -output "${OUTPUT_DIR}/lib/libcrypto.a"

echo "=============================================================================="
echo "Universal OpenSSL static libraries successfully built and installed!"
echo "Headers: ${OUTPUT_DIR}/include/openssl"
echo "Libs:    ${OUTPUT_DIR}/lib"
lipo -info "${OUTPUT_DIR}/lib/libssl.a" "${OUTPUT_DIR}/lib/libcrypto.a"
echo "=============================================================================="
