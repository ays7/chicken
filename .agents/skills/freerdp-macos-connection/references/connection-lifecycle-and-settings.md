# FreeRDP 3.x Connection Lifecycle, macOS Flow & Windows Settings Reference

This reference documents the exact connection lifecycle, state machines, macOS client implementation (`client/Mac`), and Windows Server compatibility nuances from the FreeRDP 3.x codebase (`/Volumes/Sync/ap/FreeRDP`).

---

## 1. End-to-End Connection Setup & Lifecycle

### 1.1 Instance Creation & Context Allocation (`client/common/client.c`)
The standard client entry point is `freerdp_client_context_new(const RDP_CLIENT_ENTRY_POINTS* pEntryPoints)`:
1. **`pEntryPoints->GlobalInit()`**: Runs client-specific global initialization (e.g., `mfreerdp_client_global_init` in `client/Mac/mf_client.m`, calling `freerdp_handle_signals()`).
2. **`freerdp_new()` (`libfreerdp/core/freerdp.c`)**: Allocates the `freerdp` instance struct and initializes version/size metadata.
3. **Context sizing and callbacks (`client/common/client.c:166–251`)**:
   - Sets `instance->ContextSize = pEntryPoints->ContextSize` (must be `>= sizeof(rdpClientContext)` — validated by `requireRdpClientContext()`).
   - Sets `instance->ContextNew = freerdp_client_common_new` and `instance->ContextFree = freerdp_client_common_free`.
   - Copies `pEntryPoints` to `instance->pClientEntryPoints`.
4. **`freerdp_context_new_ex(instance, pEntryPoints->settings)` (`libfreerdp/core/freerdp.c`)**:
   - Allocates `instance->context` of size `instance->ContextSize` (zero-initialized).
   - Calls `rdp_new(context)` (`libfreerdp/core/rdp.c`), which allocates:
     - `context->rdp` (`rdpRdp*`), `context->settings` (`freerdp_settings_new(0)`), and `rdp->originalSettings` (backup copy).
     - `context->input` (`rdpInput*`), `context->update` (`rdpUpdate*`), `context->autodetect`, `context->heartbeat`, `context->multitransport`, `context->pubSub` (`wPubSub*`), `context->metrics`.
     - `rdp->nego` (`rdpNego*`), `rdp->transport` (`rdpTransport*`), `rdp->mcs` (`rdpMcs*`), `rdp->license`, `rdp->redirection`, `rdp->finalize`, `rdp->abortEvent` (manual-reset WinPR event).
   - Allocates `context->errorInfo` and `context->channels = freerdp_channels_new(instance)`.
   - Invokes `instance->ContextNew(instance, instance->context)` (`freerdp_client_common_new`):
     - Sets `instance->LoadChannels = freerdp_client_load_channels`.
     - Calls `set_default_callbacks(instance)` (installs CLI fallback callbacks).
     - Allocates `cctx->oauth2`.
     - Calls `pEntryPoints->ClientNew(instance, context)` (e.g., `mfreerdp_client_new` in `client/Mac/mf_client.m`).
   - Registers static channel addin provider via `freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0)`.

