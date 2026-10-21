# Ask: chat over sources and meetings

The Ask page answers questions from the user's sources and finished meeting transcripts. Retrieval is
hybrid (embedding cosine plus BM25, fused by rank) over source chunks and `meeting_chunks`; the
chosen chat backend (Settings › Chat) writes the answer and cites passage titles. A scope popup
limits a question to one meeting.

## Sub-features

- Free-form question field, Return to send, answers appended as a conversation.
- `Scope` popup: `All sources and meetings` (default) or a single meeting.
- `New chat` clears the conversation; the model is told today's date with each question.
- Works keyword-only when no embedding model is installed.

## How to get to it (user POV)

Sidebar › Ask. Type into "Ask Backchannel about your meetings", press Return, read the answer.

## Driving it with cua-driver

Preconditions: launched and doctor passing; at least one source or finished meeting indexed
(`verify.sh db "select count(*) from chunks"` and `"select count(*) from meeting_chunks"` not both 0);
the backend in Settings › Chat is available (`defaults read dev.maulik.backchannel chatBackend`;
Stats shows the availability text).

- **Go to Ask:** `verify.sh page ask`. Observable: `"window_title": "Ask"` and the tree contains the
  text field with placeholder `Ask Backchannel about your meetings`; `verify.sh shot ask-before`.
- **Ask about something you know is indexed:** `type_text` into the field token with a question
  whose answer is in a known source (for example the scratch document from sources-import), then
  `press_key` `return` on the same token. Observable: a "thinking" state, then an assistant message
  appears in the tree (`since:"latest"` shows added static text) mentioning the source title or the
  fact; `verify.sh shot ask-answer`.
- **Scope to a meeting:** the `Scope` control is a SwiftUI `Menu` (AXMenuButton), so `set_value`
  is a no-op: `click` it, then `click` the `AXMenuItem` whose name is the meeting title (match on
  the time part, e.g. `/4:42/`; the title contains a narrow no-break space U+202F before `PM`).
  Choosing a scope starts a new conversation. Ask about that meeting. Observable: the answer draws on
  that transcript. The citation line lists only the passages the answer cites as `[n]`, so it can
  name another meeting when the answer cites one; every retrieved title when it cites none.
- **New chat:** press `New chat`. Observable: the messages disappear and the button is disabled.

## Gotchas

- Chat is not persisted: there is no database side effect to check; the proof is the rendered answer
  plus the backend named in the evidence.
- With Apple Intelligence the first answer can take 10–20 s; the endpoint backend fails fast with an
  HTTP error line when the server is down. Gemma needs the 3 GB download first.
- The answer text is model-dependent; assert that the known source title or fact appears, not an
  exact sentence.
- Proved 2026-10-19 with Apple Intelligence (`build/verify/evidence/proof-2/ask-*`): `Thinking…`
  then an answer naming the Tidewater source; scoped to the 4:42 PM meeting the answer quoted that
  transcript; `New chat` emptied the messages and reset the scope to `All sources and meetings`.
  The typing recipe is the `verify.sh run` example in SKILL.md. Proved again 2026-10-20 (proof-6,
  `ask-before.png`, `ask-answer.png`, `ask-answer.json`) with Apple Intelligence: the answer gave
  the pour temperature and curing time from `candle-wax-guide` with a `[1]` citation line. The
  defaults had `chatBackend` set to `endpoint` with Ollama down and no model name, which fails fast;
  the run switched it to `apple` with `defaults write dev.maulik.backchannel chatBackend apple`.
- Proven 2026-10-21 (run `fix-all`, build 30, `ask-citation-build30.txt`, `ask-citation-build30.png`):
  the answer `… according to [1] and [2].` carried the footer `candle-wax-guide · Meeting 20 Oct
  2026 at 12:01 PM · 20 Oct 2026` and nothing else, although retrieval returns up to 8 passages.
- `waitFor({text})` also matches the question the harness just typed; poll the tree for a fact that
  only the answer contains instead.
- `waitFor` accepts at most `timeout_ms: 10000`; loop it for the 10–20 s Apple Intelligence answer.
- Typing with a background `type_text` relies on AX insertion; if the field stays empty, re-read the
  tree and retry with the token of the field, not of the window.
