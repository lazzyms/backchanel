# Meetings: transcribe, recognize speakers, summarize

Start transcribing captures the microphone (labelled with the user's name, default "You") and
system audio ("Others") with SpeechAnalyzer, writes final lines to `segments`, and never stops on
its own. Stop ends the meeting, names other voices by speaker recognition (FluidAudio diarization,
`speakers` table), indexes the transcript into `meeting_chunks`, and writes a summary with the chosen
chat backend (overview, topics, key points, action items).

## Sub-features

- Start/Stop from the toolbar button, `File › Start transcribing` (⇧⌘R) or the menu bar extra.
- Live transcript with speaker names; floating capsule with elapsed time.
- Keep-going checkpoint: when enabled, a chime and prompt every N minutes (Settings › Meetings).
- Speaker recognition after stop; right-click a line to `Rename “Speaker 1”…` across meetings.
- Summary tab with `Summarize again`; Insights tab with questions answered live from sources and a
  field `Ask a question about your sources` (id `insightQuestion`) plus `Ask` to ask one now. Each
  answer lists only the source titles it cites as `[n]`, or all retrieved titles when it cites none.
- Transcript speaker names read `<name>, microphone` or `<name>, system audio` to accessibility and
  show the route on hover; the user's own name never appears on a system-audio line.
- History: select a past meeting to read transcript, summary and insights; `Delete Meeting` in the
  row's context menu.

## How to get to it (user POV)

Any page › toolbar `Start transcribing`. Talk or play audio. Toolbar `Stop`. The meeting appears at
the top of the Meetings list; its Summary tab fills in once the model finishes.

## Driving it with cua-driver

Preconditions: launched and doctor passing (`ui: idle`); microphone permission already granted to
Backchannel (a first run prompts the user; that dialog belongs to them); a chat backend available
for the summary; something audible on the system output while recording (for example
`say -v Samantha "<two or three sentences on a distinctive topic>"`, which the system tap hears as
"Others"). Note `verify.sh db "select count(*) from meetings"`.

- **Start:** `verify.sh tree "Start transcribing" 40`, click the toolbar button token. Observable:
  the toolbar button becomes `Stop` with an elapsed clock, the menu bar symbol changes, and
  `verify.sh db "select id,title from meetings where ended_at is null"` has one row;
  `verify.sh shot meeting-recording`.
- **Speak:** run the `say` command, wait 5 s. Observable: transcript lines with name `Others`
  appear in the tree; `verify.sh db "select speaker,speaker_name,text from segments where meeting_id=<id>"`
  shows final lines.
- **Stop:** click the `Stop` toolbar button. Observable: the toolbar shows `Finishing…`, then
  `Recognizing speakers…`, then `Summarizing…`, then `Start transcribing` again; `ended_at` is set.
- **Recognition:** `verify.sh db "select distinct speaker_name from segments where meeting_id=<id>"`
  shows `Speaker N` names (or a known name) instead of `Others` for the system-audio lines, and
  `verify.sh db "select name from speakers"` grew when the voice was new.
- **Index and summary:** `verify.sh db "select count(*) from meeting_chunks where meeting_id=<id>"`
  is at least 1 and `select summary from meetings where id=<id>` contains `**Topics**` and
  `**Action items**`; the Summary tab shows the same text; `verify.sh shot meeting-summary`.

## Gotchas

- Audio capture is real: a silent system produces an ended meeting with no segments, no speakers,
  no chunks and no summary. That is a skipped journey (no audio), not a failing app.
- The system audio tap is a CoreAudio process tap on all output; music or a video playing on the
  Mac will land in the transcript too.
- Speaker recognition needs the FluidAudio models under `models/diarization`; they download on first
  use, so the first stop can take a minute longer. Cross-meeting voice matching uses cosine ≥ 0.75
  and has not yet been checked on real meetings.
- Skipped 2026-10-19 (proof-2): only the built-in speakers at volume 100 and the user at the Mac.
  Proved 2026-10-20 (proof-6, `meeting-recording.png`, `meeting-live-transcript.png`,
  `meeting-summary.png`) with the output volume set to 20 for the run (`osascript -e 'set volume
  output volume 20'`, restored to 100 after): `say -v Samantha` on the speakers produced four
  `Others` segments within 8 s, Stop set `ended_at`, speaker recognition renamed them `Speaker 1`
  and added one `speakers` row, two `meeting_chunks` rows were written, and Apple Intelligence
  wrote a summary with `**Topics**`, `**Key points**` and `**Action items**`. The whole stop took
  under two seconds for a 55 s meeting, so a 1 s poll never saw `Finishing…`, `Recognizing
  speakers…` or `Summarizing…`; treat those labels as optional observables.
- The microphone is live during the run: whatever is said in the room lands in the transcript as
  the user's own name, and `say` on speakers can reach it too (the proof-6 lines all came through
  the system tap as `Others`).
- Sending ⇧⌘R to a background app does not reach the menu; use the toolbar button or
  `invoke_menu ["File","Start transcribing"]`.
- The checkpoint prompt only appears after `checkpointMinutes` (10–120); a verification of it
  means waiting that long, or setting the stepper to 10 minutes first.
- Start blocks with an alert when the microphone is denied or no speech locale is installed; the
  alert text names the cause.
- Proven 2026-10-21 (run `fix-all`, `insights-answered.png`, `insights-db.txt`): a question typed
  into `insightQuestion` on meeting 6 wrote `insights` row 2 (`Soy wax should be poured at
  60–65°C.`) within 2 s and the Insights list showed it. `set_value` on the field fills the text but
  not SwiftUI's binding, so Return and `Ask` do nothing after it: use `type_text` with the field's
  `element_token`, then `press_key return` with the same token.
- Proven 2026-10-21 (run `fix-all`, `transcript-speaker-labels.txt`): meeting 6's four lines read
  `Speaker 1, system audio` with help `Speaker 1 · system audio`.

### Build 39 (UX)
- The section picker's third segment reads "Insights (N)" when the meeting has insights.
- Summary shows one status strip (`id=summaryStatus`): "Summary by <model>" with "Summarize again",
  or the blocking reason with a "Chat settings" button, or "Not summarized yet" with "Summarize meeting"
  (proof: `build/verify/evidence/ux/summary-strip.png`).
- With no meetings at all the detail pane shows "Your first meeting" with three steps and either
  "Start transcribing" or "Not ready yet: …" plus "Open Setup". Not driven on the harness, whose
  database already holds meetings.
