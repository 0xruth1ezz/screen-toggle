# Screen Toggle

<img src="Assets/AppIcon.png" alt="Screen Toggle icon" width="160">

A standalone menu-bar app for switching a Mac's built-in display on and off while an external monitor is connected. No Lunar installation, Pro activation, network service, or third-party dependency is required.

## Use

Open `build/Screen Toggle.app`. Click the laptop icon in the menu bar, then **Turn Built-in Display Off**. Use the same menu on the external display to turn it back on.

- **Control–Option–Command–B:** toggle the built-in display.
- **Control–Option–Command–R:** restore the built-in display.
- Turning the display off requires an active external monitor.
- The app checks at launch, on wake, on display changes, and every second. If the built-in display is off and no awake external display is available, it requests restoration, even if another app turned it off. Failed or unapplied automatic restores are retried until the panel is enabled.
- The app remembers the external monitors present when turning the panel off. Losing all of those monitors triggers restoration, even if macOS creates a new virtual screen. The known WindowServer fallback virtual display is also excluded during launch recovery. Replacing all original monitors therefore turns the built-in panel back on.
- The disabled panel's identity stays pinned during recovery. A restore is confirmed only when that panel appears in the online display list and is awake and active or mirrored. Refreshing the menu cannot clear recovery state, and the restore shortcut always sends an enable request even if macOS already reports the panel as on.
- The app requests restoration of displays it disabled before sleep and when quitting. A pre-sleep restore stays pending across wake until the panel is confirmed enabled, even if an external monitor is connected. macOS also reverts app-scoped display configuration when the process exits.
- If another app has reserved a shortcut, it will be absent from the menu; the menu actions remain available.

This performs a display disconnect, so macOS can move windows onto the external monitor. It does not place a black window over the built-in screen. macOS manages window placement when reconnecting; exact previous window positions are not saved.

Power-off recovery depends on macOS reporting the external monitor as disconnected, inactive, or asleep. A monitor or dock that continues reporting an awake display after its power button is pressed cannot be detected through these display-state APIs. Use **Control–Option–Command–R** to request restoration in that case.

## Build

Requires Xcode or Apple Command Line Tools:

```sh
bash build.sh
```

The output is an ad-hoc signed universal app at `build/Screen Toggle.app`, containing both Intel (`x86_64`, also called `amd64`) and Apple Silicon (`arm64`) executables. Copy it to Applications if desired. The app targets macOS 12 Monterey and newer, matching Lunar 6.11.0's minimum macOS version. Download `ScreenToggle-1.0.2-macos-universal.zip` from the [latest release](https://github.com/0xruth1ezz/screen-toggle/releases/latest) for either architecture.

Turning the built-in display off and automatically restoring it after physically unplugging the external monitor has been verified on an Apple Silicon Mac running macOS 27.0 (26A428), with successful restoration confirmed in the app logs. Intel hardware and macOS 12 remain untested. Display disconnection relies on a private API whose behavior can differ between hardware and macOS versions.

The build reads its minimum deployment version from `LSMinimumSystemVersion` in `Info.plist`, keeping the executable and app bundle requirements in sync.

## Implementation and sources

Display discovery and automatic restoration are based on the approach visible in Lunar's `Lunar/Utils/DisplayController.swift` and `Lunar/Data/Display.swift`. Lunar's actual BlackOut/disconnect implementation is encrypted in this checkout, so this app implements its own display configuration transaction and does not compile Lunar's encrypted sources or licensing code.

The disconnect operation uses the private macOS `SLSConfigureDisplayEnabled` API, with a `CGSConfigureDisplayEnabled` symbol fallback. `SLSGetDisplayList` locates panels omitted by the public online list after disconnecting. These symbols are loaded dynamically: an unavailable API leaves the app launchable with its toggle disabled. The minimum OS requirement permits launch; display disconnection still depends on the private API working on that hardware and OS version.

- [Lunar](https://github.com/alin23/Lunar): original project; its MIT license is included.
- [displaytoggle API declarations](https://github.com/calvincchan/displaytoggle/blob/main/Sources/displaytoggle/SkyLightBridge.h): reference for private function signatures. This app contains an independent implementation.
- [Apple display configuration lifetime](https://developer.apple.com/documentation/coregraphics/cgconfigureoption/forapponly): configuration changes are scoped to the app process, rather than saved permanently.

## Tests

Run `bash test.sh` for 19 deterministic controller scenarios with simulated display state and configuration calls. They cover unplugging, missing or early callbacks, disconnecting during a toggle, cached panel discovery, failed and unapplied restores, sleeping mirrored monitors, multiple external monitors, fallback virtual displays (including one claiming to be built-in), the invalid `-1` status flags observed for an absent panel on macOS 27, transient recovery reports, explicit restore requests, and retrying across sleep/wake and reconnection. Tests do not change hardware display settings. Physical unplug recovery was also verified as described above; monitor power-button behavior and other hardware configurations still need testing.

## Diagnostics

The app writes diagnostics to `~/Library/Logs/ScreenToggle/recovery.log` and the macOS unified log. The file rotates at 2 MiB, keeping one prior file as `recovery.log.previous`. Each line is flushed immediately. Logs include the build and launch path, macOS version, callback registration and flags, selected/cached panel IDs, raw all/online display lists, per-display state, sleep/wake notifications, recovery decisions, and each configuration stage and result. Unchanged polling state is logged at most every 30 seconds; callbacks and restore attempts are always logged.

To follow a reproduction live:

```sh
tail -F ~/Library/Logs/ScreenToggle/recovery.log
```

To inspect unified logs, including builds predating file logging:

```sh
/usr/bin/log show --last 15m --style compact --predicate 'process == "ScreenToggle" AND (eventMessage CONTAINS "ScreenToggle" OR eventMessage CONTAINS "Recovery" OR eventMessage CONTAINS "Display change" OR eventMessage CONTAINS "Screen Toggle build")'
```
