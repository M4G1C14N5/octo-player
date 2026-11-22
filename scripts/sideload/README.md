# Octo iOS Free-Apple-ID Sideload Patch (`scripts/sideload/`)

> **Fork / sideload patch tool (not an upstream feature).**
> This branch adds the Siri-entitlement launch guard fix, a repeatable IPA prep script, and a Linux build + operator runbook for sideloading Octo onto iOS using a **free Apple ID** (no paid \$99/yr Apple Developer Program) with [`xtool`](https://github.com/xtool-org/xtool) and [PlumeImpactor / `plumesign`](https://github.com/claration/impactor). It tracks the sideloading blocker documented under MC `000a69c1`.

---

## Summary: Why Both a Rebuild AND `free-resign.sh` Are Required

For Octo 1.13.0 on a free Apple ID:

1. **Rebuilding from source (on Linux, no Mac needed) is required** because the pre-built `Octo-1.13.0-iPhone.ipa` calls `INPreferences.siriAuthorizationStatus()` *before* checking `ProvisioningProfile.grants().contains("com.apple.developer.siri")` (`ios/Sources/Octo/System/SiriMedia.swift:41-44`). Stripping entitlements from the pre-built 1.13.0 IPA alone lets `plumesign` sign and install it, **but the unmodified 1.13.0 binary still aborts at launch** with `SIGABRT … MISSING_ENTITLEMENT_com_apple_developer_siri`.
2. **This branch fixes the guard order** in `ios/Sources/Octo/System/SiriMedia.swift` (and defensively guards the two Siri delegate methods in `ios/Sources/Octo/System/SystemEntries.swift`).
3. **`scripts/sideload/free-resign.sh` + `plumesign 2.7.2`** then strips the extensions, Siri metadata, and embedded Mach-O entitlements from the rebuilt `.ipa` before signing with your free Apple ID.

---

## Why Octo 1.13.0 Fails on a Free Apple ID (Two Blockers)

The upstream Octo iOS build (`app.winters.octo`, bundle `Payload/Octo.app`) ships with two entitlements that block free-Apple-ID sideloading:

### 1. Primary Blocker: Siri Entitlement (`com.apple.developer.siri`)

- **Where it lives:** `ios/Octo.entitlements` sets `com.apple.developer.siri = true`, and in the signed `Octo-1.13.0-iPhone.ipa` release binary both `Payload/Octo.app/Octo` and `OctoWidgets.appex` carry `com.apple.developer.siri` in their embedded Mach-O `LC_CODE_SIGNATURE`.
- **No separate Siri `.appex` to delete:** App Intents (`OctoIntents` target in `ios/Package.swift`), `INPlayMediaIntent` handling (`ios/Sources/Octo/System/SiriMedia.swift`), and `NSSiriUsageDescription` (`ios/Info.plist`) are compiled directly into the main `Octo` binary.
- **Why it crashed at launch on 1.13.0:** Free Apple IDs cannot be provisioned with `com.apple.developer.siri`. In upstream 1.13.0, `OctoApp.init()` → `SystemHooks.start()` → `SiriAccess.askWhenReady()` evaluated `INPreferences.siriAuthorizationStatus() == .notDetermined` *before* `ProvisioningProfile.grants().contains("com.apple.developer.siri")`, causing `Intents.framework` to abort immediately:

```text
EXC_CRASH (SIGABRT) abort() called
Intents -[INPreferences _THROW_EXCEPTION_FOR_PROCESS_MISSING_ENTITLEMENT_com_apple_developer_siri]
```

- **Fix on this branch:** Reordered `SiriAccess.askWhenReady` (`ios/Sources/Octo/System/SiriMedia.swift:41-47`) so `ProvisioningProfile.grants().contains("com.apple.developer.siri")` short-circuits before any `INPreferences` call, and added the same entitlement guard to `OctoAppDelegate.application(_:handlerFor:)` and `application(_:handle:completionHandler:)` (`ios/Sources/Octo/System/SystemEntries.swift:264-284`).

### 2. Secondary Blocker: App Group (`com.apple.security.application-groups`) & Extensions

- **Where it lives:**
  - `ios/Octo.entitlements`: `com.apple.security.application-groups = [group.app.winters.octo]`
  - `ios/OctoShare.entitlements`: `com.apple.security.application-groups = [group.app.winters.octo]`
  - `ios/OctoWidgets.entitlements`: `com.apple.security.application-groups = [group.app.winters.octo]`
- **Why it breaks sideloading:**
  - `group.app.winters.octo` is namespaced to the upstream developer team (`C84UQRPAQ2`). A free Apple ID cannot claim it.
  - When `plumesign` sees `com.apple.security.application-groups` in multiple Mach-O binaries (`Octo`, `OctoShare.appex`, `OctoWidgets.appex`), `register_bundle` registers `group.app.winters.octo.<TEAM_ID>` in parallel across all bundles (`try_join_all`), triggering an Apple portal race (`An Application Group with Identifier … is not available`) on first sign.
  - Free Apple IDs are limited to **10 App ID registrations per 7 days**. Keeping `OctoShare.appex` and `OctoWidgets.appex` consumes **3 App IDs** per refresh window instead of **1**.
  - Without a working shared App Group, `OctoAppGroup.container()` returns `nil`, so **Share-to-Octo** (`OctoShare.appex`) and **Home Screen Widgets** (`OctoWidgets.appex`) cannot communicate with the main app anyway.
- **Default mitigation:** `free-resign.sh` removes both `Payload/Octo.app/PlugIns/OctoShare.appex` and `Payload/Octo.app/PlugIns/OctoWidgets.appex` by default. Pass `--keep-extensions` if you want to retain them (stripped of stale signatures/profiles), noting that **Share-to-Octo and Widgets will not function on a free Apple ID** without a shared App Group.

---

## Launch-Path Siri & Entitlement Audit (Verified Across `ios/Sources/`)

All occurrences of `Intents`, `AppIntents`, `INPreferences`, `INPlayMediaIntent`, `ProvisioningProfile`, `OctoAppGroup`, `WidgetKit`, `CarPlay`, `BackgroundTasks`, and `UserNotifications` across `ios/Sources/` were audited:

| Site (`file:line`) | API / Entitlement | Reachable at Launch Without Entitlement? |
| --- | --- | --- |
| `ios/Sources/Octo/OctoApp.swift:72` → `ios/Sources/Octo/System/OctoShortcuts.swift:58` → `ios/Sources/Octo/System/SiriMedia.swift:41-47` | `INPreferences.siriAuthorizationStatus()` (`com.apple.developer.siri`) | **Guarded (fixed).** `ProvisioningProfile.grants().contains("com.apple.developer.siri")` is now evaluated *before* `INPreferences.siriAuthorizationStatus()`. On any sideloaded build, `embedded.mobileprovision` is present and omits `com.apple.developer.siri`, so `askWhenReady` returns immediately and never installs the `didBecomeActiveNotification` observer or calls `INPreferences.requestSiriAuthorization` (`SiriMedia.swift:55`). |
| `ios/Sources/Octo/System/SystemEntries.swift:264-267` | `application(_:handlerFor intent: INIntent)` / `SiriMediaHandler` | **Not reachable at launch + defensively guarded.** Only invoked by UIKit when Siri dispatches an `INIntent`; now also short-circuits with `return nil` when `com.apple.developer.siri` is not granted. |
| `ios/Sources/Octo/System/SystemEntries.swift:270-284` | `application(_:handle intent: INIntent, completionHandler:)` | **Not reachable at launch + defensively guarded.** Only invoked by UIKit when Siri dispatches an `INIntent`; now also requires `com.apple.developer.siri` in its `guard` before touching `SiriMediaHandler` or `SystemActions.voice`. |
| `ios/Sources/Octo/System/OctoShortcuts.swift:60,78` & `ios/Sources/OctoIntents/*.swift` | `AppIntents` (`AppShortcutsProvider.updateAppShortcutParameters()`) | **Safe without Siri entitlement.** Modern iOS 16+ `AppIntents` / Shortcuts registration does not throw `MISSING_ENTITLEMENT_com_apple_developer_siri` (it does not call legacy `Intents.framework` `INPreferences`). |
| `ios/Sources/OctoSystem/WidgetShelf.swift:82-84` & `ios/Sources/ShareInbox/ShareInbox.swift:128-138` | `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` | **Safe without App Group.** Returns `nil` cleanly when no App Group is granted; callers (`WidgetUpdates.swift:115`, `SystemEntries.swift:55`) guard on `nil` and return without crashing. |
| `ios/Sources/Octo/System/WidgetUpdates.swift:124,129` | `WidgetCenter.shared.reloadTimelines` / `currentConfigurations()` | **Safe.** `reloadTimelines` is skipped when `shelf == nil` (`L115`), and `currentConfigurations()` is `try?` with `?? []` fallback (`L129`). |
| `ios/Sources/Octo/Playback/CarPlay.swift:14-39` | `CarPlay` (`CPTemplateApplicationSceneDelegate`) | **Not reachable on phone launch.** iOS only instantiates `CarPlaySceneDelegate` if the app holds Apple's CarPlay audio entitlement and connects to CarPlay. |
| `ios/Sources/Octo/Family/FamilyNotices.swift:24,30,47-69` | `BGTaskScheduler` (`try?`) & local `UNUserNotificationCenter` | **Safe.** Neither requires a paid capability; errors are caught (`try?`). |
| `ios/Sources/Octo/System/SystemDrive.swift`, `ios/Sources/Octo/Settings/Server/AccountHooks.swift:142` | `#if DEBUG` UI test drive hooks | **Compiled out of Release builds.** |

**Conclusion:** With the `SiriMedia.swift:41-44` guard reordered (and `SystemEntries.swift:265,271` defensively guarded), **no launch-path code in `ios/Sources/` touches any Siri (`INPreferences`) or paid-entitlement API when `com.apple.developer.siri` is absent from `embedded.mobileprovision`.**

---

## Step 1: Build the Patched `.ipa` on Linux (No Mac Required, via `xtool`)

Octo's iPhone app builds natively on Linux using [`xtool`](https://github.com/xtool-org/xtool) (verified against `ios/README.md`, `ios/scripts/release/sideload.sh`, and `xtool-org/xtool`'s Linux guide and CLI sources).

