---
name: desktop-resizing-mechanics
description: >-
  Architectural patterns, AppKit window integration, and protocol gotchas for
  dynamic remote desktop resizing in Chicken Fork across RDP (MS-RDPEDISP)
  and VNC (ExtendedDesktopSize / SetDesktopSize). Use when implementing,
  refactoring, or troubleshooting window resizing, multi-monitor frame
  restoration, display scaling, or remote resolution synchronization.
---

# Remote Desktop Resizing Mechanics & Gotchas Guide

This skill documents the client-side architecture, lifecycle synchronization, and edge cases for dynamic remote workspace resizing in Chicken Fork.

---

## 1. The Core Architecture

Dynamic desktop resizing operates in two distinct phases:
1. **Client-Driven Resize Request**: User resizes the macOS window (or reconnects with a saved window frame). The client formats and sends a protocol-specific resize PDU to the remote server.
2. **Server-Driven Framebuffer Acknowledgment**: The remote server compositor updates its virtual display and sends an acknowledgment update. The client resizes its backing framebuffer and refreshes its view.

### State Synchronization Flow

```
[ Window Resize Event / Connect ]
             │
             ▼
   [ writeSetDesktopSize: ] ──(Size identical to current?)──► [ Skip ]
             │ (Different)
             ▼
   [ Debounce / Queue ] (0.25s timer)
             │
   (Channel ready?) ──NO──► [ Retain pending size until channel opens ]
             │ YES
             ▼
   [ Send Protocol PDU ]
     - RDP: disp->SendMonitorLayout()
     - VNC: rfbSetDesktopSizeMsg
             │
   (Server accepts?)
     ├── YES ──► Server sends Resize PDU ──► [ Resize GDI/FrameBuffer ] ──► [ Resize RFBView ]
     └── NO  ──► (e.g. GDM lock screen)  ──► [ Adaptive Retry after Handover / Focus ]
```

---

## 2. AppKit Window & View Integration Rules

### A. Window Sizing & Multi-Monitor Resolution Memory
* **Problem**: A user connects on a 4K external display (3840×2160) and sizes the window to 3400×1900. Later, they open Chicken Fork on a laptop (1440×900). A single global autosave key (`[window setFrameAutosaveName:serverName]`) would clobber the large resolution.
* **Pattern**: Key window autosave names by server AND screen resolution:
  ```objc
  NSString *autoSaveName = [NSString stringWithFormat:@"%@ (%dx%d)",
                            baseName, (int)screenSize.width, (int)screenSize.height];
  [window setFrameAutosaveName:autoSaveName];
  ```
* **Fallback**: When no saved frame exists, default initial content size to **80% of visible screen frame** (bounded to min 1440×900 or screen bounds).

### B. Scrollbar Elimination on Resizable Connections
* Never show scrollbars on a resizable session window:
  ```objc
  if ([connection serverSupportsSetDesktopSize] && ![self viewOnly]) {
      [scrollView setHasHorizontalScroller:NO];
      [scrollView setHasVerticalScroller:NO];
  }
  ```
* In `_maxSizeForWindowSize:` and `windowWillResize:toSize:`, do not clamp window bounds to `_maxSize` when `serverSupportsSetDesktopSize` is `YES`.

### C. Live Resize vs. Zoom / Snapping Triggers
* **Interactive Dragging**: User drags window corner.
  - `windowWillResize:toSize:` runs continuously.
  - `[window inLiveResize]` is `YES`.
  - Dispatch final resize only in `windowDidEndLiveResize:`.
* **Instant Resizing (Green Zoom Button, Tiling, Double-Click Titlebar)**:
  - `[window inLiveResize]` is `NO`.
  - `windowDidEndLiveResize:` is **never** called.
  - Must dispatch resize in `windowDidResize:` guarded by `if (![window inLiveResize])`.

### D. Coordinate Systems & Bottom-Left Anchoring
* `RFBView` in Chicken Fork is not flipped (`isFlipped` is `NO`). Origin `(0, 0)` is at the **bottom-left**.
* If the remote desktop is smaller than the window (e.g. 1920×1080 desktop inside a 3400×1900 window):
  - `RFBView` renders anchored at bottom-left `(0, 0)`.
  - The rest of the window to the right and above is exposed as blank clip view background.
  - Therefore, the client must ensure the remote workspace matches the window content frame as quickly as possible.

### E. Native Fullscreen Spaces Integration & Dual-Frame Handover
* **Dual-Frame Calculation in `preferredInitialDesktopSize`**:
  - When launching directly into fullscreen (`[server fullscreen] == YES`), the initial desktop size must immediately match the target screen frame (with even width: `w & ~1`).
  - This allows RDP (`FreeRDP_DesktopWidth` / `FreeRDP_DesktopHeight`) and VNC to connect directly at full display resolution without requiring an immediate post-connect resize handshake.
  - Simultaneously, calculate and apply the target *windowed* frame (e.g. 80% screen or saved frame) to `window` *before* toggling fullscreen, ensuring macOS remembers the windowed geometry upon exiting fullscreen.
* **Transition Suppression (`_enteringInitialFullscreen`)**:
  - `[window toggleFullScreen:nil]` is asynchronous and animates across Spaces (~0.5s).
  - During the transition, `windowDidResize:`, `windowDidBecomeKey:`, and `windowWillResize:toSize:` fire with intermediate windowed dimensions.
  - Set a flag `_enteringInitialFullscreen = YES` before calling `toggleFullScreen:`.
  - While `_enteringInitialFullscreen` is `YES`:
    - Suppress dispatch in `writeSetDesktopSize:`.
    - Do not clamp window bounds to `_maxSize` in `windowWillResize:toSize:`.
  - In `windowDidEnterFullScreen:`, clear `_enteringInitialFullscreen = NO` and trigger a single final desktop size sync to guarantee exact alignment.
  - In `windowDidFailToEnterFullScreen:` and `windowDidExitFullScreen:`, ensure `_enteringInitialFullscreen` is cleared.

