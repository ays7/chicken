# Security Policy

## Supported Versions

Only the latest release track of Chicken Fork receives active security updates and vulnerability patches.

| Version | Supported          | Notes                                     |
| ------- | ------------------ | ----------------------------------------- |
| 2026.x  | :white_check_mark: | Active support (current release: 2026.11) |
| < 2026  | :x:                | Unsupported legacy releases               |

Users are strongly encouraged to keep their Chicken Fork installation up to date with the latest release.

---

## Reporting a Vulnerability

We take the security of Chicken Fork and its users seriously. If you discover a security vulnerability, we appreciate your help in disclosing it responsibly.

### How to Report

Please **do not** report security vulnerabilities through public GitHub issues, pull requests, or public discussions.

Instead, please report vulnerabilities using either of the following private channels:

1. **GitHub Private Vulnerability Reporting (Recommended)**:
   Submit an advisory report through GitHub's private vulnerability portal:  
   👉 [New Security Advisory](https://github.com/ays7/chicken/security/advisories/new)

2. **Direct Email**:
   Send an email to: **`chickenfork77@gmail.com`**  
   If possible, please encrypt sensitive information or coordinate with us for encrypted communication.

### What to Include

To help us investigate and resolve the issue quickly, please include:
- A clear description of the vulnerability and its potential impact.
- Step-by-step instructions or a minimal proof of concept (PoC) to reproduce the issue.
- Specific operating system version (macOS version, architecture: Apple Silicon / Intel).
- The version of Chicken Fork being used.
- Any relevant logs or stack traces.

### Response Timeline

- **Acknowledgment**: We aim to acknowledge receipt of your vulnerability report within **48–72 hours**.
- **Assessment**: We will verify the issue, assess severity, and provide regular progress updates.
- **Resolution & Disclosure**: Once a fix is verified, a patched release will be published, and an advisory will be coordinated in consultation with the reporter.

---

## Scope & Threat Model

Chicken Fork is an open-source macOS VNC and RDP remote desktop client. Areas within security scope include:

- **Protocol Decoders & Parsers**: FreeRDP engine integration, GDI order rendering, RFB (VNC) frame decoders, and virtual channels (`rdpsnd`, `cliprdr`, `disp`, `rdpgfx`).
- **Cryptographic & Authentication Handling**: NLA / CredSSP / TLS negotiation, SSPI NTLM/Kerberos packages, and SSH tunnel session management.
- **Clipboard & Data Isolation**: Secure handling of clipboard data formats between remote sessions and macOS pasteboards.
- **Local Application Security**: Memory safety, preventing unauthorized local code execution or privilege escalation via crafted server payloads.

### Out of Scope

- Attacks requiring unrestricted physical access to an unlocked host Mac.
- Denial-of-service against local UI event loops that do not affect system security or compromise remote credentials.
- Known vulnerabilities in outdated, unsupported legacy versions.

---

## Security Best Practices for Users

- **RDP Connections**: Always ensure Network Level Authentication (NLA) or TLS security is enabled (`FreeRDP_NlaSecurity` / `FreeRDP_TlsSecurity`), and verify server certificates.
- **VNC Connections**: Standard VNC traffic is unencrypted by default. Always enable the built-in **SSH Tunnel** feature in Chicken Fork when connecting to VNC servers across untrusted networks or the public internet.
- **Downloads & Integrity**: Download official releases exclusively from the [GitHub Releases](https://github.com/ays7/chicken/releases) page and verify SHA-256 checksums when provided.
