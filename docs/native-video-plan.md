# Native CRT video: findings, recommendations, and implementation plan

**Status:** proposal — agreed direction, not yet implemented
**Scope:** this core (Menu_MiSTer fork) + `zaparoo-launcher` (the ARM-side writer)
**Date:** 2026-06-11

This document explains why the native video output currently only looks right
on the CRT it was calibrated on, what a "standard" 15 kHz signal actually is,
and a phased plan to fix geometry (240p), add PAL (288p50), and add a
high-resolution interlaced mode (480i60).

---

## 1. Current architecture

The fork replaces the Menu core's noise-pattern video with:

| Piece | File | Role |
|---|---|---|
| Timing generator | `rtl/native_video_timing.sv` | Produces hsync/vsync/blanking/DE at 15 kHz from a 27.027 MHz clock ÷ 4 |
| DDR reader | `rtl/native_video_reader.sv` | Polls a control word in DDR3 each vblank, streams the active framebuffer line-by-line through a clock-crossing FIFO |
| Wrapper | `rtl/native_video_top.sv` | Wires the two together |
| Mode mux | `menu.sv` | `status[9]` selects noise pattern vs. framebuffer; OSD H/V offset trims |

ARM side (`zaparoo-launcher/src/app/native_video_writer.cpp`): Qt renders the
UI to `/dev/fb0` (320x240 RGBX8888, set up via `vmode`), and a copy thread
memcpys each frame into one of two DDR buffers, then publishes it:

```
0x3A000000  control word: (frame_counter << 2) | active_buffer
0x3A000100  buffer 0: 320x240 RGBX8888, tight stride (1280 B)
0x3A04B100  buffer 1
mmap region: 0xA0000 (640 KB)
```

The FPGA reads the control word at the start of each vblank; when the counter
changes it switches to the published buffer (double buffering, no tearing).
Byte order is swapped in RTL (`output_pixel`) so the app can memcpy linuxfb
BGRX rows without repacking.

This path deliberately bypasses MiSTer's scaler (`docs/native-core-poc.md` in
zaparoo-launcher): analog output comes straight from the core's `VGA_*`
signals. The framework (`sys/vga_out.sv`) only applies gamma/csync — it does
not retime anything — so **whatever timing this core generates is exactly what
the CRT receives.** The HDMI side is unaffected; ascal rescales any input
timing.

---

## 2. Background: how a CRT decides where and how big the picture is

A CRT has no concept of pixels or resolutions. Each scanline of the signal is:

```
 sync pulse → back porch → active video → front porch → next sync
 (4.7 µs)     (delay)       (the picture)   (delay)
```

The sync pulse is the only positional reference the TV has. The set's
deflection circuitry is factory-adjusted so that the **broadcast-standard**
active region — about **52.7 µs** of the 63.6 µs NTSC line — slightly
*overfills* the visible tube. That deliberate overfill is **overscan**:
typically 3–8% of the picture is cropped at each edge, varying from set to set
and drifting with age. The same applies vertically, measured in scanlines.

Consequences:

- If your active video is **shorter than 52.7 µs**, the picture is narrower
  than the tube — black side borders that no porch adjustment can remove.
- If your active video starts **later than ~9.4 µs after the sync edge**
  (4.7 µs sync + 4.7 µs back porch), the picture sits right of center.
- Because overscan varies per set, anything important drawn near the edges
  will be cut off on *some* sets no matter what you do.

Broadcasters solved the per-set variation problem decades ago: **fill the full
standard active area, and keep important content inside "safe areas"**
(SMPTE SD guidelines: *action safe* = the central 90%, *title safe* = the
central 80%). The picture bleeds past every tube's edges; the content never
does. This is the "safe values" approach this plan adopts.

For calibration intuition: real consoles (NES/SNES/Genesis) output ~47.7 µs of
active video — about 10% narrower than broadcast — which is why console games
show small side borders on a well-calibrated set. GroovyMAME/Switchres, the
de-facto reference for driving CRTs from emulators, instead generates
modelines that stretch the emulated image across the full 52.7 µs. We follow
the Switchres model.