> **Operator-only prerequisites:** Downloading `Xcode.xip` (~10 GB, requires Apple ID browser login) and installing the Swift 6.4 + `xtool` toolchain are one-time operator steps on the Linux build machine. You do **not** need a Mac or a paid App Store Connect API key to produce an unsigned `.ipa` for `plumesign`.

### 1.1 Install Swift 6.4, `usbmuxd`, and `xtool` (once)

```sh
# 1. Install Swift 6.4 on Linux via swiftly (see https://swift.org/install/linux)
swift --version
# Expected: Swift version 6.4 (swift-6.4-RELEASE)

# 2. Install system packages (Ubuntu/Debian)
#    libsqlite3-dev is needed for running `OCTO_KIT_ONLY=1 swift test` on Linux.
sudo apt-get update
sudo apt-get install -y usbmuxd libimobiledevice-utils libsqlite3-dev

# 3. Install the xtool AppImage onto PATH
curl -fL \
  "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
  -o xtool
chmod +x xtool
sudo mv xtool /usr/local/bin/xtool
xtool --help
```

### 1.2 Download `Xcode.xip` and Extract the Darwin iOS Swift SDK (once)

1. In a browser (authentication required — `curl` won't work), log in to <https://developer.apple.com/download/all/?q=Xcode> and download **Xcode 27.1** (`Xcode_27.1.xip`, matching `ios/README.md` / `xtool`'s Linux guide).
2. Extract and install the Darwin iOS Swift SDK into SwiftPM:

   - **SDK-only (recommended when signing with `plumesign` — no Apple login in `xtool` needed):**
     ```sh
     xtool sdk install ~/Downloads/Xcode_27.1.xip
     ```
   - **Or full interactive `xtool setup`** (runs `xtool auth` + `xtool sdk`; choose `1: Password` for a free Apple ID or `0: API Key` for a paid developer account, then enter the path to `Xcode_27.1.xip`):
     ```sh
     xtool setup
     ```
