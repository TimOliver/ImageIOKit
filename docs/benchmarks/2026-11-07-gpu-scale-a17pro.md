# GPU scale benchmarks: iPad mini (A17 Pro)

**Device:** iPad mini (A17 Pro, iPad16,2), iPadOS 27.2, 8 GB RAM, 6 cores, thermal state
nominal in every case line. **Harness:** same as the [A10X run](2026-11-07-gpu-scale-a10x.md)
(`setup-ios.sh`, Release, `devicectl` launches); fixtures are the five originals plus four
colour Scott Pilgrim pages (1800×2700 cover/interior/near-blank and a 3599×2700 spread).
The full matrix ran twice by accident (a zsh word-splitting slip turned the `--memory` launch
into a second default run): JPEG numbers reproduced within a few percent; 121 MP JXL walls
drifted up to ~30% warmer on the repeat, so treat JXL absolutes as approximate.
Logs: [results](2026-11-07-gpu-scale-a17pro-results.log),
[real](2026-11-07-gpu-scale-a17pro-real.log),
[memory](2026-11-07-gpu-scale-a17pro-memory.log),
[crop](2026-11-07-gpu-scale-a17pro-crop.log).

The mini sits where expected between the A10X floor and the iPhone Air: every routing
decision validated on those devices holds here, with no new exceptions.

## Real pages (medians, `.rgba8`)

| Page | SE fit | Pro Max fit | iPad fit |
|---|---:|---:|---:|
| Cover 1800×2700 (4.9 MP) | decode 14.7 / texture **11.2** | 46.3 / **27.5** | 23.2 / **20.3** |
| Interior 1800×2700 | 14.0 / **9.9** | 43.3 / **23.6** | 23.0 / **19.8** |
| Near-blank 1800×2700 (57 KB) | 13.4 / **9.4** | 45.0 / **25.0** | 21.6 / **18.8** |
| Spread 3599×2700 (9.7 MP) | 19.5 / **18.7** | 32.0 / **23.0** | 63.4 / **44.5** |

`makeTexture` wins or ties all twelve cells; the big margins are the small reductions
(Pro Max fit, 1.16–1.9×), where `decode(targetSize:)` pays a full-size decode plus a CPU
resample and the GPU path doesn't. Content entropy barely matters (57 KB near-blank ≈ 1 MB
interior): the hardware decoder's time tracks pixel count, not bytes.

## JPEG routing and formats (fixture matrix)

ImageIO's hardware decode stays the floor at every size: the TurboJPEG-native pipelines run
2.3–2.9× slower (121 MP: 266 vs 109 ms; 50 MP: 145 vs 51 ms; 6.6 MP manga: 37 vs 23 ms), so
the iOS routing needs no mid-tier exception either. `.gray8` remains the right call for gray
pages — `makeTexture` 21.5 ms vs 25.1 ms rgba8 at the 2048 fit, with CPU time 5.8 vs 9.4 ms —
and the repeated matrix confirmed JPEG reproducibility within a few percent.

## JXL box filter (task 6, third device)

Same inversion as the iPhone Air and A10X: at the 1024 fit the box-filtered `current` costs
80.4 ms while a full native decode plus GPU Lanczos costs 64.8 ms (`makeTexture`-gray8 66.2);
at 2048, 57.5 vs 50.4 ms. Full decode wins whenever the full-size bitmap is affordable, on
every device class measured; only the memory budget boundary (oversized sources) keeps the
filter alive.

## Shared-storage memory A/B

Shared `MTLBuffer` decode storage saves 0–11% of time (manga rgba8 @2048: 31.1 → 27.5 ms) and
leaves JPEG peak footprints flat — matching the iPhone Air, not the A10X's 20–40% peak
savings, which now clearly belong to the weakest-device class. The one large peak saving here
is the 121 MP JXL at the 2048 fit (22.0 → 7.5 MB sampled peak), where skipping the staging
copy of a 23 MB bitmap is visible. Zero-copy upload stays a win everywhere, but on 8 GB
devices it is a time-and-copies win, not a memory one.

## Zoom-tile crops (task 5), and the gray8 anomaly reproduces

| Case | Region | Full cold | Full cached |
|---|---:|---:|---:|
| 50 MP, half crop → 1376×2752 | 136.6 | 160.8 | 76.3 |
| 50 MP, quarter crop | 87.5 | 129.1 | 15.4 |
| Manga gray, half, rgba8 | 17.5 | 21.9 | 7.7 |
| Manga gray, half, gray8 | **25.3** | 20.8 | 6.7 |
| Real 4.9 MP page, half | 5.5 | 7.8 | 3.8 |

Same shape as the A10X: TurboJPEG region decode beats a cold full decode by 1.2–1.5×, a
cached full bitmap beats region decode by 1.8–6×, and the tradeoff is the ~200 MB of holding
the 50 MP bitmap, which `estimatedDecodeMemory` should gate. And the oddity is confirmed
device-independent: **gray8 region decode is again slower than rgba8 on the same crop**
(25.3 vs 17.5 ms at the half crop, 14.8 vs 12.7 at the quarter; A10X read 59.3 vs 38.2).
Two devices implicate the TurboJPEG gray path itself — plausibly the post-decode gray
colour conversion rather than the DCT work. Profile that stage before building `cropRect`
into `makeTexture`.
