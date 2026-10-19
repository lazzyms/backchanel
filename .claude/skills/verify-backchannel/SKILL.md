---
name: verify-backchannel
description: Launch, drive and prove Backchannel, the native macOS SwiftUI meeting companion in this repo (build/Backchannel.app), in the background through cua-driver. Use it after any change to the app, before claiming a feature works, or when asked to verify or reproduce app behavior. The feature map under features/ says what to drive and what proves it.
---

# Verify Backchannel

Backchannel is a single-window macOS app (SwiftPM, macOS 27, bundle id `dev.maulik.backchannel`). It
transcribes meetings from the microphone and system audio with SpeechAnalyzer, recognizes speakers,
summarizes with the chosen chat model, imports documents as sources, and answers questions from
sources plus meeting transcripts. Everything it shows lives in one SQLite file. The user is usually
working on this Mac while you verify, so every step below keeps the app in the background.

All commands are relative to the repo root. The helper is `.claude/skills/verify-backchannel/verify.sh`
(executable; `verify.sh` with no argument lists its subcommands).

## Launch

1. Build once after code changes (a few minutes; run it in the background or with a long timeout):

   ```bash
   .claude/skills/verify-backchannel/verify.sh build        # debug; `build release` for release
   ```

   Ready when the output ends with `built build/Backchannel.app`. Lines with `error:` mean the build
   failed; fix the code before verifying anything.

2. Start the app in the background:

   ```bash
   .claude/skills/verify-backchannel/verify.sh launch
   ```

   Ready when it prints `launched: pid=<pid> window_id=<id>`: the main window titled `Meetings`
   exists. On first launch with an empty data directory the app creates
   `~/Library/Application Support/Backchannel/backchannel.sqlite`, runs its migrations, and shows the
   three-step onboarding sheet (`Embedding model` › `Chat model` › `Watched folders`) until it is
   finished once (`defaults read dev.maulik.backchannel onboardingDone` is 1) and an embedding model
   is installed (about 1 GB, Settings › Embedding). To drive past it: `Continue` on step 1 needs a
   downloaded model, step 2 is `Continue`, step 3 is `Skip` (or `Finish` after adding a folder). To
   skip it on a machine that already has a model: `defaults write dev.maulik.backchannel onboardingDone -bool true`
   before `launch`.
   Without an embedding model, imports and semantic search fail with "no model installed", and
   keyword search still works.

   Launch refuses with exit code 3 when Backchannel is already running. The app is single-instance
   and has no data-directory override, so a second copy would share the user's database and
   microphone: never drive the user's own instance unless they said so. Say so and stop.

3. Teardown: `verify.sh cleanup` (see Cleanup). It quits only the pid that `launch` recorded.

## Doctor

```bash
.claude/skills/verify-backchannel/verify.sh doctor
```

Read-only. Passes when it shows Accessibility and Screen Recording granted for cua-driver, a pid
whose executable is this repo's `build/Backchannel.app`, whether that pid was launched by
`verify.sh` or is the user's, the executable's build time (compare with your last source edit),
row counts for sources, meetings and meeting chunks, the installed model directories, and
`ui: idle` (the `Start transcribing` toolbar button is in the accessibility tree). Run it before
driving and again whenever a step behaves oddly. A stale build time is the usual cause of "my
change has no effect".

## Drive

The harness is cua-driver (`cua-driver call <tool> '<json>'`), already installed with Accessibility
and Screen Recording granted. It acts on accessibility elements of the exact window and never
raises the app. Rules that matter here:

- Never use `open`, `open -a`, `osascript … activate`, or `cliclick`: all of them steal focus from
  the user. `verify.sh import` and `verify.sh launch` go through cua-driver's `launch_app` instead.
- Get `pid` and `window_id` from `verify.sh window`. Element tokens come from a snapshot and expire
  on the next snapshot of the same window; read, then act, then re-read with `since:"latest"`.