3. Verify the Darwin SDK is registered:
   ```sh
   swift sdk list
   # Expected output includes: darwin
   ```

### 1.3 Run the Linux Unit Tests (Optional Sanity Check)

`OCTO_KIT_ONLY=1` excludes the SwiftUI/iOS app targets so `OctoKit`, `ShareInbox`, and `OctoSystem` (including `ProvisioningProfile` tests) compile and run natively on Linux:

```sh
cd ios
OCTO_KIT_ONLY=1 swift test
```

### 1.4 Build the Unsigned Release `.ipa` on Linux

From this patched branch (`sideload/siri-guard-rebuild`):

```sh
cd ios
xtool dev build -c release --ipa
# Output: ios/xtool/Octo.ipa
```

Notes:
- Omitting `--sign` builds and packages `ios/xtool/Octo.ipa` without requiring `xtool auth` or an App Store Connect API key (`xtool` ad-hoc signs the bundle with `ios/*.entitlements`, which `free-resign.sh` + `plumesign` strip in the next steps).
- `xtool dev build` bundles the flat `Resources/AppIcon.png`. (Upstream store builds run `ios/scripts/release/octo_asc.py` to swap in the pre-compiled `ios/Resources/StoreAssets/Icon/Assets.car` Liquid Glass icon catalog and `Metadata.appintents`, which is optional for sideloading.)

