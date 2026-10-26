---
name: freerdp-macos-connection
description: >-
  Guide and reference for FreeRDP 3.x client connection setup, lifecycle callbacks,
  rdpSettings configuration, virtual channel loading, macOS AppKit/CoreGraphics
  integration (client/Mac), and Windows Server compatibility (NLA/CredSSP, TLS,
  RDP security, EGFX/H.264/RFX, dynamic resolution, clipboard, and OpenSSL/SSPI).
  Use whenever implementing, reviewing, or debugging FreeRDP client connections.
---

# FreeRDP 3.x Connection Setup, macOS Flow & Windows Compatibility

Use this skill when working with the FreeRDP client API (`libfreerdp-core`, `libfreerdp-client`, `libfreerdp-gdi`, `winpr`) or macOS RDP client code (`client/Mac`).

For deep architectural details, state machines, and callback signatures, read:
- [references/connection-lifecycle-and-settings.md](./references/connection-lifecycle-and-settings.md)

## 1. Critical Lifecycle & Threading Invariants

1. **Single RDP Thread Invariant (`WINPR_TLS g_Instance`)**:
   - `freerdp_connect_begin()` registers `freerdp* instance` in thread-local storage (`g_Instance` in `libfreerdp/core/client.c`).
   - `freerdp_connect()`, `freerdp_get_event_handles()`, `freerdp_check_event_handles()`, and `freerdp_disconnect()` **must all run on the same dedicated connection thread**.
2. **Channel Loading Happens Automatically After `PreConnect`**:
   - `freerdp_client_context_new()` sets `instance->LoadChannels = freerdp_client_load_channels` and registers the static channel addin provider (`freerdp_channels_load_static_addin_entry`).
   - Inside `freerdp_connect_begin()`, **after** `instance->PreConnect(instance)` returns, FreeRDP validates settings, backs up `rdp->originalSettings` (for server redirection/reconnect), and calls `utils_reload_channels(context)`.
   - `utils_reload_channels()` destroys any existing `context->channels`, creates a fresh `rdpChannels*`, calls `instance->LoadChannels(instance)` (`freerdp_client_load_addins`), and calls `freerdp_channels_pre_connect()`.
   - **Rule**: Do **not** call `freerdp_client_load_channels()` inside `PreConnect`. Configure `rdpSettings` flags in `PreConnect` and let `instance->LoadChannels` load the channels in `utils_reload_channels()`.
3. **Always Chain `freerdp_client_OnChannelConnectedEventHandler`**:
   - Subscribe `PubSub_SubscribeChannelConnected(context->pubSub, ...)` and `PubSub_SubscribeChannelDisconnected(context->pubSub, ...)`.
   - For any channel your custom handler does not exclusively manage (especially `RDPGFX_DVC_CHANNEL_NAME`, `AINPUT_DVC_CHANNEL_NAME`, `GEOMETRY_DVC_CHANNEL_NAME`), delegate to `freerdp_client_OnChannelConnectedEventHandler(context, e)` and `freerdp_client_OnChannelDisconnectedEventHandler(context, e)`.
   - When `SoftwareGdi == TRUE`, `freerdp_client_OnChannelConnectedEventHandler` automatically wires `rdpgfx` into `rdpGdi` via `gdi_graphics_pipeline_init(context->gdi, (RdpgfxClientContext*)e->pInterface)`.
4. **Initialize GDI in `PostConnect`, Free in `PostDisconnect`**:
   - Call `gdi_init(instance, PIXEL_FORMAT_BGRX32)` inside `instance->PostConnect` (after capability exchange / `Demand Active` has determined final dimensions).
   - In `DesktopResize`, always call `gdi_resize(context->gdi, width, height)` **before** re-reading `gdi->primary_buffer` and `gdi->stride` (because `gdi_resize` reallocates `primary_buffer`).
   - Call `gdi_free(instance)` inside `instance->PostDisconnect`.
5. **Thread-Safe Input & Cancellation**:
   - Never write to the RDP transport directly from the macOS main thread while the RDP thread is running.
   - Either use FreeRDP's input message queue (`freerdp_get_message_queue_event_handle(instance, FREERDP_INPUT_MESSAGE_QUEUE)` + `freerdp_message_queue_process_message()`, as in `client/Mac/MRDPView.m`) or synchronize input calls.
   - To cancel an in-progress `freerdp_connect()` or stop an active session from the UI thread, call `freerdp_abort_connect_context(context)` (which sets `rdp->abortEvent` and wakes `WaitForMultipleObjects` immediately).

---

## 2. Essential `rdpSettings` for Windows Boxes

