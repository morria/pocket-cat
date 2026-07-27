/* spectrum — see include/spectrum.h for the contract. */

#include "spectrum.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* --- Validation ----------------------------------------------------------- */

bool spec_valid_bins(uint16_t bins)
{
    return bins == 64u || bins == 128u || bins == 256u || bins == 512u;
}

bool spec_valid_fps(uint8_t fps)
{
    return fps >= 1u && fps <= 30u;
}

/* --- Fragmentation -------------------------------------------------------- */

int spec_frag_count(uint16_t bins_total, uint16_t mtu_payload)
{
    if (mtu_payload < SPEC_MIN_MTU_PAYLOAD) {
        return -1;
    }
    uint16_t cap0 = mtu_payload - SPEC_FRAG0_HDR;
    if (bins_total <= cap0) {
        return 1;
    }
    uint16_t capn = mtu_payload - SPEC_FRAGN_HDR;
    uint16_t rest = bins_total - cap0;
    return 1 + (rest + capn - 1u) / capn;
}

static void put_u16le(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)(v >> 8);
}

static void put_u32le(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)((v >> 8) & 0xFFu);
    p[2] = (uint8_t)((v >> 16) & 0xFFu);
    p[3] = (uint8_t)((v >> 24) & 0xFFu);
}

int spec_frag_build(uint8_t seq, uint8_t frag, uint16_t bins_total,
                    uint32_t sample_rate_hz, const uint8_t *bins,
                    uint16_t mtu_payload, uint8_t *out, size_t cap)
{
    int nfrags = spec_frag_count(bins_total, mtu_payload);
    if (nfrags < 0 || frag >= nfrags || bins == NULL || out == NULL) {
        return -1;
    }
    uint16_t cap0 = mtu_payload - SPEC_FRAG0_HDR;
    uint16_t capn = mtu_payload - SPEC_FRAGN_HDR;

    uint16_t first_bin;
    uint16_t count;
    if (frag == 0u) {
        first_bin = 0u;
        count = bins_total <= cap0 ? bins_total : cap0;
    } else {
        first_bin = (uint16_t)(cap0 + (uint16_t)(frag - 1u) * capn);
        uint16_t remaining = (uint16_t)(bins_total - first_bin);
        count = remaining <= capn ? remaining : capn;
    }

    size_t header = frag == 0u ? SPEC_FRAG0_HDR : SPEC_FRAGN_HDR;
    size_t total = header + count;
    if (cap < total) {
        return -1;
    }

    out[0] = seq;
    out[1] = frag;
    out[2] = (uint8_t)nfrags;
    if (frag == 0u) {
        out[3] = SPEC_FLAGS_V1;
        put_u16le(&out[4], first_bin);
        put_u16le(&out[6], bins_total);
        put_u32le(&out[8], sample_rate_hz);
        memcpy(&out[12], bins, count);
    } else {
        put_u16le(&out[3], first_bin);
        memcpy(&out[5], &bins[first_bin], count);
    }
    return (int)total;
}

/* --- DSP ------------------------------------------------------------------ */

/* In-place iterative radix-2 complex FFT (decimation in time). */
static void fft(float *re, float *im, uint16_t n)
{
    /* Bit-reversal permutation. */
    for (uint16_t i = 1u, j = 0u; i < n; i++) {
        uint16_t bit = n >> 1;
        for (; j & bit; bit >>= 1) {
            j = (uint16_t)(j ^ bit);
        }
        j = (uint16_t)(j | bit);
        if (i < j) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (uint16_t len = 2u; len <= n; len <<= 1) {
        float ang = (float)(-2.0 * M_PI) / (float)len;
        float wr = cosf(ang);
        float wi = sinf(ang);
        for (uint16_t i = 0u; i < n; i = (uint16_t)(i + len)) {
            float cr = 1.0f;
            float ci = 0.0f;
            for (uint16_t k = 0u; k < len / 2u; k++) {
                uint16_t a = (uint16_t)(i + k);
                uint16_t b = (uint16_t)(i + k + len / 2u);
                float tr = re[b] * cr - im[b] * ci;
                float ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                float ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

void spec_compute(const float *iq, uint16_t n, uint8_t *out_bins)
{
    static float re[SPEC_MAX_BINS];
    static float im[SPEC_MAX_BINS];

    /* DC removal: a direct-conversion front end always has an offset that
     * would paint a fake carrier on the tuned frequency (§3.3). */
    float mean_i = 0.0f;
    float mean_q = 0.0f;
    for (uint16_t k = 0u; k < n; k++) {
        mean_i += iq[2u * k];
        mean_q += iq[2u * k + 1u];
    }
    mean_i /= (float)n;
    mean_q /= (float)n;

    /* Hann window; coherent gain 0.5 folds into the normalisation. */
    for (uint16_t k = 0u; k < n; k++) {
        float w = 0.5f
            - 0.5f * cosf((float)(2.0 * M_PI) * (float)k / (float)n);
        re[k] = (iq[2u * k] - mean_i) * w;
        im[k] = (iq[2u * k + 1u] - mean_q) * w;
    }

    fft(re, im, n);

    /* Full-scale tone → |bin| = N * 0.5 (Hann coherent gain); normalise so
     * that reads as 0 dBFS, then quantise to 0.5 dB/LSB. fftshift so bin 0
     * is the lowest frequency and bin n/2 is DC. */
    float norm = 2.0f / (float)n;
    for (uint16_t k = 0u; k < n; k++) {
        uint16_t src = (uint16_t)((k + n / 2u) & (n - 1u));
        float mag = sqrtf(re[src] * re[src] + im[src] * im[src]) * norm;
        float db = mag > 1e-10f ? 20.0f * log10f(mag) : -1000.0f;
        float q = -db * 2.0f; /* 0.5 dB per LSB, 0 = full scale */
        if (q < 0.0f) {
            q = 0.0f;
        }
        if (q > 255.0f) {
            q = 255.0f;
        }
        out_bins[k] = (uint8_t)(q + 0.5f);
    }
}

/* --- Synthetic source ----------------------------------------------------- */

void spec_synth_init(spec_synth_t *s, uint32_t seed)
{
    s->phase_q32 = 0u;
    s->freq_q32 = 0x10000000u; /* start at +1/16 of the sample rate */
    s->rng = seed ? seed : 0xC0FFEEu;
}

static float synth_noise(uint32_t *rng)
{
    /* xorshift32 → [-1, 1) scaled way down for a ~-90 dBFS floor. */
    uint32_t x = *rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *rng = x;
    return ((float)(int32_t)x / 2147483648.0f) * 3e-5f;
}

void spec_synth_fill(spec_synth_t *s, float *iq, uint16_t npairs)
{
    for (uint16_t k = 0u; k < npairs; k++) {
        float phase = (float)s->phase_q32
            * (float)(2.0 * M_PI / 4294967296.0);
        /* -20 dBFS tone so the trace sits comfortably on screen. */
        iq[2u * k] = 0.1f * cosf(phase) + synth_noise(&s->rng);
        iq[2u * k + 1u] = 0.1f * sinf(phase) + synth_noise(&s->rng);
        s->phase_q32 += s->freq_q32;
    }
    /* Sweep: walk the tone across ±span/4 and wrap. */
    s->freq_q32 += 0x00400000u;
    if (s->freq_q32 > 0x40000000u) {
        s->freq_q32 = 0xC0000000u; /* jump to -span/4 */
    }
}
