#!/bin/sh
# Prepare an Octo iOS .ipa for signing with a FREE Apple ID (no paid Apple Developer Program).
#
# What this script does:
#   1. Unpacks the input .ipa into a private temporary directory.
#   2. Emits cleaned entitlements plists (Siri and App Group removed) for Octo, OctoShare,
#      and OctoWidgets.
#   3. Removes the two App-Group/Siri-dependent extensions (OctoShare.appex, OctoWidgets.appex)
#      by default (pass --keep-extensions to retain them without stale signatures/provisions).
#   4. Strips stale upstream _CodeSignature directories, embedded.mobileprovision files, and
#      (when python3 is available) Siri Info.plist keys.
#   5. Re-zips Payload/ to a clean .ipa and prints a summary + the verified plumesign operator
#      commands to run next as the `sideload` user.
#
# Note: This script is a sideloading patch helper and does NOT sign or install the IPA.
# POSIX sh compliant (no bashisms).

set -eu

PROG_NAME=$(basename "$0")
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)

IN_IPA=""
OUT_IPA=""
ENT_DIR=""
KEEP_EXTENSIONS=0
WORKDIR=""

usage() {
    cat <<EOF
Usage: $PROG_NAME [OPTIONS] <input.ipa>
       $PROG_NAME -i <input.ipa> [-o <output.ipa>] [--entitlements-dir <dir>] [--keep-extensions]

Strip Siri and App Group blockers from an Octo iOS .ipa for free-Apple-ID sideloading.

Options:
  -i, --input <path>             Input .ipa path (may also be given as a positional argument)
  -o, --output <path>            Output cleaned .ipa path (default: <input-stem>-free.ipa)
      --entitlements-dir <dir>   Directory for cleaned .entitlements plists
                                 (default: <output-stem>.entitlements)
      --keep-extensions          Retain Payload/Octo.app/PlugIns/OctoShare.appex and
                                 OctoWidgets.appex instead of deleting them.
                                 WARNING: Share-to-Octo and Widgets will NOT function on a
                                 free Apple ID without a shared App Group, and keeping them
                                 consumes 3 of the 10 weekly free-account App IDs.
  -h, --help                     Show this help message and exit
EOF
}

die() {
    printf '%s: error: %s\n' "$PROG_NAME" "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
    if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

trap cleanup EXIT HUP INT TERM

# Parse arguments (POSIX sh)
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|--input)
            [ "$#" -ge 2 ] || die "option $1 requires an argument"
            IN_IPA=$2
            shift 2
            ;;
        -o|--output)
            [ "$#" -ge 2 ] || die "option $1 requires an argument"
            OUT_IPA=$2
            shift 2
            ;;
        --entitlements-dir)
            [ "$#" -ge 2 ] || die "option $1 requires an argument"
            ENT_DIR=$2
            shift 2
            ;;
        --keep-extensions)
            KEEP_EXTENSIONS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                if [ -z "$IN_IPA" ]; then
                    IN_IPA=$1
                else
                    die "unexpected extra argument: $1"
                fi
                shift
            done
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            if [ -z "$IN_IPA" ]; then
                IN_IPA=$1
            else
                die "unexpected extra argument: $1"
            fi
            shift
            ;;
    esac
done

[ -n "$IN_IPA" ] || {
    usage >&2
    die "missing input .ipa path"
}

[ -f "$IN_IPA" ] || die "input .ipa not found: $IN_IPA"
[ -r "$IN_IPA" ] || die "input .ipa is not readable: $IN_IPA"

need_cmd unzip
need_cmd zip
need_cmd mktemp

# Resolve input path cleanly without relying on non-POSIX realpath flags
IN_DIR=$(CDPATH='' cd -- "$(dirname -- "$IN_IPA")" && pwd)
IN_BASE=$(basename -- "$IN_IPA")
IN_ABS="$IN_DIR/$IN_BASE"

case "$IN_BASE" in
    *.ipa) IN_STEM=${IN_BASE%.ipa} ;;
    *)     IN_STEM=$IN_BASE ;;
esac

if [ -z "$OUT_IPA" ]; then
    OUT_IPA="$IN_DIR/${IN_STEM}-free.ipa"
fi

OUT_PARENT=$(dirname -- "$OUT_IPA")
mkdir -p "$OUT_PARENT"
OUT_PARENT_ABS=$(CDPATH='' cd -- "$OUT_PARENT" && pwd)
OUT_BASE=$(basename -- "$OUT_IPA")
OUT_ABS="$OUT_PARENT_ABS/$OUT_BASE"

if [ "$OUT_ABS" = "$IN_ABS" ]; then
    die "output path must differ from input path: $OUT_ABS"
fi

case "$OUT_BASE" in
    *.ipa) OUT_STEM=${OUT_BASE%.ipa} ;;
    *)     OUT_STEM=$OUT_BASE ;;
