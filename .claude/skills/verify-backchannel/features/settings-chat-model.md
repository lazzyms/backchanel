# Settings: chat model and meeting options

Settings (⌘, or `Backchannel › Settings…`) has three tabs. `Models` picks the EmbeddingGemma
variant and downloads it. `Chat` picks what writes summaries and answers: Apple Intelligence,
Gemma 4 E2B through MLX, or any OpenAI-compatible endpoint with an optional API key kept in the
Keychain. `Meetings` sets the user's name and the keep-going checkpoint.

## Sub-features

- `Answer with` picker: `Apple Intelligence`, `Gemma 4 E2B (MLX)`, `OpenAI-compatible endpoint`;
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
  now lists a second window titled after the selected tab (`Models`, `Chat` or `Meetings`); snapshot
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

- Not yet run through this skill.
- The settings window is a separate SwiftUI `Settings` scene; opening it through the menu in the
  background has not been checked for focus side effects, so take the screenshot and verify the
  user's front app did not change (`list_windows` z_index).
- The Gemma download is 3 GB from the Hugging Face Hub and is the user's call; never start it in a
  verification unless they asked.
- `Test` with an empty model name against Ollama fails with HTTP 400; that is the server's
  behavior, not the app's.
- API keys are stored only in the Keychain item `dev.maulik.backchannel` / `endpoint-api-key`; do
  not type a real key during verification and do not read the Keychain back.