### 1.2 `freerdp_connect(instance)` & `freerdp_connect_begin(instance)` (`libfreerdp/core/freerdp.c:87–316`)
1. **`freerdp_connect_begin(instance)`**:
   - Resets `instance->ConnectionCallbackState = CLIENT_STATE_INITIAL`, clears last error and channel error, and calls `utils_reset_abort(rdp)` (resets `rdp->abortEvent`).
   - Calls `freerdp_channels_register_instance(context->channels, instance)` (`libfreerdp/core/client.c`), storing `instance` in the **`WINPR_TLS` thread-local variable `g_Instance`**.
     - **CRITICAL**: Because `FreeRDP_VirtualChannelInitEx` reads `g_Instance` from thread-local storage, `freerdp_connect()` **must** execute on the dedicated RDP worker thread.
   - Calls `freerdp_settings_set_default_order_support(settings)`.
   - Registers signal cleanup handler (`sig_abort_connect`).
   - **Calls `instance->PreConnect(instance)`** and transitions to `CLIENT_STATE_PRECONNECT_PASSED`.
   - **Post-`PreConnect` validation and backup (`freerdp.c:123–137`)**:
     - `freerdp_settings_print_warnings(settings)`
     - `freerdp_settings_enforce_monitor_exists(settings)`: Ensures at least 1 monitor in `MonitorDefArray` matching `DesktopWidth` x `DesktopHeight`.
     - `freerdp_settings_enforce_consistency(settings)`: Resolves conflicting settings (e.g., disables `SupportDisplayControl` if `UseMultimon && !ForceMultimon` with `MonitorCount > 1`; adjusts `SaltedChecksum` / `FastPathOutput` for Standard RDP security).
     - `freerdp_settings_check_client_after_preconnect(settings)`: Verifies monitor bounds (`200..32766`), no monitor overlaps or gaps, primary monitor at `(0,0)`.
     - `rdp_set_backup_settings(rdp)`: Saves a clean snapshot of `settings` into `rdp->originalSettings` so server redirection or auto-reconnect can restore pre-negotiation state.
     - **`utils_reload_channels(instance->context)` (`libfreerdp/core/utils.c`)**:
       - Closes/frees any existing `context->channels`, allocates a new `freerdp_channels_new(instance)`, registers `g_Instance`, invokes **`instance->LoadChannels(instance)`** (`freerdp_client_load_channels` -> `freerdp_client_load_addins(channels, settings)` in `client/common/cmdline.c`), and calls **`freerdp_channels_pre_connect(context->channels, instance)`**.
   - **Calls `rdp_client_connect(rdp)` (`libfreerdp/core/connection.c:302`)**:
     - Calls `rdp_client_reset_codecs(context)` (initializes `context->codecs` with `freerdp_settings_get_codecs_flags(settings)` for `DesktopWidth` x `DesktopHeight`; disables `GfxH264`/`GfxAVC444` at runtime if H.264 decoder failed to initialize).
     - Initializes OpenSSL via `winpr_InitializeSSL(flags)`.
     - Configures `rdp->nego` from `settings` (target host/port, cookie `DOMAIN\user` or `user`, `NegotiateSecurityLayer`, `RestrictedAdminModeRequired`, `RemoteCredentialGuard`, `GatewayEnabled`, `RdpSecurity`, `TlsSecurity`, `NlaSecurity`, `ExtSecurity`, `RdstlsSecurity`, `AadSecurity`, `LoadBalanceInfo`).
     - Transitions to `CONNECTION_STATE_NEGO` and calls `nego_connect(rdp->nego)`.

### 1.3 Security Negotiation & Fallback (`libfreerdp/core/nego.c`)
In `nego_connect(rdpNego* nego)` (`nego.c:165`):
1. If `NegotiateSecurityLayer` is `TRUE` (default), `nego` attempts enabled protocols in strict order:
   - `NEGO_STATE_AAD` (`PROTOCOL_RDSAAD`)
   - `NEGO_STATE_RDSTLS` (`PROTOCOL_RDSTLS | PROTOCOL_SSL`)
   - `NEGO_STATE_EXT` (`PROTOCOL_HYBRID_EX | PROTOCOL_HYBRID | PROTOCOL_SSL`)
   - `NEGO_STATE_NLA` (`PROTOCOL_HYBRID | PROTOCOL_SSL`)
   - `NEGO_STATE_TLS` (`PROTOCOL_SSL`)
   - `NEGO_STATE_RDP` (`PROTOCOL_RDP`)
2. For each state:
   - Connects TCP (`nego_transport_connect` -> `transport_connect`), sends X.224 Connection Request PDU with `RDP_NEG_REQ`, and awaits X.224 Connection Confirm (`nego_recv_response`).
   - **Automatic Protocol Downgrade (`nego_process_negotiation_failure`)**:
     - If the server returns `TYPE_RDP_NEG_FAILURE` (e.g., `SSL_REQUIRED_BY_SERVER`, `SSL_NOT_ALLOWED_BY_SERVER`, `HYBRID_REQUIRED_BY_SERVER`, `SSL_CERT_NOT_ON_SERVER`), `nego` adjusts `EnabledProtocols`, disconnects the TCP socket (`nego_transport_disconnect`), transitions to the next enabled fallback state (`NEGO_STATE_NLA` -> `NEGO_STATE_TLS` -> `NEGO_STATE_RDP`), and reconnects TCP to send a new X.224 Connection Request!
