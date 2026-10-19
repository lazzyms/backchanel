# Stats

A read-only page with counts computed from the local database: meetings, total recorded time,
sources, distinct labels, questions answered live, plus the embedding model name and the chat
backend's availability text.

## Sub-features

- Five cards: `Meetings`, `Recorded`, `Sources`, `Labels`, `Questions answered`.
- `Models` box: `Embeddings` (model name or "none installed") and `Summaries and chat`
  (backend name, or why it is unavailable).

## How to get to it (user POV)

Sidebar › Stats.

## Driving it with cua-driver

Preconditions: launched and doctor passing.

- **Go to Stats:** `verify.sh page stats`. Observable: `"window_title": "Stats"` and the tree
  contains the five card titles followed by their values; `verify.sh shot stats`.
- **Cross-check:** `verify.sh db "select count(*) from meetings"`, `"select count(*) from sources"`,
  `"select count(distinct label) from sources where label is not null"`,
  `"select count(*) from insights"`. Observable: each equals the number under the matching card.
- **Models:** the `Embeddings` value matches the directory under
  `~/Library/Application Support/Backchannel/models`, and `Summaries and chat` matches the
  backend chosen in Settings › Chat (its availability text when it cannot run).

## Gotchas

- Card values are the static text right after each card title in the tree. Proved 2026-10-19
  (`build/verify/evidence/proof-2/stats-*`): `Meetings` 5, `Recorded` 02:05, `Sources` 7, `Labels` 7,
  `Questions answered` 1, all equal to the database queries above; `Models` showed
  `EmbeddingGemma 2 · text + vision` and `Apple Intelligence` (the backend chosen at the time).
- `Recorded` is `sum(ended_at - started_at)` over ended meetings, formatted mm:ss. `started_at` and
  `ended_at` are epoch seconds stored as REAL, so `strftime('%s', ended_at)` returns NULL; use plain
  subtraction: `verify.sh db "select printf('%02d:%02d', cast(sum(ended_at-started_at) as int)/60,
  cast(sum(ended_at-started_at) as int)%60) from meetings where ended_at is not null"`.
- Counts refresh on page entry (`task` reload); after importing or deleting on another page, leave
  and re-enter Stats before comparing.
