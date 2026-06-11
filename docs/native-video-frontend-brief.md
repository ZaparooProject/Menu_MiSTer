# Frontend implementation brief: native CRT video v2 (zaparoo-launcher)

**Audience:** the zaparoo-launcher team / an implementation agent with no prior
context. This document is self-contained; `docs/native-video-plan.md` (same
repo) has the full background and rationale if you want it.
**Counterpart:** Menu_MiSTer fork, branch `fix/native-video-centering` — the
FPGA side of everything below is implemented, simulated, and pushed. The
launcher work in this brief is the only remaining piece.
**Existing code this modifies:** `src/app/native_video_writer.cpp` and the
`--crt` startup path in zaparoo-launcher (see also its `docs/native-core-poc.md`).

---

## 1. What changed and why you're doing this

The menu core no longer outputs a 320x240 picture with hand-tuned porches, and
it no longer has any OSD video options. It now generates broadcast-standard
15 kHz timing in three modes, and **everything the launcher used to rely on
the OSD for (CRT mode on/off, H/V centering) now travels through the DDR
control block you already write**. Key consequences for the app:

- The framebuffer is now **352x240** (not 320x240). 352 px fills a standard
  NTSC/PAL active line edge-to-edge; the old 320 was ~10% too narrow on every
  correctly calibrated CRT.
- The picture now *overscans* like broadcast TV: the outer few percent of the
  framebuffer is cropped on most sets. The UI must adopt safe-area rules
  (section 5) — this is as much a part of the fix as the FPGA work.
- There is no "CRT mode" toggle anywhere. **Publishing frames IS the mode
  switch**: the core shows its noise pattern until your control word goes
  live and reverts when you zero it.
- Two new modes exist when you're ready for them: **720x480i60** (mode 1) and
  **352x288p50 PAL** (mode 2). The core side is done; you opt in per-frame
  via the mode field.

Backward compatibility is handled on the core side: an old launcher writing
the legacy 320x240 layout still displays (centered with 16-px black side
bars), and your existing fb-geometry validation already self-disables the
writer against an old core. Ship order doesn't matter.

## 2. DDR contract v2 (normative)

Physical base `0x3A000000`, mmap **0x300000** (3 MB, up from 640 KB).

| Offset | Contents |
|---|---|
| `+0x0` | **word0**: `(frame_counter << 2) \| active_buffer`. Bit 1 reserved, write 0. `0` means "writer stopped". |
| `+0x4` | **word1**: `[31:16]` magic `0x5A50` ("ZP"); `[15:8]` h_offset, signed int8, pixels, + = right; `[7:4]` v_offset, signed 4-bit, lines, + = down; `[3:0]` mode |
| `+0x1000` | buffer 0 |
| `+0x180000` | buffer 1 |

Modes: `0` = 352x240 @ 60p (NTSC, default), `1` = 720x480 @ 60i,
`2` = 352x288 @ 50p (PAL). Stride is always tight (`width * 4` bytes).
Pixel format is unchanged: memcpy linuxfb BGRX rows as-is; the core swaps
bytes in RTL.

Per-mode framebuffer numbers:

| Mode | fb size | stride | frame bytes |
|---|---|---|---|
| 0 | 352x240 | 1408 | 0x52800 (337 920) |
| 2 | 352x288 | 1408 | 0x63000 (405 504) |
| 1 | 720x480 | 2880 | 0x151800 (1 382 400) |

Protocol rules:

1. **Init:** write word1 (magic + mode + saved offsets) **before** the first
   word0 publish. The core reads both words in one atomic 64-bit beat once
   per vblank, so word1-then-word0 ordering guarantees the first frame is
   interpreted correctly.
2. **Publish:** render into the inactive buffer, then write word0 once with
   the incremented counter and that buffer's index (single 32-bit store —
   this is the atomic commit). Counter is 30 bits, start at 1.
3. **Mode/offset change at runtime:** update word1 first, then bump word0.
   The core latches mode and offsets at the field boundary; modes 0↔1 keep
   the same line rate (instant re-lock), 0/1↔2 is a 50↔60 Hz retune (the CRT
   takes a moment, like real hardware).
4. **Stop:** zero word0 (zero word1 too for tidiness). The core reverts to
   its noise pattern within one frame. This is also your crash-recovery
   story — if the launcher dies and the words go stale, the core keeps
   scanning the last frame; only a zeroed word0 releases it, so keep the
   existing stop-handler behavior.
5. **Offsets:** the core honors **−8…+8 px** horizontal, **−8…+2 lines**
   vertical, and clamps anything outside (a garbage word1 degrades to a
   saturated shift, never broken sync). Don't rely on the clamp — keep the
   calibration UI within those ranges.
