#!/bin/bash
# Package the release app and CLI into dist/.
#
# The bundle is assembled in a staging directory and swapped into place, so a
# rebuild never keeps files from an earlier layout. Environment:
#   MAGICWINE_APP_NAME       bundle/display name (default MagicWine)
#   MAGICWINE_BUNDLE_ID      bundle identifier override
#   MAGICWINE_VERSION        CFBundleShortVersionString override (e.g. 1.2.3)
#   MAGICWINE_BUILD          CFBundleVersion override (integer)
#   MAGICWINE_SIGN_IDENTITY  Developer ID Application identity; enables hardened-runtime signing
#   MAGICWINE_NOTARY_PROFILE notarytool keychain profile; submits and staples (needs a sign identity)
# Without MAGICWINE_SIGN_IDENTITY the app is ad-hoc signed (local development only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/toolchain.sh"

APP_NAME="${MAGICWINE_APP_NAME:-MagicWine}"
SIGN_IDENTITY="${MAGICWINE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MAGICWINE_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
    echo "MAGICWINE_NOTARY_PROFILE requires MAGICWINE_SIGN_IDENTITY (Developer ID signing)." >&2
    exit 2
fi

# Version stamping. CFBundleShortVersionString is the newest reachable `v<number>[.<number>…]`
# git tag, else the checked-in Info.plist base version; CFBundleVersion is the commit count
# (monotonic on a linear history; needs a non-shallow clone). The checked-in Info.plist is never edited.
BASE_PLIST="$ROOT/Resources/Info.plist"
VERSION="${MAGICWINE_VERSION:-}"
BUILD="${MAGICWINE_BUILD:-}"
REVISION=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -z "$VERSION" ]] && TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)"; then
        VERSION="${TAG#v}"
    fi
    if [[ -z "$BUILD" ]]; then BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"; fi
    REVISION="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
    if [[ -n "$REVISION" && -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        REVISION="$REVISION-dirty"
    fi
fi
if [[ -z "$VERSION" ]]; then VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BASE_PLIST")"; fi
if [[ -z "$BUILD" ]]; then BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BASE_PLIST")"; fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Version '$VERSION' is not 1-3 dot-separated integers; set MAGICWINE_VERSION." >&2
    exit 2
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "Build '$BUILD' is not an integer; set MAGICWINE_BUILD." >&2
    exit 2
fi

swift build "${SWIFT_OPTIONS[@]}" -c release
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" -c release --show-bin-path)"
RESOURCE_BUNDLE="MagicWine_MagicWineCore.bundle"
UI_RESOURCE_BUNDLE="MagicWine_MagicWine.bundle"

DIST="$ROOT/dist"
mkdir -p "$DIST"
STAGE="$(mktemp -d "$DIST/.staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/$APP_NAME.app"
PLIST="$STAGED_APP/Contents/Info.plist"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/MagicWine" "$STAGED_APP/Contents/MacOS/MagicWine"
# The CLI lives beside the app executable (not in Contents/Helpers) so Bundle.main resolves to the
# app and SwiftPM's Bundle.module finds Contents/Resources/MagicWine_MagicWineCore.bundle.
# The name differs from MagicWine because the default macOS filesystem is case-insensitive.
cp "$BIN_DIR/magicwine-cli" "$STAGED_APP/Contents/MacOS/magicwine-cli"
cp "$BASE_PLIST" "$PLIST"
cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
if [[ -n "$REVISION" ]]; then
    /usr/libexec/PlistBuddy -c "Add :MagicWineGitRevision string $REVISION" "$PLIST"
fi
if [[ -n "${MAGICWINE_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $MAGICWINE_BUNDLE_ID" "$PLIST"
fi
cp "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$BIN_DIR/$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/$RESOURCE_BUNDLE"
cp -R "$BIN_DIR/$UI_RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/$UI_RESOURCE_BUNDLE"
/usr/bin/plutil -lint "$PLIST"

if [[ -n "$SIGN_IDENTITY" ]]; then
    # Sign nested code first, then the bundle, all with the hardened runtime and a secure timestamp.
    for executable in "$STAGED_APP/Contents/MacOS/magicwine-cli" "$STAGED_APP/Contents/MacOS/MagicWine"; do
        /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$executable"
    done
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGED_APP"
    /usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$STAGE/notarize.zip"
        xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$STAGED_APP"
    fi
else
    /usr/bin/codesign --force --sign - "$STAGED_APP"
fi

# dist/magicwine is a wrapper so scripts and docs that call it keep working without a second
# copy of the resource bundle. It resolves symlinks to find the app that sits beside it.
WRAPPER="$STAGE/magicwine"
{
    printf '#!/bin/bash\n'
    printf '# Generated by scripts/build-app.sh: runs the CLI packaged inside the app bundle.\n'
    printf 'self="${BASH_SOURCE[0]}"\n'
    printf 'while [[ -L "$self" ]]; do\n'
    printf '    dir="$(cd "$(dirname "$self")" && pwd)"\n'
    printf '    self="$(readlink "$self")"\n'
    printf '    [[ "$self" == /* ]] || self="$dir/$self"\n'
    printf 'done\n'
    printf 'exec "$(cd "$(dirname "$self")" && pwd)"/%q/Contents/MacOS/magicwine-cli "$@"\n' "$APP_NAME.app"
} > "$WRAPPER"
chmod 755 "$WRAPPER"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/THIRD_PARTY_NOTICES.md"

# Swap into place. The old app moves into the staging directory (removed on exit) so no stale
# file can survive; the previous layout's standalone resource bundle is dropped too.
APP="$DIST/$APP_NAME.app"
if [[ -e "$APP" ]]; then mv "$APP" "$STAGE/previous.app"; fi
mv "$STAGED_APP" "$APP" || { [[ ! -e "$STAGE/previous.app" ]] || mv "$STAGE/previous.app" "$APP"; exit 1; }
rm -rf "$DIST/$RESOURCE_BUNDLE"
mv -f "$WRAPPER" "$DIST/magicwine"
mv -f "$STAGE/LICENSE" "$DIST/LICENSE"
mv -f "$STAGE/THIRD_PARTY_NOTICES.md" "$DIST/THIRD_PARTY_NOTICES.md"

printf '\nBuilt %s %s (%s)%s\nCLI: %s/dist/magicwine\nLaunch: open "%s"\n' \
    "$APP" "$VERSION" "$BUILD" "${REVISION:+ $REVISION}" "$ROOT" "$APP"