---

## Step 2: Strip Siri & App-Group Blockers (`free-resign.sh`)

`scripts/sideload/free-resign.sh` is a POSIX `sh` script (`#!/bin/sh`, tested under `dash`) that runs fully offline.

### Requirements

- POSIX `sh`, `unzip`, `zip`, `mktemp`
- Optional: `python3` (used to strip Siri keys from XML or binary `Info.plist` and to preserve any future non-Siri/non-App-Group keys from `ios/*.entitlements`; falls back cleanly if absent)

### Syntax

```sh
./scripts/sideload/free-resign.sh [OPTIONS] <input.ipa>
```

| Flag | Description |
| --- | --- |
| `-i, --input <path>` | Input `.ipa` file (also accepted as a positional argument). |
| `-o, --output <path>` | Output cleaned `.ipa` path. Defaults to `<input-stem>-free.ipa` beside the input file. |
| `--entitlements-dir <dir>` | Output directory for cleaned `.entitlements` plists (`Octo.entitlements`, `OctoShare.entitlements`, `OctoWidgets.entitlements`). Defaults to `<output-stem>.entitlements/`. |
| `--keep-extensions` | Keep `OctoShare.appex` and `OctoWidgets.appex` instead of removing them. **Share-to-Octo and Widgets will not function on a free Apple ID**, and keeping them consumes 3 App IDs instead of 1. |
| `-h, --help` | Print usage and exit. |

### Example

```sh
./scripts/sideload/free-resign.sh \
  -i ios/xtool/Octo.ipa \
  -o /path/to/Octo-1.13.0-iPhone-free.ipa
```

