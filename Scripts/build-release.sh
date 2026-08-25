#!/usr/bin/env bash
#
# build-release.sh — build the Aorus menu-bar app into an .app bundle and a
# drag-to-Applications .dmg, optionally signing + notarizing with a Developer ID.
#
# Usage:
#   ./Scripts/build-release.sh                 # unsigned local build + DMG
#   ./Scripts/build-release.sh --sign          # adhoc/Development sign (local use)
#   ./Scripts/build-release.sh --distribute    # Developer ID sign + notarize + staple
#
# Distribution needs these env vars (or --env-file):
#   DEVELOPER_ID_CERT            base64 of the Developer ID Application .p12
#   DEVELOPER_ID_CERT_PASSWORD   password for the .p12
#   DEVELOPER_ID_APPLICATION     full identity, e.g. "Developer ID Application: Jason Rimmer (XXXXXXXXXX)"
#   ASC_API_KEY_PATH             path to the App Store Connect .p8 key file
#   ASC_API_KEY_ID               e.g. B8JKF883DC
#   ASC_ISSUER_ID                the App Store Connect issuer UUID
#   APPLE_ID / APPLE_TEAM_ID     (only if using Apple ID credentials instead of an API key)
#
# Set -euo pipefail for safety.

set -euo pipefail

# ---- Config ----------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="Aorus"
BUNDLE_ID="net.rimmer.aorus"
VERSION="1.0.0"
BUILD_NUMBER="1"
MODE="unsigned" # unsigned | sign | distribute

DIST_DIR="dist"
BUILD_DIR="$DIST_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_OUT="$DIST_DIR/$APP_NAME-$VERSION.dmg"

# ---- Parse args -----------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
    --sign)
        MODE="sign"
        shift
        ;;
    --distribute)
        MODE="distribute"
        shift
        ;;
    --env-file)
        shift
        # shellcheck disable=SC1090
        source "$1"
        shift
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
    esac
done

# Env-file convenience: if vars aren't set but a file exists, load it.
if [[ "$MODE" == "distribute" && -f .env.release ]]; then
    # shellcheck disable=SC1091
    source .env.release
fi

# ---- Helpers ---------------------------------------------------------
log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

# ---- 1. Build the executable ----------------------------------------
log "Building $APP_NAME (release, $VERSION)"
swift build -c release --product AorusApp
RELEASE_BIN="$(swift build -c release --show-bin-path)/AorusApp"
[[ -x "$RELEASE_BIN" ]] || die "Could not find built executable at $RELEASE_BIN"

# ---- 2. Assemble the .app bundle -------------------------------------
log "Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -- "$(dirname "${BASH_SOURCE[0]}")/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' >"$APP_BUNDLE/Contents/PkgInfo"

# Inject version/build numbers and bundle ID into Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"

# ---- 3. Sign ---------------------------------------------------------
SIGN_IDENTITY=""
case "$MODE" in
unsigned)
    warn "Unsigned build — other Macs will need right-click > Open to run."
    ;;
sign)
    # Local signing: use ad-hoc if no Apple Development identity is handy.
    SIGN_IDENTITY="-"
    log "Signing ad-hoc (local use only)"
    ;;
distribute)
    SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
    [[ -n "$SIGN_IDENTITY" ]] || die "MODE=distribute requires DEVELOPER_ID_APPLICATION identity"
    log "Signing with Developer ID: $SIGN_IDENTITY"
    ;;
esac

if [[ "$MODE" != "unsigned" ]]; then
    codesign_cmd=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
    # Developer-ID apps use the hardened runtime; no extra entitlements required.
    codesign_cmd+=(--entitlements "$(dirname "${BASH_SOURCE[0]}")/entitlements.plist")
    "${codesign_cmd[@]}" "$APP_BUNDLE"
    log "Codesigned $APP_BUNDLE"
fi

# ---- 4. Create the DMG (drag-to-Applications) ------------------------
log "Building DMG: $DMG_OUT"
mkdir -p "$DIST_DIR"
rm -f "$DMG_OUT"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Create the volume with the app + Applications symlink.
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null
log "Created $DMG_OUT"

if [[ "$MODE" != "distribute" ]]; then
    log "Done (MODE=$MODE). DMG at $DMG_OUT"
    exit 0
fi

# ---- 5. Notarize -----------------------------------------------------
log "Notarizing with Apple..."
NOTARY_ARGS=(notarytool submit "$DMG_OUT" --wait --output-format json)
if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
    NOTARY_ARGS+=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [[ -n "${APPLE_ID:-}" ]]; then
    # Requires a stored notarytool keychain profile, e.g.:
    #   xcrun notarytool store-credentials notarytool --apple-id ... --team-id ...
    NOTARY_ARGS+=(--keychain-profile "notarytool")
else
    die "No notarization credentials provided (set ASC_API_KEY_* or APPLE_ID)."
fi

NOTARY_JSON="$(xcrun "${NOTARY_ARGS[@]}")"
SUB_ID="$(echo "$NOTARY_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
if [[ -n "$SUB_ID" && "$SUB_ID" != "null" ]]; then
    log "Notarization accepted, submission id $SUB_ID"
else
    die "Notarization failed: $NOTARY_JSON"
fi

# ---- 6. Staple the ticket --------------------------------------------
log "Stapling notarization ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler staple "$DMG_OUT"
log "Stapled $APP_BUNDLE and $DMG_OUT"

log "Done (MODE=distribute). DMG at $DMG_OUT"