> [!IMPORTANT]
> `freerdp_settings_new()` initializes `FreeRDP_SupportGraphicsPipeline`, `FreeRDP_SupportStatusInfoPdu`, `FreeRDP_SupportErrorInfoPdu`, and `FreeRDP_SupportAsymetricKeys` to **`FALSE`** for clients! CLI clients only get EGFX/RFX/H.264 enabled because `freerdp_client_settings_parse_command_line()` calls `prepare_default_settings()` -> `freerdp_set_connection_type(settings, CONNECTION_TYPE_AUTODETECT)` and `freerdp_performance_flags_make(settings)`.

When configuring `rdpSettings` programmatically (without `freerdp_client_settings_parse_command_line`), set the following before `PreConnect` completes:

### A. Platform & Core Identity (macOS)
```c
freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH);
freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH);
```

### B. Graphics, Codecs & Performance (Windows 7/8.1/10/11 & Server 2008 R2–2025)
```c
// Option 1: Use FreeRDP's built-in autodetect preset (enables EGFX, RFX, H264, AVC444, font smoothing, composition)
freerdp_set_connection_type(settings, CONNECTION_TYPE_AUTODETECT);

// Option 2: Explicit graphics & codec configuration
freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);
freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_FastPathInput, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_FrameMarkerCommandEnabled, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_SurfaceFrameMarkerEnabled, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_BitmapCacheEnabled, TRUE);

// Modern RDP8+ Graphics Pipeline [MS-RDPEGFX] (Windows 8.1/10/11, Server 2012 R2+)
// Gracefully ignored by legacy Windows XP/2003/7/2008 R2 servers, which fall back to RFX/NSCodec/GDI orders
freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_GfxPlanar, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_GfxSmallCache, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_GfxProgressiveV2, TRUE);
// Enable H.264 if FreeRDP was built with VideoToolbox / FFmpeg / OpenH264:
freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, TRUE);

// Fast-Path Codecs (used when EGFX is disabled or unsupported by server)
freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE);

// Recompute FreeRDP_PerformanceFlags bitmask from individual boolean flags
// (AllowFontSmoothing, AllowDesktopComposition, DisableWallpaper, DisableFullWindowDrag, DisableMenuAnims)
freerdp_performance_flags_make(settings);
```

### C. Security Negotiation, NLA/CredSSP, TLS & Legacy RDP
```c
freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE);   // PROTOCOL_HYBRID (CredSSP over TLS)
freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);   // PROTOCOL_SSL
freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, TRUE);   // PROTOCOL_RDP (Standard RC4)
freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE);  // PROTOCOL_HYBRID_EX (keep FALSE unless needed)
freerdp_settings_set_uint32(settings, FreeRDP_TlsSecLevel, 1);    // Level 1 allows 1024-bit/SHA-1 certs on Win7/2008R2 (0 for TLS 1.0)
```
- **Nuance 1 — Automatic Protocol Downgrade (`nego.c`)**: With `NlaSecurity`, `TlsSecurity`, and `RdpSecurity` all `TRUE`, FreeRDP proposes `HYBRID | SSL` first. If the Windows server responds with `SSL_REQUIRED_BY_SERVER` or `SSL_NOT_ALLOWED_BY_SERVER`, `nego_connect()` automatically disconnects TCP, reconnects, and negotiates `TLS` or `RDP`.
- **Nuance 2 — Empty Credentials with NLA**: If the server accepts `PROTOCOL_HYBRID` (NLA), it requires credentials *before* starting the session. If `Username` or `Password` is missing, FreeRDP calls `instance->AuthenticateEx(..., AUTH_NLA)`. If `AuthenticateEx` does not supply credentials, NLA fails with `FREERDP_ERROR_CONNECT_LOGON_FAILURE` / `FREERDP_ERROR_CONNECT_CANCELLED` (it will **not** fall back to TLS after `HYBRID` was already selected). To show the remote Windows login screen without local credentials (on servers allowing non-NLA connections), set `FreeRDP_NlaSecurity = FALSE` and `FreeRDP_TlsSecurity = TRUE`.
- **Nuance 3 — macOS Kerberos KDC Timeout vs NTLM**: WinPR's `"Negotiate"` SSP attempts Kerberos before NTLM. On macOS, connecting to an IP address or unreachable Active Directory realm causes `krb5` KDC lookup delays or failures. Force immediate NTLM when Kerberos is not configured:
  ```c
  freerdp_settings_set_string(settings, FreeRDP_AuthenticationPackageList, "!kerberos,!u2u");
  ```