3. Once `SelectedProtocol` is agreed upon, `nego_security_connect(nego)` upgrades the transport:
   - `PROTOCOL_HYBRID` / `PROTOCOL_HYBRID_EX`: `transport_connect_nla(transport, earlyUserAuth)` -> establishes TLS (`transport_connect_tls`), verifies server certificate, extracts server public key, and runs `nla_client_authenticate(rdp->nla)`.
   - `PROTOCOL_SSL`: `transport_connect_tls(transport)` -> establishes TLS and verifies server certificate.
   - `PROTOCOL_RDSTLS`: `transport_connect_rdstls(transport)`.
   - `PROTOCOL_RDSAAD`: `transport_connect_aad(transport)`.
   - `PROTOCOL_RDP`: `transport_connect_rdp(transport)` -> uses classic RC4/RSA RDP security layer (`UseRdpSecurityLayer = TRUE`).

### 1.4 CredSSP / NLA Authentication (`libfreerdp/core/nla.c`)
1. **`nla_client_init` (`nla.c:453`)**:
   - Adjusts smartcard settings if `SmartcardLogon` is enabled.
   - Initializes `credssp_auth_init(nla->auth, NEGO_SSP_NAME, nullptr)`.
   - Calls `nla_client_setup_identity(nla)` (`nla.c:317`):
     - If `Username` is empty or `Password` (and `RedirectionPassword` / `PasswordHash` / `RemoteCredentialGuard`) is empty, sets `PromptPassword = TRUE` and calls **`utils_authenticate(instance, AUTH_NLA, TRUE)`** -> **`instance->AuthenticateEx(instance, &username, &password, &domain, AUTH_NLA)`**.
     - Populates `SEC_WINNT_AUTH_IDENTITY` (`nla->identity`).
   - Sets up client SPN `TERMSRV/<ServerHostname>` via `credssp_auth_setup_client()`.
   - Retrieves TLS server certificate public key via `transport_get_public_key()`.
2. **Synchronous NLA Handshake Loop (`nla_client_authenticate`, `nla.c:683`)**:
   - Sends initial SPNEGO/NTLM/Kerberos `negoToken` (`nla_client_begin`).
   - Loops calling `transport_read_pdu(nla->transport, s)` and `nla_recv_pdu(nla, s)` until `nla->state >= NLA_STATE_AUTH_INFO`:
     - Exchanges `negoToken` messages (`NLA_STATE_NEGO_TOKEN`).
     - Verifies server public key (`NLA_STATE_PUB_KEY_AUTH`):
       - **CredSSP v2–v4**: `nla_encrypt_public_key_echo` / `nla_decrypt_public_key_echo`.
       - **CredSSP v5–v6 (CVE-2018-0886 fix on modern Windows)**: SHA-256 binding hash over `"CredSSP Client-To-Server Binding Hash\0" + ClientNonce + PublicKey` (`nla_encrypt_public_key_hash` / `nla_decrypt_public_key_hash`).
     - Encrypts and sends `TSCredentials` (`nla_encrypt_ts_credentials`).
     - If `earlyUserAuth` (`PROTOCOL_HYBRID_EX` / `ExtSecurity`), waits for 4-byte `AUTHZ_SUCCESS` (`0x00000000`) or `AUTHZ_ACCESS_DENIED` (`0x00000005`).

### 1.5 MCS, Licensing, Capability Exchange & Finalization (`libfreerdp/core/connection.c`)
After `nego_connect` succeeds in `rdp_client_connect()`:
1. Sends **MCS Connect Initial PDU** with GCC Conference Create Request (`rdp_recv_callback` with empty stream transitions from `CONNECTION_STATE_NEGO` -> `CONNECTION_STATE_MCS_CREATE_REQUEST`).
2. Switches transport to non-blocking mode (`transport_set_blocking_mode(transport, FALSE)`), registers `rdp_recv_callback`, and enters **`rdp_client_wait_for_activation(rdp)`** (bounded by `FreeRDP_TcpAckTimeout`, default `9000` ms).
3. Inside `rdp_client_wait_for_activation`, `WaitForMultipleObjectsEx` + `rdp_check_fds` advances `rdp->state` through:
   - `CONNECTION_STATE_MCS_CREATE_RESPONSE` (parses GCC Conference Create Response)
   - `CONNECTION_STATE_MCS_ERECT_DOMAIN` (sends MCS Erect Domain Request)
   - `CONNECTION_STATE_MCS_ATTACH_USER` (sends MCS Attach User Request, receives Confirm)
   - `CONNECTION_STATE_MCS_CHANNEL_JOIN_REQUEST` / `RESPONSE` (joins user channel, I/O channel, and all static virtual channels; supports `SupportSkipChannelJoin` fast-join)
   - `CONNECTION_STATE_RDP_SECURITY_COMMENCEMENT` (`rdp_client_establish_keys` if `UseRdpSecurityLayer`)
   - `CONNECTION_STATE_SECURE_SETTINGS_EXCHANGE` (sends Client Info PDU with credentials, timezone, `PerformanceFlags`)
   - `CONNECTION_STATE_CONNECT_TIME_AUTO_DETECT_REQUEST` / `RESPONSE`
   - `CONNECTION_STATE_LICENSING` (processes Server License Error / Valid Client PDUs)
   - `CONNECTION_STATE_MULTITRANSPORT_BOOTSTRAPPING_REQUEST` / `RESPONSE`
   - `CONNECTION_STATE_CAPABILITIES_EXCHANGE_DEMAND_ACTIVE` (receives Server `Demand Active PDU`, sends Client `Confirm Active PDU`)
   - `CONNECTION_STATE_FINALIZATION_*` (sends Client Synchronize, Control Cooperate, Control Request Control, Persistent Key List, Font List PDUs; receives Server Synchronize, Cooperate, Granted Control, Font Map PDUs)
   - **`CONNECTION_STATE_ACTIVE`**: `rdp_is_active_state(rdp)` becomes `TRUE` and `rdp_client_wait_for_activation` returns `TRUE`.

