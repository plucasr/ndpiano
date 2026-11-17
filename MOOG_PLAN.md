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
- [ ] New target `NordMoog` in Package.swift (+ `Sources/NordMoog/`, + `NordMoogTests`).
- [ ] `MoogVoice`: 2 detunable saw + 1 pulse oscillator → mixer → ladder filter
      (reuse/port the ladder model from NordPianoEngine/SynthDSP.swift) → ADSR
      amp envelope; mono with glide/legato.
- [ ] `MoogPatch`: Codable parameter set (osc ranges/waves/detune, mixer levels,
      cutoff/resonance/env-amount/keytrack, filter+amp ADSR, glide time).
- [ ] Render tests: note renders audio, glide sweeps, filter envelope moves cutoff.
Status: NOT STARTED

## Phase 2 — Engine integration
- [ ] PianoPlayer hosts a moog voice as a layer type alongside sample layers;
      notes/MIDI (wheel, aftertouch, pedal) routed to it; playable from keyboard.
Status: NOT STARTED

## Phase 3 — Presets + catalog category
- [ ] Moog preset type (wraps MoogPatch; same JSON story as FXPreset).
- [ ] Catalog category `.moog` with preset-backed entries; mixer browsing and
      ‹ › stepping works for moog sounds.
Status: NOT STARTED

## Phase 4 — Moog FX view
- [ ] ChannelFXPanel shows the moog layout (sections above) for moog channels.
Status: NOT STARTED

## Phase 5 — Starter presets
- [ ] 3 lead presets tuned by ear (compare against openmini / CA-72 VST).
Status: NOT STARTED

## Working state for handoff
- Branch: main. All prior work committed/pushed before Phase 1 start.
- Build: `swift build`; tests: `swift test`. App deploy: `./build-app.sh`.
- Related prior work: FX preset import/export (Sources/NordPianoApp/FXPreset.swift,
  buttons in ChannelFXPanel header), example preset presets/lead-mono.json.