---

## 3. Findings: the current signal vs. the standard

Measured from HEAD of `fix/native-video-centering`
(pixel clock = 27.027 MHz ÷ 4 = 6.757 MHz, H total 429 px, V total 262 lines):

| Parameter | Current (HEAD) | NTSC standard | Verdict |
|---|---|---|---|
| Line rate | **15 750 Hz** | 15 734.26 Hz | Wrong PLL: 27.027 MHz is the 1.001 NTSC factor applied *backwards*. Plain **27.000 MHz** with the same ÷4 and 429-px line gives exactly 15 734.27 Hz (27 000 000 / 1716). The "15.734 kHz" comments in the code are aspirational, not true. |
| Field rate | 60.12 Hz | 59.94–60.05 | Follows from the PLL error. Harmless on CRTs but off-spec. |
| H active | 320 px = **47.4 µs** | **52.66 µs** | ~10% too narrow. This is the "too small" complaint, and it is unfixable by porch tuning. |
| H sync→active delay | 83 px = 12.3 µs | 9.4 µs | For a 47.4 µs-wide image, *centered* would be 12.0 µs — so HEAD is now roughly centered. The original Codex porches (FP/sync/BP = 14/32/63) gave **14.1 µs ≈ 5% right shift** — the "offset right on everyone else's CRT" complaint. |
| V geometry | 240 active; vsync at line 248 (FP 8) | ~241 visible; vsync at line 243 (FP 3) | Picture sits ~5 lines high of standard. |

History of the H porch split (FP/sync/BP in pixels):

- `061a888` (Codex original): **14/32/63** — calibrated to one specific CRT,
  ~5% right of standard for everyone else.
- `95a5153`: 38/32/39 — overcorrected ~9 px left of centered.
- `3a19e6d` (HEAD): **26/32/51** — within ~2 px of centered *for a 47.4 µs
  image*. Centering is now fine; width is not.

These commits also widened the OSD H offset range to ±16 px in 2-px steps to
chase per-CRT centering. That widening is deliberately reverted by this plan:
once the geometry is standard, the trim is a nicety, and the supported range
goes back to **±8 px in 1-px steps** (carried in the control word, not the
OSD — see section 5.1).

**Key insight:** the OSD H/V offset options treat the symptom. A 47.4 µs
picture can never fill a tube calibrated for 52.7 µs, and any porch split
that's perfect for one CRT is wrong on the next. The fix is broadcast
geometry (section 4) plus safe-area UI rules (section 6).

### Other defects found during review

1. **PAL is silently dropped.** `wire PAL = status[4]` in `menu.sv` is now
   dead; the old noise generator honored it. 50 Hz-only CRTs get an NTSC
   signal. (Addressed by Phase B below.)
2. **`forced_scandoubler` is ignored.** Users whose VGA output feeds a
   31 kHz-only monitor previously got a doubled signal from the menu core;
   now they must set `vga_scaler=1` in MiSTer.ini. Acceptable for a
   CRT-targeted fork, but it should be stated in the README.
3. **Reader never falls back when the writer stops.** `stopNativeVideoWriter()`
   zeroes the control word, but `frame_ready` stays latched and the core scans
   the stale (black) buffer forever instead of reverting to the noise pattern.
   `ctrl == 0` should clear `frame_ready`.
4. **FIFO preload is at its safe maximum already.** The reader preloads 2
   lines during vblank then fetches one line per scanline. Note for Phase A:
   at the new 176-word line length, preloading a 3rd line would overflow the
   512-word FIFO mid-frame (peak occupancy ~368 words with 2-line preload;
   3-line preload peaks above 512 and `overflow_checking` silently drops
   writes). Keep 2 lines, or deepen the FIFO to 1024 if more margin is wanted.
5. Reader timeout paths (`ST_WAIT_CTRL`/`ST_WAIT_LINE` → `ST_IDLE`) also leave
   `frame_ready` stale; same fix as (3).

---

## 4. Target timings

