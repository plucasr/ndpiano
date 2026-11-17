# Moog Voice — Implementation Plan & Status

Add a Minimoog-style mono lead voice to NordPiano, in phases small enough to
hand off between agents. Reference implementation (for structure and parameter
ranges only, we write Swift): https://github.com/G4m4/openmini (GPLv3, read-only
inspiration — do not copy code; the project is MIT-licensed).

Design decisions (agreed with user):
- New SwiftPM target `NordMoog` (sibling of NordPianoEngine): all Moog DSP and
  preset types, imports nothing Nord. Engine depends on it; Nord sampler paths
  untouched.
- New catalog category `.moog` next to `.synth`; moog "sounds" are preset
  entries (JSON, extends the FXPreset mechanism) — no sample files needed.
- FX panel swaps its synth rows for a moog view when the channel is a moog
  sound — a wide popover (NOT a fullscreen modal), laid out left-to-right like
  the Minimoog front panel: OSCILLATOR BANK | MIXER | FILTER | CONTOURS | OUTPUT/GLIDE.

## Phase 1 — NordMoog target: minimal voice (engine only)
- [x] New target `NordMoog` in Package.swift (+ `Sources/NordMoog/`, + `NordMoogTests`).
- [x] `MoogVoice`: 3 PolyBLEP oscillators (saw/pulse, osc2/3 detune in cents,
      osc3 octave) → mixer (levels + white noise) → 4-pole ladder w/ feedback
      resonance & tanh overload → filter + amp ADSR contours; mono, last-note
      priority, legato, exponential glide. `Sources/NordMoog/MoogVoice.swift`.
- [x] `MoogPatch`: Codable/Sendable parameter set in physical units
      (`Sources/NordMoog/MoogPatch.swift`), `MoogPatch.lead` starter.
- [x] Render tests: renders audio, decays to silence, glide sweeps & settles,
      no-glide snaps, filter env opens cutoff, patch Codable round-trip.
Status: DONE (6/6 tests green)

## Phase 2 — Engine integration
- [x] PianoPlayer hosts a moog voice as a layer type alongside sample layers
      (`LayerSource.moog`, `addMoogLayer(id:gain:patch:)`, `setMoogPatch`,
      `moogPatch`); noteOn/noteOff routed with zone/mute honored; keyboard
      sounding markers included. The channel FX strip (EQ/filter/comp/drive/
      delay/reverb) and chorus/pan apply downstream of the moog render.
Status: DONE (build green; engine commit 675fdd4). Not yet wired to UI —
Phase 3 makes moog sounds loadable from the catalog/mixer.
Known pre-existing flake: LayerFXRenderTests.testArpStopsOnKeyUpUnlessHold
(wall-clock arp timer; fails intermittently on HEAD too, unrelated).

## Phase 3 — Presets + catalog category
- [x] `MoogPreset` in NordMoog: `.moog` file = named MoogPatch JSON (wrapped or
      bare, missing keys fall back to patch defaults).
- [x] Catalog category `.moog`: `.moog` extension imports like any sound
      (identity from the file's "name" key, copied into Library/Moog).
- [x] MOOG engine panel in the top taxonomy (ContentView); `.moog` in the
      import picker; PlayerModel loads moog entries via `addMoogLayer`.
- [x] Starter files: presets/Mini Lead.moog, presets/Pulse Bass.moog (import
      them via the app's Import…).
Status: DONE (25 tests green: catalog identity/import + preset decode).
Moog channels currently show the standard FX panel — the moog-specific view
is Phase 4.

## Phase 4 — Moog FX view
- [x] ChannelFXPanel swaps the synth rows for a moog layout on moog channels
      (keeps the shared tone/insert rows): OSC 1/2/3 (wave chip, level,
      detune, octave) + MIXER (noise, pulse width) | FILTER (cutoff, emphasis,
      env amt, kb track) + FILTER CONTOUR + AMP CONTOUR | OUTPUT (glide, volume).
- [x] Patch state in PlayerModel: per-sound (path-keyed), UserDefaults-backed,
      applied on load/scene recall; scenes capture moog patches too.
- [x] Header import/export buttons branch to .moog presets for moog channels.
Status: DONE (build green). Layout is the Minimoog front-panel order inside
the existing popover — no fullscreen modal.

## Phase 5 — Starter presets
- [ ] 3 lead presets tuned by ear (compare against openmini / CA-72 VST).
Status: NOT STARTED

## Working state for handoff
- Branch: main. All prior work committed/pushed before Phase 1 start.
- Build: `swift build`; tests: `swift test`. App deploy: `./build-app.sh`.
- Related prior work: FX preset import/export (Sources/NordPianoApp/FXPreset.swift,
  buttons in ChannelFXPanel header), example preset presets/lead-mono.json.
