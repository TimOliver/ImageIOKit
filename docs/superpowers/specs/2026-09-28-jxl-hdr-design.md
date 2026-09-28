# JXL HDR preservation

Status: proposed design for review; no HDR implementation has been made.

## Intent and scope

Preserve native JXL HDR and high-bit-depth image data through decoding, cropping,
resizing, texture upload, and a lossless disk cache. Keep ordinary SDR comic pages
on the existing inexpensive path. The initial implementation targets JXL; shared
pixel and colour descriptions must also accommodate future JPEG/HEIF gain-map
decoders. Gain-map reconstruction is outside this first implementation.

The target device remains the three-core iPad Pro running iPadOS 17, with roughly
2 GiB of usable app memory. Neither HDR support nor small output tiles can impose
a strict bound on libjxl's internal working memory.

This work supplies HDR-capable building blocks. A streaming page-slice API,
texture residency manager, atlas allocator, and app display tone mapper are
separate work. Existing crop operations must retain HDR, but are not advertised
as random-access JXL decoding.

## Proposed contract

An FP16-only path would minimise memory but unnecessarily limit preservation
precision. Making every image FP32 would inflate ordinary page costs. Use FP32
for the explicit preserving path, offer FP16 for display, and retain RGBA8 for SDR.

Add an explicit HDR-preserving decode entry point alongside the existing SDR
API. It takes the same upright crop coordinates and fitting bounds, plus an
output precision choice. Its default is RGBA32Float; RGBA16Float is an explicit
display optimisation. Existing SDR entry points retain their documented sRGB,
8-bit behaviour and are documented as unsuitable for HDR preservation.

The preserving path never falls back to an 8-bit render or to an assumed sRGB
profile when colour interpretation fails. Unsupported colour conversions report
an error. An unresized buffer crop copies components without colour conversion.

“Preserve HDR” means retaining extended range and the information needed to
interpret it, without implicit clipping or display tone mapping. It does not
promise recovery of the original compressed file or bit-identical original
samples after colour conversion, alpha premultiplication, or resizing.

RGBA16Float rounds values and cannot exactly represent every 16-bit integer or
32-bit float source sample. It must not be described as an archival lossless
format. Values that cannot be represented in a requested output format cause an
error instead of being silently clamped or becoming infinity.

## Buffers and colour information

Extend PixelBuffer with RGBA16Float and RGBA32Float layouts, floating-point pixel
access, and matching CGImage and Metal descriptions. Keep the existing 8-bit
layouts unchanged. Retain premultiplied alpha as the rendering-buffer contract.

Carry a format-independent colour description with each preserving buffer:

- The profile/structured colour encoding that actually describes its components.
- Transfer function, primaries, and white point when explicitly available.
- Luminance interpretation and available source intensity metadata.
- Source channel precision, separately from the buffer's storage precision.

Retain source metadata separately from output metadata. A profile name alone
does not describe HDR. A high bit depth or a wide gamut alone does not establish
that an image is HDR; unknown information stays unknown.

Metal textures contain component data, not this colour description. The caller
must retain the description and configure the renderer accordingly. Creating a
texture never applies a display tone map.

## Native JXL decoding and scaling

Use the currently pinned libjxl floating-point output API. Obtain structured
colour information where possible, retaining ICC data for profiles that require
it. Query the decoder's actual output profile after choosing its output settings;
do not label decoded pixels with the original profile unless they match.

Preserve native range without requesting an SDR intensity target. Add tests for
the pinned decoder's behaviour rather than assuming that choosing a float output
type also establishes the correct colour space or luminance scale.

Keep float data out of all current UInt8 render and UInt16 accumulation paths.
HDR resizing operates in a correctly described linear-light working space with
float32 accumulation and premultiplied alpha. Preserve negative wide-gamut
components and highlights above SDR white. Converting the result to half-float is
an explicit final step. Unsupported profile-to-linear conversions fail clearly.

Keep the current SDR thumbnail optimisations. HDR DC previews are allowed only
after their profile, luminance, alpha, and precision behaviour is verified; an
HDR preview is never treated as a lossless representation of the original.

## Disk cache

Add native lossless JXL encoding for the floating-point buffers, retaining their
actual colour description, luminance metadata, precision, and premultiplied-alpha
interpretation. Preserve pixel values beneath transparent pixels where present.
Use the existing atomic replacement pattern so failures leave an old entry intact.

The cache guarantee is an exact round trip of the supplied finite buffer
components and equivalent colour/alpha interpretation. Reopening the cache uses
the preserving decode path. Encoder settings must explicitly enable lossless
mode; a quality number alone is insufficient. Float32 caches may require JXL
level 10 and are primarily an internal cache format, not a promise of universal
third-party viewer compatibility.

An HDR buffer cannot silently pass through the current JPEG/8-bit writer.
Unsupported exports fail with a clear error. JPEG quality 0.95 remains the SDR
cache default. A deliberate HDR-to-SDR conversion belongs to a separately
specified operation; clipping is not a substitute for tone mapping.

## Memory and validation

A tightly packed 400 × 2,048 tile occupies 3.125 MiB in RGBA8, 6.25 MiB in
RGBA16Float, or 12.5 MiB in RGBA32Float. CPU storage, the copied Metal texture,
filter accumulators, and codec working storage must be counted separately.
Update memory estimates for the selected precision and intermediates; retain
their documented status as estimates rather than limits.

Use generated, non-identifying JXL fixtures covering PQ, HLG, linear HDR,
high-bit-depth SDR, grayscale, alpha, all orientations, and ICC-only profiles.
Check known reference values, not merely agreement between two code paths.

Required checks include preservation of highlights and negative components,
correct transfer/luminance interpretation, float crop identity, linear-light
resize results, alpha edges, exact lossless-cache round trips, safe rejection of
unsupported exports, and unchanged SDR behaviour. Exercise both raw codestreams
and containers. Verify CGImage and texture components separately from on-screen
appearance, which depends on display headroom.

On the physical iPad, measure decode latency, peak process footprint, texture
upload, cache write/read latency, and cache size for both float precisions. Cover
one through three concurrent operations and tall/oversized synthetic pages,
starting with smaller fixtures to establish safe working-memory requirements.
Record actual successful concurrency rather than assuming three simultaneous
large HDR decodes will fit.

## Primary references

- [libjxl 0.11.2 pixel types](https://github.com/libjxl/libjxl/blob/v0.11.2/lib/include/jxl/types.h)
- [Decoder colour and output contracts](https://github.com/libjxl/libjxl/blob/v0.11.2/lib/include/jxl/decode.h)
- [JXL precision and intensity metadata](https://github.com/libjxl/libjxl/blob/v0.11.2/lib/include/jxl/codestream_header.h)
- [Lossless encoding and codestream levels](https://github.com/libjxl/libjxl/blob/v0.11.2/lib/include/jxl/encode.h)
- [Apple: Explore EDR on iOS](https://developer.apple.com/videos/play/wwdc2022/10113/)