Everything derives from one clock change: CLK_VIDEO goes from 27.027027 MHz
to **27.000000 MHz** — the universal SD video clock (it is exactly 1716 ×
NTSC line rate and 1728 × PAL line rate).

> **Implementation note (found at fit time):** 27.000 MHz cannot come from
> the existing PLL. All outputs of one PLL divide a shared VCO, and
> lcm(100 MHz clk_sys, 27 MHz) = 2700 MHz exceeds the Cyclone V's
> 600–1600 MHz VCO range — 27.027027 (1000 MHz / 37) is precisely the
> closest sharable frequency, which is why stock MiSTer uses it. The fix is
> a dedicated video PLL (`rtl/pll_video.v`, VCO 1350 MHz = 50 × 27, C = 50)
> whose sole output drives CLK_VIDEO; `pll_0002.v` stays stock.

| Mode | ce_pix | H total | H active / FP / sync / BP (px) | V total | V active / FP / sync / BP (lines) | Line rate | Refresh |
|---|---|---|---|---|---|---|---|
| **0: 240p60** (default) | 27 ÷ 4 = 6.75 MHz | 429 | **352** / 12 / 32 / 33 | 262 | **240** / 3 / 3 / 16 | 15 734.27 Hz | 60.05 Hz |
| **1: 480i60** | 27 ÷ 2 = 13.5 MHz | 858 | **720** / 19 / 62 / 57 | 525 (262+263 fields) | 240 / 4 / 3 / 15–16 per field | 15 734.27 Hz | 59.94 Hz interlaced |
| **2: 288p50** (PAL) | 6.75 MHz | 432 | **352** / 11 / 32 / 37 | 312 | **288** / 3 / 3 / 18 | 15 625.00 Hz | 50.08 Hz |

Where these numbers come from:

- **Switchres monitor presets** (`monitor.cpp`, the GroovyMAME engine):
  - `ntsc`: 15 734.26 Hz; H porches 1.5 / 4.7 / 4.7 µs; V 3 / 3 / 15 lines.
  - `pal`: 15 625 Hz; H porches 1.5 / 4.7 / 5.8 µs.
- **CEA-861 720x480i**: H total 858 @ 13.5 MHz, FP 19 / sync 62 / BP 57.
- **SMPTE 170M**: 63.556 µs line, 10.9 µs blanking, 52.66 µs active.

The H porch pixel values above are the preset µs values converted at the pixel
clock, nudged by ≤ 0.3 µs so the active width sits centered in the standard
window. Sanity checks: 352+12+32+33 = 429; 352+11+32+37 = 432; 720+19+62+57 = 858.

Why these active sizes:

- **352 px @ 6.75 MHz = 52.15 µs ≈ 99% of NTSC standard active width** (and
  ~100% of PAL's 52 µs). The picture fills every screen edge-to-edge with
  normal overscan crop. 352x240 / 352x288 are standard SIF resolutions;
  pixel aspect ratio is the BT.601-classic **10:11** (~9% narrower than
  square — fine to ignore for a UI, but stated for completeness).
- **PAL gets 288 active lines, not 240.** PAL tubes show ~288 lines; a
  240-line picture at 50 Hz would be visibly undersized vertically. The app
  renders 352x288 in PAL mode.
- **480i uses the CEA-861 numbers verbatim** — the most universally accepted
  SD interlaced timing in existence.

### 480i specifics

Interlacing is *not* just doubling the line count. The 525-line frame is two
fields of 262 and 263 lines, and the **odd field's vsync must be asserted half
a scanline (429 ce_pix clocks at 13.5 MHz) later** than the even field's.
That half-line offset is what makes the CRT draw the second field's lines
*between* the first field's — without it both fields land on the same
scanlines ("line pairing") and you get 240p with combing.

MiSTer framework support is already there:

- `VGA_F1` (field number) is a standard core output — currently hardwired to
  `0` in `menu.sv`. It must toggle per field in 480i.
- `sys/sys_top.v` wires `VGA_F1` → ascal's `i_fl`; ascal auto-detects
  interlace and deinterlaces for HDMI, so HDMI users keep working.
- The analog path passes core sync through untouched; csync generation in
  `sys_top.v` handles interlaced cores today (PSX, Saturn, Genesis all output
  real 480i this way).
- Reference implementation for the half-line trick:
  `MiSTer-devel/PSX_MiSTer rtl/gpu_videoout_async.vhd` (search "half line
  later").

---

## 5. DDR contract v2

Designed now so Phases A–C don't break each other or deployed frontends.
Versioned via a magic value; layout sized for the largest mode:

```
0x3A000000  word0: (frame_counter << 2) | active_buffer        (unchanged)
0x3A000004  word1: [31:16] magic 0x5A50 ("ZP")
                   [15:8]  h_offset, signed, pixels  (+ = right; core honors −8…+8)
                   [7:4]   v_offset, signed, lines   (+ = down;  core honors −8…+2)
                   [3:0]   mode: 0 = 352x240 @ 60p (NTSC)
                                 1 = 720x480 @ 60i
                                 2 = 352x288 @ 50p (PAL)
0x3A001000  buffer 0  (page-aligned; sized for max mode: 720*480*4 = 1.35 MB)
0x3A180000  buffer 1
mmap region: 0x300000 (3 MB)
stride: always tight, width * 4 bytes
```

Design points:

- The reader already fetches the control word as one 64-bit DDR beat and
  discards the top half — **word1 costs nothing extra to read**. One read per
  vblank picks up frame counter, buffer index, mode, and offset trims
  atomically.
- **The control block replaces every OSD video option** (see section 5.1):
  there is no CRT-mode toggle and no OSD offset menu. A valid magic plus a
  changing frame counter *is* the mode signal — the core shows the noise
  pattern until the launcher publishes frames and reverts when word0 clears.
  Offsets come from word1 and are owned by a calibration screen in the
  launcher.
- Offsets and mode cross from the DDR clock domain into the video timing
  domain as quasi-static values: two-flop synchronize and latch them at the
  frame boundary (`new_frame`) so a mid-frame update can't corrupt sync. RTL
  clamps offsets to the porch budget of the active mode (effective FP/BP
  never < 2 px / 1 line), so a buggy or out-of-range value degrades to a
  saturated shift, never a broken signal.
- **Legacy compatibility:** if word1 has no magic, the core treats the region
  as today's layout (320x240 buffers at +0x100 / +0x4B100) and scans it
  centered in the 352-px active area with black side bars (16 px each side).
  An already-deployed launcher keeps working against the new core; the new
  launcher's fb-geometry validation already self-disables cleanly against an
  old core. No flag day.
- Mode changes apply at frame boundaries. Modes 0↔1 keep the same line rate,
  so the CRT re-locks almost instantly; switching to/from PAL is a bigger
  retune (50↔60 Hz) and takes a moment, as on real hardware.
- Address-space safety: MiSTer reserves 0x20000000+ of DDR for the FPGA side;
  0x30000000–0x3FFFFFFF is core-owned and the menu core uses none of it
  elsewhere. The 3 MB region at 0x3A000000 conflicts with nothing (the
  framework scaler framebuffers live at 0x20000000+).
- In 480i the FPGA reads source line `vcount*2 + field`, so the app renders
  one normal progressive 720x480 frame — no field-splitting on the ARM side.

DDR bandwidth is a non-issue: worst case (480i) is 720×480×4 B × 60 ≈ 80 MB/s
of sequential bursts against a multi-GB/s DDR3 port that nothing else in the
menu core touches.

### 5.1 Removing the OSD video options entirely

Question raised during review: can the "Video" section / second OSD page go
away, with the CRT mode toggle and the H/V offset trims moving into the ARM
launcher? **Yes — and it simplifies the core.** Every OSD video option maps
onto something the v2 control block already carries:

| OSD option today | Replacement |
|---|---|
| CRT/native mode toggle (`status[9]`) | Implicit: valid magic + advancing frame counter in the control block ⇒ native scanout; word0 = 0 or stale ⇒ noise pattern. The launcher "turns on CRT mode" simply by publishing frames. `status[9]` and its CONF_STR entry are deleted. |
| H Offset list (`status[13:10]`) | `word1[15:8]` signed pixel trim (−8…+8, 1-px steps), set from a calibration screen in the launcher (arrow keys, live preview), persisted in the launcher's own config. |
| V Offset list (`status[17:14]`) | `word1[7:4]` signed line trim (−8…+2), same screen. |

`CONF_STR` shrinks back to the stock menu core entry
(`"MENU;UART31250,MIDI;-;V,v"` + build date): one page, no Video section. The
core stops using `status[]` for video entirely.

Why this is the right direction, beyond decluttering:

- **One contract, one owner.** Mode and trims live next to the frames they
  describe, set by the same process that renders them, read atomically in the
  same 64-bit beat. No second control path through hps_io status bits.
- **Better calibration UX.** The launcher can draw a border test pattern
  *while* the user nudges offsets — the OSD lists couldn't show the effect on
  a full-bleed image, and 16-entry enum lists are a clumsy way to express
  "nudge left a bit". Per-device persistence lives with the rest of the
  launcher's config instead of MiSTer's core-config blob.
- **Fewer moving parts in RTL.** The offset inputs move from
  `status`-decoding in `menu.sv` to the reader's already-synchronized control
  parse; the OSD enum↔signed-value mapping tricks disappear.

Trade-offs / notes:

- A user running the **legacy (pre-v2) launcher** gets no trims (word1 absent
  → offsets = 0). Acceptable: the new default timing is standard, trims are a
  nicety, and legacy mode is compat-only.
- If the framebuffer path is off (noise pattern), there is nothing to
  calibrate against — also fine, calibration belongs in the app.
- The MiSTer OSD overlay itself (main menu, file browser) is untouched; this
  removes only the core's *option entries*, not the OSD.

**Rejected alternative:** having the ARM app poke core status bits through a
patched Main_MiSTer (the Zaparoo_MiSTer fork could add a command for it).
Works, but spreads the video contract across three codebases and a Main fork
that must track upstream, for zero functional gain over the DDR words the
core already reads every vblank.

---

## 6. App-side rules (zaparoo-launcher)

These are as much a part of the fix as the RTL — geometry alone doesn't solve
"every CRT crops differently":

1. **Render full-bleed.** Background art/color must reach all four edges of
   the framebuffer; the outer few percent will be cropped on most sets and
   visible on a few.
2. **Safe areas** (SMPTE SD guidelines):
   - All interactive/meaningful content inside the central **90%**
     (*action safe*: ~317x216 of 352x240, ~317x259 of 352x288, ~648x432 of
     720x480).
   - Text you must be able to read inside the central **80%**
     (*title safe*: ~282x192 / ~282x230 / ~576x384).
3. **Pixel aspect ratio is 10:11** (pixels slightly narrower than square) in
   all three modes. A perfect circle needs ~10% more width in pixels. Safe to
   ignore for boxes-and-text UI; matters if rendering logos/art that must not
   look squished.
4. **480i flicker discipline:** every scanline is repainted 30 times/second,
   so 1-px horizontal lines and fine text shimmer. Use ≥2 px horizontal
   strokes, avoid hard 1-px horizontal edges, or apply a mild vertical blur
   (the standard trick in console-era 480i dashboards). The existing CRT
   typography rules in `docs/native-core-poc.md` (integer snapping, bitmap
   fonts) stay in force.
5. **Own the centering trims** (section 5.1): a calibration screen that draws
   an edge/border test pattern and lets the user nudge H/V offsets with live
   preview, publishing them via control word1 and persisting them in the
   launcher config. Defaults are zero — the standard timing is the centering
   mechanism; trims only compensate for miscentered sets.

---

## 7. Implementation plan

### Phase A — broadcast-geometry 240p (the main fix)

FPGA (this repo):

1. ~~`rtl/pll/pll_0002.v`: `output_clock_frequency1` 27.027027 MHz →
   `27.000000 MHz`.~~ Superseded: the shared PLL cannot fit 27.000 MHz (see
   the implementation note in §4). Instead `pll_0002.v` stays stock and a
   new dedicated `rtl/pll_video.v` (+ `rtl/pll_video/pll_video_0002.v`,
   `rtl/pll_video.qip`) generates CLK_VIDEO = 27.000000 MHz; menu.sv holds
   the native video path in reset until it locks.
2. **`rtl/native_video_timing.sv`**: mode-0 constants — H 352/12/32/33,
   V 240/3/3/16. Structure the constants as per-mode parameter sets selected
   by a `mode` input (tied to 0 until Phases B/C) so later modes are additive.
   Offset budgets change: positive H offset eats the now-small 12-px front
   porch. **Trim range is deliberately reverted to ±8 px H, 1-px steps**
   (this branch had widened it to ±16 in 2-px steps while the porches were
   the centering mechanism — with broadcast-fill geometry the trim is a
   nicety, and ±8 px ≈ ±1.2 µs is plenty). V range −8…+2 lines. RTL clamps
   to these ranges and additionally never lets effective FP/BP drop below
   2 px / 1 line, so out-of-range word1 values saturate instead of breaking
   sync.
3. **`rtl/native_video_reader.sv`**:
   - Parse word1 (`ddr_dout[63:32]`) in `ST_WAIT_CTRL`: magic present → v2
     layout (buffers at word addresses 0x07400200 / 0x07430000, line burst
     176 words) and extract mode + h/v offsets; absent → legacy layout
     (0x07400020 / 0x07409620, 160 words, offsets 0) displayed centered with
     16-px black bars (needs `hcount` from the timing module, already
     exported but unconnected). Forward the synchronized offsets to the
     timing module, latched at `new_frame`.
   - `word0 == 0` → clear `frame_ready` and `first_frame_loaded` → core
     reverts to the noise pattern (fixes defects 3/5 in section 3).
   - Keep the 2-line preload (see defect 4 — it's already at the FIFO's safe
     maximum); optionally deepen the FIFO to 1024 words for margin.
4. **`menu.sv`**: remove all video options from `CONF_STR` (back to the stock
   `"MENU;UART31250,MIDI;-;V,v"` + build date — one OSD page, no Video
   section); delete `status[9]` / `status[17:10]` decoding and the offset
   wiring from `hps_io` (offsets now arrive via the reader's control parse,
   section 5.1); correct the stale "15.734 kHz" comments (true again after
   the PLL fix); README note about `forced_scandoubler`/`vga_scaler`.
5. **Testbench before synthesis** (see section 8).

Frontend (`zaparoo-launcher`):

6. `--crt` path sets fb0 to **352x240** 32bpp (`vmode -r 352 240 rgb32`
   equivalent); writer constants: width 352, stride 1408, frame size 0x52800,
   buffers at +0x1000 / +0x180000, region 0x300000; write magic + mode +
   offset word on init (offsets from saved config, default 0) and clear both
   words on stop.
7. UI safe-area pass per section 6; calibration screen for the H/V trims
   (border test pattern + arrow-key nudge within ±8 px / −8…+2 lines,
   persisted in launcher config).
8. Release coordination: core's legacy mode covers old-launcher/new-core; the
   launcher's existing fb-geometry validation covers new-launcher/old-core
   (writer disables itself, core shows noise — obvious, not subtle breakage).

### Phase B — PAL 288p50

9. Timing mode 2: H total 432 (352/11/32/37), V total 312 (288/3/3/18).
   Same 6.75 MHz clock; line rate exactly 15 625 Hz.
10. Reader: 288-line frame, same stride; fits existing buffer slots
    (352×288×4 = 396 KB < 1.35 MB slot).
11. Launcher: a "video standard: NTSC / PAL" user setting → renders 352x288
    and publishes mode 2. PAL sets that accept 60 Hz RGB ("PAL-60", most of
    them via SCART) can simply stay on mode 0; mode 2 is for strict-50 Hz
    sets and correct-speed feel in PAL regions.

### Phase C — 480i60 (after A/B verified on real CRTs)

12. Timing mode 1: ce_pix ÷2 (13.5 MHz); H 858 total (720/19/62/57); 525-line
    dual-field vertical counter; **half-line (429-clock) vsync offset on the
    odd field**; field bit out → `VGA_F1` (replace the hardwired 0 in
    `menu.sv`).
13. Reader: source line = `vcount*2 + field`; 720 px = 360 DDR words/line
    exceeds the 8-bit burst counter, so fetch each line as **2×180-beat
    bursts**; FIFO sizing: 360-word lines × 2-line preload = 720 words →
    deepen FIFO to 1024.
14. Launcher: 720x480 rendering path; per-screen mode selection (e.g. launcher
    UI in 240p, text-heavy screens in 480i); flicker styling per section 6.

### Explicitly out of scope / rejected

- **Using MiSTer's scaler framebuffer instead** — already rejected by the
  project (`native-core-poc.md`): the whole point is core-owned, low-latency,
  exact 15 kHz output.
- **31 kHz / 480p output** for VGA PC monitors — different audience; the
  framework's `vga_scaler=1` path already serves it.
- **Changing the pixel clock to stretch 320 px across 52.7 µs** (the literal
  Switchres approach, ~6.1 MHz dot clock) — works, but leaves the 27 MHz
  family for no benefit; widening the framebuffer is cleaner on every axis.

---

## 8. Verification

1. **Simulation first** (no Quartus needed): a small testbench on
   `native_video_timing` that measures, in µs/lines against section 4's table:
   line period, sync width, sync→active delay, active width, frame period —
   and for 480i: field alternation, the half-line vsync offset, and total
   525 lines/frame. This is cheap and catches every off-by-one that matters.
2. **CI build** (existing GitHub Actions Quartus workflow) for timing closure
   and resource sanity.
3. **Hardware checklist** (per phase):
   - Launcher renders a cross-hatch + border test pattern (240p-test-suite
     style: 1-px frame at the extreme edge, safe-area rectangles at 90%/80%).
   - Verify fill/centering on **at least 2–3 different CRTs** plus a capture
     device (OSSC/RetroTINK profile or capture card reporting measured line
     rate — should read 15.734 kHz exactly after the PLL fix).
   - Legacy-compat check: old launcher against new core → centered 320x240
     with side bars.
   - Writer-stop check: kill the launcher → noise pattern returns.
   - Trim check: launcher calibration screen nudges the picture live in both
     axes; values survive a launcher restart; out-of-range word1 values
     saturate without disturbing sync.
   - OSD check: core options reduced to a single page (no Video section);
     the OSD overlay itself still renders and is usable in every mode.
   - HDMI side still locks (ascal) in every mode.
   - 480i: confirm real interlacing (no line pairing) — fine horizontal lines
     should shimmer, not stack; capture device should report 480i, not 240p.

---

## 9. References

- Switchres monitor presets (GroovyMAME):
  `github.com/antonioginer/switchres` `monitor.cpp` — `ntsc`, `pal`,
  `arcade_15` ranges (porch values in µs/ms).
- SMPTE 170M / standard NTSC line structure: 63.556 µs line, 10.9 µs
  blanking, 52.66 µs active, 9.4 µs sync→active.
- CEA-861 720x480i timing: 858/19/62/57 @ 13.5 MHz, 525 lines.
- SMPTE safe areas (SD practice): action safe 90%, title safe 80%
  (HD-era ST 2046-1 relaxed these to 93%/90% — use the SD numbers for
  consumer CRTs).
- PSX_MiSTer `rtl/gpu_videoout_async.vhd` — half-line vsync offset reference.
- MiSTer framework: `sys/sys_top.v` (`VGA_F1` → ascal `i_fl`; csync),
  `sys/vga_out.sv` (analog path is timing-transparent).
- ARM writer: `zaparoo-launcher/src/app/native_video_writer.cpp`,
  `zaparoo-launcher/docs/native-core-poc.md`.
- Pixel aspect ratio / SIF background: BT.601 (704x480 → PAR 10:11; 352x240
  inherits it).
