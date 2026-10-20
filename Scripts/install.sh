#!/bin/zsh
# Builds Backchannel and installs it into /Applications (or ~/Applications when
# /Applications is not writable). Usage: Scripts/install.sh [--zip] [--debug] [--force]
#   --zip    also write build/Backchannel-<version>.zip for sharing
#   --debug  install a debug build instead of release
#   --force  quit a running installed copy instead of refusing
# The app is never launched.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
ZIP=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --zip) ZIP=1 ;;
    --debug) CONFIG=debug ;;
    --force) FORCE=1 ;;
    *) echo "usage: Scripts/install.sh [--zip] [--debug] [--force]" >&2; exit 2 ;;
  esac
done

if [[ -w /Applications ]]; then
  TARGET=/Applications/Backchannel.app
else
  TARGET="$HOME/Applications/Backchannel.app"
fi
EXECUTABLE="$TARGET/Contents/MacOS/Backchannel"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Matches only a process whose command line starts with the installed executable path,
# never a same-named app elsewhere.
running_pids() { pgrep -f "^${EXECUTABLE}( |$)" || true; }

stop_running_instance() {
  local pids
  pids="$(running_pids)"
  [[ -n "$pids" ]] || return 0
  if (( ! FORCE )); then
    echo "Backchannel is running from $TARGET (pid ${pids//$'\n'/, }). Quit it, or rerun with --force." >&2
    exit 1
  fi
  echo "sending SIGTERM to pid ${pids//$'\n'/, }"
  kill -TERM ${=pids}
  local i
  for i in {1..100}; do
    [[ -n "$(running_pids)" ]] || return 0
    sleep 0.1
  done
  echo "Backchannel (pid ${pids//$'\n'/, }) did not exit within 10 s of SIGTERM" >&2
  exit 1
}

stop_running_instance
Scripts/build-app.sh "$CONFIG"
stop_running_instance

mkdir -p "${TARGET:h}"
rm -rf "$TARGET"
ditto build/Backchannel.app "$TARGET"
"$LSREGISTER" -f "$TARGET"

PLIST="$TARGET/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
SIGNATURE="$(codesign -dvv "$TARGET" 2>&1)"
AUTHORITY="$(print -r -- "$SIGNATURE" | sed -n 's/^Authority=//p' | head -n 1)"
[[ -n "$AUTHORITY" ]] || AUTHORITY="ad-hoc ($(print -r -- "$SIGNATURE" | grep -o 'Signature=adhoc' || echo 'no Authority line'))"
echo "installed $TARGET"
echo "version $VERSION (build $BUILD), signed by $AUTHORITY"

if (( ZIP )); then
  ZIP_PATH="build/Backchannel-$VERSION.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$TARGET" "$ZIP_PATH"
  echo "wrote $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
  echo "The zip is signed with a development certificate and not notarized. On another Mac, open it the first time with right-click > Open, or run: xattr -dr com.apple.quarantine /Applications/Backchannel.app"
fi
