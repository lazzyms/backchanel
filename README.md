# Backchannel for Mac

A personal, offline meeting companion for Apple-silicon Macs (macOS 27+). It transcribes meetings
from your microphone and from system audio without joining the call, spots questions as they are
asked, and answers them from documents you imported. Everything runs on-device.

## Interface

The window mirrors Google AI Edge Foresight: a sidebar with **Meetings**, **Ask**, **Sources** and
**Stats**, a global **Start transcribing** button in the toolbar (⇧⌘R, also in the File menu and the
menu bar item), and **Settings** (⌘,) for the embedding model and the keep-going interval. Meetings
shows the list beside a Transcript / Summary / Insights detail; Ask is the chat with a scope chip
(sources only, or one meeting); Sources is the library with graph or document view; Stats counts
meetings, recorded time, sources, labels and answered questions.

## Features

- **Sources**: drop or import Markdown, text, PDF and image files. Text is extracted (Vision OCR for
  images and scanned PDFs), chunked, embedded, and labelled by Apple's on-device language model.
  The graph view places sources by similarity (PCA of their embeddings) and draws edges above
  cosine 0.55.
- **Live meetings**: one `SpeechAnalyzer` pipeline for the mic ("You") and one for a CoreAudio
  process tap of all system output ("Others"). Offline after the locale assets are installed.
- **Announcement**: a tone plus a spoken "Backchannel is now transcribing this meeting." before any
  audio is captured.
- **Never stops on its own**: every 30 minutes the capsule asks "Keep going?" with a tone. The
  transcript continues until you press Stop.
- **Floating capsule**: a small always-on-top panel (all Spaces, over full-screen apps) with a
  recording dot, elapsed time and a Stop button.
- **Live Q&A**: final transcript segments that look like questions are checked by the on-device
  model, matched against your sources by embedding, and answered in the right-hand pane. Answers
  are stored with the meeting.

## Requirements

- macOS 27.0 or later, Apple silicon, Xcode 27.1 or later.
- Apple Intelligence enabled (for labels, live Q&A, meeting summaries and chat; transcription works
  without it). The on-device model only; Apple exposes no Private Cloud Compute to third-party apps.
- Permissions on first run: Microphone, Speech Recognition, and Screen & System Audio Recording
  (System Settings > Privacy & Security) for the system-audio tap.

## Build and run

```bash
Scripts/build-app.sh
```

```bash
open build/Backchannel.app
```

`Scripts/build-app.sh [debug|release]` runs `xcodebuild` on the SwiftPM package and assembles
`build/Backchannel.app` with `Resources/Info.plist`, the MLX Metal shader bundle, an ad-hoc
signature and the entitlements. Building needs the Xcode Metal Toolchain once
(`xcodebuild -downloadComponent MetalToolchain`); the built app does not. Set
`BACKCHANNEL_NO_MLX=1` to build without MLX (the Gemma model then shows as "Not in this build").

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

Apple's on-device foundation model writes a summary (overview, key points, action items) when a
meeting stops, stored in the `meetings.summary` column and shown above Live Q&A; "Summarize
meeting" runs it for older meetings. The Chat section answers multi-turn questions from the top
EmbeddingGemma matches across your sources plus, if chosen in the scope picker, one meeting's
summary and transcript tail. Chat history is in memory only. Long transcripts are summarised in
windows because the model sees about 4,000 tokens at once.

### App icon

`Resources/AppIcon.icon` is an Icon Composer bundle; the build script compiles it with `actool`
into `AppIcon.icns` and `Assets.car` inside the app.

## Data

Everything lives in `~/Library/Application Support/Backchannel/backchannel.sqlite`
(sources, chunks, meetings, segments, insights). Delete the file to start over.

## Layout

```
Sources/Backchannel/
  App/            BackchannelApp (window, Settings scene, menu bar item), AppModel, ContentView (sidebar + pages)
  Audio/          SystemAudioTap (CoreAudio process tap), MicrophoneCapture, Announcer
  Transcription/  TranscriptionChannel (SpeechAnalyzer + SpeechTranscriber per speaker)
  Meeting/        MeetingSession (state machine, checkpoint prompt, persistence)
  QA/             OnDeviceLM (FoundationModels: labels, Q&A, summaries), LiveQAService, ChatSession
  Sources/        SourceImporter (extract + chunk), Embedder, EmbeddingModels (catalog + downloads), SourceLibrary
  Storage/        Database (SQLite), Store, Models, Schema.sql
  UI/             MeetingsView, AskView, SourcesView + GraphView, StatsView, SettingsView, CapsulePanel, ModelPickerView
Resources/        Info.plist, entitlements, AppIcon.icon (Icon Composer bundle)
```
