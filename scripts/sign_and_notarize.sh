#!/bin/bash
#
# scripts/sign_and_notarize.sh
# Codesigns, packages, notarizes, and staples Chicken Fork for direct distribution.
#

set -euo pipefail

# --- Color formatting helpers ---
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

info()  { echo -e "${BOLD}${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${BOLD}${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${BOLD}${RED}[ERROR]${RESET} $*" >&2; }

# --- Argument & path resolution ---
APP_PATH="${1:-}"
OUTPUT_DIR="${2:-dist}"

if [ -z "$APP_PATH" ]; then
  # Auto-discover Chicken Fork.app in DerivedData if not provided
  APP_PATH=$(find ./DerivedData -name "Chicken Fork.app" -type d 2>/dev/null | head -n 1 || true)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  error "Target application bundle not found: '$APP_PATH'"
  echo "Usage: $0 [path/to/Chicken Fork.app] [output_directory]"
  exit 1
fi

info "Target App Bundle: $APP_PATH"
mkdir -p "$OUTPUT_DIR"

# --- Validate Required Environment Variables ---
MISSING_SECRETS=()
[ -z "${MACOS_CERTIFICATE_P12:-}" ]      && MISSING_SECRETS+=("MACOS_CERTIFICATE_P12")
[ -z "${MACOS_CERTIFICATE_PASSWORD:-}" ] && MISSING_SECRETS+=("MACOS_CERTIFICATE_PASSWORD")
[ -z "${APPLE_API_KEY_CONTENT:-}" ]       && MISSING_SECRETS+=("APPLE_API_KEY_CONTENT")
[ -z "${APPLE_API_KEY_ID:-}" ]            && MISSING_SECRETS+=("APPLE_API_KEY_ID")
[ -z "${APPLE_API_ISSUER:-}" ]            && MISSING_SECRETS+=("APPLE_API_ISSUER")

if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
  error "Missing required Apple Developer / Notarization secrets:"
  for secret in "${MISSING_SECRETS[@]}"; do
    echo "  - $secret"
  done
  echo ""
  echo "Please configure these secrets in your GitHub repository under Settings -> Secrets and variables -> Actions."
  echo "Refer to docs/developer-id-signing.md for setup instructions."
  exit 1
fi

# Temporary storage variables for cleanup trap
TEMP_KEYCHAIN=""
API_KEY_FILE=""
STAGING_DIR=""

cleanup() {
  local exit_code=$?
  info "Cleaning up temporary files and credentials..."

  if [ -n "$API_KEY_FILE" ] && [ -f "$API_KEY_FILE" ]; then
    rm -f "$API_KEY_FILE"
  fi

  if [ -n "$TEMP_KEYCHAIN" ]; then
    if security list-keychains | grep -q "$TEMP_KEYCHAIN"; then
      security default-keychain -s login.keychain-db 2>/dev/null || true
      security delete-keychain "$TEMP_KEYCHAIN" 2>/dev/null || true
    fi
  fi

  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi

  if [ $exit_code -eq 0 ]; then
    info "Sign and notarize completed successfully."
  else
    error "Process failed with exit code $exit_code."
  fi
}
trap cleanup EXIT INT TERM

# --- Step 1: Provision Ephemeral CI Keychain ---
info "Setting up ephemeral macOS keychain for code signing..."
TEMP_KEYCHAIN="temp_signing_$$.keychain"
KEYCHAIN_PWD=$(openssl rand -base64 32)

security create-keychain -p "$KEYCHAIN_PWD" "$TEMP_KEYCHAIN"
security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PWD" "$TEMP_KEYCHAIN"

# Add temporary keychain to user search list
CURRENT_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
security list-keychains -d user -s "$TEMP_KEYCHAIN" $CURRENT_KEYCHAINS

# Import PKCS#12 certificate
TEMP_P12="temp_cert_$$.p12"
echo "$MACOS_CERTIFICATE_P12" | base64 -d > "$TEMP_P12"
security import "$TEMP_P12" -k "$TEMP_KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
rm -f "$TEMP_P12"

# Allow codesign without GUI password prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PWD" "$TEMP_KEYCHAIN" >/dev/null

