# Backchannel feature map

What a user can do in Backchannel, how to reach it, how to drive it with cua-driver and
`verify.sh`, and what end state proves it. One file per feature. Keep this honest: when a feature
changes, change its file; when a journey fails for a missing precondition, record it in that file's
Gotchas rather than softening the journey.

## Baseline preconditions

- `build/Backchannel.app` built from the current source (`verify.sh build`), launched with
  `verify.sh launch`, and `verify.sh doctor` passing.
- An embedding model installed under `~/Library/Application Support/Backchannel/models` (chosen
  once in Settings › Models). Without it imports and semantic retrieval fail by design.
- For chat and summaries: the backend chosen in Settings › Chat is available (Apple Intelligence
  enabled on this Mac, or Gemma downloaded, or an endpoint that answers `verify.sh`'s Test).
- For meetings: microphone access granted to Backchannel and audio actually playing or spoken.

## Driving conventions

- `PID`/`WID` are the values `verify.sh window` prints. Tokens come from the latest tree read of
  that window; re-read before acting after anything changed.
- Go to a page with `verify.sh page ask` (and so on): sidebar rows have no accessibility action
  and ignore background pixel clicks, so the helper moves the selection with arrow keys.
- Direct `cua-driver call`s need `"session":"verify-backchannel"` or their tokens go stale; prefer
  `verify.sh run "<js>"` for a read-act-check flow.
- Keep the app in the background. Shortcuts like ⇧⌘R are menu equivalents: use the toolbar button or
  `invoke_menu` with `["File", "Start transcribing"]` instead of sending the chord.
- Read side effects with `verify.sh db`, settings with `defaults read dev.maulik.backchannel`.

## Proof and skip reporting

A journey passes when every observable in its "Driving it" section matched; evidence goes to the run's
`build/verify/evidence/<run>/` folder as screenshots plus the query output. A journey that cannot
run (precondition missing, backend unavailable) is reported as skipped with the reason, never as
passed. Say which chat backend answered when chat or summaries were involved.

## Feature entry contract

Each file has an H1 with the feature name, one paragraph saying what it is, then exactly these H2s:
`Sub-features`, `How to get to it (user POV)`, `Driving it with cua-driver`, `Gotchas`. The driving
section starts with `Preconditions:` and lists labeled steps, each pairing an action with the
observable that proves it.

## Features

- [sources-import.md](sources-import.md): add documents, see them listed and in the graph, remove them.
- [ask-chat.md](ask-chat.md): ask questions answered from sources and meeting transcripts, scoped or not.
- [meetings-transcribe.md](meetings-transcribe.md): start and stop a meeting, live transcript, speaker names, summary.
- [settings-chat-model.md](settings-chat-model.md): choose Apple Intelligence, Gemma 4 or an OpenAI-compatible endpoint; meeting options.
- [stats.md](stats.md): counts of meetings, sources and insights, and which models are in use.
