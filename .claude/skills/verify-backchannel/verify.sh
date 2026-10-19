#!/bin/zsh
# Verification helper for Backchannel (native macOS app). Every subcommand is shown in SKILL.md.
# Drives the app in the background through cua-driver; never uses `open`, which would steal focus.
set -euo pipefail
ROOT="${0:A:h:h:h:h}"            # repo root (this file lives in .claude/skills/verify-backchannel/)
APP="$ROOT/build/Backchannel.app"
BUNDLE_ID="dev.maulik.backchannel"
DB="$HOME/Library/Application Support/Backchannel/backchannel.sqlite"
STATE="$ROOT/build/verify/state"          # pid of the instance *we* launched; cleanup kills only that
EVIDENCE_ROOT="$ROOT/build/verify/evidence"
RUN="${VERIFY_RUN:-$(date +%Y%m%d-%H%M%S)}"
EVIDENCE="$EVIDENCE_ROOT/$RUN"

SESSION="verify-backchannel"            # one driver session for the whole run, so snapshots and tokens persist between calls
cua() { cua-driver call "$@"; }
# Run a cua-driver JavaScript (run_script) with PID/WID substituted and the shared session label.
script() {
  local w="$(window)"; [[ -n "$w" ]] || { echo "not running"; return 1; }
  local js="${1//PID/${w%% *}}"; js="${js//WID/${w##* }}"
  python3 -I -c 'import json,sys; print(json.dumps({"session":sys.argv[1],"timeout_ms":60000,"script":sys.argv[2]}))' "$SESSION" "$js"     | cua run_script | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("value") if d.get("ok") else {"error":d.get("error")}, indent=1))'
}
need_driver() { cua-driver status >/dev/null 2>&1 || { echo "cua-driver daemon is not running (cua-driver status)"; exit 2; }; }

# pid and window_id of the main Backchannel window, as "pid window_id" (empty when not running).
window() {
  cua list_windows '{"app":"Backchannel"}' | python3 -I -c '
import json,sys
w=[x for x in json.load(sys.stdin)["windows"] if x["layer"]==0]
w.sort(key=lambda x:-(x.get("z_index") or 0))
print(w[0]["pid"], w[0]["window_id"]) if w else None'
}

