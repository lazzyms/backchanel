# Settings: chat model and meeting options

Settings (⌘, or `Backchannel › Settings…`) has five tabs. `Setup` is the meeting readiness list
(see setup.md). `Embedding` picks the embedding model: the two bundled EmbeddingGemma 2 variants
plus any text-embedding repo added from the Hugging Face Hub search under the list (vectors for
matching; switching re-embeds everything). `Chat` picks, separately, what writes summaries and
answers: Apple Intelligence, a Hugging Face model through MLX (Gemma 4 E2B by default, any repo the
loader supports via the same Hub search), or any OpenAI-compatible endpoint with an optional API key
kept in the Keychain. `Folders` lists the watched folders (see watched-folders.md). `Meetings` sets
the user's name and the keep-going checkpoint. The same embedding and chat controls are onboarding
steps 2 and 3.

## Sub-features

- `Answer with` picker: `Apple Intelligence`, `Hugging Face model (on device)`, `Your own model (API)`;
  per-backend status line.
- Hugging Face model: `Model` popup over the added repos (always includes `gemma-4-e2b-it-4bit`);
  `Status` row with `Download (about 3 GB)` for Gemma 4, `Download` for other repos, progress, or
  `Downloaded` (installed state detected from the Hub cache); `Repo` row with the repo id and a
  `Remove` button for every repo except Gemma 4.
- `Add from Hugging Face` (Chat tab): search field, `Search`, up to 25 results per pipeline tag
  (`text-generation`, tagged `mlx`, most downloaded first) with name, `owner · model_type · params ·
  downloads`, and `Add` only when the model_type is in `HubModel.supportedTypes`; otherwise
  `Not supported`. `Add` appends to the popup and selects it.
- `Add from Hugging Face` (Embedding tab): same search over `feature-extraction` and
  `sentence-similarity`; `Add` appends a row (`Download` plus an xmark `Remove`) and selects it;
  `Use this model` stays disabled until the row is downloaded.
- Endpoint: `Base URL`, `Model`, `API key (optional)`, `Test` button that sends a one-line chat and
  shows the reply or the HTTP error.
- Meetings: `Your name`, `Ask whether to keep going` toggle, `Every N minutes` stepper (10–120,
  disabled when the toggle is off).

## How to get to it (user POV)

Sidebar `Settings` button or app menu `Backchannel › Settings…`; click a tab.

## Driving it with cua-driver

Preconditions: launched and doctor passing. Hub search needs network access to huggingface.co. For
the endpoint test, a server answering `/v1/chat/completions` (Ollama or LM Studio on this Mac, or a
hosted API with a key the user provides out of band).

- **Open Settings:** `invoke_menu {"pid":PID,"path":["Backchannel","Settings…"]}`. Observable:
  `verify.sh window` still returns the main window; `cua-driver call list_windows '{"app":"Backchannel"}'`
  now lists a second window titled after the selected tab (`Setup`, `Embedding`, `Chat`, `Folders` or `Meetings`); snapshot
  it with its own window_id; `shot` targets the main window only, so save the settings screenshot
  with `get_window_state … --screenshot-out-file`.
- **Switch tab:** `get_window_state` with `"query":"Chat"` (or `"Embedding"`) returns the toolbar
  button; click it. Observable: the window title becomes the tab name.
- **Choose a backend:** click the `Chat` tab, `set_value` the `Answer with` popup. Observable:
  `defaults read dev.maulik.backchannel chatBackend` returns `apple`, `mlx` or `endpoint` (`gemma`
  from older builds still reads as the Hugging Face backend), and the status line under the picker changes.
- **Search the Hub (either tab):** on the search field, `set_value ""`, then `type_text` the query,
  then `press_key return`; wait 6–8 s. Observable: result rows appear as `AXStaticText` name and
  detail with an `Add <name>` button or a `Not supported` text; `No MLX models match.` when empty.
- **Add and remove (Chat):** click `Add <name>`. Observable: the `Model` popup reads `<name>`,
  `Download <name>` and `Remove <name>` buttons exist, `defaults read … mlxModelID` is the repo id
  and `hubChatModels` (JSON data) contains it. Click `Remove <name>`. Observable: popup back to
  `gemma-4-e2b-it-4bit`, `mlxModelID` back to `mlx-community/gemma-4-e2b-it-4bit`.
- **Add and remove (Embedding):** click `Add <name>`. Observable: a third row with `Download <name>`
  and `Remove <name>`, `hubEmbeddingModels` (JSON data) contains it, `embeddingModelID` unchanged
  until `Use this model`. Click `Remove <name>`. Observable: row gone, `hubEmbeddingModels` is `[]`.