### 1.6 `PostConnect` & Channel Activation (`libfreerdp/core/freerdp.c:201–316`)
When `freerdp_connect_begin()` returns `1`:
1. Registers pointer cache callbacks (`pointer_cache_register_callbacks(context->update)`).
2. **Calls `instance->PostConnect(instance)`** (`CLIENT_STATE_POSTCONNECT_PASSED`):
   - Client calls `gdi_init(instance, PIXEL_FORMAT_BGRX32)`.
   - Client registers `rdpPointer` callbacks (`graphics_register_pointer(context->graphics, &rdp_pointer)`).
3. **Calls `freerdp_channels_post_connect(context->channels, instance)`**:
   - Sends `CHANNEL_EVENT_CONNECTED` to all static channels (`cliprdr`, `rdpdr`, `rdpsnd`, `drdynvc`, etc.).
   - Fires `PubSub_OnChannelConnected(context->pubSub, context, &e)` for each static channel.
   - When `drdynvc` initializes, it opens negotiated Dynamic Virtual Channels (`rdpgfx`, `disp`, `audin`, `ainput`, `rdpei`) and fires `PubSub_OnChannelConnected` for each DVC as the server opens it.
4. **Calls `update_post_connect(context->update)`**.
5. Sets `transport_set_connected_event(rdp->transport)` and publishes `PubSub_OnConnectionResult`.

---

## 2. macOS Client Architecture (`client/Mac/`)

### 2.1 Files & Responsibilities
- **`client/Mac/mf_client.m`**: Implements `RdpClientEntry()`, `mfreerdp_client_new()` (assigns `PreConnect`, `PostConnect`, `PostDisconnect`, `AuthenticateEx`, `VerifyCertificateEx`, `VerifyChangedCertificateEx`, `LogonErrorInfo`, and `mfc->stopEvent`), `mfreerdp_client_start()`, `mfreerdp_client_stop()`, and mouse coordinate scaling (`mf_scale_mouse_event`).
- **`client/Mac/MRDPView.m`**: `NSView` subclass managing the connection thread (`mac_client_thread`), CoreGraphics `CGBitmapContext` rendering (`drawRect:`), `NSCursor` pointer cache, AppKit keyboard/mouse events, and modal credential/certificate sheets.
- **`client/Mac/Keyboard.m`**: Uses `IOHIDManager` (`mac_detect_keyboard_type`) to detect Apple ANSI, ISO, and JIS keyboards (`APPLE_KEYBOARD_TYPE_*`).
- **`client/Mac/Clipboard.m`**: Bridges `CliprdrClientContext` and `NSPasteboard` using WinPR's `wClipboard` synthesizer and a 500ms `NSTimer` (`onPasteboardTimerFired:`).
- **`client/Mac/PasswordDialog.m` & `CertificateDialog.m`**: Modal `NSWindowController` sheets dispatched onto the main thread via `dispatch_sync(dispatch_get_main_queue(), ...)`.

