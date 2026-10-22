#!/bin/zsh
# Packages build/Backchannel.app as a zip and publishes it as a GitHub Release, so
# https://github.com/lazzyms/backchanel/releases/latest/download/Backchannel.zip
# (linked from docs/index.html) always resolves to the newest build.
# Usage: Scripts/release.sh [--no-build] [--dry-run] [--notes "text"]
#   --no-build  package the existing build/Backchannel.app instead of running Scripts/build-app.sh release
#   --dry-run   build and zip, print the release that would be created, create nothing
#   --notes     release notes; default is a one-line note plus GitHub's generated notes
# Each release carries two copies of the same zip: Backchannel.zip (stable name for the
# "latest" link) and Backchannel-<version>-<build>.zip. The tag is v<version>-<build>.
# When the build is signed with a Developer ID Application certificate, the app is
# submitted to Apple's notary service with the keychain profile named by NOTARY_PROFILE
# (default "backchannel"; create it once with
#   xcrun notarytool store-credentials backchannel --apple-id <id> --team-id <team> --password <app-specific>
# ), stapled, and only then zipped, so Gatekeeper opens it with a plain double-click.
# With an Apple Development certificate the zip is published as is and the notes tell
# the user to open it the first time with right-click > Open.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
DRY_RUN=0
NOTES=""
while (( $# )); do
  case "$1" in
    --no-build) BUILD=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --notes) shift; NOTES="${1:?--notes needs text}" ;;
    *) echo "usage: Scripts/release.sh [--no-build] [--dry-run] [--notes \"text\"]" >&2; exit 2 ;;
  esac
  shift
done

APP=build/Backchannel.app
command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in (gh auth login)" >&2; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree has uncommitted changes; commit them so the tag matches the build" >&2
  (( DRY_RUN )) || exit 1
fi

if (( BUILD )); then
  Scripts/build-app.sh release
fi
[[ -d "$APP" ]] || { echo "no $APP; run without --no-build" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
TAG="v$VERSION-$BUILD_NUMBER"
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
[[ -n "$AUTHORITY" ]] || { echo "$APP is signed ad-hoc; other Macs cannot open it. Set CODESIGN_IDENTITY and rebuild." >&2; exit 1; }
codesign --verify --deep --strict "$APP"

NOTARIZED=0
if [[ "$AUTHORITY" == "Developer ID Application:"* ]]; then
  NOTARY_PROFILE="${NOTARY_PROFILE:-backchannel}"
  if (( DRY_RUN )); then
    echo "dry run: would notarize with keychain profile '$NOTARY_PROFILE' and staple"
  else
    SUBMIT_ZIP="build/Backchannel-notarize.zip"
    rm -f "$SUBMIT_ZIP"
    ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
    xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
      || { echo "notarization failed; see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2; exit 1; }
    rm -f "$SUBMIT_ZIP"
    xcrun stapler staple "$APP"
    spctl --assess --type execute "$APP"
    NOTARIZED=1
  fi
fi

STABLE_ZIP="build/Backchannel.zip"
VERSIONED_ZIP="build/Backchannel-$VERSION-$BUILD_NUMBER.zip"
rm -f "$STABLE_ZIP" "$VERSIONED_ZIP"
ditto -c -k --keepParent "$APP" "$VERSIONED_ZIP"
cp "$VERSIONED_ZIP" "$STABLE_ZIP"
echo "packaged $VERSIONED_ZIP ($(du -h "$VERSIONED_ZIP" | cut -f1)), signed by $AUTHORITY"

if [[ -z "$NOTES" ]]; then
  NOTES="Backchannel $VERSION (build $BUILD_NUMBER) for Apple-silicon Macs on macOS 27 or later."
  if (( NOTARIZED )); then
    NOTES+=" Signed with a Developer ID certificate and notarized by Apple."
  else
    NOTES+=" Signed with an Apple Development certificate and not notarized: open the first time with right-click > Open."
  fi
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release $TAG already exists; bump the build (commit) before releasing again" >&2
  exit 1
fi

if (( DRY_RUN )); then
  echo "dry run: would tag $(git rev-parse --short HEAD) as $TAG and create release '$TAG' with assets:"
  echo "  $STABLE_ZIP"
  echo "  $VERSIONED_ZIP"
  echo "notes: $NOTES"
  exit 0
fi

gh release create "$TAG" --target "$(git rev-parse HEAD)" --title "Backchannel $VERSION ($BUILD_NUMBER)" \
  --notes "$NOTES" --generate-notes --latest \
  "$STABLE_ZIP#Backchannel.zip" "$VERSIONED_ZIP#Backchannel-$VERSION-$BUILD_NUMBER.zip"
echo "published https://github.com/lazzyms/backchanel/releases/tag/$TAG"