case "${1:-}" in
  build)    # compile and assemble build/Backchannel.app (minutes; run in the background)
    "$ROOT/Scripts/build-app.sh" "${2:-debug}" ;;

  launch)   # start the app in the background and wait until its main window exists
    need_driver
    [[ -d "$APP" ]] || { echo "no $APP: run verify.sh build first"; exit 2; }
    if [[ -n "$(window)" ]]; then
      echo "Backchannel is already running (pid $(window | cut -d' ' -f1)). It is a single-instance app with one shared"
      echo "database; refusing to launch a second copy. Use the running instance only if the user said so, or cleanup first."
      exit 3
    fi
    # LaunchServices must know this build; registering is idempotent and does not activate anything.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null
    cua launch_app "{\"bundle_id\":\"$BUNDLE_ID\",\"session\":\"$SESSION\"}" >/dev/null
    for i in {1..30}; do w="$(window)"; [[ -n "$w" ]] && break; sleep 1; done
    [[ -n "${w:-}" ]] || { echo "no Backchannel window after 30 s"; exit 1; }
    mkdir -p "$(dirname "$STATE")"; echo "$w" > "$STATE"
    echo "launched: pid=${w%% *} window_id=${w##* }" ;;

  doctor)   # read-only: is this instance worth driving?
    need_driver
    cua-driver permissions status | grep -E "Accessibility|Screen Recording"
    w="$(window)"; [[ -n "$w" ]] || { echo "DOCTOR FAIL: Backchannel is not running"; exit 1; }
    pid="${w%% *}"
    exe="$(ps -o comm= -p "$pid")"
    [[ "$exe" == "$APP/Contents/MacOS/Backchannel" ]] || { echo "DOCTOR FAIL: pid $pid runs $exe, not $APP"; exit 1; }
    [[ -f "$STATE" && "$(cat "$STATE")" == "$w" ]] && owner="launched by verify.sh" || owner="NOT launched by verify.sh (the user's instance)"
    echo "process: pid=$pid window_id=${w##* } $owner"
    echo "build:   $(stat -f '%Sm' "$APP/Contents/MacOS/Backchannel") (executable mtime; newer source files mean a stale build)"
    [[ -f "$DB" ]] && echo "db:      $(sqlite3 "$DB" 'select count(*) from sources')" sources, "$(sqlite3 "$DB" 'select count(*) from meetings')" meetings, "$(sqlite3 "$DB" 'select count(*) from meeting_chunks')" meeting chunks || echo "db:      missing ($DB)"
    ls "$HOME/Library/Application Support/Backchannel/models" 2>/dev/null | sed 's/^/models:  /' || echo "models:  none installed (import and embedding search will fail)"
    cua get_window_state "{\"pid\":$pid,\"window_id\":${w##* },\"session\":\"$SESSION\",\"include_screenshot\":false,\"query\":\"Start transcribing\",\"max_elements\":40}" \
      | grep -q "Start transcribing" && echo "ui:      idle (Start transcribing button present)" || echo "ui:      not idle, or window tree unreadable" ;;

  window)   # print "pid window_id"
    need_driver; window ;;

  page)     # select a sidebar page: verify.sh page meetings|ask|sources|stats (arrow keys on the sidebar outline; rows have no AX action)
    need_driver
    case "${2:-}" in meetings) n=0;; ask) n=1;; sources) n=2;; stats) n=3;; *) echo "page meetings|ask|sources|stats"; exit 2;; esac
    script 'const app = await cua.getApp({pid: PID, windowId: WID});
      const st = await app.getState({max_elements: 60, query: "Sidebar", tree_format: "elements"});
      const outline = st.elements.find(e => e.role === "AXOutline");
      for (let i = 0; i < 3; i++) { await app.pressKey("up", outline.element_token); await cua.sleep(150); }
      for (let i = 0; i < '"$n"'; i++) { await app.pressKey("down", outline.element_token); await cua.sleep(150); }
      await cua.sleep(500);
      const after = await app.getState({max_elements: 5, include_screenshot: false});
      return {window_title: after.window_title};' ;;

  run)      # run a cua-driver JavaScript body against the main window (PID and WID are substituted): verify.sh run "<js>"
    need_driver; script "${2:?js}" ;;

  tree)     # accessibility tree, optionally filtered: verify.sh tree [query] [max_elements]
    need_driver; w="$(window)"; [[ -n "$w" ]] || { echo "not running"; exit 1; }
    q="${2:-}"; n="${3:-250}"
    cua get_window_state "{\"pid\":${w%% *},\"window_id\":${w##* },\"session\":\"$SESSION\",\"include_screenshot\":false,\"max_elements\":$n$( [[ -n "$q" ]] && printf ',"query":"%s"' "$q" )}" ;;

  shot)     # screenshot of the main window into the evidence dir: verify.sh shot <name>
    need_driver; w="$(window)"; [[ -n "$w" ]] || { echo "not running"; exit 1; }
    mkdir -p "$EVIDENCE"
    cua get_window_state "{\"pid\":${w%% *},\"window_id\":${w##* },\"session\":\"$SESSION\",\"include_accessibility_tree\":false}" \
      --screenshot-out-file "$EVIDENCE/${2:?name}.png" >/dev/null
    echo "$EVIDENCE/${2}.png" ;;

  db)       # run SQL against the app's database (read-only use expected): verify.sh db "select ..."
    sqlite3 -header "$DB" "${2:?sql}" ;;

  import)   # hand files to the running app as open-targets (AppDelegate imports them as sources)
    need_driver; w="$(window)"; [[ -n "$w" ]] || { echo "not running"; exit 1; }
    shift; urls=""; for f in "$@"; do urls="$urls${urls:+,}\"file://${f:A}\""; done
    cua launch_app "{\"bundle_id\":\"$BUNDLE_ID\",\"session\":\"$SESSION\",\"urls\":[$urls]}" >/dev/null && echo "sent to app: $*" ;;

  log)      # app log lines from the last N minutes (default 5)
    log show --last "${2:-5}m" --predicate 'process == "Backchannel"' --style compact 2>/dev/null | tail -n 200 ;;

  evidence) # print this run's evidence directory
    mkdir -p "$EVIDENCE"; echo "$EVIDENCE" ;;

  cleanup)  # quit only the instance verify.sh launched; evidence is kept
    if [[ -f "$STATE" ]]; then
      pid="$(cut -d' ' -f1 "$STATE")"
      if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$APP/Contents/MacOS/Backchannel" ]]; then
        kill -TERM "$pid" && echo "terminated pid $pid"
      else
        echo "pid $pid is no longer our Backchannel; nothing killed"
      fi
      rm -f "$STATE"
    else
      echo "no instance launched by verify.sh; nothing to clean up"
    fi
    rm -f /tmp/backchannel-verify-*.md
    echo "evidence kept under $EVIDENCE_ROOT" ;;

  *) sed -n '2,3p' "$0"; grep -E '^  [a-z]+\)' "$0" | sed 's/)//'; exit 2 ;;
esac