# Determine signing identity
SIGN_ID="${MACOS_SIGNING_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  # Auto-detect Developer ID identity from imported keychain
  SIGN_ID=$(security find-identity -v -p codesigning "$TEMP_KEYCHAIN" | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

if [ -z "$SIGN_ID" ]; then
  error "Failed to locate a valid 'Developer ID Application' identity in imported keychain!"
  security find-identity -v -p codesigning "$TEMP_KEYCHAIN"
  exit 1
fi

info "Using Signing Identity: $SIGN_ID"

# --- Step 2: Code Sign App Bundle & Nested Resources ---
info "Signing nested binaries and app bundle..."

ENTITLEMENTS_FILE="cotvnc/Resources/ChickenFork.entitlements"
ENTITLEMENTS_FLAG=""
if [ -f "$ENTITLEMENTS_FILE" ]; then
  info "Applying Hardened Runtime entitlements: $ENTITLEMENTS_FILE"
  ENTITLEMENTS_FLAG="--entitlements $ENTITLEMENTS_FILE"
fi

# Sign helper scripts or nested executables if present
if [ -f "$APP_PATH/Contents/Resources/ssh-helper.sh" ]; then
  chmod +x "$APP_PATH/Contents/Resources/ssh-helper.sh"
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP_PATH/Contents/Resources/ssh-helper.sh"
fi

# Sign any frameworks or dylibs if present
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
  find "$APP_PATH/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) -exec \
    codesign --force --options runtime --timestamp -s "$SIGN_ID" {} +
fi

# Sign the main application bundle
codesign --force --deep --options runtime --timestamp \
  $ENTITLEMENTS_FLAG \
  -s "$SIGN_ID" \
  "$APP_PATH"

info "Verifying app bundle signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
info "App signature verification passed."

# --- Step 3: Package DMG ---
VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "2026.11")
DMG_NAME="Chicken-Fork-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

info "Packaging $DMG_NAME..."
STAGING_DIR="dmg_staging_$$"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Chicken Fork" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

sync

# --- Step 4: Code Sign DMG ---
info "Signing DMG with Developer ID Application identity..."
codesign --force --timestamp -s "$SIGN_ID" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
info "DMG signature verified."

# --- Step 5: Apple Notarization with notarytool ---
info "Configuring App Store Connect API Key for notarytool..."
API_KEY_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$API_KEY_DIR"
API_KEY_FILE="$API_KEY_DIR/AuthKey_${APPLE_API_KEY_ID}.p8"

if echo "$APPLE_API_KEY_CONTENT" | grep -q "BEGIN PRIVATE KEY"; then
  echo "$APPLE_API_KEY_CONTENT" > "$API_KEY_FILE"
else
  echo "$APPLE_API_KEY_CONTENT" | base64 -d > "$API_KEY_FILE"
fi
chmod 600 "$API_KEY_FILE"

info "Submitting $DMG_NAME to Apple Notary Service (this may take 1-3 minutes)..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
  --key "$API_KEY_FILE" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --wait 2>&1)

echo "$NOTARY_OUTPUT"

SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -E "^\s*id:" | awk '{print $2}' | head -n 1 || true)
STATUS=$(echo "$NOTARY_OUTPUT" | grep -E "^\s*status:" | awk '{print $2}' | head -n 1 || true)

if [ "$STATUS" != "Accepted" ]; then
  error "Notarization failed with status: '$STATUS'"
  if [ -n "$SUBMISSION_ID" ]; then
    echo "=== Notarization Log ($SUBMISSION_ID) ==="
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$API_KEY_FILE" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER" || true
    echo "=========================================="
  fi
  exit 1
fi
info "Notarization Accepted! Submission ID: $SUBMISSION_ID"

# --- Step 6: Staple Notarization Ticket ---
info "Stapling notarization ticket to $DMG_NAME..."
xcrun stapler staple "$DMG_PATH"

info "Validating stapled ticket..."
xcrun stapler validate "$DMG_PATH"

# --- Step 7: Gatekeeper Assessment ---
info "Assessing Gatekeeper compliance..."
spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

info "=== Artifact Ready for Distribution ==="
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
echo "========================================"

# Export output variables for GitHub Actions if running in GHA
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "dmg_path=$DMG_PATH" >> "$GITHUB_OUTPUT"
  echo "dmg_name=$DMG_NAME" >> "$GITHUB_OUTPUT"
  echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
