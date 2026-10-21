# Setup: get this Mac ready for meetings

Everything a meeting needs from the Mac, checked up front instead of at the first `Start
transcribing`: Apple Intelligence, microphone access, the on-device speech model, the Screen &
System Audio Recording permission, and the FluidAudio voice models used to name who spoke. One
registry (`SetupChecker`, one `SetupItem` per row) feeds both onboarding step 1 (`Get this Mac
ready`) and Settings › Setup. Each row shows `Ready`, a progress bar while working, a one-line
message with a single button, or grey text when the Mac cannot do it. Nothing is required: step 1
always lets the user `Continue`, and `Start transcribing` still runs its own checks.

## Sub-features

- `Apple Intelligence`: `Ready` when `SystemLanguageModel` is available; otherwise the reason and
  `Open System Settings` (Apple Intelligence & Siri pane); grey when the Mac does not support it.
- `Microphone`: `Ready` when authorized; `Allow` when never asked (raises the system prompt);
  `Open System Settings` (Privacy › Microphone) when denied.
- `Speech model`: `Ready` when the SpeechAnalyzer assets for the preferred locale are installed;
  `Download` with a progress bar otherwise; grey when on-device transcription is unavailable or the
  language is unsupported.
- `System audio`: there is no API to read this permission, so it is `Allow` until the user presses
  it once; pressing creates and immediately stops a CoreAudio process tap, which is what makes macOS
  ask. Success is remembered in `defaults` (`systemAudioGranted`). Never probed during a meeting.
- `Voice models`: `Ready` when the offline diarizer files exist under
  `~/Library/Application Support/Backchannel/models/diarization/speaker-diarization-coreml/`;
  `Download` otherwise (progress is indeterminate).
- Statuses refresh when the view appears and whenever the app becomes active, so a change made in
  System Settings shows without relaunch.

## How to get to it (user POV)

First launch: the onboarding sheet opens on `1. Setup`; press each button that is offered, or
`Continue` and come back later. Later: sidebar `Settings` or `Backchannel › Settings…`, tab `Setup`.

## Driving it with cua-driver

Preconditions: launched and doctor passing. For onboarding: `defaults delete dev.maulik.backchannel
onboardingDone` before `verify.sh launch` (restore it afterwards). Reading statuses is always
safe. The buttons are two kinds: `Download` (speech model, voice models) only needs network and
time; `Allow` (microphone, system audio) raises a macOS prompt that the user answers, so press it
only when the user said they are at the Mac, and tell them the prompt is up.

- **Onboarding step 1:** `verify.sh tree "Setup" 200` on the main window. Observable: the step
  indicator reads `1. Setup`, the heading `Get this Mac ready`, and five rows `Apple Intelligence`,
  `Microphone`, `Speech model`, `System audio`, `Voice models`, each with `Ready`, a progress
  indicator, or a message plus exactly one of `Allow`, `Download`, `Open System Settings`.
  `verify.sh shot setup-onboarding`.
- **Speech model download (only if the row shows `Download`):** click that button. Observable:
  the row becomes a progress bar, then `Ready`; `verify.sh shot setup-speech-progress` during and
  `setup-speech-ready` after.
- **Continue through:** `Continue` (step 2 needs an installed embedding model to continue),
  `Continue`, then `Skip` or `Finish`. Observable: the sheet closes and
  `defaults read dev.maulik.backchannel onboardingDone` is 1.
- **Settings › Setup:** `invoke_menu ["Backchannel","Settings…"]`, then on the settings window
  (`list_windows`, its own window_id) click the `Setup` tab. Observable: the window title is
  `Setup` and the same five rows show the same statuses as step 1; save the screenshot with
  `get_window_state … --screenshot-out-file`.
- **Voice models download (only if the row shows `Download`):** click it. Observable: the button
  disappears and a progress bar shows; within about a minute the row reads `Ready` and
  `~/Library/Application Support/Backchannel/models/diarization/speaker-diarization-coreml/` exists.
- **Microphone `Allow` (user present):** click it. Observable: a `UserNotificationCenter` window
  (`list_windows` with that app's pid, layer 8) whose tree reads `Allow “Backchannel” to access your
  microphone?`; save it with `get_window_state … --screenshot-out-file`. While it is pending the
  app's own trees come back empty (`total_element_count` 0) although screenshots still work. After
  the user presses Allow the row reads `Ready` on the next read.
- **System audio `Allow` (user present):** click it. Observable: `defaults read
  dev.maulik.backchannel systemAudioGranted` becomes 1 and the row reads `Ready`.
- **Refresh on activation:** not drivable in the background (it needs the app to become active);
  verify by reading the tree after a relaunch instead.

Cleanup: `verify.sh cleanup`, then `defaults write dev.maulik.backchannel onboardingDone -bool true`.

## Gotchas

- `Allow` on `Microphone` and `System audio` raise system permission prompts that only the user
  may answer, and `Open System Settings` brings System Settings to the front: click them only with
  the user's go-ahead, never answer the prompt from the harness.
- `System audio` is unknowable until first use: a fresh machine shows `Allow` even when the
  permission was granted to this bundle before, until the probe runs once and sets
  `systemAudioGranted`. A denied permission does not make the probe throw on every macOS build;
  then the row reads `Ready` while the tap delivers silence.
- The speech model `Download` is a few hundred MB from Apple and needs network; the `Speech
  model` row shows an indeterminate bar while another process (the first `Start transcribing`)
  is downloading the same assets.
- The voice models `Download` is from the Hugging Face Hub (hundreds of MB); do not start it in a
  verification unless asked.
- Rows are `LabeledContent`; the message and the button sit in the value column, so a `query` on
  the row title returns the title only. Read the whole tree (`max_elements` 200) for the statuses.
- Proved 2026-10-19 (proof-4: onboarding step 1 through Finish, Settings › Setup; proof-5: the
  release build installed by `Scripts/install.sh`, Settings opens on the Setup tab) and 2026-10-20
  (proof-6, `build/verify/evidence/proof-6/setup-*.png`, `macos-microphone-prompt.png`): voice
  models `Download` reached `Ready` in about a minute; microphone `Allow` raised the macOS prompt
  and the row read `Ready` once the user allowed it; system audio `Allow` set `systemAudioGranted`
  to 1 and read `Ready`, with no separate macOS prompt seen by the harness (it may have been queued
  behind the microphone one and answered in the same visit; uncertain). The error paths (denied
  permission, failed download) still have no runtime proof.