Outputs:
- `/path/to/Octo-1.13.0-iPhone-free.ipa` — re-zipped `Payload/Octo.app` with:
  - `PlugIns/OctoShare.appex` and `PlugIns/OctoWidgets.appex` removed (unless `--keep-extensions`)
  - stale `_CodeSignature/` and `embedded.mobileprovision` removed
  - `Info.plist` Siri keys (`NSSiriUsageDescription`, `INIntentsSupported`, `INSupportedMediaCategories`) removed
- `/path/to/Octo-1.13.0-iPhone-free.entitlements/` containing cleaned XML plists (`<dict/>`, Siri + App Group stripped) for `Octo`, `OctoShare`, and `OctoWidgets`

---

## Step 3: Operator Re-Sign & Install (`plumesign 2.7.2` as `sideload` user)

### How `plumesign 2.7.2` Actually Handles Entitlements (Verified)

Verified directly against `/opt/sideload/bin/plumesign --help` (`plumesign 2.7.2`) and `claration/impactor` tag `v2.7.2` (`apps/plumesign/src/commands/sign.rs`, `crates/plume_utils/src/signer.rs`, `crates/plume_core/src/utils/{macho.rs,provision.rs,mod.rs}`):

1. **`plumesign sign` has NO `--entitlements` CLI flag and ignores external `.entitlements` files.**
   (`SignerOptions.custom_entitlements` exists only in the desktop `PlumeImpactor` GUI when `single_profile` / LiveContainer mode is enabled; it is not wired to the `plumesign` CLI.)
2. **Where `plumesign sign --apple-id` gets entitlements instead:**
   - **Registration (`register_bundle`)**: Reads the **embedded entitlements inside each Mach-O executable's `LC_CODE_SIGNATURE`** (`MachO::new(exe).entitlements()`), requests matching Apple capabilities (`v1_request_capabilities_for_entitlements`) and registers any `com.apple.security.application-groups` entries (`qh_ensure_app_group` / `qh_assign_app_group`), then downloads a fresh `embedded.mobileprovision` for `<bundle_id>.<TEAM_ID>`.
   - **Signing (`sign_single_bundle`)**: Uses the downloaded `embedded.mobileprovision`'s `Entitlements` dictionary (merging only `keychain-access-groups` and expanding `*` wildcards via `plume_core::utils::merge_entitlements`) and signs the bundle in place with `apple-codesign-rs`.
3. **How to clear embedded Mach-O entitlements with `plumesign` before Apple ID signing:**
   Running `plumesign sign` in **ad-hoc mode** (omitting `--apple-id` and `--pem`, supplying `-o <out.ipa>`) invokes `apple-codesign` (`UnifiedSigner::sign_path_in_place`) with `settings.entitlements_xml = None`. Verified in `apple-codesign` `0.29.0` (`src/macho_signing.rs`), this writes a fresh ad-hoc `LC_CODE_SIGNATURE` with **no `CodeSigningSlot::Entitlements` blob** — completely clearing `com.apple.developer.siri` and `com.apple.security.application-groups` from the Mach-O binary so `plumesign sign --apple-id` never requests Siri or App Groups from Apple.

> **Alternative signers:** If you re-sign with macOS `codesign --entitlements`, `ldid -S`, or Octo's patched `zsign --bundle-entitlements` (`ios/scripts/release/`), pass the cleaned `*.entitlements` files generated by `free-resign.sh` directly.

### Copy-Paste Commands for the Operator (on `claw-server`, as `sideload`)

Copy the Linux-built `ios/xtool/Octo.ipa` into `/var/lib/sideload/ipa/Octo-1.13.0-rebuilt.ipa`, then run as the `sideload` user (which owns `/var/lib/sideload` and `~/.config/PlumeImpactor/`):

