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

- Card values are the static text right after each card title in the tree (seen 2026-10-19:
  `Meetings` `5`, `Sources` `7`, …); the page itself was reached but its counts were not cross-checked
  through this skill yet.
- Counts refresh on page entry (`task` reload); after importing or deleting on another page, leave
  and re-enter Stats before comparing.
