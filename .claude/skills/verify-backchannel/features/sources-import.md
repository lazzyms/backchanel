# Sources: import documents

Sources are the user's own documents (markdown, text, PDF, images) embedded on this Mac so chat
and live answers can quote them. Importing extracts the text, chunks and embeds it, stores it in
`sources` and `chunks`, labels it with the on-device model (or the first heading), and lays it out
in the similarity graph.

## Sub-features

- Add through the `Add source` button (NSOpenPanel), by dropping files on the Dock icon, or by
  opening files with the app (what `verify.sh import` does).
- List view with title, label and rationale; Graph view (`View` picker) with edges above 0.55 cosine.
- Context menu per source: `Reveal in Finder`, `Remove from library`.
- Re-embedding of every source when the embedding model changes (Settings › Embedding).

## How to get to it (user POV)

Sidebar › Sources. Click `Add source`, pick files, wait for the "Importing …" indicator to clear;
the new source appears at the top of the list with its label.

## Driving it with cua-driver

Preconditions: launched and doctor passing; an embedding model installed (doctor's `models:` line
shows an EmbeddingGemma directory); note the current count from
`verify.sh db "select count(*) from sources"`.

- **Make a scratch document:** write `/tmp/backchannel-verify-<something>.md` with a heading and a
  few sentences on a distinctive topic (cleanup deletes files matching this name).
- **Go to Sources:** `verify.sh page sources`. Observable: it returns `"window_title": "Sources"`
  and the tree holds the sources list (or `Add source` when empty) and the `View` picker;
  `verify.sh shot sources-before`.
- **Import:** `verify.sh import /tmp/backchannel-verify-<something>.md`. Observable: within a few
  seconds the tree (`since:"latest"`) gains a row whose title is the file name without extension,
  and `verify.sh db "select id,title,label from sources order by id desc limit 1"` returns that
  title with a non-empty label; `verify.sh shot sources-after`.
- **Side effect:** `verify.sh db "select count(*) from chunks where source_id=(select max(id) from sources)"`
  is at least 1, and the source count rose by one.
- **Remove (optional):** right-click the row (`click` with `"button":"right"`) and press
  `Remove from library`. Observable: the row disappears and the `sources` count returns to the
  starting value.

## Gotchas

- `Add source` opens a system open panel owned by a panel service; drive imports through
  `verify.sh import`, which reaches the same `importFiles` path via the app delegate.
- Importing through `verify.sh import` makes macOS reopen the app, which adds a second main window
  titled like the first; harmless, and cleanup quits the process.
- Proven 2026-10-19 (run `proof-1`): row 7 `backchannel-verify-tidewater`, label written by Apple
  Intelligence, 1 chunk, visible on the Sources page.
- Proven 2026-10-21 (run `full-test-12`): row 864 `backchannel-verify-harbor`, 1 chunk, top of
  the list; the Graph view with 857 sources is unreadable and its AX tree exceeds 2000 nodes, so
  read the list with `query` or `max_depth:2`. The View picker exposes no AX children.
- Without an embedding model the import fails with "no model installed" shown in an alert; that is
  a skipped journey, not a pass.
- Labels come from Apple Intelligence; when it is unavailable the label is the first heading and
  the rationale says so. Both are valid.
- Image sources also get a vision chunk when the chosen model has vision; PDFs rely on PDFKit text
  extraction and scanned PDFs yield little text.
