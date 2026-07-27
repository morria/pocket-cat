/*
 * spectrum — panadapter DSP + frame codec (docs/qmx-panadapter.md §3.3, §4).
 *
 * Pure C11, no ESP-IDF / FreeRTOS dependencies: unit-tested on the Linux
 * host. Window → FFT → dB → fftshift → fragment. The FFT is a plain float
 * radix-2 — at 512 points × 30 fps it is a rounding error on the LX7's FPU,
 * and keeping it dependency-free is what makes the host tests and golden
 * vectors possible (swap in esp-dsp later only if measurement demands it).
 *
 * Frame format (v1, little-endian):
 *   frag 0 : [seq][frag=0][nfrags][flags][first_bin u16][bins_total u16]
 *            [sample_rate_hz u32][bin bytes…]                 header 12 B
 *   frag n : [seq][frag][nfrags][first_bin u16][bin bytes…]   header  5 B
 *
 * Bins are dBFS at 0.5 dB/LSB: 0 = full scale, 255 = −127.5 dBFS.
 * dB reference: a full-scale complex exponential (|IQ| = 1.0) centred on a
 * bin reads 0 after the Hann window and 2/(N·1.0) coherent-gain
 * normalisation — pinned by the golden tests, do not change silently.
 * Bin 0 is the lowest frequency; bin bins_total/2 is DC (fftshift order).
 */
#ifndef SPECTRUM_H
#define SPECTRUM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPEC_FLAGS_V1        0u
#define SPEC_FRAG0_HDR       12u
#define SPEC_FRAGN_HDR       5u
#define SPEC_MAX_BINS        512u
#define SPEC_MIN_MTU_PAYLOAD 32u
/* Achievability ceiling enforced at SET_SPECTRUM (§3.2): fragments per
 * frame × fps must stay under this. Conservative for a 15 ms connection
 * interval with a handful of packets per event. */
#define SPEC_NOTIFY_BUDGET_PER_S 60u

bool spec_valid_bins(uint16_t bins); /* {64, 128, 256, 512} */
bool spec_valid_fps(uint8_t fps);    /* 1–30 */

/*
 * Number of notification fragments for one frame at the given usable
 * notify payload (ATT_MTU − 3). Returns -1 when mtu_payload is below
 * SPEC_MIN_MTU_PAYLOAD.
 */
int spec_frag_count(uint16_t bins_total, uint16_t mtu_payload);

/*
 * Build fragment `frag` (0-based) of a frame into out. Returns the
 * fragment length, or -1 on bad args / short buffer. Deterministic pure
 * function — the golden vectors are built on it.
 */
int spec_frag_build(uint8_t seq, uint8_t frag, uint16_t bins_total,
                    uint32_t sample_rate_hz, const uint8_t *bins,
                    uint16_t mtu_payload, uint8_t *out, size_t cap);

/*
 * One spectrum frame from bins_total interleaved I/Q pairs in [-1, 1):
 * DC removal (mean subtract) → Hann → FFT(bins_total) → magnitude →
 * dBFS quantised to 0.5 dB/LSB → fftshift into out_bins[bins_total].
 * bins_total must satisfy spec_valid_bins.
 */
void spec_compute(const float *iq, uint16_t bins_total, uint8_t *out_bins);

/*
 * Synthetic source (milestone M2): a tone sweeping the span plus a white
 * noise floor, deterministic from the seed. Fills npairs interleaved I/Q
 * pairs.
 */
typedef struct {
    uint32_t phase_q32; /* tone phase, 2^32 = one turn */
    uint32_t freq_q32;  /* tone frequency, 2^32 = sample rate */
    uint32_t rng;       /* xorshift32 state, never 0 */
} spec_synth_t;

void spec_synth_init(spec_synth_t *s, uint32_t seed);
void spec_synth_fill(spec_synth_t *s, float *iq, uint16_t npairs);

#ifdef __cplusplus
}
#endif

#endif /* SPECTRUM_H */
