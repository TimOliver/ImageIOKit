# TurboJPEG vs ImageIO texture routing on the M1 (TASKS item 3)

**Machine:** MacBook Air (M1, 16 GB, fanless), macOS 27.2, AC power, Low Power Mode off.
**Harness:** `CutoffSweep` ([harness/README.md](harness/README.md)), Release. `setup-mac.sh` patches
its library copy so the probe can pin the complete `makeTexture(fitting:)` pipeline — decode,
shared-storage wrap, GPU resample — to either JPEG route per call. Fixtures are the 2026-11-06
procedural comic page at 6.6, 8, 12, 16, 24, 36 and 50 MP, colour and gray; targets are 2752 px
(large reading fit) and 1664 px (window fit); each cell alternates the two routes inside every
iteration and reports medians and minimums over 8–10 timed runs.

## Question

`turboJPEGTextureSource` routed JPEGs of 12 MP or less to TurboJPEG on Mac and Catalyst. The
cutoff was a guess bracketed on the M4 Max (2026-11-06: TurboJPEG won at 6.6 MP, lost at 50 MP).
Where is the crossover on the slowest Apple Silicon Mac?

## Answer: there is no crossover

ImageIO won **all 42 cells in both full runs** — one with the process QoS-clamped on an otherwise
idle machine, one QoS-lifted while other agents held the CPU at 100% — and the one near-idle
spot check. TurboJPEG never came within 30% at any size, in any condition. ImageIO's advantage
on throttle-resistant minimums in the contended run (`turboMin ÷ imageioMin`):

| MP | colour @2752 | colour @1664 | gray8 @2752 | gray8 @1664 | gray rgba8 @2752 | gray rgba8 @1664 |
|---:|---:|---:|---:|---:|---:|---:|
| 6.6 | 1.58 | 1.76 | 2.97 | 2.70 | 1.94 | 1.51 |
| 8 | 2.08 | 1.52 | 2.96 | 4.91 | 2.33 | 2.84 |
| 12 | 1.92 | 4.10 | 3.97 | 6.89 | 2.09 | 4.22 |
| 16 | 1.45 | 2.45 | 3.61 | 5.29 | 1.97 | 2.66 |
| 24 | 2.72 | 3.66 | 3.70 | 3.19 | 2.84 | 2.85 |
| 36 | 3.73 | 6.85 | 6.94 | 5.55 | 3.18 | 6.30 |
| 50 | 3.05 | 5.47 | 8.82 | 9.22 | 4.78 | 6.35 |

The gap widens with size (TurboJPEG's single-threaded IDCT scales with pixels; the hardware
decoder barely moves) and is larger for gray pages, where ImageIO's `gray8` render is very cheap
while TurboJPEG still pays a full entropy decode. ImageIO wins even where its intermediate is
larger — at 36 MP @2752 it decodes 2450×3674 against TurboJPEG's DCT-scaled 1838×2756 and still
finishes 3–7× sooner.

## Conditions, and why the sign is trustworthy anyway

No pristine-idle dataset exists: the first run was QoS-clamped (below), and by the retry other
agents held every core at 100%. Three independent conditions were measured:

1. **QoS-clamped, machine otherwise idle** ([log](2026-11-07-turbojpeg-cutoff-m1-qos-clamped.log)):
   ImageIO won 42/42, median ratios 1.14–10.2. Its first fixture ran straight after ~250 MP of
   fixture generation on a hot chassis and is inflated; later cells show throttle waves (a few
   cells read slower at the smaller target).
2. **QoS lifted, near idle, warm** (spot checks on the most TurboJPEG-friendly cell measured,
   6.6 MP colour @1664): at calib 91–99 ms, TurboJPEG 113.3 ms (min 99.0) vs ImageIO 69.1 ms
   (min 52.8), 1.64× (1.88× on minimums); at the day's best calibration of 75–78 ms,
   TurboJPEG 41.1 ms vs ImageIO 29.9 ms, 1.38×. The margin shrinks as conditions improve
   and extrapolates to roughly 1.2–1.3× pristine — not to a flip.
3. **QoS lifted, CPU fully contended** ([log](2026-11-07-turbojpeg-cutoff-m1-contended.log),
   the table above): ImageIO won 42/42 with the calibration canary reading 46–373 ms, i.e. under
   genuine, varying load.

Every handicap in these conditions — efficiency cores, heat, contention — hits the CPU-bound
TurboJPEG leg *and* ImageIO's CPU portions; the within-cell comparison stayed alternating and
fair throughout. For TurboJPEG to win anywhere it would have to close a 1.5–1.9× gap in the
near-idle spot check as conditions improve, and there is no mechanism for that: better
conditions help both legs' CPU work alike. A pristine run can shrink ImageIO's margin at the
small end, not flip 84 cells.

## Contention resilience

ImageIO's times were close to indifferent to CPU conditions: between the clamped-idle and
lifted-contended runs its medians mostly moved within ±15% (24 MP gray8 @2752: 38.6 → 34.1 ms;
50 MP colour @1664: 63.5 → 64.2 ms; 8 MP colour @2752: 130.1 → 131.7 ms) and never beyond about
1.4×, because the decode itself runs on the fixed-function engine. TurboJPEG's times tracked CPU
availability, spiking to 2.3 s on the 50 MP gray page under a contention burst. On a machine
running anything else — the realistic case for a comic reader — the hardware route is not just
faster but far more predictable.

## The background-QoS discovery

Shells spawned by coding agents carry a background Darwin QoS role on macOS, which schedules
their work onto the M1's efficiency cores. The probe's `calib=` canary (a fixed
dependency-chained FP loop) read 150–168 ms in those shells and 91–99 ms after
`taskpolicy -B -p $$` lifted the role in the same warm conditions — the first full run was
~2–3× inflated end to end. Any absolute Mac timing taken from an agent shell without lifting
the role understates the machine, and it understates CPU-bound code more than hardware-backed
code. The 2026-11-06 Mac harness absolutes predate this discovery and may carry the same clamp;
their cross-pipeline *comparisons* shared whatever clamp was present. Device runs over
`devicectl` are unaffected (the clamp is on the Mac process).

## Decision

`turboJPEGTextureSource` is now compiled only for Intel (`arch(x86_64)`): Apple Silicon Macs
always route `makeTexture` JPEGs through ImageIO subsampling, matching iOS. The M4 Max's small
sub-7 MP TurboJPEG win (2026-11-06) is forgone: it was a few milliseconds on an already fast
path, measured before the QoS discovery, while keeping the route would cost the slowest Macs
1.5–5× on the most common page sizes. Intel Macs keep the provisional 12 MP cutoff — they have
no hardware JPEG decoder, so TurboJPEG plausibly wins there, but it is unmeasured: run
`CutoffSweep` on one before trusting it. TurboJPEG itself stays load-bearing everywhere for
region decode (`decode(cropRect:)`), which is unchanged.
