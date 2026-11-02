---
name: release-attribution
description: >-
  Direct and manage release version attribution for all changes, features, and dependency
  updates in Chicken Fork. Defines the active in-development release target, shipped release
  history, and the checklist of files to update when logging changes or bumping releases.
---

# Release Attribution & Version Management Guide

Use this skill when attributing new code changes, feature additions, dependency upgrades (e.g. FreeRDP, OpenSSL, libjpeg-turbo), or bug fixes to Chicken Fork releases.

---

## 📌 Release Target Configuration

| Role | Version | Status | Release Date |
| :--- | :--- | :--- | :--- |
| **Active Target** | **`2026.12`** | **In Development (Target for all new changes)** | December 2026 |
| Shipped Release | `2026.11` | Shipped (IMMUTABLE) | November 2026 |
| Shipped Release | `2026.9` | Shipped (IMMUTABLE) | August 2026 |
| Shipped Release | `2026.6` | Shipped (IMMUTABLE) | June 2026 |

> [!IMPORTANT]
> **Cardinal Rule of Change Attribution:**
> **Never** attribute newly developed changes, refactors, or dependency upgrades to a version that has already shipped (such as `2026.11`). All new modifications must be attributed exclusively to the current active in-development release target (**`2026.12`**). Shipped release notes and historical changelog entries are immutable records of what was actually published.

---

## 📁 Release Attribution Checklist

When introducing changes or dependency bumps, update the following files in accordance with the active release target:

### 1. Release Notes (`release-notes/`)
- Record new features, library upgrades, and fixes in `release-notes/<ACTIVE_VERSION>.md` (currently `release-notes/2026.12.md`).
- Keep past release files (e.g., `release-notes/2026.11.md`) frozen with the contents as originally shipped.

### 2. Project Metadata & Build Settings
- **`cotvnc/Resources/Info.plist`**:
  - `CFBundleShortVersionString`: Set to active target (e.g., `2026.12`).
  - `CFBundleVersion`: Set to active target (e.g., `2026.12`).
- **`cotvnc/ChickenFork.xcodeproj/project.pbxproj`**:
  - Update `_CHICKEN_VERSION_` across all build configurations (`Development`, `Deployment`, `Default`, `Universal Fast Development`).

### 3. Readme & Documentation (`README.md`, `docs/`)
- **`README.md`**:
  - Add the new version link to the `## 📝 Release Notes` list.
  - Distinguish historical feature introductions (e.g., "RDP support added in 2026.11") from subsequent upgrades (e.g., "FreeRDP 3.33.0 upgrade in 2026.12").
- **`docs/history.html`**:
  - Add a new `<div class="release-card">` at the top of the "Modern Chicken Fork Releases" section marked `&bull; In Development`.
  - Ensure previous release cards retain their accurate, historical feature bullet points.
- **`docs/rdp.html` & `docs/faq.html`**:
  - When library versions are mentioned, attribute upgrades to the active release (e.g. "FreeRDP 3.x, upgraded to 3.33.0 in 2026.12").
- **`docs/index.html`**:
  - Update the `softwareVersion` in the JSON-LD schema.
  - Update the changelog summary table description.
- **Header Version Pills (`docs/*.html`)**:
  - The navbar version pills (`<a class="version-pill">`) reflect the latest shipped release or the active target as determined by release packaging.

### 4. CI & Packaging Scripts
- `scripts/sign_and_notarize.sh`: Default fallback version.
- `.github/workflows/build.yml`: Fallback version string.

---

## 🔄 Procedure for Bumping to a New Release Cycle

When the active release (e.g. `2026.12`) ships:
1. Update `release-notes/2026.12.md` release date and finalize changelog bullets.
2. In `docs/history.html`, change `&bull; In Development` to `&bull; Latest Release` and remove `Latest Release` from the prior version.
3. Advance the "Active Target" in this skill file (`SKILL.md`) to the next release (e.g. `2027.01` or `2026.13`).
4. Create the new `release-notes/<NEXT_VERSION>.md` template.
5. Bump `Info.plist` and `project.pbxproj` (`_CHICKEN_VERSION_`) to the next version.