---

## 3. Protocol Gotchas & Failure Modes

### Gotcha 1: Premature Desktop Size Equality Check
* **Symptom**: Window opens enlarged, but desktop never resizes to fit it until the user manually wiggles the window border.
* **Root Cause**:
  1. Client initialized `currentDesktopSize` to the target window size before connecting.
  2. Server connected at a fallback/default size (e.g. GDM at 1920×1080).
  3. Client's `writeSetDesktopSize:` checked `if (w == currentDesktopSize.width) return;` and silently dropped the resize request.
* **Rule**: Keep `currentDesktopSize` as `NSZeroSize` until the remote server/GDI actually connects and reports real dimensions. In `notifyConnected`, check if server size matches window content size; if not, immediately request a resize.

### Gotcha 2: The Silent Drop on Unready Channels
* **Symptom**: Initial layout sent at startup is ignored.
* **Root Cause**: `performDelayedDesktopSize` ran before `dispReady` / `dispContext` was established. Because `dispReady` was `NO`, it exited without queueing or rescheduling.
* **Rule**: Maintain `hasPendingDesktopSize = YES`. When `DisplayControlCaps` arrives, or when connection completes, flush any pending desktop size.

### Gotcha 3: Linux GDM Lock-Screen Handover
* **Symptom**: On Linux RDP (e.g. AlmaLinux, Fedora, Ubuntu via `gnome-remote-desktop`), connecting to the login screen shows 1920×1080. After logging in, the desktop remains stuck at 1920×1080 with large blank areas.
* **Root Cause**:
  1. GDM login screen ignores `SendMonitorLayout` because the display configuration is locked.
  2. Logging in hands over the session to GNOME Shell, but does not trigger a virtual channel disconnect/reconnect.
  3. No window resize event occurs after login.
* **Rule**: Implement adaptive synchronization:
  - In `windowDidBecomeKey:`, check if remote desktop size differs from window content size.
  - In incoming graphics update callbacks (`notifyDirtyRect:` for RDP, `frameBufferUpdateComplete` for VNC), check if `currentDesktopSize != winSize`. If a mismatch persists and no resize was sent within a 2-second cooldown, resend the layout PDU.

### Gotcha 4: The `lastDesktopSizeSent` Deadlock
* **Symptom**: Client sends a resize request once. Server ignores or rejects it. Client refuses to ever send that size again, even after login.
* **Root Cause**: Client had `if (!NSEqualSizes(lastDesktopSizeSent, winContentSize)) [self writeSetDesktopSize:winContentSize];`. Since `lastDesktopSizeSent` was already set to `winContentSize`, it was permanently deadlocked.
* **Rule**: Track `lastDesktopSizeSentTime` and `desktopResizeAttempts`. Allow retry if `now - lastDesktopSizeSentTime >= 2.0` and attempts < 3. Reset attempts when server acknowledges a resize or user resizes window.

### Gotcha 5: MS-RDPEDISP Monitor Layout Constraints
* Width must be an even integer: `UINT32 w = ((UINT32)newSize.width) & ~1;`.
* Width and height must be clamped between `200` and `8192`.
* Physical dimensions: `PhysicalWidth = (UINT32)(w * 25.4 / 96.0)` (min 10).
* `DesktopScaleFactor` and `DeviceScaleFactor` must not be zero: pass `100` (100% scaling) or value from `FreeRDP_DesktopScaleFactor`.

### Gotcha 6: Spaces Transition Size Drops During Fullscreen Launch
* **Symptom**: Session launches with fullscreen requested, but connects at an intermediate or reduced windowed resolution, or freezes resizing altogether.
* **Root Cause**:
  1. `[window toggleFullScreen:nil]` was triggered at window setup.
  2. While macOS animated the window into its dedicated Space, `windowDidResize:` fired with the temporary pre-animation windowed content size.
  3. The client dispatched a layout PDU for this intermediate size, clobbering the initial fullscreen negotiation and triggering `lastDesktopSizeSent` deadlocks.
* **Rule**: Gate all dynamic resize PDU transmissions behind `!_enteringInitialFullscreen`. Only permit resize dispatch once `windowDidEnterFullScreen:` or normal windowed presentation is confirmed.

### Gotcha 7: Multi-Monitor Full-Screen Layout Constraints (MS-RDPEDISP & AppKit)
* **Coordinate Systems**:
  - In AppKit, screen frames are in Cocoa coordinates with (0,0) at primary screen bottom-left, Y increasing upwards.
  - In FreeRDP and MS-RDPEDISP, monitor coordinates are top-down with the primary monitor positioned strictly at `(0, 0)`.
  - Convert `rdpLeft = screen.origin.x - primary.origin.x` and `rdpTop = (primary.origin.y + primary.size.height) - (screen.origin.y + screen.size.height)`.
  - Widths must be even integers (`w & ~1`).
* **FrameBuffer Offsets & Auxiliary Windows**:
  - The unified GDI / `RDPFrameBuffer` size matches the total bounding box of all displays.
  - The primary display runs in a native macOS fullscreen Space; companion displays run borderless windows with `NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary` at `NSMainMenuWindowLevel + 1`.
  - Each `RFBView` maintains a `monitorOrigin` pointing to its monitor's buffer origin in the unified framebuffer (`imgX = -monOrigin.x; imgY = viewHeight + monOrigin.y - size.height;`).
  - Pointer event coordinates clamp to the active view and add `monitorOrigin` to deliver virtual desktop coordinates to `freerdp_input_send_mouse_event`.