### 2.2 Threading & Event Loop Pattern (`MRDPView.m:126–212`)
```c
DWORD WINAPI mac_client_thread(void *param)
{
    @autoreleasepool
    {
        rdpContext *context = (rdpContext *)param;
        mfContext *mfc = (mfContext *)context;
        freerdp *instance = context->instance;
        HANDLE events[64] = WINPR_C_ARRAY_INIT;

        if (!freerdp_connect(instance))
            return 0;

        HANDLE inputEvent = freerdp_get_message_queue_event_handle(instance, FREERDP_INPUT_MESSAGE_QUEUE);

        while (!freerdp_shall_disconnect_context(context))
        {
            DWORD nCount = 0;
            events[nCount++] = mfc->stopEvent;
            if (inputEvent)
                events[nCount++] = inputEvent;

            DWORD tmp = freerdp_get_event_handles(context, &events[nCount], ARRAYSIZE(events) - nCount);
            if (tmp == 0)
                break;
            nCount += tmp;

            DWORD rc = WaitForMultipleObjects(nCount, events, FALSE, INFINITE);
            if (rc >= (WAIT_OBJECT_0 + nCount) || rc == WAIT_OBJECT_0)
                break;

            if (inputEvent && WaitForSingleObject(inputEvent, 0) == WAIT_OBJECT_0)
                input_activity_cb(instance); // processes FREERDP_INPUT_MESSAGE_QUEUE

            if (!freerdp_check_event_handles(context))
                break;
        }

        freerdp_disconnect(instance);
        return 0;
    }
}
```

### 2.3 CoreGraphics Framebuffer & Coordinate Flip (`MRDPView.m:687–711, 1368–1543`)
- **Pixel Format**: `gdi_init(instance, PIXEL_FORMAT_BGRX32)` creates a 32-bit little-endian `BGRX` buffer in `gdi->primary_buffer`, compatible with:
  ```objc
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef bitmap_context = CGBitmapContextCreate(
      gdi->primary_buffer, gdi->width, gdi->height, 8, gdi->stride, colorSpace,
      kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
  CGColorSpaceRelease(colorSpace);
  ```
- **Coordinate System Conversion**:
  - Windows RDP coordinates have `(0, 0)` at the **top-left**.
  - Default `NSView` coordinates have `(0, 0)` at the **bottom-left** (unless `-[NSView isFlipped]` returns `YES`).
  - Dirty rect conversion (`windows_to_apple_cords`):
    ```objc
    viewRect.origin.y = viewBounds.size.height - (rdpRect.origin.y + rdpRect.size.height);
    ```
  - Mouse event conversion:
    ```objc
    UINT16 rdpY = (UINT16)(viewBounds.size.height - locInView.y);
    ```
- **Scroll Wheel Conversion (`MRDPView.m:362–409`)**:
  - RDP `PTR_FLAGS_WHEEL` / `PTR_FLAGS_HWHEEL` uses 9-bit two's complement rotation units in the lower byte (`0x00FF`).
  - Positive rotation: `step` in `1..0xFF`.
  - Negative rotation: set `PTR_FLAGS_WHEEL_NEGATIVE` (`0x0100`) and encode `step = 0x100 - step` in the low 8 bits (`flags | step`).

### 2.4 Keyboard Scancode & Modifier Mapping on macOS (`MRDPView.m:425–675`)
- **Physical Key Events**:
  - Convert macOS `[event keyCode]` (`kVK_*`) to Windows Virtual Key via `GetVirtualKeyCodeFromKeycode(keyCode, WINPR_KEYCODE_TYPE_APPLE)`.
  - Convert Virtual Key to RDP scancode via `DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkcode, 4)`.
  - Extract extended flag: `UINT16 keyFlags = (scancode & KBDEXT) ? KBDEXT : 0;` and mask `scancode &= 0xFF`.
  - Send via `freerdp_input_send_keyboard_event(input, keyFlags | (down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE), scancode)`.
- **Modifier Flags (`flagsChanged:`)**:
  - Track previous `kbdModFlags` and compare with `[event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask`.
  - Map `NSEventModifierFlagShift` -> `RDP_SCANCODE_LSHIFT`, `NSEventModifierFlagControl` -> `RDP_SCANCODE_LCONTROL`, `NSEventModifierFlagOption` -> `RDP_SCANCODE_LMENU`, `NSEventModifierFlagCommand` -> `RDP_SCANCODE_LWIN`, `NSEventModifierFlagCapsLock` -> `RDP_SCANCODE_CAPSLOCK`.
  - When view loses focus (`pause`), release all held modifiers via `releaseFlagStates(input, kbdModFlags)`.