esac

if [ -z "$ENT_DIR" ]; then
    ENT_DIR="$OUT_PARENT_ABS/${OUT_STEM}.entitlements"
fi
mkdir -p "$ENT_DIR"
ENT_DIR_ABS=$(CDPATH='' cd -- "$ENT_DIR" && pwd)

# Create private temporary working directory
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/octo-free-resign.XXXXXX")
UNPACK_DIR="$WORKDIR/unpacked"
mkdir -p "$UNPACK_DIR"

# 1. Unzip input IPA
unzip -q "$IN_ABS" -d "$UNPACK_DIR" || die "failed to unzip input .ipa: $IN_ABS"

APP_DIR="$UNPACK_DIR/Payload/Octo.app"
[ -d "$APP_DIR" ] || die "expected Payload/Octo.app inside $IN_ABS (not an Octo iOS .ipa?)"

# 2. Generate cleaned entitlements files (strip Siri + App Group)
write_clean_entitlements() {
    ent_src=$1
    ent_dst=$2
    if [ -f "$ent_src" ] && command -v python3 >/dev/null 2>&1; then
        python3 -I - "$ent_src" "$ent_dst" <<'PYEOF'
import plistlib
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as fh:
    data = plistlib.load(fh)

for key in (
    "com.apple.developer.siri",
    "com.apple.security.application-groups",
):
    data.pop(key, None)

with open(dst, "wb") as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_XML, sort_keys=True)
PYEOF
    else
        cat >"$ent_dst" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
XMLEOF
    fi
}

write_clean_entitlements "$REPO_ROOT/ios/Octo.entitlements"        "$ENT_DIR_ABS/Octo.entitlements"
write_clean_entitlements "$REPO_ROOT/ios/OctoShare.entitlements"   "$ENT_DIR_ABS/OctoShare.entitlements"
write_clean_entitlements "$REPO_ROOT/ios/OctoWidgets.entitlements" "$ENT_DIR_ABS/OctoWidgets.entitlements"

# 3. Strip stale upstream code signature & provisioning profile from main app
STRIPPED_SIGS=""
strip_bundle_sig() {
    bdir=$1
    label=$2
    if [ -d "$bdir/_CodeSignature" ]; then
        rm -rf "$bdir/_CodeSignature"
        STRIPPED_SIGS="${STRIPPED_SIGS}  - removed ${label}/_CodeSignature
"
    fi
    if [ -f "$bdir/embedded.mobileprovision" ]; then
        rm -f "$bdir/embedded.mobileprovision"
        STRIPPED_SIGS="${STRIPPED_SIGS}  - removed ${label}/embedded.mobileprovision
"
    fi
}

strip_bundle_sig "$APP_DIR" "Payload/Octo.app"

# 4. Handle extensions (remove by default, or retain and strip stale signatures if --keep-extensions)
EXT_REPORT=""
PLUGINS_DIR="$APP_DIR/PlugIns"
if [ "$KEEP_EXTENSIONS" -eq 0 ]; then
    for ext in OctoShare.appex OctoWidgets.appex; do
        if [ -d "$PLUGINS_DIR/$ext" ]; then
            rm -rf "$PLUGINS_DIR/$ext"
            EXT_REPORT="${EXT_REPORT}  - removed Payload/Octo.app/PlugIns/${ext}
"
        else
            EXT_REPORT="${EXT_REPORT}  - absent  Payload/Octo.app/PlugIns/${ext} (not present in input IPA)
"
        fi
    done
    if [ -d "$PLUGINS_DIR" ]; then
        # Prune PlugIns/ only if empty
        if rmdir "$PLUGINS_DIR" 2>/dev/null; then
            EXT_REPORT="${EXT_REPORT}  - removed empty Payload/Octo.app/PlugIns/
"
        fi
    fi
else
    for ext in OctoShare.appex OctoWidgets.appex; do
        if [ -d "$PLUGINS_DIR/$ext" ]; then
            strip_bundle_sig "$PLUGINS_DIR/$ext" "Payload/Octo.app/PlugIns/${ext}"
            EXT_REPORT="${EXT_REPORT}  - KEPT    Payload/Octo.app/PlugIns/${ext} (--keep-extensions)
"
        else
            EXT_REPORT="${EXT_REPORT}  - absent  Payload/Octo.app/PlugIns/${ext} (not present in input IPA)
"
        fi
    done
fi

