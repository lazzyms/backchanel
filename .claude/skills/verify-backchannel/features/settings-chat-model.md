# Settings: chat model and meeting options

Settings (⌘, or `Backchannel › Settings…`) has four tabs. `Embedding` picks the EmbeddingGemma
variant and downloads it (vectors for matching; switching re-embeds everything). `Chat` picks,
separately, what writes summaries and answers: Apple Intelligence, Gemma 4 E2B through MLX, or
any OpenAI-compatible endpoint with an optional API key kept in the Keychain. `Folders` lists the
watched folders (see watched-folders.md). `Meetings` sets the user's name and the keep-going
checkpoint. The same embedding and chat controls are onboarding steps 1 and 2.

## Sub-features

- `Answer with` picker: `Apple Intelligence`, `Gemma 4 E2B (on device)`, `Your own model (API)`;
  per-backend status line.
- Gemma: `Download (about 3 GB)` with progress; installed state detected from the Hub cache.
- Endpoint: `Base URL`, `Model`, `API key (optional)`, `Test` button that sends a one-line chat and
  shows the reply or the HTTP error.
- Meetings: `Your name`, `Ask whether to keep going` toggle, `Every N minutes` stepper (10–120,
  disabled when the toggle is off).

## How to get to it (user POV)

Sidebar `Settings` button or app menu `Backchannel › Settings…`; click a tab.

## Driving it with cua-driver

Preconditions: launched and doctor passing. For the endpoint test, a server answering
`/v1/chat/completions` (Ollama or LM Studio on this Mac, or a hosted API with a key the user
provides out of band).

- **Open Settings:** `invoke_menu {"pid":PID,"path":["Backchannel","Settings…"]}`. Observable:
  `verify.sh window` still returns the main window; `cua-driver call list_windows '{"app":"Backchannel"}'`
  now lists a second window titled after the selected tab (`Embedding`, `Chat`, `Folders` or `Meetings`); snapshot
  it with its own window_id; `shot` targets the main window only, so save the settings screenshot
  with `get_window_state … --screenshot-out-file`.
- **Choose a backend:** click the `Chat` tab, `set_value` the `Answer with` popup. Observable:
  `defaults read dev.maulik.backchannel chatBackend` returns `apple`, `gemma` or `endpoint`, and the
  status line under the picker changes.
- **Endpoint:** `set_value` on `Base URL` and `Model`, press `Test`. Observable: the result line shows
  the model's reply, or `HTTP <code>` with the server's message when it refuses; `defaults read`
  shows `endpointURL` and `endpointModel`; the key never appears in defaults.
- **Meetings tab:** set `Your name`, toggle `Ask whether to keep going`. Observable:
  `defaults read dev.maulik.backchannel userName` and `checkpointEnabled`; the stepper is disabled
  when the toggle is off.
- **Restore:** put the picker and fields back to what doctor found before the run; the user's
  settings are live settings.

## Gotchas

- Proved 2026-10-19 (`build/verify/evidence/proof-2/settings-*`): the menu opened Settings without
  changing the user's front app (Preview before and after); picking `Apple Intelligence` wrote
  `chatBackend = apple` and showed `Ready`; `Base URL` + `Model` + `Test` against the default
  `http://localhost:11434/v1` with no server gave `Could not connect to the server.` and wrote
  `endpointURL`/`endpointModel`, no key typed; the Meetings toggle wrote `checkpointEnabled = 1` and
  enabled the stepper; everything was restored (`chatBackend = endpoint`, model empty, toggle off).
  The Gemma download was not started.
- The settings window is a separate SwiftUI `Settings` scene; opening it through the menu in the
  background did not change the front app, but check it each run (`front-before/after` evidence).
- The settings window's AX tree can come back empty (0 elements) and clicks then fail with
  `off_space_or_ax_unresolved`; invoking `Backchannel › Settings…` again restores it. Its title is
  the selected tab and was seen changing between reads, so re-read the title before each step.
- `set_value` on a text field does not commit the SwiftUI binding: press `return` on the field
  afterwards; for `Model`, `setValue("")` then `typeText` then `return` was needed. `Test` stays
  disabled until `Model` is non-empty (`isAvailable`), so commit the fields before pressing it.
- The `Every N minutes` stepper is absent from the tree while disabled; its presence after the
  toggle is the observable, not an `enabled` flag.
- The Gemma download is 3 GB from the Hugging Face Hub and is the user's call; never start it in a
  verification unless they asked.
- `Test` with an empty model name against Ollama fails with HTTP 400; that is the server's
  behavior, not the app's.
- API keys are stored only in the Keychain item `dev.maulik.backchannel` / `endpoint-api-key`; do
  not type a real key during verification and do not read the Keychain back.