- **Nuance 4 — OpenSSL 3.x MD4/RC4 for NTLM**: NTLM requires MD4 and RC4. Ensure FreeRDP/WinPR on macOS is compiled with `-DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON` (or that OpenSSL 3's `legacy` provider is available).

### D. Channels, Clipboard, Dynamic Resolution & Redirection Dependencies
- **Dynamic Channels (`drdynvc`)**: Set `FreeRDP_SupportDynamicChannels = TRUE` whenever using `disp`, `rdpgfx`, `audin`, `rdpsnd` (dynamic), or `ainput`.
- **Dynamic Display Resize (`disp`)**: Set `FreeRDP_SupportDisplayControl = TRUE` and `FreeRDP_DynamicResolutionUpdate = TRUE`. Once `DispClientContext` connects (`DISP_DVC_CHANNEL_NAME`) and receives `DisplayControlCaps`, send `DISPLAY_CONTROL_MONITOR_LAYOUT` via `disp->SendMonitorLayout(disp, 1, &layout)` (width must be even, `200..8192`).
- **Clipboard (`cliprdr`)**: Set `FreeRDP_RedirectClipboard = TRUE`. In `CLIPRDR_SVC_CHANNEL_NAME`, respond to `MonitorReady` by sending `ClientCapabilities` (`CB_USE_LONG_FORMAT_NAMES`) and `ClientFormatList`. Convert between macOS `NSUTF8StringEncoding` (`\n`) and Windows `CF_UNICODETEXT` (`UTF-16LE` with `\r\n` via WinPR `wClipboard` or manual conversion).
- **Hidden `rdpdr` / `rdpsnd` Coupling (`client/common/cmdline.c:6275–6300`)**:
  - Enabling `FreeRDP_AudioPlayback`, `FreeRDP_NetworkAutoDetect`, `FreeRDP_SupportHeartbeatPdu`, or `FreeRDP_SupportMultitransport` causes `freerdp_client_load_addins()` to automatically enable `FreeRDP_DeviceRedirection = TRUE` (`rdpdr`) and `rdpsnd`!
  - Windows RDP servers require the `rdpdr` static virtual channel to be registered and complete its handshake before initializing the audio driver (`rdpsnd`).
  - Statically link `CHANNEL_RDPSND=ON`, `CHANNEL_RDPSND_CLIENT=ON`, `CHANNEL_RDPDR=ON`, `CHANNEL_RDPDR_CLIENT=ON`, and `-DWITH_MACAUDIO=ON` (`rdpsnd_mac.m` with `AVAudioEngine`).
  - On macOS, linking `rdpsnd_mac.m` and `rdpdr` into the host app requires `AVFoundation.framework`, `CoreAudio.framework`, `AudioToolbox.framework`, and `CoreServices.framework`.
  - When disabling device redirections (drives, printers, smartcards, serial/parallel ports), set their individual booleans (`FreeRDP_RedirectDrives = FALSE`, etc.) to `FALSE` while keeping `FreeRDP_DeviceRedirection = TRUE` when `AudioPlayback == TRUE`.

---

### E. Audio Reception (`rdpsnd` & `drdynvc`) on macOS (Windows & Linux GNOME)

```c
// 1. Enable Audio Playback & Device Redirection
freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, TRUE); // Mandatory for rdpsnd
freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, FALSE);

// 2. Network Autodetect & Heartbeat (MANDATORY for GNOME Remote Desktop)
// GNOME Remote Desktop intentionally drops audio output redirection if the client
// does not support autodetecting network characteristics ([MS-RDPEAUT])!
freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE);
freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, TRUE);

// 3. Dynamic Virtual Channels
freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels, TRUE);
```

- **Linux / GNOME Remote Desktop (RHEL, Fedora, Ubuntu)**:
  - During connection, GNOME Remote Desktop queries client formats (`[AAC: false, Opus: false, PCM: true]`).
  - While it prefers Opus or AAC when compiled with those libraries, standard uncompressed PCM (`WAVE_FORMAT_PCM`, 16-bit stereo 44.1kHz) is fully supported as a fallback over SVC or DVC.
  - **Critical Failure Mode**: If `NetworkAutoDetect` is `FALSE`, `gnome-remote-desktop` logs:
    `[RDP] Client does not support autodetecting network characteristics. Disabling audio output redirection`
    and skips opening the audio channel entirely. Always enable `FreeRDP_NetworkAutoDetect` and `FreeRDP_SupportHeartbeatPdu`.
- **Windows Server / Desktop**:
  - Requires `FreeRDP_DeviceRedirection = TRUE` (`rdpdr`) static channel to complete initialization before the remote audio driver starts streaming `rdpsnd` packets.
- **macOS Backend (`rdpsnd_mac.m`)**:
  - Schedules PCM buffers to `AVAudioPlayerNode` / `AVAudioEngine`.
  - Supports `WAVE_FORMAT_PCM` with `wBitsPerSample == 16` and `nChannels == 2`. Audio blocks arrive over dynamic DVC as `Wave2PDU` (4096 bytes per packet) and static SVC as `WavePDU`.