```sh
# 1. Produce the cleaned IPA (no extensions, no stale signatures/provisions, no Info.plist Siri keys)
sudo -u sideload -H /path/to/octo-player/scripts/sideload/free-resign.sh \
  -i /var/lib/sideload/ipa/Octo-1.13.0-rebuilt.ipa \
  -o /var/lib/sideload/ipa/Octo-1.13.0-free.ipa

# 2. Strip embedded Mach-O entitlements offline using plumesign ad-hoc mode
#    (no Apple ID / no network; rewrites LC_CODE_SIGNATURE with empty entitlements)
sudo -u sideload -H /opt/sideload/bin/plumesign sign \
  -p /var/lib/sideload/ipa/Octo-1.13.0-free.ipa \
  -o /var/lib/sideload/ipa/Octo-1.13.0-free-adhoc.ipa

# Optional sanity check: confirm embedded entitlements are now empty
# (unzip Payload/Octo.app/Octo to a temp dir and inspect with plumesign mach-o --entitlements)
```

#### Option A — Re-sign with Free Apple ID and Install Over Wi-Fi (via `netmuxd`)

`plumesign` connects to `/run/usbmuxd` directly (ignoring `USBMUXD_SOCKET_ADDRESS`) and expects `--udid` to be the muxer's **numeric DeviceID** (resolved via `/opt/sideload/bin/mux-devid`), not the UDID string. Run inside a transient systemd unit that bind-mounts `netmuxd`'s socket:

```sh
# Replace <DEVICE_UDID> with the target iPhone UDID from /etc/sideload/octo.conf
sudo systemd-run --quiet --wait --pipe --collect \
  -p User=sideload \
  -p BindPaths=/run/netmuxd/usbmuxd:/run/usbmuxd \
  /bin/sh -eu -c '
    DEVID=$(/opt/sideload/bin/mux-devid "<DEVICE_UDID>")
    /opt/sideload/bin/plumesign sign \
      -p /var/lib/sideload/ipa/Octo-1.13.0-free-adhoc.ipa \
      --apple-id \
      --register-and-install \
      --udid "$DEVID" </dev/null
  '
```

#### Option B — Re-sign with Free Apple ID to an Output `.ipa` (No Install)

```sh
sudo -u sideload -H /opt/sideload/bin/plumesign sign \
  -p /var/lib/sideload/ipa/Octo-1.13.0-free-adhoc.ipa \
  --apple-id \
  -o /var/lib/sideload/ipa/Octo-1.13.0-signed.ipa </dev/null
```

---

## 7-Day Free-Certificate Expiry Caveat (MC `000a69c1`)

Apps signed with a free Apple ID are subject to Apple's personal-team limits:

- **7-day provisioning expiry:** The app stops launching 7 days after signing unless re-signed and reinstalled before expiry.
- **3 active sideloaded apps** per device at once.
- **10 App IDs per 7 days** per Apple ID (removing `OctoShare.appex` and `OctoWidgets.appex` cuts Octo from 3 App IDs down to 1).
- **1-year development certificate** (auto-reused by `plumesign` from `~/.config/PlumeImpactor/`; signing with another sideload tool on the same Apple ID can revoke it).

### Tying Into Auto-Refresh (SideStore / `octo-refresh.timer`)

Under the MC `000a69c1` sideload auto-refresh setup on `claw-server`:
- `octo-refresh.timer` runs daily and triggers a re-sign + Wi-Fi reinstall whenever the last success is ≥ 72 hours old (leaving ~4 days of slack if the phone is away from home Wi-Fi).
- Point the refresh flow at the locally rebuilt + cleaned IPA (`Octo-1.13.0-free-adhoc.ipa`) instead of downloading the unpatched upstream 1.13.0 release asset (until an upstream release includes the `SiriMedia.swift` guard-order fix).
- Alternatively, the rebuilt/cleaned IPA can be refreshed on-device via **SideStore** (using the same free Apple ID and pairing file) to avoid depending on home Wi-Fi mDNS reachability.
- As long as the signed bundle identifier (`app.winters.octo.<TEAM_ID>`) stays unchanged across refreshes, iOS preserves Octo's local library, settings, and downloaded tracks.
