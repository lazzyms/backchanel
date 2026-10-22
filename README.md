# Backchannel for Mac

A personal, offline meeting companion for Apple-silicon Macs (macOS 27+). It transcribes meetings
from your microphone and from system audio without joining the call, spots questions as they are
asked, and answers them from documents you imported. Everything runs on-device.

## Interface

The window mirrors Google AI Edge Foresight: a sidebar with **Meetings**, **Ask**, **Sources** and
**Stats**, a global **Start transcribing** button in the toolbar (⇧⌘R, also in the File menu and the
menu bar item), and **Settings** (⌘,) for the embedding model and the keep-going interval. Meetings
shows the list beside a Transcript / Summary / Insights detail; Ask is the chat with a scope chip
(all sources and meetings, or focused on one meeting); Sources is the library with graph or document view; Stats counts
meetings, recorded time, sources, labels and answered questions.

## Features

- **Sources**: drop or import Markdown, text, PDF and image files. Text is extracted (Vision OCR for
  images and scanned PDFs), chunked, embedded, and labelled by Apple's on-device language model.
  The graph view places sources by similarity (PCA of their embeddings) and draws edges above
  cosine 0.55.
- **Live meetings**: one `SpeechAnalyzer` pipeline for the mic (your name, set in Settings) and one
  for a CoreAudio process tap of all system output. Offline after the locale assets are installed.
  Meetings start and stop silently.
- **Speaker recognition**: system audio is also written to a 16 kHz WAV during the meeting. On stop,
  FluidAudio's offline diarizer (pyannote segmentation + WeSpeaker embeddings, Core ML, models
  downloaded once into Application Support) splits it by voice; each transcript line takes the
  voice that overlaps it most. Voices are matched against earlier meetings (cosine above the threshold under Settings › Meetings, 0.75 by default; every decision is logged to voice-matches.tsv) or named
  "Speaker N". Right-click a line to rename a voice; the name propagates to every meeting.
- **Never stops on its own**: every 30 minutes (interval and on/off in Settings › Meetings) the capsule asks "Keep going?" with a chime. The
  transcript continues until you press Stop.
- **Floating capsule**: a small always-on-top panel (all Spaces, over full-screen apps) with a
  recording dot, elapsed time and a Stop button.
- **Live Q&A**: final transcript segments that look like questions are checked by the on-device
  model, matched against your sources by embedding, and answered in the right-hand pane. Answers
  are stored with the meeting.
- **Vocabulary**: words the speech model mishears ("hola sale" for "wholesale") are corrected in
  transcript lines and questions before retrieval. Source titles and labels count automatically;
  add your own under Settings › Meetings › Vocabulary. Hover a corrected line to see what was heard.
- **Notes and export**: a Notes section beside each meeting, and ⌘E (or the share button) writes
  the meeting as Markdown: notes, summary, insights with sources, and the timestamped transcript.
- **Calendar titles**: with Settings › Meetings › Calendar on, a new meeting is named after the
  calendar event under way (read-only access, asked once).

## Known limitations

- The voice-match threshold (0.75) is adjustable but has not been tuned on real data; use
  voice-matches.tsv to see where matches and misses fall.
- Releases are notarized only when a Developer ID certificate is in the keychain; otherwise the
  first launch needs right-click > **Open**.

## Requirements

- macOS 27.0 or later, Apple silicon, Xcode 27.1 or later.
- Apple Intelligence enabled for labels and live Q&A, and for summaries and chat unless another chat
  model is chosen (transcription works without it). The on-device model only; Apple exposes no
  Private Cloud Compute to third-party apps.
- Permissions on first run: Microphone, Speech Recognition, and Screen & System Audio Recording
  (System Settings > Privacy & Security) for the system-audio tap.

## Install

```bash
Scripts/install.sh
```

`Scripts/install.sh` builds a release app with `Scripts/build-app.sh`, copies it to
`/Applications/Backchannel.app` (or `~/Applications` when `/Applications` is not writable), replacing
any earlier copy, and registers it with Launch Services. It refuses to replace a copy that is
running unless you pass `--force`, which quits that copy first. It prints the installed path, the
version and build number, and the signing identity, and it does not launch the app. Pass `--debug`
to install a debug build.

The build is signed with the first "Developer ID Application" identity in your keychain, else the
first "Apple Development" one, or with `CODESIGN_IDENTITY` when set. A stable identity means macOS keeps the Microphone and Screen & System
Audio Recording grants across reinstalls. Without an identity the app is signed ad-hoc, and macOS
asks for both grants again after each reinstall.

Pass `--zip` to also write `build/Backchannel-<version>.zip` for another Mac. With a development
certificate the zip is not notarized, so the first launch there needs right-click > **Open**, or
`xattr -dr com.apple.quarantine /Applications/Backchannel.app`. Publish through the release script
below for a build that opens with a double-click.

### Release

`Scripts/release.sh` builds a release app, zips it, and publishes a GitHub Release tagged
`v<version>-<build>` with two copies of the zip: `Backchannel.zip` (a stable name, so
`releases/latest/download/Backchannel.zip` always resolves to the newest build) and
`Backchannel-<version>-<build>.zip`. It needs a clean working tree and `gh auth login`. Pass
`--no-build` to package the existing `build/Backchannel.app`, `--dry-run` to see what it would
publish, `--notes "text"` for custom notes. The landing page under `docs/` is hosted on Netlify at https://backchannel-mac.netlify.app and
links to those assets; redeploy it with `npx netlify-cli deploy --prod --dir docs --site backchannel-mac`. When a "Developer ID
Application" certificate is in the keychain, the app is signed with it under the hardened runtime,
notarized through `xcrun notarytool` with the keychain profile `NOTARY_PROFILE` (default
`backchannel`) and stapled before it is zipped, so Gatekeeper opens it with a double-click. Store
the credentials once with `xcrun notarytool store-credentials backchannel --apple-id <id> --team-id
<team> --password <app-specific-password>`; the certificate comes from the paid Apple Developer
Program. Without one, releases carry the Apple Development signature and the notes say to open the
first time with right-click > **Open**.

