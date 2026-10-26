# Apple Developer ID Code Signing & Notarization Guide

This guide walks you through setting up Apple Developer ID code signing and Apple Notarization for Chicken Fork distribution outside the Mac App Store via GitHub Releases.

---

## Overview of Credentials Needed

To sign and notarize headlessly in GitHub Actions, you need:
1. **Developer ID Application Certificate (`.p12`)** + Passphrase
2. **App Store Connect API Key (`.p8`)** + Key ID + Issuer ID
3. Six GitHub Repository Secrets configured in your repository settings

---

## Step 1: Create a Certificate Signing Request (CSR)

1. Open **Keychain Access** on your Mac (`/Applications/Utilities/Keychain Access.app` or Spotlight: `Keychain Access`).
2. In the top menu bar, select:
   **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority...**
3. In the Certificate Assistant window:
   - **User Email Address:** Enter your Apple Developer email address.
   - **Common Name:** Enter your name or company name (e.g., `Alexey Developer ID`).
   - **CA Email Address:** Leave blank.
   - **Request is:** Select **Saved to disk**.
   - Check **Let me specify key pair information**.
4. Click **Continue**.
5. Set **Key Size:** `2048 bits` and **Algorithm:** `RSA`.
6. Click **Continue** and save the file as `CertificateSigningRequest.certSigningRequest` on your Desktop.

---

## Step 2: Generate the Developer ID Application Certificate

> [!IMPORTANT]
> You must choose **"Developer ID Application"**.
> - Do **NOT** choose "Apple Development" (only runs on local registered dev devices).
> - Do **NOT** choose "Mac App Distribution" (only runs inside the Mac App Store sandbox).
> - Do **NOT** choose "Developer ID Installer" (only used for `.pkg` package installers, not `.app` or `.dmg`).

1. Log in to [Apple Developer: Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
2. Click the blue **+** button next to **Certificates**.
3. Under **Software**, select:
   🔘 **Developer ID Application**
4. Click **Continue**.
5. When prompted, upload the `CertificateSigningRequest.certSigningRequest` file you saved in Step 1.
6. Click **Continue**.
7. Download the generated certificate file (named `developerID_application.cer`).
8. Double-click `developerID_application.cer` in Finder to install it into your macOS **login** keychain.

---

## Step 3: Export the Certificate as a `.p12` File

1. In **Keychain Access**, select the **login** keychain on the left and the **My Certificates** tab.
2. Locate the certificate:
   `Developer ID Application: <Your Name / Organization> (<Team ID>)`
3. Click the small arrow to expand it. Ensure your private key is nested under the certificate.
4. Right-click the **Developer ID Application** certificate (with its private key) and choose **Export "Developer ID Application: ...":**
5. Save settings:
   - **File Format:** `Personal Information Exchange (.p12)`
   - **File Name:** `DeveloperIDApp.p12`
6. Click **Save**.
7. Enter a strong password to protect the `.p12` export. **Remember this password** (this becomes `MACOS_CERTIFICATE_PASSWORD`).
8. If macOS prompts for your Mac login password to authorize exporting the key, enter your Mac password and click **Allow**.

### Base64 Encode the `.p12` for GitHub:
Run the following in your terminal to copy the base64-encoded certificate directly to your clipboard:
```bash
base64 -i ~/Desktop/DeveloperIDApp.p12 | pbcopy
```
*(Keep this clipboard value handy for Step 5).*

---

## Step 4: Create an App Store Connect API Key for Notarization

Apple requires headless CI to authenticate with `notarytool`. The App Store Connect API key does not expire and does not trigger two-factor authentication prompts.

1. Go to [App Store Connect: Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api).
2. Select the **App Store Connect API** tab.
   *(If prompted to generate your first API key, click **Request Access**).*
3. Copy the **Issuer ID** (a UUID like `57246542-96fe-1a63-e053-0824d011072a`) displayed at the top. This will be `APPLE_API_ISSUER`.
4. Click the **+** button to generate a new key:
   - **Name:** `Chicken Fork CI Notarization`
   - **Access:** Select **Developer** (or **App Manager**).
5. Click **Generate**.
6. Note the **Key ID** (a 10-character code like `2X9R427N34`). This will be `APPLE_API_KEY_ID`.
7. Click **Download API Key** next to the key you just created.
   > [!WARNING]
   > Apple only allows you to download this private key file (`AuthKey_XXXXXXXXXX.p8`) **once**. Store a backup securely!

### Base64 Encode the `.p8` file:
```bash
base64 -i ~/Downloads/AuthKey_*.p8 | pbcopy
```
*(Or you can paste the raw contents of the `.p8` file starting with `-----BEGIN PRIVATE KEY-----`).*

---

## Step 5: Configure GitHub Repository Secrets

In your GitHub repository (e.g. `ays7/chicken`):
1. Navigate to: **Settings → Secrets and variables → Actions**.
2. Click **New repository secret** for each of the following:

| Secret Name | Value |
| :--- | :--- |
| `MACOS_CERTIFICATE_P12` | The base64 string of `DeveloperIDApp.p12` (from Step 3) |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` (from Step 3) |
| `MACOS_SIGNING_IDENTITY` | Exact certificate name, e.g. `Developer ID Application: Your Name (TEAMID)`. *(Optional: script will auto-detect if left blank)* |
| `APPLE_API_KEY_CONTENT` | The base64 or raw text content of `AuthKey_*.p8` (from Step 4) |
| `APPLE_API_KEY_ID` | The 10-character Key ID (from Step 4) |
| `APPLE_API_ISSUER` | The Issuer ID UUID (from Step 4) |

---

## Step 6: Testing & Verification

### Test via GitHub Actions `workflow_dispatch`
1. Go to **Actions** in your GitHub repository.
2. Select **Publish Release** in the left sidebar.
3. Click **Run workflow**:
   - (Optional) Enter a test tag name or leave blank to test packaging.
4. Watch the workflow steps:
   - Ephemeral keychain created and unlocked.
   - Binaries and `Chicken Fork.app` signed with Hardened Runtime & secure timestamp.
   - DMG packaged and signed with Developer ID Application.
   - `xcrun notarytool submit` uploads the DMG and polls status until `Accepted`.
   - `xcrun stapler staple` pins the notarization ticket to the DMG.
   - `spctl -a -t open --context context:primary-signature -v` validates Gatekeeper approval (`source=Notarized Developer ID`).
   - Temporary keychain and credentials destroyed.

### Verify on macOS
Download the released DMG and run:
```bash
# 1. Verify DMG code signature
codesign -dv --verbose=4 Chicken-Fork-2026.11.dmg

# 2. Verify notarization ticket is stapled
xcrun stapler validate Chicken-Fork-2026.11.dmg

# 3. Verify Gatekeeper acceptance
spctl -a -t open --context context:primary-signature -v Chicken-Fork-2026.11.dmg
```
Expected output:
```
Chicken-Fork-2026.11.dmg: accepted
source=Notarized Developer ID
```
When an end user opens the DMG and launches the application, macOS will show a clean, friendly prompt with an immediate **Open** button, with no warnings about unidentified developers.
