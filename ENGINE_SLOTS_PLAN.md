# Engine slots / catalog — working plan (branch: feat/engine-slots)

Goal: Nord-Stage-style left panel — engine boxes (PIANO / ORGAN / SYNTH), a "→"
button assigning the highlighted sound to a channel, and an app-managed library
with import + categorization instead of raw folder scanning.

## Step 1 (this commit) — data layer only, no UI changes
- `SoundCatalog` in NordPianoCore: entries with id, name, version, category
  (piano/organ/synth/other), piano subcategory (grand/upright/ep), path, date.
- Import: copy into `~/Library/Application Support/nordpiano/Library/<Category>/…`
  (by-reference import comes later).
- Classification: heuristics on the sound name (no type field exists in .npno or
  .nsmp3/4); user override at import, editable later.
- Unit tests: classifier cases, catalog save/load round-trip, import of the
  existing `.nsmp4` fixture.

## Step 2 — engine-box left panel UI
Engine tabs (PIANO with GRAND/UPRIGHT/EP sub-buttons, ORGAN, SYNTH), catalog list,
"→" assign button. Old folder scanner keeps working in parallel.

## Step 3 — slot/channel refactor (the risky one)
Replace URL-keyed layers/channels with stable slot IDs (PianoPlayer key type
change, ~15 sites, render path untouched). Migrate persisted scenes/layerFX from
path keys to slot/catalog IDs. Headless unit tests for slot bookkeeping.

## Step 4 — scenes reference catalog IDs; perform page unchanged visually.
