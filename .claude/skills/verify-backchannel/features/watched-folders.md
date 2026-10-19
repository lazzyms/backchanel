# Watched folders: import automatically

Backchannel keeps the library in step with the disk while it runs, including in the background
with the window closed. Two things are watched: the folders chosen at onboarding step 3 or under
Settings › Folders (every supported file in them, recursively, new or changed, is imported and
embedded), and every source already in the library however it was added (re-imported when its file
changes). A changed file replaces its `sources` row (same `path`) and its `chunks`. Nothing is ever
removed from the library on its own.

## Sub-features

- Onboarding step 3 `Which folders should Backchannel watch?` with `Add folder…`, `Skip` / `Finish`.
- Settings › Folders: list of folders with `Remove`, `Add folder…`, `Last scan` time.
- Scan at launch, on every folder-list change, and within a couple of seconds of an FSEvents
  change under a watched folder or under the folder of an individually added source.
- `sources.modified_at` records the file's modification date at import; a file is re-imported when
  it is newer by a second or more. A file whose import failed is not retried until it changes.

## How to get to it (user POV)

Finish onboarding, or open Settings › Folders and press `Add folder…`, pick a folder, close
Settings. Drop a markdown file into that folder: a few seconds later it is on the Sources page with
a label. Edit it and save: the Sources row keeps its title and gets re-labelled; `Ask` answers from
the new text.

## Driving it with cua-driver

Preconditions: an embedding model installed; `defaults read dev.maulik.backchannel onboardingDone`
is 1 (or drive the sheet); the app NOT running yet when you seed the folder list.

- **Seed a watched folder without the open panel:** `mkdir -p /tmp/backchannel-verify-watch` and
  `defaults write dev.maulik.backchannel watchedFolders -array /tmp/backchannel-verify-watch`, then
  `verify.sh launch`. Observable: `defaults read dev.maulik.backchannel watchedFolders` lists it;
  Settings › Folders shows the row (snapshot the settings window).
- **New file:** write `/tmp/backchannel-verify-watch/lantern-notes.md` with a heading and a
  distinctive sentence. Observable: within about 10 s
  `verify.sh db "select id,title,label,modified_at from sources where path like '%backchannel-verify-watch%'"`
  returns one row with a label and a non-null `modified_at`; `verify.sh page sources` then
  `verify.sh shot watched-new` shows the row.
- **Changed file:** append a second distinctive sentence to the same file (`touch` is not enough on
  its own if the content is identical, but it does bump the date, which is what the watcher keys on).
  Observable: the row's `id` changes (replaced), `modified_at` moves forward,
  `verify.sh db "select count(*) from chunks where source_id=(select max(id) from sources)"` is at
  least 1, and `select text from sources where ...` contains the new sentence.
- **Individually added file stays watched:** `verify.sh import /tmp/backchannel-verify-other.md`,
  then edit that file. Observable: same replacement as above for that path.
- **Remove a folder:** Settings › Folders › `Remove`. Observable: `watchedFolders` no longer lists
  it; the sources it imported remain.

Cleanup: `defaults delete dev.maulik.backchannel watchedFolders`, delete
`/tmp/backchannel-verify-watch`, and remove the test rows with `Remove from library` or
`verify.sh db "delete from chunks where source_id in (select id from sources where path like '%backchannel-verify-%'); delete from sources where path like '%backchannel-verify-%'"`.

## Gotchas

- `Add folder…` opens an NSOpenPanel owned by the panel service; seed `watchedFolders` through
  `defaults` before launch instead, or drive the panel by pixels in its own window.
- Scans only run when an embedding model is installed; the watcher starts after the first
  `SourceLibrary.reload()` and again after an embedding-model switch.
- FSEvents latency is 2 s and imports take a few seconds each (extraction, embedding, labelling);
  poll the database rather than snapshotting once.
- Stored paths are resolved, so a file under `/tmp` is stored as `/private/tmp/...`; match with
  `path like '%backchannel-verify-%'`, never a `/tmp/` prefix.
- A re-import replaces the row: the source gets a new id and its label is regenerated. Poll for the
  id to change, not for `modified_at` alone.
- Proved 2026-10-19 (proof-3): onboarding folder step showed the seeded folder; launch scan imported
  the seeded file; a new file appeared as a source after about 45 s; an appended line re-imported the
  file with one chunk whose text contained the amendment. Evidence: `watched-db.txt`,
  `watched-sources-tree.txt`, `watched-sources.png`. Not yet run: remove-folder and the
  individually-added-file journeys.