### Build only

`Scripts/build-app.sh [debug|release]` runs `xcodebuild` on the SwiftPM package and assembles
`build/Backchannel.app` with `Resources/Info.plist`, the MLX Metal shader bundle, the signature
and the entitlements. `CFBundleVersion` in the built app is the commit count of `HEAD`. Building
needs the Xcode Metal Toolchain once (`xcodebuild -downloadComponent MetalToolchain`); the built
app does not. Set `BACKCHANNEL_NO_MLX=1` to build without MLX (the Gemma model then shows as
"Not in this build").

### Embedding models

On first launch a sheet asks which embedding model to use; "Models…" in the Sources footer
reopens it. Switching re-embeds every stored source, since vectors from different models
never mix.

Embeddings are Google's EmbeddingGemma 2 (8-bit MLX weights, 768-dim, multilingual), downloaded
in-app from Hugging Face into `~/Library/Application Support/Backchannel/models/embeddinggemma-2/`:

- Text: 320 MB (`text-q8/`). Images and PDF scans are embedded from their OCR text.
- Text + vision: 514 MB (adds `vision-q8/`, sharing the text weights). Image sources also get a
  vision embedding stored as an extra chunk, so a question can match what a picture shows.

Nothing embeds until a model is installed; the picker stays open on launch until then. Newer
EmbeddingGemma versions are added as entries in `EmbeddingModel.catalog`
(`Sources/Backchannel/Sources/EmbeddingModels.swift`); `Embedders.make` needs no change.

### Summaries and chat

Settings › Chat picks the model that answers chat and writes summaries:

- **Apple Intelligence**: the on-device foundation model, guided generation for summaries. About
  4,000 tokens of context, so long transcripts are summarised in windows and merged.
- **Gemma 4 E2B (on device)**: `mlx-community/gemma-4-e2b-it-4bit` through mlx-swift-lm, downloaded
  in-app from the Hugging Face Hub into `Application Support/Backchannel/models/hub/` (about 3 GB).
- **Your own model (API)**: any OpenAI-compatible `/chat/completions` endpoint, local or hosted:
  base URL, model name and an optional API key. Ollama (`http://localhost:11434/v1`) and LM Studio
  work offline. The key is stored only in the login Keychain and sent only to that URL.

A summary (overview, topics, key points, action items with owners) is written when a meeting stops
and stored in `meetings.summary`; "Summarize again" re-runs it for older meetings.

Chat retrieval is hybrid: every passage (source chunks and, after each meeting, ~900-character
windows of the named transcript plus the summary, in `meeting_chunks`) is scored by BM25 over
tokens and by cosine similarity of EmbeddingGemma vectors, and the two rankings are fused with
reciprocal rank fusion (`QA/Retrieval.swift`). The top passages, plus one meeting's summary and
transcript tail when chosen in the scope picker, go to the chat model with today's date, so
"what did Alice say on Friday about pricing" resolves by name and date. Chat history is in memory
only.

### App icon

`Resources/AppIcon.icon` is an Icon Composer bundle; the build script compiles it with `actool`
into `AppIcon.icns` and `Assets.car` inside the app.

## Data

Everything lives in `~/Library/Application Support/Backchannel/backchannel.sqlite`
(sources, chunks, meetings, segments with speaker names, meeting_chunks, speakers with voice
embeddings, insights). Delete the file to start over. Models live beside it under `models/`.

## Layout

```
Sources/Backchannel/
  App/            BackchannelApp (window, Settings scene, menu bar item), AppModel, ContentView (sidebar + pages)
  Audio/          SystemAudioTap (CoreAudio process tap), MicrophoneCapture, Chime
  Transcription/  TranscriptionChannel (SpeechAnalyzer + SpeechTranscriber per stream), SpeakerRecognizer (FluidAudio diarization + WAV recorder)
  Meeting/        MeetingSession (state machine, checkpoint prompt, stop pipeline: recognize → summarize → index)
  QA/             OnDeviceLM (FoundationModels: labels, Q&A, summaries), ChatBackend (Apple / Gemma MLX / endpoint + ChatModelManager),
                  Keychain, Summarizer, Retrieval (BM25 + cosine + RRF), LiveQAService, ChatSession
  Sources/        SourceImporter (extract + chunk), Embedder, EmbeddingModels (catalog + downloads), SourceLibrary
  Storage/        Database (SQLite), Store, Models, Schema.sql
  UI/             MeetingsView, AskView, SourcesView + GraphView, StatsView, SettingsView, CapsulePanel, ModelPickerView
Resources/        Info.plist, entitlements, AppIcon.icon (Icon Composer bundle)
```

## License

MIT. See [LICENSE](LICENSE). The Swift packages it builds on are MIT (EmbeddingGemma2Swift, mlx-swift-lm) and Apache 2.0 (FluidAudio, swift-transformers, swift-huggingface); model weights downloaded from the Hugging Face Hub carry their own licenses.