- Every direct `cua-driver call` must carry `"session":"verify-backchannel"`. Without it each CLI
  call is its own session and the tokens from the previous read are reported stale. `verify.sh`
  adds the label itself, and `verify.sh run "<js>"` runs a whole read-act-check flow in one
  `run_script` call (`PID` and `WID` are substituted, `cua.getApp({pid: PID, windowId: WID})`).
- Sidebar rows expose no accessibility action and ignore background pixel clicks. Change page with
  `verify.sh page meetings|ask|sources|stats` (arrow keys on the sidebar outline); the window title
  becomes the page name.

Reading the window (tree only; `query` filters rows, `max_elements` bounds the walk):

```bash
.claude/skills/verify-backchannel/verify.sh tree "Start transcribing" 40
```

Acting (tokens are `<snapshot_id>:<row>` from the tree you just read):

```bash
S='"session":"verify-backchannel"'
cua-driver call click "{\"pid\":PID,\"window_id\":WID,$S,\"element_token\":\"s000000c3:24\"}"
cua-driver call type_text "{\"pid\":PID,\"window_id\":WID,$S,\"element_token\":\"TOKEN\",\"text\":\"What did we decide?\"}"
cua-driver call press_key "{\"pid\":PID,\"window_id\":WID,$S,\"element_token\":\"TOKEN\",\"key\":\"return\"}"
cua-driver call invoke_menu "{\"pid\":PID,$S,\"path\":[\"Backchannel\",\"Settings…\"]}"
cua-driver call get_window_state "{\"pid\":PID,\"window_id\":WID,$S,\"include_screenshot\":false,\"since\":\"latest\"}"
```

Or one flow in a script (what `verify.sh page` does internally):

```bash
.claude/skills/verify-backchannel/verify.sh run 'const app = await cua.getApp({pid: PID, windowId: WID});
  const st = await app.getState({max_elements: 80, query: "Ask Backchannel", tree_format: "elements"});
  const field = st.elements.find(e => e.role === "AXTextField");
  await app.typeText("What is the Tidewater lantern?", field.element_token);
  await app.pressKey("return", field.element_token);
  for (let i = 0; i < 4; i++) {           // the driver caps timeout_ms at 10000; loop for longer waits
    try { await app.waitFor({text: "Tidewater", timeout_ms: 10000}); break; } catch (e) { if (i === 3) throw e; }
  }
  return (await app.getState({since: "latest", max_elements: 300})).tree_diff;'
```

Stable handles in this app (from the accessibility tree of the running build):

| Handle | Where | Role / label |
| --- | --- | --- |
| Sidebar pages | main window | `AXOutline` (Sidebar) rows with static text `Meetings`, `Ask`, `Sources`, `Stats`; no AX action, use `verify.sh page` |
| Start / stop | toolbar | `AXButton (Start transcribing)`, help "Transcribe microphone and system audio (⇧⌘R)"; becomes `Stop` while recording |
| Meeting list | Meetings page | rows titled `Meeting <date> at <time>` with a subtitle `<date> · mm:ss` |
| Chat input | Ask page | `AXTextField` placeholder `Ask Backchannel about your meetings`; `New chat` button; `Scope` popup |
| Source import | Sources page | `Add source` button (opens an NSOpenPanel: use `verify.sh import` instead); `View` picker List / Graph |
| Settings | app menu `Backchannel › Settings…` or sidebar `Settings` button | window with tabs `Embedding`, `Chat`, `Folders`, `Meetings` |
| Watched folders | Settings › Folders, onboarding step 3 | `Add folder…` (NSOpenPanel: seed `defaults write dev.maulik.backchannel watchedFolders -array <path>` instead), `Remove` per row, `Last scan` |
| Menu bar extra | status item | `Start transcribing` / `Stop transcribing`, `Open Backchannel`, `Quit Backchannel` |

Entry points that need no clicking:

- `verify.sh import <files…>` hands files to the running app as open-targets; the app delegate
  imports them as sources exactly like a Dock drop or `Add source`. macOS also reopens the app,
  which adds a second main window; `verify.sh window` keeps using the topmost one and `cleanup`
  quits them both.
- `verify.sh db "<sql>"` reads the app's SQLite (tables: `sources`, `chunks`, `meetings`,
  `segments`, `insights`, `speakers`, `meeting_chunks`).
- Settings are `UserDefaults` of `dev.maulik.backchannel` (`chatBackend`, `endpointURL`,
  `endpointModel`, `userName`, `checkpointEnabled`, `checkpointMinutes`); read them with
  `defaults read dev.maulik.backchannel`. The endpoint API key is in the Keychain only.

The feature map in `features/` says, per feature, which of these to use and what end state proves it.

## Evidence

Each run gets `build/verify/evidence/<timestamp>/` (`verify.sh evidence` prints it; set
`VERIFY_RUN=<name>` to pin the folder for a whole run). Put there:

- `verify.sh shot <name>` screenshots before the action and after the resulting state, named for
  the step (`ask-before.png`, `ask-answer.png`).
- Tree snapshots or `since:"latest"` diffs saved from the cua-driver output (`> $EVIDENCE/x.json`).
- The `verify.sh db` query output that shows the side effect (new `sources` row, `meetings.ended_at`
  set, `meeting_chunks` count), and `verify.sh log` lines when a failure needs them.

Proof standards:

- Exercise the real user path: the toolbar button, the Ask field, files handed to the app. Do not
  insert rows with sqlite3 and call the feature verified.
- Capture the action and the resulting state, not only the final screen, and check the side effect
  next to what is visible: a source shows in the list *and* has `chunks` rows; a stopped meeting shows
  in the list *and* has `ended_at`, `segments` and `meeting_chunks`.
- Nothing here is mocked. Chat and summaries call the backend chosen in Settings › Chat (Apple
  Intelligence on-device, Gemma 4 through MLX, or an OpenAI-compatible endpoint); a verification of
  those features is a verification against that backend, so name it in the evidence.
- A journey whose precondition is missing (no embedding model, no chat backend available, no
  microphone access) fails and says why; do not weaken it to pass.

## Cleanup

```bash
.claude/skills/verify-backchannel/verify.sh cleanup
```

Sends SIGTERM to the pid recorded by `launch` after checking it is still this repo's
Backchannel, forgets it, and deletes `/tmp/backchannel-verify-*.md` scratch sources. It never kills
by name, never touches the user's instance, and never deletes `build/verify/evidence/`. Run it after
every attempt, failed ones included.

Data the drive created in the user's database stays (it is their one database): remove a test
source from the Sources page context menu (`Remove from library`) or a test meeting from the
Meetings list (`Delete`) through the UI, or leave them and say so in the report.

## Helpers

`verify.sh` subcommands, all shown above: `build [debug|release]`, `launch`, `doctor`, `window`,
`page <name>`, `run "<js>"`, `tree [query] [max_elements]`, `shot <name>`, `db "<sql>"`,
`import <files…>`, `log [minutes]`, `evidence`, `cleanup`.

Proven on 2026-10-19 with the `sources-import` journey: launch, doctor, import of a scratch
markdown file, page change, tree and screenshot evidence, database side effect (`sources` row with
an Apple Intelligence label and one `chunks` row), cleanup, evidence intact under
`build/verify/evidence/proof-1/`. Proven on 2026-10-19 under `proof-2/`: `ask-chat`,
`settings-chat-model` and `stats` (results and gotchas in each feature file); `meetings-transcribe`
was skipped because audio would have reached the user's speakers while they worked. The driver ends
an idle session after a while, so `verify.sh` revives it (`start_session`) before every call, and
it prefers the window recorded by `launch` so an open Settings window is not mistaken for the main
one. It needs `cua-driver` (daemon running: `cua-driver status`), `sqlite3`,
`python3` and Xcode 27.