6. **480i is rendered progressive:** publish one normal 720x480 frame; the
   core extracts fields itself (reads source line `2*line + field`). No
   field splitting, no half-frame timing on the ARM side.

## 3. Task 1 — Phase A (required): 352x240 writer + safe-area UI

This is the must-ship piece; modes 1 and 2 are follow-ups.

1. `--crt` startup sets fb0 to **352x240 32bpp** (the `vmode -r 352 240
   rgb32` equivalent of the current 320x240 setup). Update the fb-geometry
   validation to expect 352x240.
2. Update writer constants: width 352, stride 1408, frame size 0x52800,
   buffers at `+0x1000` / `+0x180000`, mmap 0x300000.
3. Write word1 on init: magic `0x5A50`, mode 0, offsets from launcher config
   (default 0/0). Clear both words on stop.
4. UI safe-area pass (section 5).
5. Calibration screen (section 6).

Acceptance: on hardware with the new core, the launcher UI fills a CRT
edge-to-edge; killing the launcher returns the noise pattern; a capture
device reports 15.734 kHz / 240p.

## 4. Tasks 2 & 3 — PAL and 480i (when ready)

**PAL (mode 2):** add a "video standard: NTSC / PAL" user setting. PAL
renders **352x288** and publishes mode 2. Note most PAL sets accept 60 Hz
RGB over SCART ("PAL-60"), so mode 0 remains a fine default in PAL regions;
mode 2 is for strict-50 Hz sets and correct-speed feel.

**480i (mode 1):** add a 720x480 rendering path and (optionally) per-screen
mode selection — e.g. main UI in 240p, text-heavy screens in 480i.
Flicker discipline is mandatory (section 5, rule 4).

## 5. UI rendering rules (apply to every mode)

These are not suggestions; geometry alone doesn't fix "every CRT crops
differently":

1. **Render full-bleed.** Background art/color must reach all four edges.
   The outer few percent will be cropped on most sets and visible on a few —
   both must look intentional.
2. **Safe areas** (SMPTE SD practice):
   - *Action safe* (all interactive/meaningful content): central **90%** —
     ~317x216 of 352x240, ~317x259 of 352x288, ~648x432 of 720x480.
   - *Title safe* (text that must be readable): central **80%** —
     ~282x192 / ~282x230 / ~576x384.
3. **Pixel aspect ratio is 10:11** (pixels ~9% narrower than square) in all
   three modes. Ignorable for boxes-and-text; correct for logos/art that
   must not look squished (a true circle needs ~10% more width in pixels).
4. **480i flicker discipline:** every scanline repaints 30x/second, so 1-px
   horizontal lines and fine text shimmer. Use ≥2 px horizontal strokes,
   avoid hard 1-px horizontal edges, or apply a mild vertical blur (the
   standard console-era 480i dashboard trick). Existing CRT typography rules
   in `native-core-poc.md` (integer snapping, bitmap fonts) stay in force.

## 6. Calibration screen

The launcher now owns centering (the OSD options are gone):

- Draw a border test pattern (240p-test-suite style: 1-px frame at the
  extreme edge, rectangles at the 90% and 80% safe areas, cross-hatch).
- Arrow keys nudge h_offset (−8…+8, 1-px steps) and v_offset (−8…+2),
  publishing word1 live so the user sees the picture move in real time.
- Persist the values in launcher config; load them at init. Defaults are
  zero — the standard timing is the centering mechanism, trims only
  compensate for miscentered sets.

## 7. Verification checklist (frontend-visible items)

- Fill/centering on **2–3 different CRTs** plus a capture device (should
  report 15.734 kHz exactly; 480i should be detected as 480i, not 240p).
- Writer-stop: kill the launcher → noise pattern returns.
- Trim screen: live nudge both axes; values survive a restart; out-of-range
  values (if forced) shift-and-saturate without disturbing sync.
- Compat matrix: old launcher + new core → centered 320x240 with side bars;
  new launcher + old core → writer self-disables via fb-geometry validation,
  core shows noise (obvious, not subtle, breakage).
- 480i: fine horizontal lines should shimmer, not stack (no line pairing).
- HDMI output still locks in every mode (the core's ascal path handles it;
  just confirm).

## 8. Reference

- FPGA-side spec and rationale: `docs/native-video-plan.md` (Menu_MiSTer).
- RTL that consumes this contract: `rtl/native_video_reader.sv` (the word1
  parse and buffer addresses are the source of truth, with simulation
  coverage in `tb/native_video_reader_tb.sv`).
- Current writer: `src/app/native_video_writer.cpp` (zaparoo-launcher).
- Why the scaler is bypassed: `docs/native-core-poc.md` (zaparoo-launcher).