# 5. Strip Siri Info.plist keys from Payload/Octo.app/Info.plist (if present and python3 is available)
INFO_PLIST="$APP_DIR/Info.plist"
INFO_REPORT=""
if [ -f "$INFO_PLIST" ]; then
    if command -v python3 >/dev/null 2>&1; then
        INFO_STRIPPED=$(python3 -I - "$INFO_PLIST" <<'PYEOF'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as fh:
    raw = fh.read()

fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
data = plistlib.loads(raw)

removed = []
for key in (
    "NSSiriUsageDescription",
    "INIntentsSupported",
    "INSupportedMediaCategories",
):
    if key in data:
        del data[key]
        removed.append(key)

if removed:
    with open(path, "wb") as fh:
        plistlib.dump(data, fh, fmt=fmt)

print(",".join(removed))
PYEOF
        )
        if [ -n "$INFO_STRIPPED" ]; then
            INFO_REPORT="  - removed Info.plist keys: $INFO_STRIPPED"
        else
            INFO_REPORT="  - no Siri keys found in Payload/Octo.app/Info.plist"
        fi
    else
        INFO_REPORT="  - skipped Info.plist Siri key stripping (python3 not found)"
    fi
else
    INFO_REPORT="  - skipped Info.plist Siri key stripping (Payload/Octo.app/Info.plist absent)"
fi

# 6. Re-zip Payload/ to output IPA
TMP_OUT_IPA="$WORKDIR/output.ipa"
(
    cd "$UNPACK_DIR"
    zip -qry "$TMP_OUT_IPA" Payload
) || die "failed to create output .ipa"

mv "$TMP_OUT_IPA" "$OUT_ABS"

# 7. Print summary and verified next steps
OUT_ADHOC_IPA="$OUT_PARENT_ABS/${OUT_STEM}-adhoc.ipa"

cat <<EOF
================================================================================
Octo free-Apple-ID sideload patch complete
================================================================================
Input IPA:          $IN_ABS
Output IPA:         $OUT_ABS
Entitlements dir:   $ENT_DIR_ABS

1. Cleaned entitlements files written (removed: com.apple.developer.siri,
   com.apple.security.application-groups):
  - $ENT_DIR_ABS/Octo.entitlements          (app.winters.octo)
  - $ENT_DIR_ABS/OctoShare.entitlements     (app.winters.octo.share)
  - $ENT_DIR_ABS/OctoWidgets.entitlements   (app.winters.octo.widgets)

2. App extensions:
${EXT_REPORT}3. Stale upstream signature / provisioning profile cleanup:
${STRIPPED_SIGS:-  - none present in input IPA
}4. Info.plist Siri metadata:
${INFO_REPORT}
EOF

if [ "$KEEP_EXTENSIONS" -eq 1 ]; then
    cat <<EOF

WARNING (--keep-extensions):
  OctoShare.appex and OctoWidgets.appex were retained. On a free Apple ID without
  a shared App Group, Share-to-Octo and Home Screen Widgets will NOT function,
  and keeping them consumes 3 of the 10 weekly free-account App IDs.
EOF
fi

cat <<EOF

================================================================================
Next steps (operator: run as the \`sideload\` user with plumesign 2.7.2)
================================================================================
NOTE: plumesign 2.7.2 has NO --entitlements CLI flag and ignores external
.entitlements files. Instead, it reads entitlements embedded inside each Mach-O
executable's LC_CODE_SIGNATURE during Apple ID registration, then signs with the
Apple-issued provisioning profile.

Step A — Clear embedded Mach-O entitlements offline via plumesign ad-hoc mode
         (prevents plumesign from requesting Siri or App Groups from Apple):

  /opt/sideload/bin/plumesign sign \\
    -p "$OUT_ABS" \\
    -o "$OUT_ADHOC_IPA"

Step B — Re-sign with the saved free Apple ID and install over Wi-Fi (as \`sideload\`
         inside the netmuxd bind-mount namespace; replace <UDID> with device UDID):

  sudo systemd-run --quiet --wait --pipe --collect \\
    -p User=sideload \\
    -p BindPaths=/run/netmuxd/usbmuxd:/run/usbmuxd \\
    /bin/sh -eu -c '
      DEVID=\$(/opt/sideload/bin/mux-devid "<UDID>")
      /opt/sideload/bin/plumesign sign \\
        -p "$OUT_ADHOC_IPA" \\
        --apple-id \\
        --register-and-install \\
        --udid "\$DEVID" </dev/null
    '

  (Or to export a signed .ipa without installing, drop --register-and-install and
   --udid, and pass -o /path/to/Octo-signed.ipa.)

IMPORTANT CAVEAT FOR OCTO 1.13.0 PRE-BUILT BINARY:
  See scripts/sideload/README.md ("Known Octo 1.13.0 Launch Caveat"). In Octo
  1.13.0, SiriAccess.askWhenReady() calls INPreferences.siriAuthorizationStatus()
  before checking ProvisioningProfile.grants().contains("com.apple.developer.siri").
  Signing/install succeeds cleanly, but launching the unmodified 1.13.0 Mach-O
  binary without the Siri entitlement still aborts in Intents.framework unless
  Octo is rebuilt from source with those guard clauses swapped or patched with a
  tweak dylib (-t).
EOF