- **Endpoint:** `set_value` on `Base URL` and `Model`, press `Test`. Observable: the result line shows
  the model's reply, or `HTTP <code>` with the server's message when it refuses; `defaults read`
  shows `endpointURL` and `endpointModel`; the key never appears in defaults.
- **Meetings tab:** set `Your name`, toggle `Ask whether to keep going`. Observable:
  `defaults read dev.maulik.backchannel userName` and `checkpointEnabled`; the stepper is disabled
  when the toggle is off.
- **Restore:** put the picker and fields back to what doctor found before the run, and remove any
  repo the run added; the user's settings are live settings.

## Gotchas

- Proved 2026-10-19 (`build/verify/evidence/proof-2/settings-*`): the menu opened Settings without
  changing the user's front app (Preview before and after); picking `Apple Intelligence` wrote
  `chatBackend = apple` and showed `Ready`; `Base URL` + `Model` + `Test` against the default
  `http://localhost:11434/v1` with no server gave `Could not connect to the server.` and wrote
  `endpointURL`/`endpointModel`, no key typed; the Meetings toggle wrote `checkpointEnabled = 1` and
  enabled the stepper; everything was restored (`chatBackend = endpoint`, model empty, toggle off).
  The Gemma download was not started.
- Proved 2026-10-20 (`build/verify/evidence/hub-search/`): Chat tab search `qwen3` listed Hub
  repos with `Add` for `qwen3`/`qwen3_moe`/`qwen3_5` types; adding `Qwen3-8B-4bit` switched the
  popup and `mlxModelID`, removing restored Gemma 4. Embedding tab search `nomic` returned only
  `modernbert` repos, all `Not supported`; `bge` returned `bert` and `xlm-roberta` repos with `Add`;
  adding `bge-small-en-v1.5-bf16` added a selected row with `Download`, removing emptied
  `hubEmbeddingModels`. No Hub download was started, so downloading and running a searched repo
  (`HubEmbedder`, `MLXChatModel` with a non-Gemma repo) is unproven.
- The settings window is a separate SwiftUI `Settings` scene; opening it through the menu in the
  background did not change the front app, but check it each run (`front-before/after` evidence).
- The settings window's AX tree can come back empty (0 elements) and clicks then fail with
  `off_space_or_ax_unresolved`; invoking `Backchannel › Settings…` again restores it. Its title is
  the selected tab and was seen changing between reads, so re-read the title before each step.
  The toolbar sometimes drops out of a full read; a `query` for the tab name still finds it.
- `set_value` on a text field does not commit the SwiftUI binding: press `return` on the field
  afterwards; for `Model` and the Hub search field, `setValue("")` then `typeText` then `return` was
  needed (the `Search` button stays disabled after `set_value` alone). Clicking the search field
  itself fails with `AXPress -25206`; act on it with `type_text` and `press_key` directly.
- Download counts are formatted with the user's locale (`5.5L` under the Indian locale); match
  names, not counts.
- The `Every N minutes` stepper is absent from the tree while disabled; its presence after the
  toggle is the observable, not an `enabled` flag.
- The Gemma download is 3 GB from the Hugging Face Hub and is the user's call; never start it in a
  verification unless they asked. The same holds for any searched repo: `Download` fetches weights
  into `~/Library/Application Support/Backchannel/models/hub`.
- `Test` with an empty model name against Ollama fails with HTTP 400; that is the server's
  behavior, not the app's.
- API keys are stored only in the Keychain item `dev.maulik.backchannel` / `endpoint-api-key`; do
  not type a real key during verification and do not read the Keychain back.

### Build 39 (UX)
- Every backend shows the same first section: "Answer with" picker, "Status" row, footer text.
  Backend-specific rows follow in a "Model" or "Endpoint" section; Hub search is a disclosure
  "Add from Hugging Face" inside Model (proof: `build/verify/evidence/ux/settings-chat.png`).

### Build 46 (Settings › Meetings)
- Proved 2026-10-22 (run `issues`, `settings-meetings.png`): the tab shows Speakers, Calendar
  (toggle `calendarTitles`), Voice matching (slider `voiceThreshold`, "Show log", "Reset to 0.75"),
  Vocabulary (text area `vocabulary`) and Checkpoints. `press_key left` on the slider with a fresh
  token wrote `voiceMatchThreshold` 0.74 and Reset wrote 0.75; `set_value` on the slider does
  nothing. `set_value` on `vocabulary` wrote the `vocabulary` default. Not driven: a corrected Ask
  question, and the calendar toggle (it raises the Calendars permission prompt).
