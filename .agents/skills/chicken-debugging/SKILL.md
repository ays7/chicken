---
name: chicken-debugging
description: >-
  Troubleshoot and diagnose crashes, exceptions, and protocol faults in Chicken Fork
  using unstripped Development builds and LLDB batch sessions. Use whenever a crash,
  hang, or regression occurs during VNC or RDP connections.
---

# Chicken Fork Debugging & Troubleshooting Guide

Use this skill when investigating crashes, unexpected disconnects, or memory faults in Chicken Fork.

## Why Release / Deployment Builds Mislead Debugging
- Chicken Fork's `Deployment` build enables Link-Time Optimization (LTO) and runs `strip -D` on the binary.
- When stripped binaries crash, backtraces show nearest preceding symbols and inlined offsets, leading to false diagnoses (e.g., attributing socket or drawing faults to unrelated methods like `-[RFBView setDelegate:]`).
- **Rule**: Never debug stripped release binaries. Always build the `Development` configuration.

## Standard Debugging Workflow

### Step 1: Compile the Development Build
Compile with full DWARF debug symbols and active architecture only:
```bash
cd cotvnc && xcodebuild -project ChickenFork.xcodeproj \
  -scheme "Chicken Fork" \
  -configuration Development \
  -derivedDataPath ./DerivedData \
  ONLY_ACTIVE_ARCH=YES \
  DEBUG_INFORMATION_FORMAT="dwarf-with-dsym" \
  GCC_OPTIMIZATION_LEVEL=0 \
  build
```
The resulting unstripped `.app` bundle is located at:
`cotvnc/DerivedData/Build/Products/Development/Chicken Fork.app`

### Step 2: Launch Under LLDB for User Reproduction (Option 1)
Run LLDB in batch mode via a background command (`BypassSandbox: true`):
```bash
lldb "cotvnc/DerivedData/Build/Products/Development/Chicken Fork.app" --batch \
  -o "run" \
  -k "thread backtrace all" \
  -k "frame variable" \
  -k "register read"
```
1. The app GUI appears on the user's macOS desktop.
2. The user interacts with the UI (selects server, enters credentials, connects) to reproduce the fault.
3. When the crash occurs, LLDB catches `EXC_BAD_ACCESS`, `SIGSEGV`, or `objc_exception_throw`.
4. LLDB dumps:
   - Complete stack traces for all active threads (UI main thread, RDP worker thread, channel threads).
   - Exact file names and line numbers from DWARF.
   - Local variables in the crashing frame (`frame variable`).
   - CPU register values (`register read`) showing faulting memory addresses.

### Step 3: Interactive LLDB Shell (Option 2)
If manual inspection (`po`, breakpoints, memory examination) is desired, run in a separate terminal:
```bash
lldb "cotvnc/DerivedData/Build/Products/Development/Chicken Fork.app"
(lldb) run
```

### Step 4: Diagnostic Checklist
- **Register `0x0` / Low Addresses (`0x8`, `0x10`, etc.)**: Dereference of a nil or uninitialized ivar/struct pointer.
- **`0x7fff...` / Garbage Addresses**: Use-after-free or dangling pointer across thread boundaries.
- **Thread 1 in UI, Thread 2 in FreeRDP/libwinpr**: Check for thread-safety violations between background sockets and AppKit UI objects.

---

## 3. RDP Audio & Dynamic Virtual Channel Diagnostics

When diagnosing silent audio, missing dynamic virtual channels, or server channel drops:

### 1. Elevate FreeRDP Channel Log Levels
Enable `WLOG_DEBUG` in `threadMain:` or before connection:
```c
#include <winpr/wlog.h>
WLog_SetLogLevel(WLog_Get("com.freerdp.channels.rdpsnd.client"), WLOG_DEBUG);
WLog_SetLogLevel(WLog_Get("com.freerdp.channels.drdynvc.client"), WLOG_DEBUG);
WLog_SetLogLevel(WLog_Get("com.freerdp.codec.dsp"), WLOG_DEBUG);
```
- Logs every `CreateListener`, `process_create_request`, and `open_channel`.
- Dumps server audio format offerings (`Server Audio Formats`) and client replies (`Client Audio Formats`).
- Logs every `WavePDU` / `Wave2PDU` block received and sent to CoreAudio.

### 2. Inspect Server-Side Logs (Linux / GNOME Remote Desktop)
```bash
sudo journalctl -b | grep -E "gnome-remote-desktop|\[RDP" | tail -n 100
```
- Look for: `[RDP] Client does not support autodetecting network characteristics. Disabling audio output redirection`
  - **Remedy**: Set `freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE)` and `SupportHeartbeatPdu = TRUE`.
- Look for: `[RDP.AUDIO_PLAYBACK] Client Formats: [AAC: ..., Opus: ..., PCM: ...]`
  - Confirms if client advertised formats were accepted or rejected.

### 3. Check Remote PipeWire Audio Graph (Linux)
```bash
wpctl status
pactl list sinks short
```
- Check under `Video` and `Audio` streams:
  - If `gnome-remote-desktop-daemon` only appears under `Video Streams` and not `Audio Streams`, the server audio driver/sink was not initialized for this RDP connection.
