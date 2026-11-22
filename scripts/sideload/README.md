# Octo iOS Free-Apple-ID Sideload Patch (`scripts/sideload/`)

> **Fork / sideload patch tool (not an upstream feature).**
> This directory provides a repeatable IPA prep script and operator runbook for sideloading Octo onto iOS using a **free Apple ID** (no paid \$99/yr Apple Developer Program) with [PlumeImpactor / `plumesign`](https://github.com/claration/impactor). It tracks the sideloading blocker documented under MC `000a69c1`.

---

## Why Octo 1.13.0 Fails on a Free Apple ID (Two Blockers)

The upstream Octo iOS build (`app.winters.octo`, bundle `Payload/Octo.app`) ships with two entitlements that block free-Apple-ID sideloading:

### 1. Primary Blocker: Siri Entitlement (`com.apple.developer.siri`)

- **Where it lives:** `ios/Octo.entitlements` sets `com.apple.developer.siri = true`, and in the signed `Octo-1.13.0-iPhone.ipa` release binary both `Payload/Octo.app/Octo` and `OctoWidgets.appex` carry `com.apple.developer.siri` in their embedded Mach-O `LC_CODE_SIGNATURE`.
- **No separate Siri `.appex` to delete:** App Intents (`OctoIntents` target in `ios/Package.swift`), `INPlayMediaIntent` handling (`ios/Sources/Octo/System/SiriMedia.swift`), and `NSSiriUsageDescription` (`ios/Info.plist`) are compiled directly into the main `Octo` binary.
- **Why it fails on a free Apple ID:** Free Apple IDs cannot be provisioned with the SiriKit capability (`com.apple.developer.siri`). Apple's free provisioning profile never grants it.

#### Known Octo 1.13.0 Launch Caveat (`SiriMedia.swift` Guard Order)

Stripping `com.apple.developer.siri` (and Siri `Info.plist` keys) lets `plumesign` register, sign, and install Octo cleanly without requesting Siri from Apple. However, **for the pre-built `Octo-1.13.0-iPhone.ipa` binary specifically**, there is a compiled-in startup bug in `ios/Sources/Octo/System/SiriMedia.swift`:

```swift
static func askWhenReady(library: Library?) {
    guard observer == nil, INPreferences.siriAuthorizationStatus() == .notDetermined,
          ProvisioningProfile.grants().contains("com.apple.developer.siri") else { return }
```

`OctoApp.init()` → `SystemHooks.start()` calls `SiriAccess.askWhenReady()` at launch. Because Swift evaluates `guard` clauses left to right, `INPreferences.siriAuthorizationStatus()` executes **before** `ProvisioningProfile.grants().contains("com.apple.developer.siri")`. On iOS, calling `INPreferences.siriAuthorizationStatus()` without the `com.apple.developer.siri` entitlement causes `Intents.framework` to abort immediately:

```text
EXC_CRASH (SIGABRT) abort() called
Intents -[INPreferences _THROW_EXCEPTION_FOR_PROCESS_MISSING_ENTITLEMENT_com_apple_developer_siri]
```

What this means in practice:
- Re-signing a **pre-built 1.13.0 `.ipa`** with stripped entitlements will install cleanly, **but will still crash at launch on iOS** until one of the following is done:
  1. **Rebuild from source** with the two `guard` conditions in `SiriAccess.askWhenReady` swapped (`ProvisioningProfile.grants().contains("com.apple.developer.siri")` checked *before* `INPreferences.siriAuthorizationStatus()`), then run `free-resign.sh` + `plumesign`; or
  2. **Inject a tweak dylib** via `plumesign sign -t <stub.dylib>` that swizzles/stubs `+[INPreferences siriAuthorizationStatus]` to return `INSiriAuthorizationStatusDenied`; or
  3. **Sign with a paid Apple Developer Program account** (\$99/yr), which can provision `com.apple.developer.siri` directly.

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

## Script Usage (`free-resign.sh`)

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
  -i /path/to/Octo-1.13.0-iPhone.ipa \
  -o /path/to/Octo-1.13.0-iPhone-free.ipa
```

Outputs:
- `/path/to/Octo-1.13.0-iPhone-free.ipa` — re-zipped `Payload/Octo.app` with:
  - `PlugIns/OctoShare.appex` and `PlugIns/OctoWidgets.appex` removed (unless `--keep-extensions`)
  - stale `_CodeSignature/` and `embedded.mobileprovision` removed
  - `Info.plist` Siri keys (`NSSiriUsageDescription`, `INIntentsSupported`, `INSupportedMediaCategories`) removed
- `/path/to/Octo-1.13.0-iPhone-free.entitlements/` containing cleaned XML plists (`<dict/>`, Siri + App Group stripped) for `Octo`, `OctoShare`, and `OctoWidgets`

---

## Operator Re-Sign Steps (`plumesign 2.7.2` as `sideload` user)

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

Run Step 1 on the unpacked IPA copy, then Steps 2–3 as the `sideload` user (which owns `/var/lib/sideload` and `~/.config/PlumeImpactor/`):

```sh
# 1. Produce the cleaned IPA (no extensions, no stale signatures/provisions, no Info.plist Siri keys)
sudo -u sideload -H /path/to/octo-player/scripts/sideload/free-resign.sh \
  -i /var/lib/sideload/ipa/Octo-1.13.0-iPhone.ipa \
  -o /var/lib/sideload/ipa/Octo-1.13.0-iPhone-free.ipa

# 2. Strip embedded Mach-O entitlements offline using plumesign ad-hoc mode
#    (no Apple ID / no network; rewrites LC_CODE_SIGNATURE with empty entitlements)
sudo -u sideload -H /opt/sideload/bin/plumesign sign \
  -p /var/lib/sideload/ipa/Octo-1.13.0-iPhone-free.ipa \
  -o /var/lib/sideload/ipa/Octo-1.13.0-iPhone-free-adhoc.ipa

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
      -p /var/lib/sideload/ipa/Octo-1.13.0-iPhone-free-adhoc.ipa \
      --apple-id \
      --register-and-install \
      --udid "$DEVID" </dev/null
  '
```

*(If injecting a Siri-stub tweak dylib for the pre-built 1.13.0 binary, add `-t /path/to/siri-stub.dylib` to the `plumesign sign` command above.)*

#### Option B — Re-sign with Free Apple ID to an Output `.ipa` (No Install)

```sh
sudo -u sideload -H /opt/sideload/bin/plumesign sign \
  -p /var/lib/sideload/ipa/Octo-1.13.0-iPhone-free-adhoc.ipa \
  --apple-id \
  -o /var/lib/sideload/ipa/Octo-1.13.0-iPhone-signed.ipa </dev/null
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
- To integrate this patch into unattended refresh once a Siri-safe binary is available (rebuilt from source or tweak-patched), run `free-resign.sh` + ad-hoc strip on the downloaded IPA before passing it to `plumesign sign --apple-id --register-and-install`.
- Alternatively, the cleaned/signed IPA can be refreshed on-device via **SideStore** (using the same free Apple ID and pairing file) to avoid depending on home Wi-Fi mDNS reachability.
- As long as the signed bundle identifier (`app.winters.octo.<TEAM_ID>`) stays unchanged across refreshes, iOS preserves Octo's local library, settings, and downloaded tracks.
