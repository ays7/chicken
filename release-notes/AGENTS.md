# Release Notes Editorial Guidelines

Files in this directory are user-facing release notes published for end users and system administrators.

## 🚫 Strict Negative Constraints
- **NO source file names or paths** (e.g., do NOT mention `.m`, `.h`, `.c`, `.swift`, `.sh` files).
- **NO function, method, or selector names** (e.g., do NOT mention `resetCursorRects`, `mouseMoved:`, etc.).
- **NO internal class, struct, or variable names** (e.g., do NOT mention `RFBView`, `RDPConnection`, etc.).
- **NO compiler/CMake flags or build commands** (e.g., do NOT mention `-D...`, raw CLI commands).
- **NO low-level protocol constants or internal enum symbols** (e.g., do NOT mention `PERF_...`, `PTR_FLAGS_...`).

## ✅ Tone & Content Requirements
- Focus on **user-facing benefits and outcomes** (e.g., responsiveness, visual fluidity, reliability, hardware acceleration).
- Refer to technologies by their broad industry or platform names (e.g., "Apple VideoToolbox", "Hardware H.264 Decoding", "RDPEGFX Graphics").
- Keep bullet points concise, benefit-driven, and clear, following the established style of shipped releases (`2026.11.md`, `2026.9.md`).
