/*
 * oercel_gpu.cu -- Oercel GPU engine: a CUDA port of engine/oercel.c (2D dissipative
 * particle dynamics with local stochastic chemistry, SPEC.md), including the lipid
 * architecture extension of runs/memB_src/oercel.c (lip_arch, r0_head, k_head, cos_head,
 * lip_tie, syn_nN).  Drop-in replacement: same command line, same ini parameters and
 * defaults, same output files (snapshots, stats.csv, events.csv, params.ini, log.txt,
 * ckpt.bin in the reference checkpoint format v2 / memB v3).  See README.md.
 *
 * ONE SOURCE, TWO BUILDS
 *   nvcc  -x cu   -> CUDA build: every "kernel" runs on the GPU.
 *   g++   -x c++  -> CPU emulation: the very same kernel bodies run as OpenMP loops.
 * Kernels are written as `pfor(n, KL (int i) { ... })`: KL is `[=] __device__` under
 * nvcc and `[=]` otherwise; pfor launches a grid or runs an OpenMP loop.  Atomics, loads
 * and memory transfers go through thin wrappers (at_*, ldg, h2d/d2h).  No Thrust/CUB.
 *
 * DETERMINISM: for a fixed build and device, a run is a deterministic function of its
 * parameters (and independent of the OpenMP thread count in emulation): stable sort,
 * fixed per-bead summation order, fixed-partition reductions, no floating-point atomics,
 * chemistry decisions from counter-based hashes and a parallel schedule that is provably
 * equivalent to one serial order (see chemistry()).  It is NOT bitwise identical to the
 * CPU reference engine (single-precision pair forces); it is statistically equivalent.
 *
 * DATA LAYOUT (device): per-bead state in "slot" order, re-sorted by cell every step.
 * Cells are >= 1 wide (ncx = ncy = floor(L)), row major (c = cy*ncx + cx).  State is
 * double (x, y, half-step velocity vh, force f); the pair kernel reads a float4
 * (x, y relative to the bead's own cell corner, predicted velocity vt) plus
 * gid|type<<29, so the pair arithmetic is single precision but never loses position
 * resolution, whatever the box size.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <csignal>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <omp.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

/* ================================================================== portability layer */
#if defined(__CUDACC__)
#define OG_CUDA 1
#include <cuda_runtime.h>
#define HD __host__ __device__
#define KL [=] __device__
#else
#define OG_CUDA 0
#define HD
#define KL [=]
struct alignas(16) float4 { float x, y, z, w; };
static inline float4 make_float4(float a, float b, float c, float d) {
    float4 r;
    r.x = a; r.y = b; r.z = c; r.w = d;
    return r;
}
#endif

#define OG_VERSION "1.0"

/* read-only cached load */
template <class T> HD inline T ldg(const T *p) {
#ifdef __CUDA_ARCH__
    return __ldg(p);
#else
    return *p;
#endif
}
HD inline float og_rsqrt(float x) {
#ifdef __CUDA_ARCH__
    return rsqrtf(x);
#else
    return 1.0f / sqrtf(x);
#endif
}
/* integer atomics (relaxed); on the host GCC builtins */
HD inline int at_add(int *p, int v) {
#ifdef __CUDA_ARCH__
    return atomicAdd(p, v);
#else
    return __atomic_fetch_add(p, v, __ATOMIC_RELAXED);
#endif
}
HD inline int at_load(const int *p) {
#ifdef __CUDA_ARCH__
    return *(const volatile int *)p;
#else
    return __atomic_load_n(p, __ATOMIC_RELAXED);
#endif
}
HD inline void at_store(int *p, int v) {
#ifdef __CUDA_ARCH__
    *(volatile int *)p = v;
#else
    __atomic_store_n(p, v, __ATOMIC_RELAXED);
#endif
}
HD inline void at_min(int *p, int v) {
#ifdef __CUDA_ARCH__
    atomicMin(p, v);
#else
    int cur = __atomic_load_n(p, __ATOMIC_RELAXED);
    while (v < cur && !__atomic_compare_exchange_n(p, &cur, v, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
    }
#endif
}
HD inline void at_max(int *p, int v) {
#ifdef __CUDA_ARCH__
    atomicMax(p, v);
#else
    int cur = __atomic_load_n(p, __ATOMIC_RELAXED);
    while (v > cur && !__atomic_compare_exchange_n(p, &cur, v, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
    }
#endif
}
HD inline void at_or(int *p, int v) {
#ifdef __CUDA_ARCH__
    atomicOr(p, v);
#else
    __atomic_fetch_or(p, v, __ATOMIC_RELAXED);
#endif
}
/* max of non-negative doubles (their bit patterns order like unsigned integers) */
HD inline void at_maxpos(double *p, double v) {
    if (!(v > 0.0)) return;
#ifdef __CUDA_ARCH__
    if (v > *(volatile double *)p)
        atomicMax((unsigned long long *)p, (unsigned long long)__double_as_longlong(v));
#else
    unsigned long long nv;
    memcpy(&nv, &v, 8);
    unsigned long long *q = (unsigned long long *)p;
    unsigned long long cur = __atomic_load_n(q, __ATOMIC_RELAXED);
    while (nv > cur && !__atomic_compare_exchange_n(q, &cur, nv, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
    }
#endif
}
/* a*b rounded to float, never fused into a following add (keeps TwoSum exact; the host
 * build is compiled with -ffp-contract=off for the same reason) */
HD inline float fmul_rn(float a, float b) {
#ifdef __CUDA_ARCH__
    return __fmul_rn(a, b);
#else
    return a * b;
#endif
}
/* compensated (TwoSum) single-precision accumulation: s + c carries ~48 bits */
HD inline void two_sum_acc(float &s, float &c, float v) {
    const float t = s + v;
    const float bp = t - s;
    c += (s - (t - bp)) + (v - bp);
    s = t;
}

/* ================================================================== util */
#define NTYPES 7
enum { TW = 0, TH = 1, TT = 2, TN = 3, TKA = 4, TKB = 5, TZ = 6 };
static const char *TNAME[NTYPES] = {"W", "H", "T", "N", "Ka", "Kb", "Z"};
#define MAXMLEN 12 /* memB: up to 12 beads per lipid */
#define MAXMB (2 * MAXMLEN)
#define SQRT12 3.4641016151377545870548926830117
#define GIDBITS 29
#define GIDMASK ((1u << GIDBITS) - 1u)
#define CHEM_MARGIN 0.5 /* max displacement since the last cell sort that chemistry tolerates */
#define RMAX_GATHER 4   /* largest per-step cell displacement handled by the local sort */

static FILE *g_log = NULL;
static volatile sig_atomic_t g_stop = 0;
static int64_t g_warm_end = 0;
static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void logmsg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fflush(stdout);
    if (g_log) {
        va_start(ap, fmt);
        vfprintf(g_log, fmt, ap);
        va_end(ap);
        fflush(g_log);
    }
}

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "oercel_gpu: error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    if (g_log) {
        va_start(ap, fmt);
        fprintf(g_log, "error: ");
        vfprintf(g_log, fmt, ap);
        fprintf(g_log, "\n");
        va_end(ap);
        fflush(g_log);
    }
    exit(1);
}

static void *xmalloc(size_t n) {
    void *p = NULL;
    if (n == 0) n = 64;
    if (posix_memalign(&p, 64, n) != 0 || !p) die("out of host memory (%zu bytes)", n);
    return p;
}

static double wtime(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

/* ================================================================== RNG and hashes */
HD inline uint64_t mix13(uint64_t z) {
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}
/* per-step key for the pair noise (identical to the reference) */
HD inline uint64_t step_seed(uint64_t seed, int64_t step) {
    return mix13(mix13(seed ^ 0x5851f42d4c957f2dULL) ^ mix13((uint64_t)step + 0x632be59bd9b4e019ULL));
}
/* symmetric pair noise, uniform on [-sqrt3, sqrt3): the reference's hash, in double ... */
HD inline double pair_theta(uint64_t sseed, uint32_t gi, uint32_t gj) {
    const uint64_t key = gi < gj ? (((uint64_t)gi << 32) | gj) : (((uint64_t)gj << 32) | gi);
    const uint64_t h = mix13((key * 0x9e3779b97f4a7c15ULL) ^ sseed);
    return (double)(int64_t)h * (SQRT12 / 18446744073709551616.0);
}
/* ... and the same deviate rounded to float (used by the pair kernel) */
HD inline float pair_theta_f(uint64_t sseed, uint32_t gi, uint32_t gj) {
    const uint64_t key = gi < gj ? (((uint64_t)gi << 32) | gj) : (((uint64_t)gj << 32) | gi);
    const uint64_t h = mix13((key * 0x9e3779b97f4a7c15ULL) ^ sseed);
    return (float)(int32_t)(uint32_t)(h >> 32) * (float)(SQRT12 / 4294967296.0); /* int32 -> float is native on GPUs */
}
/* counter-based uniform deviates for order-independent decisions (reference) */
HD inline uint64_t hash_key(uint64_t seed, int64_t step, uint64_t salt) {
    return mix13(seed ^ mix13((uint64_t)step * 0x9e3779b97f4a7c15ULL + salt));
}
HD inline double hash_u01(uint64_t key, uint32_t g) {
    return (double)(mix13(key ^ ((uint64_t)g * 0xd1b54a32d192ed03ULL)) >> 11) * 0x1.0p-53;
}
HD inline uint64_t hash_u64(uint64_t key, uint32_t g) { return mix13(key ^ ((uint64_t)g * 0xd1b54a32d192ed03ULL)); }

/* xoshiro256** for the serial initialisation (identical to the reference) */
typedef struct { uint64_t s[4]; } rng_t;
static inline uint64_t rotl64(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }
static uint64_t rng_next(rng_t *r) {
    uint64_t *s = r->s;
    const uint64_t result = rotl64(s[1] * 5, 7) * 9;
    const uint64_t t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl64(s[3], 45);
    return result;
}
static void rng_seed(rng_t *r, uint64_t seed) {
    uint64_t z = seed;
    for (int k = 0; k < 4; k++) {
        z += 0x9e3779b97f4a7c15ULL;
        r->s[k] = mix13(z);
    }
}
static double rng_unif(rng_t *r) { return (double)(rng_next(r) >> 11) * 0x1.0p-53; }
static double rng_normal(rng_t *r) {
    double u1 = rng_unif(r), u2 = rng_unif(r);
    if (u1 < 1e-300) u1 = 1e-300;
    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

/* ================================================================== params */
typedef struct {
    double L, rho, dt, lambda, gamma, kT;
    double k_bond, r0, k_angle;
    int lip_nH, lip_nT;
    char lip_arch[16]; /* memB */
    double r0_head, k_head, cos_head;
    int lip_tie;
    int syn_nN;
    double a[NTYPES][NTYPES];
    long steps, snap_every, stats_every, ckpt_every, log_every;
    int ckpt_keep;
    long warmup;
    int syn_tries;
    int syn_relax;
    int threads;
    int nsub;
    uint64_t seed;
    char init[64];
    char restart[1024];
    int restart_reseed;
    double walltime;
    int chem;
    long n_chem;
    double r_cat;
    double p_syn_a, p_syn_b, p_rep_a, p_rep_b, mu, p_ld, p_kd, p_nd;
    char feed[16];
    double p_feed, feed_cap;
    char vent_shape[16];
    double vent_x, vent_y, vent_r, vent_w;
    int events;
    double stir_A;
    int stir_n;
    double kT_amp, kT_period;
    double f_lip, f_Ka, f_Kb, c_N;
    double sigma;
    int feed_mode, vent_kind;
} Params;

enum { FEED_NONE = 0, FEED_UNIFORM = 1, FEED_VENT = 2 };
enum { VENT_DISK = 0, VENT_VSTRIP = 1, VENT_HSTRIP = 2 };
typedef enum { PT_INT, PT_LONG, PT_DBL, PT_STR, PT_U64 } ptype_t;
typedef struct {
    const char *key;
    ptype_t t;
    size_t off;
    size_t sz;
    const char *def;
    const char *help;
} pdef_t;

#define OFF(f) offsetof(Params, f), sizeof(((Params *)0)->f)
/* identical to engine/oercel.c + the memB keys, same order, defaults and help texts */
static const pdef_t PDEFS[] = {
    {"L", PT_DBL, OFF(L), "64", "box side (rc units); N = round(rho*L*L)"},
    {"rho", PT_DBL, OFF(rho), "3", "bead number density"},
    {"dt", PT_DBL, OFF(dt), "0.03", "time step"},
    {"lambda", PT_DBL, OFF(lambda), "0.65", "Groot-Warren velocity-prediction lambda"},
    {"gamma", PT_DBL, OFF(gamma), "4.5", "DPD friction; sigma = sqrt(2*gamma*kT) is derived"},
    {"kT", PT_DBL, OFF(kT), "1", "thermostat temperature"},
    {"k_bond", PT_DBL, OFF(k_bond), "100", "harmonic bond constant, U = k/2 (r-r0)^2"},
    {"r0", PT_DBL, OFF(r0), "0.5", "bond rest length"},
    {"k_angle", PT_DBL, OFF(k_angle), "10", "angle constant, U = k (1 - cos theta) on consecutive triplets"},
    {"lip_nH", PT_INT, OFF(lip_nH), "1", "head beads per lipid"},
    {"lip_nT", PT_INT, OFF(lip_nT), "3", "tail beads per lipid (linear) or per tail (pi, y)"},
    {"lip_arch", PT_STR, OFF(lip_arch), "linear", "lipid architecture: linear (lip_nH heads then lip_nT tails), pi (2 bonded heads, each carrying a tail of lip_nT beads), y (1 head carrying two tails of lip_nT beads) or bola (asymmetric membrane-spanning macrocycle: head pair, two tails of lip_nT beads, one head on the other end)"},
    {"r0_head", PT_DBL, OFF(r0_head), "0.5", "pi: rest length of the head-head bond (and of the optional tie bond)"},
    {"k_head", PT_DBL, OFF(k_head), "0", "pi/y: junction angle term U = k_head (cos theta - cos_head)^2 at the branch beads (theta = deviation from straight; 0 = free)"},
    {"cos_head", PT_DBL, OFF(cos_head), "0", "pi/y: preferred cos of the junction deviation angle (0 = 90 degrees)"},
    {"lip_tie", PT_INT, OFF(lip_tie), "0", "pi/y: number of ladder rungs: bonds between tail beads Ta_m and Tb_m, m = 1..lip_tie (pi: rest r0_head; y: rest 1.2 r0)"},
    {"syn_nN", PT_INT, OFF(syn_nN), "0", "lipid synthesis: number of N consumed (0 = all beads of the lipid); the remaining beads of the new lipid are the nearest W beads of the catalyst"},
    {"steps", PT_LONG, OFF(steps), "10000", "run until this absolute step number"},
    {"snap_every", PT_LONG, OFF(snap_every), "1000", "snapshot interval (0 = none)"},
    {"stats_every", PT_LONG, OFF(stats_every), "100", "stats.csv interval (0 = none)"},
    {"ckpt_every", PT_LONG, OFF(ckpt_every), "10000", "checkpoint interval (0 = only at the end)"},
    {"ckpt_keep", PT_INT, OFF(ckpt_keep), "0", "1 = also keep ckpt_<step>.bin copies"},
    {"log_every", PT_LONG, OFF(log_every), "1000", "log line interval"},
    {"warmup", PT_LONG, OFF(warmup), "1000", "fresh soup starts: repulsion above 25 is ramped in linearly over the first warmup steps (0 = off; not applied after restart)"},
    {"threads", PT_INT, OFF(threads), "2", "OpenMP threads"},
    {"nsub", PT_INT, OFF(nsub), "4", "performance only: y sub-cells per unit cell (1..8); same physics, different round-off order"},
    {"seed", PT_U64, OFF(seed), "1", "random seed"},
    {"init", PT_STR, OFF(init), "soup", "soup (random well-mixed start) or restart (continue a checkpoint of a soup run)"},
    {"restart", PT_STR, OFF(restart), "", "checkpoint file; if non-empty the run restarts from it"},
    {"restart_reseed", PT_INT, OFF(restart_reseed), "0", "1 = on restart use this ini's seed (branch) instead of the checkpoint's"},
    {"walltime", PT_DBL, OFF(walltime), "0", "stop cleanly (with checkpoint) after this many seconds (0 = off)"},
    {"chem", PT_INT, OFF(chem), "1", "1 = chemistry on (reactions, decay and food supply)"},
    {"n_chem", PT_LONG, OFF(n_chem), "10", "chemistry check interval (steps); all p_* are per check"},
    {"r_cat", PT_DBL, OFF(r_cat), "1.2", "catalyst reaction radius"},
    {"syn_tries", PT_INT, OFF(syn_tries), "8", "new lipid: orientation = lowest overlap energy of this many random ones (1 = purely random)"},
    {"syn_relax", PT_INT, OFF(syn_relax), "20", "new lipid: steepest-descent iterations moving only its own beads (step <= 0.05 each; 0 = off)"},
    {"p_syn_a", PT_DBL, OFF(p_syn_a), "0.02", "lipid synthesis probability per check, Ka"},
    {"p_syn_b", PT_DBL, OFF(p_syn_b), "0.06", "lipid synthesis probability per check, Kb"},
    {"p_rep_a", PT_DBL, OFF(p_rep_a), "0.001", "catalyst replication probability per check, Ka"},
    {"p_rep_b", PT_DBL, OFF(p_rep_b), "0.001", "catalyst replication probability per check, Kb"},
    {"mu", PT_DBL, OFF(mu), "0.02", "mutation probability per replication (a<->b)"},
    {"p_ld", PT_DBL, OFF(p_ld), "2e-4", "lipid decay probability per molecule per check"},
    {"p_kd", PT_DBL, OFF(p_kd), "5e-4", "catalyst decay probability per check"},
    {"p_nd", PT_DBL, OFF(p_nd), "1e-4", "nutrient decay probability per check"},
    {"feed", PT_STR, OFF(feed), "uniform", "food supply W -> N, structure blind: none, uniform (every W anywhere) or vent (every W inside the fixed vent region)"},
    {"p_feed", PT_DBL, OFF(p_feed), "1e-3", "probability per chemistry check that an eligible W becomes N"},
    {"feed_cap", PT_DBL, OFF(feed_cap), "0.12", "global cap on the nutrient fraction nN/N_beads: conversions that would exceed it are dropped at random (0 = no cap)"},
    {"vent_shape", PT_STR, OFF(vent_shape), "disk", "feed = vent: disk (radius vent_r around (vent_x, vent_y)), vstrip (abs(x - vent_x) < vent_w/2, all y) or hstrip (abs(y - vent_y) < vent_w/2, all x)"},
    {"vent_x", PT_DBL, OFF(vent_x), "-1", "vent centre x (-1 = L/2); fixed coordinates"},
    {"vent_y", PT_DBL, OFF(vent_y), "-1", "vent centre y (-1 = L/2); fixed coordinates"},
    {"vent_r", PT_DBL, OFF(vent_r), "5", "vent disk radius"},
    {"vent_w", PT_DBL, OFF(vent_w), "4", "vent strip width"},
    {"events", PT_INT, OFF(events), "1", "1 = write events.csv"},
    {"stir_A", PT_DBL, OFF(stir_A), "0", "stirring: Kolmogorov body force f_x = stir_A sin(2 pi stir_n y / L) on every bead (net force removed; 0 = off)"},
    {"stir_n", PT_INT, OFF(stir_n), "1", "stirring: number of sine periods across the box"},
    {"kT_amp", PT_DBL, OFF(kT_amp), "0", "temperature cycle: kT(t) = kT + kT_amp sin(2 pi t / kT_period), applied through sigma (0 = off)"},
    {"kT_period", PT_DBL, OFF(kT_period), "1000", "temperature cycle period (time units)"},
    {"f_lip", PT_DBL, OFF(f_lip), "0.10", "soup: fraction of beads in lipids"},
    {"f_Ka", PT_DBL, OFF(f_Ka), "0.005", "soup: fraction of beads that are Ka"},
    {"f_Kb", PT_DBL, OFF(f_Kb), "0", "soup: fraction of beads that are Kb"},
    {"c_N", PT_DBL, OFF(c_N), "0.12", "soup: initial nutrient fraction"},
};
static const char *REMOVED_KEYS[] = {"seed_R", "seed_spacing", "seed_cN_in", "seed_nKa", "feed_every", "feed_grid", "feed_tmin"};
#define NPDEFS ((int)(sizeof(PDEFS) / sizeof(PDEFS[0])))

static void default_amatrix(Params *P) {
    for (int i = 0; i < NTYPES; i++)
        for (int j = 0; j < NTYPES; j++) P->a[i][j] = 25.0;
#define SETA(i, j, v) (P->a[i][j] = P->a[j][i] = (v))
    SETA(TW, TH, 20.0);
    SETA(TW, TT, 80.0);
    SETA(TH, TT, 50.0);
    SETA(TN, TW, 25.0);
    SETA(TN, TH, 25.0);
    SETA(TN, TT, 40.0);
    for (int k = TKA; k <= TKB; k++) {
        SETA(k, TW, 25.0);
        SETA(k, TH, 30.0);
        SETA(k, TT, 120.0);
        SETA(k, TN, 25.0);
    }
#undef SETA
}

static int type_from_name(const char *s) {
    for (int t = 0; t < NTYPES; t++)
        if (strcmp(s, TNAME[t]) == 0) return t;
    if (strcmp(s, "K") == 0) return -2;
    return -1;
}

static char *trim(char *s) {
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r' || e[-1] == '\n')) *--e = 0;
    return s;
}

static void set_param(Params *P, const char *key, const char *val) {
    if (strncmp(key, "a_", 2) == 0) {
        char buf[64];
        snprintf(buf, sizeof buf, "%s", key + 2);
        char *us = strchr(buf, '_');
        if (!us) die("bad repulsion key '%s' (use a_X_Y)", key);
        *us = 0;
        int t1 = type_from_name(buf), t2 = type_from_name(us + 1);
        if (t1 == -1 || t2 == -1) die("bad repulsion key '%s'", key);
        char *end;
        double v = strtod(val, &end);
        if (end == val) die("bad value for %s: '%s'", key, val);
        int l1[2], n1 = 0, l2[2], n2 = 0;
        if (t1 == -2) { l1[n1++] = TKA; l1[n1++] = TKB; } else l1[n1++] = t1;
        if (t2 == -2) { l2[n2++] = TKA; l2[n2++] = TKB; } else l2[n2++] = t2;
        for (int i = 0; i < n1; i++)
            for (int j = 0; j < n2; j++) P->a[l1[i]][l2[j]] = P->a[l2[j]][l1[i]] = v;
        return;
    }
    for (int k = 0; k < NPDEFS; k++) {
        const pdef_t *d = &PDEFS[k];
        if (strcmp(d->key, key) != 0) continue;
        char *p = (char *)P + d->off;
        char *end;
        switch (d->t) {
        case PT_INT: {
            long v = strtol(val, &end, 10);
            if (end == val || *trim(end)) die("bad integer for %s: '%s'", key, val);
            *(int *)p = (int)v;
        } break;
        case PT_LONG: {
            double v = strtod(val, &end);
            if (end == val || *trim(end)) die("bad integer for %s: '%s'", key, val);
            *(long *)p = (long)llround(v);
        } break;
        case PT_U64: {
            unsigned long long v = strtoull(val, &end, 0);
            if (end == val || *trim(end)) die("bad integer for %s: '%s'", key, val);
            *(uint64_t *)p = (uint64_t)v;
        } break;
        case PT_DBL: {
            double v = strtod(val, &end);
            if (end == val || *trim(end)) die("bad number for %s: '%s'", key, val);
            *(double *)p = v;
        } break;
        case PT_STR:
            if (strlen(val) >= d->sz) die("value too long for %s", key);
            strcpy(p, val);
            break;
        }
        return;
    }
    for (size_t k = 0; k < sizeof REMOVED_KEYS / sizeof REMOVED_KEYS[0]; k++)
        if (!strcmp(key, REMOVED_KEYS[k]))
            die("parameter '%s' was removed: init = seeded and the flood-fill food supply violate SPEC section 0 "
                "(see engine/README.md, 'Food supply')", key);
    die("unknown parameter '%s'", key);
}

static int is_generic_akey(const char *key) {
    if (strncmp(key, "a_", 2) != 0) return 0;
    char buf[64];
    snprintf(buf, sizeof buf, "%s", key + 2);
    char *us = strchr(buf, '_');
    if (!us) return 0;
    *us = 0;
    return strcmp(buf, "K") == 0 || strcmp(us + 1, "K") == 0;
}

typedef struct { char key[64]; char val[1024]; } kv_t;

static int read_ini(const char *path, kv_t **out) {
    FILE *f = fopen(path, "r");
    if (!f) die("cannot open parameter file %s: %s", path, strerror(errno));
    int n = 0, cap = 64;
    kv_t *kv = (kv_t *)malloc(cap * sizeof(kv_t));
    char line[2048];
    int ln = 0;
    while (fgets(line, sizeof line, f)) {
        ln++;
        char *h = strchr(line, '#');
        if (h) *h = 0;
        char *s = trim(line);
        if (!*s) continue;
        char *eq = strchr(s, '=');
        if (!eq) die("%s:%d: expected key = value", path, ln);
        *eq = 0;
        char *k = trim(s), *v = trim(eq + 1);
        if (n == cap) kv = (kv_t *)realloc(kv, (cap *= 2) * sizeof(kv_t));
        snprintf(kv[n].key, sizeof kv[n].key, "%s", k);
        snprintf(kv[n].val, sizeof kv[n].val, "%s", v);
        n++;
    }
    fclose(f);
    *out = kv;
    return n;
}

/* ------------------------------------------------------------------ molecule template (memB)
 * A lipid is a fixed template: bead types by position (heads first), bonds (position
 * pairs with a rest length), angle terms on position triplets.  The beads of one molecule
 * are linked through nxt[] in position order (mpos = position).  For lip_arch = linear the
 * template reproduces the original engine exactly. */
enum { ARCH_LINEAR = 0, ARCH_PI = 1, ARCH_Y = 2, ARCH_BOLA = 3 };
typedef struct {
    int arch, mlen, nH, nT;
    int nb;
    int bi[MAXMB], bj[MAXMB];
    double br0[MAXMB];
    int na;
    int ai[MAXMB], aj[MAXMB], ak[MAXMB];
    int akind[MAXMB]; /* 0: U = K (1 - cos th);  1: U = K (cos th - c0)^2 */
    double aK[MAXMB], ac0[MAXMB];
    double px[MAXMLEN], py[MAXMLEN]; /* template coordinates (centroid 0), long axis along +x */
    double ix[MAXMLEN], iy[MAXMLEN]; /* soup-init offsets relative to bead 0 */
} mol_t;
#if OG_CUDA
__constant__ mol_t c_mol;
#endif
static mol_t g_mol;
#ifdef __CUDA_ARCH__
#define MOL c_mol
#else
#define MOL g_mol
#endif

static void mol_bond(mol_t *M, int i, int j, double r0) {
    M->bi[M->nb] = i; M->bj[M->nb] = j; M->br0[M->nb] = r0; M->nb++;
}
static void mol_angle(mol_t *M, int i, int j, int k, int kind, double K, double c0) {
    if (K == 0.0) return;
    M->ai[M->na] = i; M->aj[M->na] = j; M->ak[M->na] = k;
    M->akind[M->na] = kind; M->aK[M->na] = K; M->ac0[M->na] = c0; M->na++;
}
static void mol_chain(mol_t *M, const int *c, int n, double r0, double ka) {
    for (int b = 0; b + 1 < n; b++) mol_bond(M, c[b], c[b + 1], r0);
    for (int b = 0; b + 2 < n; b++) mol_angle(M, c[b], c[b + 1], c[b + 2], 0, ka, 0.0);
}

static void mol_build(const Params *P) {
    mol_t *M = &g_mol;
    memset(M, 0, sizeof *M);
    const double r0 = P->r0;
    const int nT = P->lip_nT;
    M->nT = nT;
    if (!strcmp(P->lip_arch, "linear")) {
        M->arch = ARCH_LINEAR;
        M->nH = P->lip_nH;
        M->mlen = P->lip_nH + nT;
        if (P->lip_nH < 1 || nT < 1 || M->mlen > MAXMLEN) die("lipid length must be 2..%d with >=1 head and tail", MAXMLEN);
        for (int b = 0; b + 1 < M->mlen; b++) mol_bond(M, b, b + 1, r0);
        for (int b = 0; b + 2 < M->mlen; b++) mol_angle(M, b, b + 1, b + 2, 0, P->k_angle, 0.0);
        for (int b = 0; b < M->mlen; b++) {
            M->px[b] = (b - 0.5 * (M->mlen - 1)) * r0;
            M->py[b] = 0.0;
            M->ix[b] = b * r0;
            M->iy[b] = 0.0;
        }
        return;
    }
    if (nT < 1) die("lip_nT must be >= 1");
    int ca[MAXMLEN + 2], cb[MAXMLEN + 2];
    if (!strcmp(P->lip_arch, "pi")) {
        M->arch = ARCH_PI;
        M->nH = 2;
        M->mlen = 2 + 2 * nT;
        if (M->mlen > MAXMLEN) die("pi lipid with lip_nT=%d has %d beads (max %d)", nT, M->mlen, MAXMLEN);
        const double h = P->r0_head;
        mol_bond(M, 0, 1, h);
        ca[0] = 0; cb[0] = 1;
        for (int k = 1; k <= nT; k++) { ca[k] = 1 + k; cb[k] = 1 + nT + k; }
        mol_chain(M, ca, nT + 1, r0, P->k_angle);
        mol_chain(M, cb, nT + 1, r0, P->k_angle);
        for (int m = 1; m <= P->lip_tie && m <= nT; m++) mol_bond(M, ca[m], cb[m], h);
        mol_angle(M, 1, 0, ca[1], 1, P->k_head, P->cos_head);
        mol_angle(M, 0, 1, cb[1], 1, P->k_head, P->cos_head);
        M->px[0] = 0.0; M->py[0] = -0.5 * h;
        M->px[1] = 0.0; M->py[1] = 0.5 * h;
        for (int k = 1; k <= nT; k++) {
            M->px[ca[k]] = k * r0; M->py[ca[k]] = -0.5 * h;
            M->px[cb[k]] = k * r0; M->py[cb[k]] = 0.5 * h;
        }
    } else if (!strcmp(P->lip_arch, "y")) {
        M->arch = ARCH_Y;
        M->nH = 1;
        M->mlen = 1 + 2 * nT;
        if (M->mlen > MAXMLEN) die("y lipid with lip_nT=%d has %d beads (max %d)", nT, M->mlen, MAXMLEN);
        ca[0] = 0; cb[0] = 0;
        for (int k = 1; k <= nT; k++) { ca[k] = k; cb[k] = nT + k; }
        mol_chain(M, ca, nT + 1, r0, P->k_angle);
        mol_chain(M, cb, nT + 1, r0, P->k_angle);
        for (int m = 1; m <= P->lip_tie && m <= nT; m++) mol_bond(M, ca[m], cb[m], 1.2 * r0);
        mol_angle(M, ca[1], 0, cb[1], 1, P->k_head, P->cos_head);
        M->px[0] = 0.0; M->py[0] = 0.0;
        for (int k = 1; k <= nT; k++) {
            M->px[ca[k]] = 0.8 * r0 + (k - 1) * r0; M->py[ca[k]] = -0.6 * r0;
            M->px[cb[k]] = 0.8 * r0 + (k - 1) * r0; M->py[cb[k]] = 0.6 * r0;
        }
    } else if (!strcmp(P->lip_arch, "bola")) {
        M->arch = ARCH_BOLA;
        M->nH = 3;
        M->mlen = 3 + 2 * nT;
        if (M->mlen > MAXMLEN) die("bola lipid with lip_nT=%d has %d beads (max %d)", nT, M->mlen, MAXMLEN);
        const double h = P->r0_head;
        mol_bond(M, 0, 1, h);
        ca[0] = 0; cb[0] = 1;
        for (int k = 1; k <= nT; k++) { ca[k] = 2 + k; cb[k] = 2 + nT + k; }
        ca[nT + 1] = 2; cb[nT + 1] = 2;
        mol_chain(M, ca, nT + 2, r0, P->k_angle);
        mol_chain(M, cb, nT + 2, r0, P->k_angle);
        for (int m = 1; m <= P->lip_tie && m <= nT; m++) mol_bond(M, ca[m], cb[m], h * (1.0 - (double)m / (nT + 1)));
        mol_angle(M, 1, 0, ca[1], 1, P->k_head, P->cos_head);
        mol_angle(M, 0, 1, cb[1], 1, P->k_head, P->cos_head);
        const double X = sqrt((nT + 1) * r0 * (nT + 1) * r0 - 0.25 * h * h);
        M->px[0] = 0.0; M->py[0] = -0.5 * h;
        M->px[1] = 0.0; M->py[1] = 0.5 * h;
        M->px[2] = X; M->py[2] = 0.0;
        for (int k = 1; k <= nT; k++) {
            const double f = (double)k / (nT + 1);
            M->px[ca[k]] = f * X; M->py[ca[k]] = -0.5 * h * (1.0 - f);
            M->px[cb[k]] = f * X; M->py[cb[k]] = 0.5 * h * (1.0 - f);
        }
    } else die("lip_arch must be linear, pi, y or bola");
    double mx = 0, my = 0;
    for (int b = 0; b < M->mlen; b++) { mx += M->px[b]; my += M->py[b]; }
    mx /= M->mlen; my /= M->mlen;
    for (int b = 0; b < M->mlen; b++) { M->px[b] -= mx; M->py[b] -= my; }
    for (int b = 0; b < M->mlen; b++) { M->ix[b] = M->px[b] - M->px[0]; M->iy[b] = M->py[b] - M->py[0]; }
}

static void finalize_params(Params *P) {
    P->sigma = sqrt(2.0 * P->gamma * P->kT);
    mol_build(P);
    if (P->syn_nN < 0 || P->syn_nN > g_mol.mlen) die("syn_nN must be 0..%d", g_mol.mlen);
    if (P->r0_head <= 0) die("r0_head must be > 0");
    if (P->L < 8) die("L must be >= 8");
    if (P->dt <= 0) die("dt must be > 0");
    if (P->threads < 1) P->threads = 1;
    if (P->nsub < 1 || P->nsub > 8) die("nsub must be 1..8");
    if (P->n_chem < 1) P->n_chem = 1;
    if (P->syn_tries < 1) P->syn_tries = 1;
    if (P->warmup < 0) P->warmup = 0;
    if (!strcmp(P->init, "seeded"))
        die("init = seeded was removed (SPEC section 0): the only start state is a random soup or a checkpoint of one");
    if (strcmp(P->init, "soup") && strcmp(P->init, "restart")) die("init must be soup or restart");
    if (!strcmp(P->init, "restart") && !P->restart[0]) die("init = restart needs restart = <checkpoint>");
    if (!strcmp(P->feed, "none") || !strcmp(P->feed, "0")) { P->feed_mode = FEED_NONE; strcpy(P->feed, "none"); }
    else if (!strcmp(P->feed, "uniform")) P->feed_mode = FEED_UNIFORM;
    else if (!strcmp(P->feed, "vent")) P->feed_mode = FEED_VENT;
    else if (!strcmp(P->feed, "1"))
        die("feed = 1 (flood fill of the 'outside medium') was removed (SPEC section 0); use feed = uniform, vent or none");
    else die("feed must be none, uniform or vent");
    if (P->p_feed < 0 || P->p_feed > 1) die("p_feed must be in [0, 1]");
    if (P->feed_cap < 0 || P->feed_cap >= 1) die("feed_cap must be in [0, 1) (0 = no cap)");
    if (!strcmp(P->vent_shape, "disk")) P->vent_kind = VENT_DISK;
    else if (!strcmp(P->vent_shape, "vstrip")) P->vent_kind = VENT_VSTRIP;
    else if (!strcmp(P->vent_shape, "hstrip")) P->vent_kind = VENT_HSTRIP;
    else die("vent_shape must be disk, vstrip or hstrip");
    if (P->vent_x < 0) P->vent_x = 0.5 * P->L;
    if (P->vent_y < 0) P->vent_y = 0.5 * P->L;
    if (P->feed_mode == FEED_VENT) {
        if (P->vent_x >= P->L || P->vent_y >= P->L) die("vent_x and vent_y must lie in [0, L)");
        if (P->vent_kind == VENT_DISK && (P->vent_r <= 0 || P->vent_r >= 0.5 * P->L)) die("vent_r must be in (0, L/2)");
        if (P->vent_kind != VENT_DISK && (P->vent_w <= 0 || P->vent_w > P->L)) die("vent_w must be in (0, L]");
    }
    if (P->stir_n < 1) die("stir_n must be >= 1");
    if (P->kT <= 0) die("kT must be > 0");
    if (fabs(P->kT_amp) >= P->kT) die("|kT_amp| must be < kT (the temperature must stay positive)");
    if (P->kT_amp != 0 && P->kT_period <= 0) die("kT_period must be > 0");
}

static inline double kT_at(const Params *P, double t) {
    return P->kT_amp == 0.0 ? P->kT : P->kT + P->kT_amp * sin(2.0 * M_PI * t / P->kT_period);
}

static void write_params(const Params *P, const char *path, int argc_over, char **over) {
    FILE *f = fopen(path, "w");
    if (!f) die("cannot write %s", path);
    fprintf(f, "# Oercel parameters actually used (all keys, defaults filled in)\n");
    if (argc_over > 0) {
        fprintf(f, "# command-line overrides:");
        for (int i = 0; i < argc_over; i++) fprintf(f, " %s", over[i]);
        fprintf(f, "\n");
    }
    for (int k = 0; k < NPDEFS; k++) {
        const pdef_t *d = &PDEFS[k];
        const char *p = (const char *)P + d->off;
        switch (d->t) {
        case PT_INT: fprintf(f, "%s = %d", d->key, *(const int *)p); break;
        case PT_LONG: fprintf(f, "%s = %ld", d->key, *(const long *)p); break;
        case PT_U64: fprintf(f, "%s = %llu", d->key, (unsigned long long)*(const uint64_t *)p); break;
        case PT_DBL: fprintf(f, "%s = %.17g", d->key, *(const double *)p); break;
        case PT_STR: fprintf(f, "%s = %s", d->key, p); break;
        }
        fprintf(f, "    # %s\n", d->help);
    }
    fprintf(f, "# derived: sigma = %.17g%s\n", P->sigma,
            P->kT_amp != 0 ? " at kT; with the temperature cycle sigma(t) = sqrt(2 gamma kT(t))" : "");
    fprintf(f, "# repulsion matrix a_ij (symmetric)\n");
    for (int i = 0; i < NTYPES; i++)
        for (int j = i; j < NTYPES; j++) fprintf(f, "a_%s_%s = %.17g\n", TNAME[i], TNAME[j], P->a[i][j]);
    fclose(f);
}

/* ================================================================== device memory, kernels */
#if OG_CUDA
static void ck(cudaError_t e, const char *what) {
    if (e != cudaSuccess) die("CUDA error in %s: %s", what, cudaGetErrorString(e));
}
static int g_sync_each = 0; /* OERCEL_SYNC=1: synchronise after every kernel (debugging) */
static void *dmalloc(size_t n) {
    void *p = NULL;
    cudaError_t e = cudaMalloc(&p, n ? n : 64);
    if (e != cudaSuccess) die("out of GPU memory allocating %zu bytes (%s)", n, cudaGetErrorString(e));
    return p;
}
static void dfree(void *p) {
    if (p) cudaFree(p);
}
static void h2d(void *d, const void *h, size_t n) {
    if (n) ck(cudaMemcpy(d, h, n, cudaMemcpyHostToDevice), "copy to device");
}
static void d2h(void *h, const void *d, size_t n) {
    if (n) ck(cudaMemcpy(h, d, n, cudaMemcpyDeviceToHost), "copy to host (or an earlier kernel)");
}
static void dzero(void *d, size_t n) {
    if (n) ck(cudaMemset(d, 0, n), "memset");
}
static void dsync(void) { ck(cudaDeviceSynchronize(), "synchronize (or an earlier kernel)"); }

template <class F> __global__ void k_pfor(long n, F f) {
    const long i = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) f((int)i);
}
static int g_tpb = 256;
template <class F> static void pfor(long n, const F &f) {
    if (n <= 0) return;
    const int tpb = g_tpb;
    k_pfor<<<(unsigned)((n + tpb - 1) / tpb), tpb>>>(n, f);
    ck(cudaGetLastError(), "kernel launch");
    if (g_sync_each) ck(cudaDeviceSynchronize(), "kernel execution");
}
/* imbalanced work (chemistry): small blocks */
template <class F> static void pfor_dyn(long n, const F &f) {
    if (n <= 0) return;
    k_pfor<<<(unsigned)((n + 31) / 32), 32>>>(n, f);
    ck(cudaGetLastError(), "kernel launch");
    if (g_sync_each) ck(cudaDeviceSynchronize(), "kernel execution");
}
#else
static void *dmalloc(size_t n) { return xmalloc(n); }
static void dfree(void *p) { free(p); }
static void h2d(void *d, const void *h, size_t n) {
    if (n) memcpy(d, h, n);
}
static void d2h(void *h, const void *d, size_t n) {
    if (n) memcpy(h, d, n);
}
static void dzero(void *d, size_t n) {
    if (n) memset(d, 0, n);
}
static void dsync(void) {}
template <class F> static void pfor(long n, const F &f) {
#pragma omp parallel for schedule(static)
    for (long i = 0; i < n; i++) f((int)i);
}
template <class F> static void pfor_dyn(long n, const F &f) {
#pragma omp parallel for schedule(dynamic, 1)
    for (long i = 0; i < n; i++) f((int)i);
}
#endif
template <class T> static T *dnew(size_t n) { return (T *)dmalloc(n * sizeof(T)); }
static void dset_int(int *d, int v) { h2d(d, &v, sizeof v); }
static void dset_dbl(double *d, double v) { h2d(d, &v, sizeof v); }

/* Deterministic reductions: level 1 = RED_NT1 threads, thread t combines elements
 * t, t+RED_NT1, ... in order; level 2 = RED_NT2 threads combine the partials with a
 * fixed stride; the host combines the RED_NT2 results in order.  The partition does
 * not depend on the device or the thread count, so the result is reproducible. */
#define RED_NT1 16384
#define RED_NT2 64
static void *g_redbuf = NULL;
static size_t g_redsz = 0;
#if OG_CUDA
template <class T, class M, class C> __global__ void k_red1(long n, T zero, M map, C comb, T *part) {
    const int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= RED_NT1) return;
    T acc = zero;
    for (long i = t; i < n; i += RED_NT1) acc = comb(acc, map((int)i));
    part[t] = acc;
}
template <class T, class C> __global__ void k_red2(T zero, C comb, const T *part, T *out) {
    const int u = blockIdx.x * blockDim.x + threadIdx.x;
    if (u >= RED_NT2) return;
    T acc = zero;
    for (int t = u; t < RED_NT1; t += RED_NT2) acc = comb(acc, part[t]);
    out[u] = acc;
}
#endif
template <class T, class M, class C> static T dreduce(long n, T zero, const M &map, const C &comb) {
    const size_t need = (size_t)(RED_NT1 + RED_NT2) * sizeof(T);
    if (g_redsz < need) {
        dfree(g_redbuf);
        g_redbuf = dmalloc(need);
        g_redsz = need;
    }
    T *p1 = (T *)g_redbuf, *p2 = p1 + RED_NT1;
#if OG_CUDA
    k_red1<T, M, C><<<RED_NT1 / 128, 128>>>(n, zero, map, comb, p1);
    ck(cudaGetLastError(), "reduce launch");
    k_red2<T, C><<<1, RED_NT2>>>(zero, comb, p1, p2);
    ck(cudaGetLastError(), "reduce launch");
#else
#pragma omp parallel for schedule(static)
    for (int t = 0; t < RED_NT1; t++) {
        T acc = zero;
        for (long i = t; i < n; i += RED_NT1) acc = comb(acc, map((int)i));
        p1[t] = acc;
    }
    for (int u = 0; u < RED_NT2; u++) {
        T acc = zero;
        for (int t = u; t < RED_NT1; t += RED_NT2) acc = comb(acc, p1[t]);
        p2[u] = acc;
    }
#endif
    T h[RED_NT2];
    d2h(h, p2, sizeof h);
    T acc = zero;
    for (int u = 0; u < RED_NT2; u++) acc = comb(acc, h[u]);
    return acc;
}
struct SumD {
    HD double operator()(double a, double b) const { return a + b; }
};
struct SumL {
    HD long long operator()(long long a, long long b) const { return a + b; }
};

/* exclusive prefix sum of n ints (recursive, blocks of SCAN_B; integer, so exact) */
#define SCAN_B 64
static void dscan_rec(long n, const int *in, int *out, int *pool) {
    if (n <= SCAN_B) {
        pfor(1, KL(int) {
            int run = 0;
            for (long i = 0; i < n; i++) {
                const int v = in[i];
                out[i] = run;
                run += v;
            }
        });
        return;
    }
    const long nb = (n + SCAN_B - 1) / SCAN_B;
    int *bs = pool, *bss = pool + nb;
    pfor(nb, KL(int b) {
        const long i0 = (long)b * SCAN_B, i1 = i0 + SCAN_B < n ? i0 + SCAN_B : n;
        int sum = 0;
        for (long i = i0; i < i1; i++) sum += in[i];
        bs[b] = sum;
    });
    dscan_rec(nb, bs, bss, pool + 2 * nb);
    pfor(nb, KL(int b) {
        const long i0 = (long)b * SCAN_B, i1 = i0 + SCAN_B < n ? i0 + SCAN_B : n;
        int run = bss[b];
        for (long i = i0; i < i1; i++) {
            const int v = in[i];
            out[i] = run;
            run += v;
        }
    });
}
static long scan_pool_size(long n) {
    long s = 0;
    while (n > SCAN_B) {
        n = (n + SCAN_B - 1) / SCAN_B;
        s += 2 * n;
    }
    return s + 64;
}

/* ================================================================== system */
typedef struct {
    double dmax;    /* max |displacement| component of this step (chemistry steps) */
    double maxbond; /* running max bond length since the last stats row */
    int maxdc;      /* max cell displacement since the last sort */
    int err;        /* error bits (ERR_*) */
    int nev;        /* events in the device buffer */
    int nact;       /* active catalysts this check */
    int ndone;      /* executed active catalysts */
    int ndec;       /* decays this check */
    int nfc;        /* feed candidates this check */
    int pad;
} Status;
enum { ERR_SORT = 1, ERR_CHAIN = 2, ERR_EVOVF = 4 };

typedef struct {
    long long step, i;
    double x, y;
    unsigned long long key; /* order inside a step: phase << 60 | seq << 8 | sub */
    int kind, var;
} Event;
enum { EV_SYN, EV_REP, EV_MUT, EV_DLIP, EV_DK, EV_DN, EV_FEED };
static const char *EVNAME[] = {"syn", "rep", "mut", "dlip", "dK", "dN", "feed"};

/* device view, captured by value by every kernel */
typedef struct {
    int N, mlen, nH, ncx, ncy, ncell;
    double L, csx, csy, icsx, icsy;
    float csxf, csyf;
    double *x, *y, *vx, *vy, *fx, *fy; /* slot order; vx,vy = half-step velocity vh */
    float *vtx, *vty;                  /* Groot-Warren predicted velocity (force input) */
    uint8_t *type;
    uint32_t *gid;
    int32_t *nxt; /* slot of the next bead in the lipid, -1 if none */
    int8_t *mpos; /* position in the lipid (0 = first bead), -1 = not a lipid */
    int *cell;    /* cell of each slot at the last sort */
    int *cstart;  /* ncell + 1 */
    float4 *pv;   /* pair input: x,y relative to the own cell corner, vtx, vty */
    uint32_t *gt; /* gid | type << GIDBITS */
    float *atab;  /* 8x8 repulsion table in use (warm-up ramp) */
    Status *st;
    Event *ev;
    int evcap;
    int *lock; /* chemistry cell locks, INT_MAX = free */
} Dev;

typedef struct {
    Dev d;
    double *x2, *y2, *vx2, *vy2;
    float *vtx2, *vty2;
    uint8_t *type2;
    uint32_t *gid2;
    int32_t *nxt2;
    int8_t *mpos2;
    int *cell2, *cstart2;
    int *cnt, *cnew, *src, *dest, *scanpool;
    /* chemistry */
    int *act, *actlist, *done, *claimed;
    uint32_t *actg;
    int actcap;
    int *fcand;
    unsigned long long *fkey;
    int fcap;
    /* host side */
    int64_t step;
    double time;
    double t_anchor, dt_anchor;
    int64_t step_anchor;
    uint64_t seed, soup_seed;
    rng_t rng;
    std::vector<Event> *hev; /* host-made events (feed) waiting for the next flush */
    int nev_host;            /* last known device event count */
    float atab_host[64];
    int atab_valid;
    FILE *ef;
} Sys;

static Status get_status(Sys *s) {
    Status h;
    d2h(&h, s->d.st, sizeof h);
    s->nev_host = h.nev;
    return h;
}
static void check_err(Sys *s, const char *where) {
    Status h = get_status(s);
    if (h.err & ERR_SORT) die("%s: cell sort lost beads (a bead moved more than %d cells in one step: unstable run)", where, RMAX_GATHER);
    if (h.err & ERR_CHAIN) die("%s: broken lipid chain detected", where);
    if (h.err & ERR_EVOVF) die("%s: event buffer overflow (internal error)", where);
}

#if OG_CUDA
static size_t bytes_per_bead(void) {
    return 2 * (4 * sizeof(double) + 2 * sizeof(float) + 1 + 4 + 4 + 1 + 4) /* state x2 */ + 2 * sizeof(double) /* f */ +
           3 * sizeof(int) /* cnew src dest */ + sizeof(float4) + 4 /* pv gt */;
}
#endif

static void sys_alloc(Sys *s, int N, double L, int mlen, int nH) {
    memset(s, 0, sizeof *s);
    Dev &D = s->d;
    D.N = N;
    D.L = L;
    D.mlen = mlen;
    D.nH = nH;
    if ((unsigned)N > GIDMASK) die("N = %d beads exceeds the limit %u of this build", N, GIDMASK);
    D.ncx = (int)floor(L);
    D.ncy = (int)floor(L);
    D.ncell = D.ncx * D.ncy;
    D.csx = L / D.ncx;
    D.csy = L / D.ncy;
    D.icsx = D.ncx / L;
    D.icsy = D.ncy / L;
    D.csxf = (float)D.csx;
    D.csyf = (float)D.csy;
#if OG_CUDA
    {
        size_t fr = 0, tot = 0;
        ck(cudaMemGetInfo(&fr, &tot), "cudaMemGetInfo");
        const double need = (double)N * bytes_per_bead() + 6.0 * D.ncell * sizeof(int) + 64e6;
        logmsg("GPU memory: need ~%.2f GB, free %.2f of %.2f GB\n", need / 1e9, fr / 1e9, tot / 1e9);
        if (need > 0.97 * (double)fr) die("not enough GPU memory for N = %d beads (need ~%.2f GB, free %.2f GB)", N, need / 1e9, fr / 1e9);
    }
#endif
    D.x = dnew<double>(N); D.y = dnew<double>(N); D.vx = dnew<double>(N); D.vy = dnew<double>(N);
    D.fx = dnew<double>(N); D.fy = dnew<double>(N);
    D.vtx = dnew<float>(N); D.vty = dnew<float>(N);
    D.type = dnew<uint8_t>(N); D.gid = dnew<uint32_t>(N); D.nxt = dnew<int32_t>(N); D.mpos = dnew<int8_t>(N);
    D.cell = dnew<int>(N);
    D.cstart = dnew<int>(D.ncell + 1);
    D.pv = dnew<float4>(N);
    D.gt = dnew<uint32_t>(N);
    D.atab = dnew<float>(64);
    D.st = dnew<Status>(1);
    D.evcap = 1 << 16;
    D.ev = dnew<Event>(D.evcap);
    D.lock = dnew<int>(D.ncell);
    s->x2 = dnew<double>(N); s->y2 = dnew<double>(N); s->vx2 = dnew<double>(N); s->vy2 = dnew<double>(N);
    s->vtx2 = dnew<float>(N); s->vty2 = dnew<float>(N);
    s->type2 = dnew<uint8_t>(N); s->gid2 = dnew<uint32_t>(N); s->nxt2 = dnew<int32_t>(N); s->mpos2 = dnew<int8_t>(N);
    s->cell2 = dnew<int>(N);
    s->cstart2 = dnew<int>(D.ncell + 1);
    s->cnt = dnew<int>(D.ncell);
    s->cnew = dnew<int>(N);
    s->src = dnew<int>(N);
    s->dest = dnew<int>(N);
    s->scanpool = dnew<int>(scan_pool_size(D.ncell));
    s->actcap = 1024;
    s->act = dnew<int>(s->actcap); s->actlist = dnew<int>(s->actcap); s->done = dnew<int>(s->actcap);
    s->claimed = dnew<int>(s->actcap); s->actg = dnew<uint32_t>(s->actcap);
    s->fcap = 4096;
    s->fcand = dnew<int>(s->fcap);
    s->fkey = dnew<unsigned long long>(s->fcap);
    dzero(D.st, sizeof(Status));
    dzero(D.fx, N * sizeof(double));
    dzero(D.fy, N * sizeof(double));
    int *lock = D.lock;
    pfor(D.ncell, KL(int c) { lock[c] = INT_MAX; });
    s->hev = new std::vector<Event>();
}

/* ================================================================== geometry */
HD inline void wrap1(double *p, double L) {
    double v = *p;
    if (v < 0.0) {
        v += L;
        if (v >= L) v -= L;
    } else if (v >= L) {
        v -= L;
        if (v >= L || v < 0.0) v = fmod(v, L);
    }
    *p = v;
}
/* any finite v into [0, L) */
HD inline double wrap_any(double v, double L) {
    v = fmod(v, L);
    if (v < 0.0) v += L;
    if (v >= L) v -= L;
    return v;
}
HD inline double minimg(double d, double L) {
    const double h = 0.5 * L;
    if (d > h) d -= L;
    else if (d < -h) d += L;
    return d;
}
HD inline int wrapi(int v, int n) { return v < 0 ? v + n : (v >= n ? v - n : v); }
HD inline int cell_of(const Dev &D, double x, double y) {
    int cx = (int)(x * D.icsx), cy = (int)(y * D.icsy);
    if (cx >= D.ncx) cx = D.ncx - 1;
    if (cy >= D.ncy) cy = D.ncy - 1;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    return cy * D.ncx + cx;
}

/* ================================================================== cell sort
 * Stable sort of all slot arrays by cell.  Normal path ("local gather"): beads move at
 * most R cells per step, so the beads of new cell c are found by scanning the old cells
 * within R of c in increasing old-slot order -> exactly the stable counting sort, done
 * by one thread per cell without atomics on positions.  If R > RMAX_GATHER, or at start
 * / restart, a stable counting sort on the host computes the same permutation. */
static double g_t_sortfull = 0;
static long g_nsortfull = 0, g_maxR = 0; /* diagnostics: host full sorts, largest gather radius */
static void sort_cells(Sys *s, int full, int permf) {
    Dev D = s->d;
    const int N = D.N, nc = D.ncell;
    int *cnt = s->cnt, *cnew = s->cnew, *src = s->src, *dest = s->dest;
    dzero(cnt, (size_t)nc * sizeof(int));
    int track = !full;
    if (track) dset_int(&D.st->maxdc, 0);
    pfor(N, KL(int i) {
        const int c = cell_of(D, D.x[i], D.y[i]);
        cnew[i] = c;
        at_add(&cnt[c], 1);
        if (track) {
            const int co = D.cell[i];
            if (co != c) {
                int dx = c % D.ncx - co % D.ncx, dy = c / D.ncx - co / D.ncx;
                dx = dx < 0 ? -dx : dx;
                dy = dy < 0 ? -dy : dy;
                if (dx > D.ncx - dx) dx = D.ncx - dx;
                if (dy > D.ncy - dy) dy = D.ncy - dy;
                const int m = dx > dy ? dx : dy;
                if (m > at_load(&D.st->maxdc)) at_max(&D.st->maxdc, m);
            }
        }
    });
    int R = 1;
    if (track) {
        Status h = get_status(s);
        if (h.err) check_err(s, "sort");
        R = h.maxdc < 1 ? 1 : h.maxdc;
        if (R > g_maxR) g_maxR = R;
        if (R > RMAX_GATHER || 2 * R + 1 > D.ncx || 2 * R + 1 > D.ncy) full = 1;
    }
    int *csn = s->cstart2;
    dscan_rec(nc, cnt, csn, s->scanpool);
    pfor(1, KL(int) { csn[nc] = N; });
    if (!full) {
        const int *cso = D.cstart;
        pfor(nc, KL(int c) {
            const int cx = c % D.ncx, cy = c / D.ncx;
            int rows[2 * RMAX_GATHER + 1], cols[2 * RMAX_GATHER + 1], nr = 0, ncl = 0;
            for (int o = -R; o <= R; o++) { /* sorted, unique wrapped rows / columns */
                int v = wrapi(cy + o, D.ncy), b = nr++;
                while (b > 0 && rows[b - 1] > v) { rows[b] = rows[b - 1]; b--; }
                rows[b] = v;
                v = wrapi(cx + o, D.ncx);
                b = ncl++;
                while (b > 0 && cols[b - 1] > v) { cols[b] = cols[b - 1]; b--; }
                cols[b] = v;
            }
            const int base = csn[c], want = csn[c + 1] - base;
            int r = 0;
            for (int a = 0; a < nr; a++) {
                if (a > 0 && rows[a] == rows[a - 1]) continue;
                for (int b = 0; b < ncl; b++) {
                    if (b > 0 && cols[b] == cols[b - 1]) continue;
                    const int oc = rows[a] * D.ncx + cols[b];
                    const int j1 = cso[oc + 1];
                    for (int i = cso[oc]; i < j1; i++)
                        if (cnew[i] == c) {
                            if (r < want) {
                                src[base + r] = i;
                                dest[i] = base + r;
                            }
                            r++;
                        }
                }
            }
            if (r != want) at_or(&D.st->err, ERR_SORT);
        });
    } else {
        const double t0 = wtime();
        int *hc = (int *)xmalloc((size_t)N * sizeof(int));
        int *hs = (int *)xmalloc((size_t)N * sizeof(int));
        int *pos = (int *)xmalloc((size_t)(nc + 1) * sizeof(int));
        d2h(hc, cnew, (size_t)N * sizeof(int));
        d2h(pos, csn, (size_t)(nc + 1) * sizeof(int));
        for (int i = 0; i < N; i++) hs[pos[hc[i]]++] = i;
        h2d(src, hs, (size_t)N * sizeof(int));
        free(hc);
        free(hs);
        free(pos);
        pfor(N, KL(int d) { dest[src[d]] = d; });
        g_t_sortfull += wtime() - t0;
        g_nsortfull++;
    }
    double *fx2 = NULL, *fy2 = NULL;
    if (permf) {
        fx2 = dnew<double>(N);
        fy2 = dnew<double>(N);
    }
    double *x2 = s->x2, *y2 = s->y2, *vx2 = s->vx2, *vy2 = s->vy2;
    float *vtx2 = s->vtx2, *vty2 = s->vty2;
    uint8_t *type2 = s->type2;
    uint32_t *gid2 = s->gid2;
    int32_t *nxt2 = s->nxt2;
    int8_t *mpos2 = s->mpos2;
    int *cell2 = s->cell2;
    pfor(N, KL(int d) {
        const int si = src[d];
        const int c = cnew[si];
        const double xs = D.x[si], ys = D.y[si];
        x2[d] = xs;
        y2[d] = ys;
        vx2[d] = D.vx[si];
        vy2[d] = D.vy[si];
        const float tx = D.vtx[si], ty = D.vty[si];
        vtx2[d] = tx;
        vty2[d] = ty;
        const uint8_t t = D.type[si];
        type2[d] = t;
        const uint32_t g = D.gid[si];
        gid2[d] = g;
        mpos2[d] = D.mpos[si];
        const int32_t o = D.nxt[si];
        nxt2[d] = o < 0 ? -1 : dest[o];
        cell2[d] = c;
        const int cx = c % D.ncx, cy = c / D.ncx;
        D.pv[d] = make_float4((float)(xs - cx * D.csx), (float)(ys - cy * D.csy), tx, ty);
        D.gt[d] = g | ((uint32_t)t << GIDBITS);
        if (permf) {
            fx2[d] = D.fx[si];
            fy2[d] = D.fy[si];
        }
    });
    Dev &W = s->d;
    std::swap(W.x, s->x2); std::swap(W.y, s->y2); std::swap(W.vx, s->vx2); std::swap(W.vy, s->vy2);
    std::swap(W.vtx, s->vtx2); std::swap(W.vty, s->vty2);
    std::swap(W.type, s->type2); std::swap(W.gid, s->gid2); std::swap(W.nxt, s->nxt2); std::swap(W.mpos, s->mpos2);
    std::swap(W.cell, s->cell2);
    std::swap(W.cstart, s->cstart2);
    if (permf) {
        dfree(W.fx);
        dfree(W.fy);
        W.fx = fx2;
        W.fy = fy2;
    }
}

/* ================================================================== forces */
static double a_eff(const Params *P, int i, int j, int64_t step, int64_t warm_end) {
    const double a = P->a[i][j];
    if (step >= warm_end || P->warmup <= 0 || a <= 25.0) return a;
    const double f = 1.0 - (double)(warm_end - step) / (double)P->warmup;
    return 25.0 + (a - 25.0) * (f < 0 ? 0 : f);
}

/* sin(2 pi u): range reduction in double, polynomial in float (|error| < 1e-6) */
HD inline float sin2pi_f(double u) {
    u -= rint(u);
    const double a = fabs(u);
    const float r = (float)(a > 0.25 ? 0.5 - a : a);
    const float x = 6.28318530717958648f * r, x2 = x * x;
    float p = 1.6059044e-10f;
    p = p * x2 - 2.5052108e-08f;
    p = p * x2 + 2.7557319e-06f;
    p = p * x2 - 1.9841270e-04f;
    p = p * x2 + 8.3333333e-03f;
    p = p * x2 - 1.6666667e-01f;
    const float v = x + x * x2 * p;
    return u < 0.0 ? -v : v;
}

typedef struct {
    float gam, sdt;
    uint64_t sseed;
} PairPar;

/* bonded forces of one molecule (template bonds and angles); slots sl[], forces by
 * template position into fx[b], fy[b]; mb = max bond length */
HD inline void mol_forces(const double *x, const double *y, double L, const int *sl, double kb, double *fx, double *fy,
                          double *mb) {
    for (int q = 0; q < MOL.nb; q++) {
        const int bi = MOL.bi[q], bj = MOL.bj[q];
        const int i = sl[bi], j = sl[bj];
        const double dx = minimg(x[j] - x[i], L), dy = minimg(y[j] - y[i], L);
        const double r = sqrt(dx * dx + dy * dy);
        if (r > *mb) *mb = r;
        const double f = -kb * (r - MOL.br0[q]) / r;
        fx[bj] += f * dx; fy[bj] += f * dy;
        fx[bi] -= f * dx; fy[bi] -= f * dy;
    }
    for (int q = 0; q < MOL.na; q++) {
        const int pi_ = MOL.ai[q], pj = MOL.aj[q], pk = MOL.ak[q];
        const int i = sl[pi_], j = sl[pj], k = sl[pk];
        const double ax = minimg(x[j] - x[i], L), ay = minimg(y[j] - y[i], L);
        const double cxv = minimg(x[k] - x[j], L), cyv = minimg(y[k] - y[j], L);
        const double la = sqrt(ax * ax + ay * ay), lc = sqrt(cxv * cxv + cyv * cyv);
        const double ilac = 1.0 / (la * lc);
        const double cs = (ax * cxv + ay * cyv) * ilac;
        const double g = MOL.akind[q] == 0 ? -MOL.aK[q] : 2.0 * MOL.aK[q] * (cs - MOL.ac0[q]);
        const double dUax = g * (cxv * ilac - cs * ax / (la * la));
        const double dUay = g * (cyv * ilac - cs * ay / (la * la));
        const double dUcx = g * (ax * ilac - cs * cxv / (lc * lc));
        const double dUcy = g * (ay * ilac - cs * cyv / (lc * lc));
        fx[pi_] += dUax; fy[pi_] += dUay;
        fx[pj] += -dUax + dUcx; fy[pj] += -dUay + dUcy;
        fx[pk] -= dUcx; fy[pk] -= dUcy;
    }
}

static void upload_atab(Sys *s, const Params *P, int64_t step) {
    float a[64];
    memset(a, 0, sizeof a);
    for (int i = 0; i < NTYPES; i++)
        for (int j = 0; j < NTYPES; j++) a[8 * i + j] = (float)a_eff(P, i, j, step, g_warm_end);
    if (!s->atab_valid || memcmp(a, s->atab_host, sizeof a)) {
        h2d(s->d.atab, a, sizeof a);
        memcpy(s->atab_host, a, sizeof a);
        s->atab_valid = 1;
    }
}

#if OG_CUDA
static int g_pair_tpb = 0; /* OERCEL_PAIR_TPB */
#endif

/* forces of the configuration at time t (step): stirring body force (minus its mean),
 * DPD pair forces (full neighbour list: every pair is evaluated by both beads, with
 * bit-identical magnitudes, so F_ji = -F_ij exactly), bonded forces (one thread per
 * molecule, each bead belongs to one molecule -> no atomics). */
static void compute_forces(Sys *s, const Params *P, int64_t step, double t, int do_pair, int do_bond) {
    Dev D = s->d;
    const int N = D.N;
    upload_atab(s, P, step);
    PairPar pp;
    pp.gam = (float)P->gamma;
    pp.sdt = (float)(sqrt(2.0 * P->gamma * kT_at(P, t)) / sqrt(P->dt));
    pp.sseed = step_seed(s->seed, step);
    const int stir = P->stir_A != 0.0;
    double mean = 0.0;
    if (stir) {
        const double A = P->stir_A, kn = (double)P->stir_n / D.L;
        pfor(N, KL(int i) {
            D.fx[i] = A * (double)sin2pi_f(kn * D.y[i]);
            D.fy[i] = 0.0;
        });
        mean = dreduce(N, 0.0, KL(int i)->double { return D.fx[i]; }, SumD()) / N;
    }
    if (do_pair) {
#if OG_CUDA
        const int tpb_save = g_tpb;
        if (g_pair_tpb > 0) g_tpb = g_pair_tpb;
#endif
        pfor(N, KL(int i) {
            const float4 pi = ldg(D.pv + i);
            const uint32_t gti = ldg(D.gt + i);
            const uint32_t gi = gti & GIDMASK;
            const float *arow = D.atab + 8 * (gti >> GIDBITS);
            const int c = ldg(D.cell + i);
            const int cx = c % D.ncx, cy = c / D.ncx;
            float sx_ = 0.f, cx_ = 0.f, sy_ = 0.f, cy_ = 0.f; /* compensated sums */
            for (int oy = -1; oy <= 1; oy++) {
                int ry = cy + oy;
                ry += ry < 0 ? D.ncy : 0;
                ry -= ry >= D.ncy ? D.ncy : 0;
                const float shy = (float)oy * D.csyf;
                const float yi = pi.y;
                for (int ox = -1; ox <= 1; ox++) {
                    int rx = cx + ox;
                    rx += rx < 0 ? D.ncx : 0;
                    rx -= rx >= D.ncx ? D.ncx : 0;
                    const float shx = (float)ox * D.csxf;
                    const int nc = ry * D.ncx + rx;
                    const int j0 = ldg(D.cstart + nc), j1 = ldg(D.cstart + nc + 1);
                    for (int j = j0; j < j1; j++) {
                        const float4 pj = ldg(D.pv + j);
                        /* exactly antisymmetric in (i, j): fl(a - b) = -fl(b - a) */
                        const float dx = (pi.x - pj.x) - shx, dy = (yi - pj.y) - shy;
                        const float r2 = dx * dx + dy * dy;
                        if (r2 < 1.0f && r2 > 0.0f) {
                            const uint32_t gtj = ldg(D.gt + j);
                            const float ir = og_rsqrt(r2);
                            const float r = r2 * ir;
                            const float w = 1.0f - r;
                            const float rv = (dx * (pi.z - pj.z) + dy * (pi.w - pj.w)) * ir;
                            const float th = pair_theta_f(pp.sseed, gi, gtj & GIDMASK);
                            const float aij = ldg(arow + (gtj >> GIDBITS));
                            const float fm = w * (aij - pp.gam * w * rv + pp.sdt * th) * ir;
                            two_sum_acc(sx_, cx_, fmul_rn(fm, dx));
                            two_sum_acc(sy_, cy_, fmul_rn(fm, dy));
                        }
                    }
                }
            }
            const double base = stir ? D.fx[i] - mean : 0.0;
            D.fx[i] = base + ((double)sx_ + (double)cx_);
            D.fy[i] = (double)sy_ + (double)cy_;
        });
#if OG_CUDA
        g_tpb = tpb_save;
#endif
    } else if (!stir) {
        dzero(D.fx, (size_t)N * sizeof(double));
        dzero(D.fy, (size_t)N * sizeof(double));
    } else {
        pfor(N, KL(int i) { D.fx[i] -= mean; });
    }
    if (do_bond) {
        const double kb = P->k_bond;
        const int ml = D.mlen;
        pfor(N, KL(int h) {
            if (D.mpos[h] != 0) return;
            int sl[MAXMLEN];
            int n = 0;
            for (int d = h; d >= 0 && n < ml; d = D.nxt[d]) sl[n++] = d;
            if (n != ml) {
                at_or(&D.st->err, ERR_CHAIN);
                return;
            }
            double fxl[MAXMLEN], fyl[MAXMLEN], mb = 0.0;
            for (int b = 0; b < ml; b++) fxl[b] = fyl[b] = 0.0;
            mol_forces(D.x, D.y, D.L, sl, kb, fxl, fyl, &mb);
            for (int b = 0; b < ml; b++) {
                D.fx[sl[b]] += fxl[b];
                D.fy[sl[b]] += fyl[b];
            }
            at_maxpos(&D.st->maxbond, mb);
        });
    }
}

/* ================================================================== chemistry */
typedef struct {
    int64_t step;
    uint64_t seed;
    uint64_t ksyn, krep, kmu, kld, kkd, knd, kfeed, kcap;
    double psa, psb, pra, prb, mu, pld, pkd, pnd, pfeed;
    double r_cat, k_bond;
    int rwx, rwy; /* N/W search window (cells) */
    int owx, owy; /* overlap-energy window */
    int lwx, lwy; /* relax neighbour window */
    int RL;       /* lock radius (cells) */
    int syn_tries, syn_relax, nsynN;
    int feed_mode, vent_kind;
    double vent_x, vent_y, vent_r, vent_w;
    double a[NTYPES][NTYPES];
} ChemPar;

typedef struct { int slot; double d2; } Nbr;

HD inline void ev_add(const Dev &D, long long step, int kind, long long i, double x, double y, int var, unsigned phase,
                      unsigned seq, unsigned sub) {
    const int idx = at_add(&D.st->nev, 1);
    if (idx >= D.evcap) {
        at_or(&D.st->err, ERR_EVOVF);
        return;
    }
    Event e;
    e.step = step; e.i = i; e.x = x; e.y = y; e.kind = kind; e.var = var;
    e.key = ((unsigned long long)phase << 60) | ((unsigned long long)seq << 8) | sub;
    D.ev[idx] = e;
}

/* top-K beads of the given type within r_cat of slot k, sorted by (distance, gid);
 * returns the total count within r_cat.  Uses the cell index of the last sort. */
HD inline int find_near(const Dev &D, const ChemPar &C, int k, int type, Nbr *out, int K) {
    const double xk = D.x[k], yk = D.y[k], L = D.L, r2c = C.r_cat * C.r_cat;
    const int c = cell_of(D, xk, yk), cx = c % D.ncx, cy = c / D.ncx;
    int n = 0, nk = 0;
    for (int oy = -C.rwy; oy <= C.rwy; oy++) {
        const int yy = wrapi(cy + oy, D.ncy);
        for (int ox = -C.rwx; ox <= C.rwx; ox++) {
            const int cc = yy * D.ncx + wrapi(cx + ox, D.ncx);
            const int j1 = D.cstart[cc + 1];
            for (int j = D.cstart[cc]; j < j1; j++) {
                if (D.type[j] != type || j == k) continue;
                const double dx = minimg(D.x[j] - xk, L), dy = minimg(D.y[j] - yk, L);
                const double d2 = dx * dx + dy * dy;
                if (d2 >= r2c) continue;
                if (n < 256) n++; /* the reference caps the list at 256 */
                if (K <= 0) continue;
                const uint32_t g = D.gid[j];
                if (nk == K) {
                    const Nbr &l = out[K - 1];
                    if (!(d2 < l.d2 || (d2 == l.d2 && g < D.gid[l.slot]))) continue;
                }
                int b = nk < K ? nk++ : K - 1;
                while (b > 0 && (out[b - 1].d2 > d2 || (out[b - 1].d2 == d2 && D.gid[out[b - 1].slot] > g))) {
                    out[b] = out[b - 1];
                    b--;
                }
                out[b].slot = j;
                out[b].d2 = d2;
            }
        }
    }
    return n;
}

/* conservative overlap energy of a would-be lipid (centre c0, direction u) with all other
 * beads within rc (excluding the beads sl[] that will form it) */
HD inline double chain_overlap_energy(const Dev &D, const ChemPar &C, double cx0, double cy0, double ux, double uy,
                                      const int *sl) {
    const int ml = D.mlen;
    const double L = D.L;
    double U = 0.0;
    for (int b = 0; b < ml; b++) {
        double px = cx0 + (MOL.px[b] * ux - MOL.py[b] * uy), py = cy0 + (MOL.px[b] * uy + MOL.py[b] * ux);
        wrap1(&px, L);
        wrap1(&py, L);
        const int tb = b < D.nH ? TH : TT;
        const int c = cell_of(D, px, py), cx = c % D.ncx, cy = c / D.ncx;
        for (int oy = -C.owy; oy <= C.owy; oy++) {
            const int yy = wrapi(cy + oy, D.ncy);
            for (int ox = -C.owx; ox <= C.owx; ox++) {
                const int cc = yy * D.ncx + wrapi(cx + ox, D.ncx);
                for (int j = D.cstart[cc]; j < D.cstart[cc + 1]; j++) {
                    int skip = 0;
                    for (int q = 0; q < ml; q++) skip |= j == sl[q];
                    if (skip) continue;
                    const double dx = minimg(D.x[j] - px, L), dy = minimg(D.y[j] - py, L);
                    const double r2 = dx * dx + dy * dy;
                    if (r2 >= 1.0) continue;
                    const double w = 1.0 - sqrt(r2);
                    U += 0.5 * C.a[tb][D.type[j]] * w * w;
                }
            }
        }
    }
    return U;
}

/* steepest-descent relaxation of a new chain in the frozen field of its neighbours */
#define MAXNB 512
HD inline void relax_new_chain(const Dev &D, const ChemPar &C, const int *sl) {
    const int ml = D.mlen;
    const double L = D.L, cap = 0.05, alpha = 0.002;
    int nbj[MAXNB];
    int nnb = 0;
    const double reach = 1.0 + cap * C.syn_relax;
    const double reach2 = reach * reach;
    /* neighbours within reach of any chain bead, collected once.  Fast path: one pass over
     * the bounding box of cells around the chain (each cell once, no duplicates); the same set
     * as the reference's per-bead windows, in a different order.  Tiny boxes, where the
     * bounding box would wrap onto itself, use the reference's per-bead loop. */
    {
        const double x0 = D.x[sl[0]], y0 = D.y[sl[0]];
        double rxb[MAXMLEN], ryb[MAXMLEN], mnx = 0, mxx = 0, mny = 0, mxy = 0;
        for (int b = 0; b < ml; b++) {
            rxb[b] = minimg(D.x[sl[b]] - x0, L);
            ryb[b] = minimg(D.y[sl[b]] - y0, L);
            mnx = fmin(mnx, rxb[b]); mxx = fmax(mxx, rxb[b]);
            mny = fmin(mny, ryb[b]); mxy = fmax(mxy, ryb[b]);
        }
        const double R = reach + CHEM_MARGIN;
        const int cx0 = (int)floor((x0 + mnx - R) * D.icsx), cx1 = (int)floor((x0 + mxx + R) * D.icsx);
        const int cy0 = (int)floor((y0 + mny - R) * D.icsy), cy1 = (int)floor((y0 + mxy + R) * D.icsy);
        if (cx1 - cx0 + 1 <= D.ncx && cy1 - cy0 + 1 <= D.ncy) {
            for (int cyy = cy0; cyy <= cy1; cyy++) {
                const int yy = ((cyy % D.ncy) + D.ncy) % D.ncy;
                for (int cxx = cx0; cxx <= cx1; cxx++) {
                    const int cc = yy * D.ncx + ((cxx % D.ncx) + D.ncx) % D.ncx;
                    for (int j = D.cstart[cc]; j < D.cstart[cc + 1]; j++) {
                        int skip = 0;
                        for (int q = 0; q < ml; q++) skip |= j == sl[q];
                        if (skip) continue;
                        const double dx = minimg(D.x[j] - x0, L), dy = minimg(D.y[j] - y0, L);
                        int near = 0;
                        for (int b = 0; b < ml && !near; b++) {
                            /* minimum image again: in small boxes dx - rxb can exceed L/2 */
                            const double ex = minimg(dx - rxb[b], L), ey = minimg(dy - ryb[b], L);
                            near = ex * ex + ey * ey < reach2;
                        }
                        if (near && nnb < MAXNB) nbj[nnb++] = j;
                    }
                }
            }
            goto collected;
        }
    }
    for (int b = 0; b < ml && nnb < MAXNB; b++) {
        const double px = D.x[sl[b]], py = D.y[sl[b]];
        const int c = cell_of(D, px, py), cx = c % D.ncx, cy = c / D.ncx;
        for (int ox = -C.lwx; ox <= C.lwx; ox++) {
            const int xx = wrapi(cx + ox, D.ncx);
            for (int oy = -C.lwy; oy <= C.lwy; oy++) {
                const int cc = wrapi(cy + oy, D.ncy) * D.ncx + xx;
                for (int j = D.cstart[cc]; j < D.cstart[cc + 1]; j++) {
                    int skip = 0;
                    for (int q = 0; q < ml; q++) skip |= j == sl[q];
                    for (int q = 0; q < nnb && !skip; q++) skip |= nbj[q] == j;
                    if (skip) continue;
                    const double dx = minimg(D.x[j] - px, L), dy = minimg(D.y[j] - py, L);
                    if (dx * dx + dy * dy < reach2 && nnb < MAXNB) nbj[nnb++] = j;
                }
            }
        }
    }
collected:
    for (int it = 0; it < C.syn_relax; it++) {
        double fx[MAXMLEN], fy[MAXMLEN];
        for (int b = 0; b < ml; b++) fx[b] = fy[b] = 0.0;
        for (int b = 0; b < ml; b++) {
            const int i = sl[b];
            for (int q = 0; q < nnb; q++) {
                const int j = nbj[q];
                const double dx = minimg(D.x[i] - D.x[j], L), dy = minimg(D.y[i] - D.y[j], L);
                const double r2 = dx * dx + dy * dy;
                if (r2 >= 1.0 || r2 < 1e-24) continue;
                const double r = sqrt(r2);
                const double f = C.a[D.type[i]][D.type[j]] * (1.0 - r) / r;
                fx[b] += f * dx;
                fy[b] += f * dy;
            }
        }
        double mbd = 0.0;
        mol_forces(D.x, D.y, L, sl, C.k_bond, fx, fy, &mbd);
        for (int b = 0; b < ml; b++) {
            double mx = alpha * fx[b], my = alpha * fy[b];
            const double m = sqrt(mx * mx + my * my);
            if (m > cap) { mx *= cap / m; my *= cap / m; }
            D.x[sl[b]] += mx;
            D.y[sl[b]] += my;
            wrap1(&D.x[sl[b]], L);
            wrap1(&D.y[sl[b]], L);
        }
    }
}

/* One catalyst's reactions (lipid synthesis, then replication), executed by one thread.
 * Semantics identical to the reference's per-catalyst body; random numbers come from
 * counter-based hashes of (seed, step, gid of the catalyst). */
HD inline void chem_react(const Dev &D, const ChemPar &C, int k, int rank) {
    const int tk = D.type[k];
    if (tk != TKA && tk != TKB) return;
    const int var = tk == TKB;
    const uint32_t g = D.gid[k];
    const double us = hash_u01(C.ksyn, g), ur = hash_u01(C.krep, g);
    const double psyn = var ? C.psb : C.psa, prep = var ? C.prb : C.pra;
    const int ml = D.mlen, nsynN = C.nsynN;
    const double L = D.L;
    Nbr nb[MAXMLEN + 2], nbw[MAXMLEN];
    const int nn = find_near(D, C, k, TN, nb, nsynN + 2);
    if (nn < 2) return;
    int used = 0;
    const double xk = D.x[k], yk = D.y[k];
    int nw = 0;
    if (nn >= nsynN && nsynN < ml) nw = find_near(D, C, k, TW, nbw, ml - nsynN);
    if (nn >= nsynN && nsynN + nw >= ml && us < psyn) {
        double cxm = 0, cym = 0, mvx = 0, mvy = 0, mtx = 0, mty = 0;
        int sl[MAXMLEN];
        for (int b = 0; b < ml; b++) {
            const int j = b < nsynN ? nb[b].slot : nbw[b - nsynN].slot;
            sl[b] = j;
            cxm += minimg(D.x[j] - xk, L);
            cym += minimg(D.y[j] - yk, L);
            mvx += D.vx[j]; mvy += D.vy[j];
            mtx += D.vtx[j]; mty += D.vty[j];
        }
        cxm = xk + cxm / ml; cym = yk + cym / ml;
        mvx /= ml; mvy /= ml; mtx /= ml; mty /= ml;
        double ux = 1.0, uy = 0.0, ubest = 1e300;
        for (int tr = 0; tr < C.syn_tries; tr++) {
            const double phi = 2.0 * M_PI * hash_u01(hash_key(C.seed, C.step, 40 + (uint64_t)tr), g);
            const double cx_ = cos(phi), cy_ = sin(phi);
            const double U = C.syn_tries > 1 ? chain_overlap_energy(D, C, cxm, cym, cx_, cy_, sl) : 0.0;
            if (U < ubest) { ubest = U; ux = cx_; uy = cy_; }
        }
        for (int b = 0; b < ml; b++) {
            const int j = sl[b];
            D.x[j] = cxm + (MOL.px[b] * ux - MOL.py[b] * uy);
            D.y[j] = cym + (MOL.px[b] * uy + MOL.py[b] * ux);
            wrap1(&D.x[j], L);
            wrap1(&D.y[j], L);
            D.vx[j] = mvx; D.vy[j] = mvy;
            D.vtx[j] = (float)mtx; D.vty[j] = (float)mty;
            D.type[j] = b < D.nH ? TH : TT;
        }
        for (int b = 0; b < ml; b++) {
            D.mpos[sl[b]] = (int8_t)b;
            D.nxt[sl[b]] = b + 1 < ml ? sl[b + 1] : -1;
        }
        if (C.syn_relax > 0) relax_new_chain(D, C, sl);
        ev_add(D, C.step, EV_SYN, g, xk, yk, var, 0, (unsigned)rank, 0);
        used = nsynN;
    }
    if (nn - used >= 2 && ur < prep) {
        int nv = var, mut = 0;
        if (hash_u01(C.kmu, g) < C.mu) { nv = 1 - var; mut = 1; }
        const int j1 = nb[used].slot, j2 = nb[used + 1].slot;
        D.type[j1] = nv ? TKB : TKA;
        D.type[j2] = TW;
        ev_add(D, C.step, mut ? EV_MUT : EV_REP, D.gid[j1], xk, yk, nv, 0, (unsigned)rank, 1);
    }
}

HD inline int decay_kind(const Dev &D, const ChemPar &C, int d) {
    const uint32_t g = D.gid[d];
    if (D.mpos[d] == 0) return (C.pld > 0 && hash_u01(C.kld, g) < C.pld) ? 1 : 0;
    const int t = D.type[d];
    if (t == TKA || t == TKB) return (C.pkd > 0 && hash_u01(C.kkd, g) < C.pkd) ? 2 : 0;
    if (t == TN) return (C.pnd > 0 && hash_u01(C.knd, g) < C.pnd) ? 3 : 0;
    return 0;
}

HD inline int in_vent(const ChemPar &C, double L, double x, double y) {
    if (C.vent_kind == VENT_DISK) {
        const double dx = minimg(x - C.vent_x, L), dy = minimg(y - C.vent_y, L);
        return dx * dx + dy * dy < C.vent_r * C.vent_r;
    }
    if (C.vent_kind == VENT_VSTRIP) return fabs(minimg(x - C.vent_x, L)) < 0.5 * C.vent_w;
    return fabs(minimg(y - C.vent_y, L)) < 0.5 * C.vent_w;
}

static void flush_events(Sys *s);
static void ensure_ev(Sys *s, long extra) {
    if (s->nev_host + extra <= s->d.evcap) return;
    flush_events(s);
    if (extra > s->d.evcap) {
        int cap = s->d.evcap;
        while (cap < extra) cap *= 2;
        dfree(s->d.ev);
        s->d.ev = dnew<Event>(cap);
        s->d.evcap = cap;
    }
}

static double g_t_react = 0, g_t_decay = 0, g_t_feed = 0;
static long g_rounds = 0, g_nact_tot = 0;
static int g_chem_serial = 0; /* OERCEL_CHEM_SERIAL=1: reactions strictly serial (test oracle, slow) */

/* One chemistry check: reactions, decay, food supply (in this order, as the reference).
 *
 * Reactions: the reference visits all catalysts serially in a random order.  Here every
 * catalyst draws its synthesis/replication decision from a counter-based hash; only the
 * "active" ones (that drew a reaction) matter.  They get a random priority (another
 * hash) and are executed in rounds: each active catalyst claims (atomicMin of its
 * priority rank) every cell within RL of its own; a catalyst whose claims all hold its
 * own rank executes this round.  RL covers twice the reach of a reaction (cells read or
 * written: search window, overlap/relax windows, new bead positions), so catalysts
 * executing in the same round can not influence each other, and every catalyst runs
 * after all lower-ranked catalysts within reach -> the result is exactly that of the
 * serial loop in priority order, for any device or thread count. */
static void chemistry(Sys *s, const Params *P, int64_t step) {
    Dev D = s->d;
    const int N = D.N;
    ChemPar C;
    memset(&C, 0, sizeof C);
    C.step = step;
    C.seed = s->seed;
    C.ksyn = hash_key(s->seed, step, 21);
    C.krep = hash_key(s->seed, step, 22);
    C.kmu = hash_key(s->seed, step, 23);
    C.kld = hash_key(s->seed, step, 11);
    C.kkd = hash_key(s->seed, step, 12);
    C.knd = hash_key(s->seed, step, 13);
    C.kfeed = hash_key(s->seed, step, 14);
    C.kcap = hash_key(s->seed, step, 25);
    C.psa = P->p_syn_a; C.psb = P->p_syn_b; C.pra = P->p_rep_a; C.prb = P->p_rep_b; C.mu = P->mu;
    C.pld = P->p_ld; C.pkd = P->p_kd; C.pnd = P->p_nd; C.pfeed = P->p_feed;
    C.r_cat = P->r_cat; C.k_bond = P->k_bond;
    C.rwx = (int)ceil((P->r_cat + CHEM_MARGIN) * D.icsx);
    C.rwy = (int)ceil((P->r_cat + CHEM_MARGIN) * D.icsy);
    C.owx = (int)ceil((1.0 + CHEM_MARGIN) * D.icsx);
    C.owy = (int)ceil((1.0 + CHEM_MARGIN) * D.icsy);
    const double reach = 1.0 + 0.05 * P->syn_relax;
    C.lwx = (int)ceil((reach + CHEM_MARGIN) * D.icsx);
    C.lwy = (int)ceil((reach + CHEM_MARGIN) * D.icsy);
    {
        double E = 0; /* template extent */
        for (int b = 0; b < D.mlen; b++) E = fmax(E, hypot(g_mol.px[b], g_mol.py[b]));
        const int ww = (C.rwx > C.rwy ? C.rwx : C.rwy);                         /* slots written */
        const int wo = C.owx > C.owy ? C.owx : C.owy, wl = C.lwx > C.lwy ? C.lwx : C.lwy;
        const int wr = ww + (int)ceil((P->r_cat + E + 0.05 * P->syn_relax) * fmax(D.icsx, D.icsy)) + 1 +
                       (wo > wl ? wo : wl);                                       /* slots read */
        C.RL = (ww + wr + 1) / 2 + 1;
    }
    C.syn_tries = P->syn_tries; C.syn_relax = P->syn_relax;
    C.nsynN = P->syn_nN > 0 ? P->syn_nN : D.mlen;
    C.feed_mode = P->feed_mode; C.vent_kind = P->vent_kind;
    C.vent_x = P->vent_x; C.vent_y = P->vent_y; C.vent_r = P->vent_r; C.vent_w = P->vent_w;
    for (int i = 0; i < NTYPES; i++)
        for (int j = 0; j < NTYPES; j++) C.a[i][j] = P->a[i][j];

    double tc0 = wtime();
    /* ---------------- reactions */
    if (P->p_syn_a > 0 || P->p_syn_b > 0 || P->p_rep_a > 0 || P->p_rep_b > 0) {
        int nact;
        for (;;) {
            dset_int(&D.st->nact, 0);
            int *act = s->act;
            uint32_t *actg = s->actg;
            const int cap = s->actcap;
            pfor(N, KL(int d) {
                const int t = D.type[d];
                if (t != TKA && t != TKB) return;
                const int var = t == TKB;
                const uint32_t g = D.gid[d];
                const int a = hash_u01(C.ksyn, g) < (var ? C.psb : C.psa) || hash_u01(C.krep, g) < (var ? C.prb : C.pra);
                if (!a) return;
                const int idx = at_add(&D.st->nact, 1);
                if (idx < cap) {
                    act[idx] = d;
                    actg[idx] = g;
                }
            });
            nact = get_status(s).nact;
            if (nact <= s->actcap) break;
            int nc = s->actcap;
            while (nc < nact) nc *= 2;
            dfree(s->act); dfree(s->actlist); dfree(s->done); dfree(s->claimed); dfree(s->actg);
            s->act = dnew<int>(nc); s->actlist = dnew<int>(nc); s->done = dnew<int>(nc);
            s->claimed = dnew<int>(nc); s->actg = dnew<uint32_t>(nc);
            s->actcap = nc;
        }
        if (nact > 0) {
            /* deterministic random priority order (host: the list is short) */
            std::vector<int> ha(nact);
            std::vector<uint32_t> hg(nact);
            d2h(ha.data(), s->act, nact * sizeof(int));
            d2h(hg.data(), s->actg, nact * sizeof(uint32_t));
            const uint64_t kp = hash_key(s->seed, step, 24);
            std::vector<std::pair<uint64_t, int> > pr(nact);
            for (int q = 0; q < nact; q++) pr[q] = std::make_pair(hash_u64(kp, hg[q]), q);
            std::sort(pr.begin(), pr.end(), [&](const std::pair<uint64_t, int> &a, const std::pair<uint64_t, int> &b) {
                return a.first != b.first ? a.first < b.first : hg[a.second] < hg[b.second];
            });
            std::vector<int> hl(nact);
            for (int q = 0; q < nact; q++) hl[q] = ha[pr[q].second];
            h2d(s->actlist, hl.data(), nact * sizeof(int));
            dzero(s->done, nact * sizeof(int));
            dzero(s->claimed, nact * sizeof(int));
            dset_int(&D.st->ndone, 0);
            ensure_ev(s, 2L * nact);
            D = s->d; /* event buffer may have moved */
            int *actlist = s->actlist, *done = s->done, *claimed = s->claimed;
            const int RL = C.RL;
            int ndone = 0, rounds = 0;
            if (g_chem_serial) {
                /* test oracle (OERCEL_CHEM_SERIAL=1): the plain serial loop in priority order; the
                 * lock rounds below must give bitwise the same result (selftest section 2) */
                pfor_dyn(1, KL(int) {
                    for (int r = 0; r < nact; r++) chem_react(D, C, actlist[r], r);
                });
                ndone = nact;
                rounds = nact;
            }
            while (ndone < nact) {
                pfor(nact, KL(int r) {
                    if (done[r]) return;
                    claimed[r] = 1;
                    const int k = actlist[r];
                    const int c = cell_of(D, D.x[k], D.y[k]), cx = c % D.ncx, cy = c / D.ncx;
                    for (int oy = -RL; oy <= RL; oy++) {
                        const int yy = ((cy + oy) % D.ncy + D.ncy) % D.ncy;
                        for (int ox = -RL; ox <= RL; ox++) at_min(&D.lock[yy * D.ncx + ((cx + ox) % D.ncx + D.ncx) % D.ncx], r);
                    }
                });
                pfor_dyn(nact, KL(int r) {
                    if (done[r]) return;
                    const int k = actlist[r];
                    const int c = cell_of(D, D.x[k], D.y[k]), cx = c % D.ncx, cy = c / D.ncx;
                    for (int oy = -RL; oy <= RL; oy++) {
                        const int yy = ((cy + oy) % D.ncy + D.ncy) % D.ncy;
                        for (int ox = -RL; ox <= RL; ox++)
                            if (at_load(&D.lock[yy * D.ncx + ((cx + ox) % D.ncx + D.ncx) % D.ncx]) != r) return;
                    }
                    chem_react(D, C, k, r);
                    done[r] = 1;
                    at_add(&D.st->ndone, 1);
                });
                pfor(nact, KL(int r) {
                    if (!claimed[r]) return;
                    claimed[r] = 0;
                    const int k = actlist[r];
                    const int c = cell_of(D, D.x[k], D.y[k]), cx = c % D.ncx, cy = c / D.ncx;
                    for (int oy = -RL; oy <= RL; oy++) {
                        const int yy = ((cy + oy) % D.ncy + D.ncy) % D.ncy;
                        for (int ox = -RL; ox <= RL; ox++) at_store(&D.lock[yy * D.ncx + ((cx + ox) % D.ncx + D.ncx) % D.ncx], INT_MAX);
                    }
                });
                const int nd = get_status(s).ndone;
                if (nd <= ndone) die("chemistry: no progress in round %d (internal error)", rounds);
                ndone = nd;
                rounds++;
            }
            g_rounds += rounds;
            g_nact_tot += nact;
        }
    }
    double tc1 = wtime();
    g_t_react += tc1 - tc0;
    /* ---------------- decay */
    if (P->p_ld > 0 || P->p_kd > 0 || P->p_nd > 0) {
        dset_int(&D.st->ndec, 0);
        pfor(N, KL(int d) {
            if (decay_kind(D, C, d)) at_add(&D.st->ndec, 1);
        });
        const int ndec = get_status(s).ndec;
        if (ndec > 0) {
            ensure_ev(s, ndec);
            D = s->d;
            const int ml = D.mlen;
            pfor(N, KL(int d) {
                const int kd = decay_kind(D, C, d);
                if (!kd) return;
                if (kd == 1) {
                    const double hx = D.x[d], hy = D.y[d];
                    const uint32_t g0 = D.gid[d];
                    int c = d, n = 0;
                    while (c >= 0 && n < ml) {
                        const int nx = D.nxt[c];
                        D.type[c] = TW;
                        D.mpos[c] = -1;
                        D.nxt[c] = -1;
                        c = nx;
                        n++;
                    }
                    ev_add(D, C.step, EV_DLIP, g0, hx, hy, -1, 1, (unsigned)d, 0);
                } else if (kd == 2) {
                    const int t = D.type[d];
                    D.type[d] = TW;
                    ev_add(D, C.step, EV_DK, D.gid[d], D.x[d], D.y[d], t == TKB, 1, (unsigned)d, 0);
                } else {
                    D.type[d] = TW;
                    ev_add(D, C.step, EV_DN, D.gid[d], D.x[d], D.y[d], -1, 1, (unsigned)d, 0);
                }
            });
        }
    }
    double tc2 = wtime();
    g_t_decay += tc2 - tc1;
    /* ---------------- food supply (structure blind; decisions identical to the reference) */
    if (P->feed_mode != FEED_NONE && P->p_feed > 0.0) {
        int nc;
        for (;;) {
            dset_int(&D.st->nfc, 0);
            int *fcand = s->fcand;
            unsigned long long *fkey = s->fkey;
            const int cap = s->fcap;
            pfor(N, KL(int d) {
                if (D.type[d] != TW) return;
                if (C.feed_mode == FEED_VENT && !in_vent(C, D.L, D.x[d], D.y[d])) return;
                const uint32_t g = D.gid[d];
                if (!(hash_u01(C.kfeed, g) < C.pfeed)) return;
                const int idx = at_add(&D.st->nfc, 1);
                if (idx < cap) {
                    fcand[idx] = d;
                    fkey[idx] = (hash_u64(C.kcap, g) & 0xFFFFFFFF00000000ULL) | g;
                }
            });
            nc = get_status(s).nfc;
            if (nc <= s->fcap) break;
            int ncap = s->fcap;
            while (ncap < nc) ncap *= 2;
            dfree(s->fcand); dfree(s->fkey);
            s->fcand = dnew<int>(ncap);
            s->fkey = dnew<unsigned long long>(ncap);
            s->fcap = ncap;
        }
        long add = nc;
        unsigned long long thr = ~0ULL;
        if (P->feed_cap > 0.0 && nc > 0) {
            const long long nN = dreduce(N, 0LL, KL(int i)->long long { return D.type[i] == TN; }, SumL());
            long room = (long)floor(P->feed_cap * (double)N + 1e-9) - (long)nN;
            if (room < 0) room = 0;
            if (add > room) {
                /* a uniformly random subset of size room: the room smallest hash keys */
                add = room;
                if (room > 0) {
                    std::vector<unsigned long long> hk(nc);
                    d2h(hk.data(), s->fkey, (size_t)nc * sizeof(unsigned long long));
                    std::nth_element(hk.begin(), hk.begin() + (room - 1), hk.end());
                    thr = hk[room - 1];
                }
            }
        }
        if (add > 0) {
            int *fcand = s->fcand;
            unsigned long long *fkey = s->fkey;
            pfor(nc, KL(int q) {
                if (fkey[q] <= thr) D.type[fcand[q]] = TN;
            });
            Event e;
            e.step = step; e.i = add; e.x = NAN; e.y = NAN; e.kind = EV_FEED; e.var = -1;
            e.key = (2ULL << 60);
            s->hev->push_back(e);
        }
    }
    g_t_feed += wtime() - tc2;
}

/* ================================================================== host init */
typedef struct {
    double *x, *y, *vx, *vy, *fx, *fy;
    uint8_t *type;
    uint32_t *gid;
    int32_t *nxt;
    int8_t *mpos;
    int N;
} Host;

static void host_alloc(Host *h, int N) {
    h->N = N;
    h->x = (double *)xmalloc((size_t)N * 8); h->y = (double *)xmalloc((size_t)N * 8);
    h->vx = (double *)xmalloc((size_t)N * 8); h->vy = (double *)xmalloc((size_t)N * 8);
    h->fx = (double *)xmalloc((size_t)N * 8); h->fy = (double *)xmalloc((size_t)N * 8);
    h->type = (uint8_t *)xmalloc(N); h->mpos = (int8_t *)xmalloc(N);
    h->gid = (uint32_t *)xmalloc((size_t)N * 4); h->nxt = (int32_t *)xmalloc((size_t)N * 4);
    for (int i = 0; i < N; i++) { h->nxt[i] = -1; h->mpos[i] = -1; h->fx[i] = h->fy[i] = 0.0; }
}
static void host_free(Host *h) {
    free(h->x); free(h->y); free(h->vx); free(h->vy); free(h->fx); free(h->fy);
    free(h->type); free(h->mpos); free(h->gid); free(h->nxt);
}
static void host_upload(Sys *s, const Host *h, int with_f) {
    Dev &D = s->d;
    const size_t N = D.N;
    h2d(D.x, h->x, N * 8); h2d(D.y, h->y, N * 8); h2d(D.vx, h->vx, N * 8); h2d(D.vy, h->vy, N * 8);
    if (with_f) { h2d(D.fx, h->fx, N * 8); h2d(D.fy, h->fy, N * 8); }
    h2d(D.type, h->type, N); h2d(D.mpos, h->mpos, N); h2d(D.gid, h->gid, N * 4); h2d(D.nxt, h->nxt, N * 4);
}
static void host_download(Sys *s, Host *h, int all) {
    Dev &D = s->d;
    const size_t N = D.N;
    d2h(h->x, D.x, N * 8); d2h(h->y, D.y, N * 8);
    if (all) { d2h(h->vx, D.vx, N * 8); d2h(h->vy, D.vy, N * 8); d2h(h->fx, D.fx, N * 8); d2h(h->fy, D.fy, N * 8); }
    d2h(h->type, D.type, N); d2h(h->mpos, D.mpos, N); d2h(h->gid, D.gid, N * 4); d2h(h->nxt, D.nxt, N * 4);
}

static void set_velocities(Host *h, rng_t *rng, const Params *P) {
    double px = 0, py = 0;
    for (int i = 0; i < h->N; i++) {
        h->vx[i] = rng_normal(rng) * sqrt(P->kT);
        h->vy[i] = rng_normal(rng) * sqrt(P->kT);
        px += h->vx[i]; py += h->vy[i];
    }
    px /= h->N; py /= h->N;
    double k2 = 0;
    for (int i = 0; i < h->N; i++) {
        h->vx[i] -= px; h->vy[i] -= py;
        k2 += h->vx[i] * h->vx[i] + h->vy[i] * h->vy[i];
    }
    const double sc = sqrt(P->kT * (2.0 * h->N - 2.0) / k2);
    for (int i = 0; i < h->N; i++) { h->vx[i] *= sc; h->vy[i] *= sc; }
}

/* the random soup, identical (same RNG stream) to the reference engine */
static void init_soup(Host *h, rng_t *rng, const Params *P, int quiet) {
    const int N = h->N, ml = g_mol.mlen;
    const double L = P->L;
    const long nlip = lround(P->f_lip * N / ml);
    const long nKa = lround(P->f_Ka * N), nKb = lround(P->f_Kb * N), nN = lround(P->c_N * N);
    if (nlip * ml + nKa + nKb + nN > N) die("soup composition exceeds N");
    int gi = 0;
    for (long m = 0; m < nlip; m++) {
        const double hx = L * rng_unif(rng), hy = L * rng_unif(rng);
        const double phi = 2.0 * M_PI * rng_unif(rng);
        const double cph = cos(phi), sph = sin(phi);
        int sl[MAXMLEN];
        for (int b = 0; b < ml; b++) {
            h->x[gi] = hx + (g_mol.ix[b] * cph - g_mol.iy[b] * sph);
            h->y[gi] = hy + (g_mol.ix[b] * sph + g_mol.iy[b] * cph);
            wrap1(&h->x[gi], L);
            wrap1(&h->y[gi], L);
            h->type[gi] = b < g_mol.nH ? TH : TT;
            h->gid[gi] = gi;
            sl[b] = gi;
            gi++;
        }
        for (int b = 0; b < ml; b++) {
            h->mpos[sl[b]] = (int8_t)b;
            h->nxt[sl[b]] = b + 1 < ml ? sl[b + 1] : -1;
        }
    }
    long cnt = 0;
    for (; gi < N; gi++, cnt++) {
        h->x[gi] = L * rng_unif(rng);
        h->y[gi] = L * rng_unif(rng);
        h->gid[gi] = gi;
        if (cnt < nKa) h->type[gi] = TKA;
        else if (cnt < nKa + nKb) h->type[gi] = TKB;
        else if (cnt < nKa + nKb + nN) h->type[gi] = TN;
        else h->type[gi] = TW;
    }
    if (!quiet) logmsg("init soup: N=%d lipids=%ld (%ld beads) Ka=%ld Kb=%ld N=%ld\n", N, nlip, nlip * ml, nKa, nKb, nN);
}

/* ================================================================== IO */
static int file_exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

static Host g_out; /* persistent host buffers for output */
static int g_out_ok = 0;
static Host *out_buf(Sys *s) {
    if (!g_out_ok) {
        host_alloc(&g_out, s->d.N);
        g_out_ok = 1;
    }
    return &g_out;
}

typedef struct { int32_t key, sub, i, j; } brec_t;
static int brec_cmp(const void *a, const void *b) {
    const brec_t *p = (const brec_t *)a, *q = (const brec_t *)b;
    if (p->key != q->key) return p->key < q->key ? -1 : 1;
    return (p->sub > q->sub) - (p->sub < q->sub);
}

static void write_snapshot(Sys *s, const char *dir) {
    check_err(s, "snapshot");
    char path[2048], tmp[2100];
    snprintf(path, sizeof path, "%s/snap_%010lld.bin", dir, (long long)s->step);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    Host *h = out_buf(s);
    host_download(s, h, 0);
    FILE *f = fopen(tmp, "wb");
    if (!f) die("cannot write %s", tmp);
    const int N = s->d.N, ml = s->d.mlen;
    int *slot = (int *)xmalloc((size_t)N * sizeof(int));
    for (int d = 0; d < N; d++) slot[h->gid[d]] = d;
    int32_t nmol = 0;
    for (int d = 0; d < N; d++) nmol += h->mpos[d] == 0;
    const int32_t nb = nmol * g_mol.nb;
    const int32_t ver = 1, n32 = N;
    const int64_t st = s->step;
    fwrite("OCEL", 1, 4, f);
    fwrite(&ver, 4, 1, f);
    fwrite(&n32, 4, 1, f);
    fwrite(&nb, 4, 1, f);
    fwrite(&st, 8, 1, f);
    fwrite(&s->time, 8, 1, f);
    fwrite(&s->d.L, 8, 1, f);
    float *buf = (float *)xmalloc((size_t)N * sizeof(float));
    for (int g = 0; g < N; g++) buf[g] = (float)h->x[slot[g]];
    fwrite(buf, 4, N, f);
    for (int g = 0; g < N; g++) buf[g] = (float)h->y[slot[g]];
    fwrite(buf, 4, N, f);
    uint8_t *tb = (uint8_t *)buf;
    for (int g = 0; g < N; g++) tb[g] = h->type[slot[g]];
    fwrite(tb, 1, N, f);
    free(buf);
    /* template bonds, ordered by the id of the bond's first template bead, then by
     * template order (for linear lipids exactly the reference engine's order) */
    brec_t *br = (brec_t *)xmalloc((size_t)(nb + 1) * sizeof(brec_t));
    int k = 0;
    for (int d = 0; d < N; d++) {
        if (h->mpos[d] != 0) continue;
        int sl[MAXMLEN], n = 0;
        for (int c = d; c >= 0 && n < ml; c = h->nxt[c]) sl[n++] = c;
        if (n != ml) die("broken lipid chain at slot %d", d);
        for (int q = 0; q < g_mol.nb; q++) {
            const int32_t i = (int32_t)h->gid[sl[g_mol.bi[q]]], j = (int32_t)h->gid[sl[g_mol.bj[q]]];
            br[k].key = i;
            br[k].sub = q;
            br[k].i = i < j ? i : j;
            br[k].j = i < j ? j : i;
            k++;
        }
    }
    qsort(br, (size_t)nb, sizeof(brec_t), brec_cmp);
    int32_t *bb = (int32_t *)xmalloc((size_t)(nb + 1) * 2 * sizeof(int32_t));
    for (int q = 0; q < nb; q++) { bb[2 * q] = br[q].i; bb[2 * q + 1] = br[q].j; }
    fwrite(bb, 4, 2 * (size_t)nb, f);
    free(bb);
    free(br);
    free(slot);
    if (fclose(f) != 0) die("write error on %s", tmp);
    if (rename(tmp, path) != 0) die("rename %s failed", tmp);
}

/* checkpoint: the reference format (version 2 for linear lipids, memB version 3 with the
 * architecture code otherwise); per-bead arrays in this engine's slot order */
#define CKPT_VERSION 2
static void write_ckpt(Sys *s, const char *dir, int keep) {
    check_err(s, "checkpoint");
    char path[2048], tmp[2100];
    snprintf(path, sizeof path, "%s/ckpt.bin", dir);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    Host *h = out_buf(s);
    host_download(s, h, 1);
    Status hs = get_status(s);
    FILE *f = fopen(tmp, "wb");
    if (!f) die("cannot write %s", tmp);
    const int32_t ver = g_mol.arch == ARCH_LINEAR ? CKPT_VERSION : 3, N = s->d.N, ml = s->d.mlen, nH = s->d.nH;
    const int32_t arch = g_mol.arch;
    fwrite("OCKP", 1, 4, f);
    fwrite(&ver, 4, 1, f);
    fwrite(&N, 4, 1, f);
    fwrite(&ml, 4, 1, f);
    fwrite(&nH, 4, 1, f);
    if (ver == 3) fwrite(&arch, 4, 1, f); /* memB: version 3 = version 2 + lipid architecture code */
    fwrite(&s->step, 8, 1, f);
    fwrite(&s->time, 8, 1, f);
    fwrite(&s->d.L, 8, 1, f);
    fwrite(&s->seed, 8, 1, f);
    fwrite(s->rng.s, 8, 4, f);
    fwrite(&hs.maxbond, 8, 1, f);
    fwrite(&g_warm_end, 8, 1, f);
    fwrite(&s->t_anchor, 8, 1, f);
    fwrite(&s->step_anchor, 8, 1, f);
    fwrite(&s->dt_anchor, 8, 1, f);
    fwrite(&s->soup_seed, 8, 1, f);
    fwrite(h->gid, 4, N, f);
    fwrite(h->type, 1, N, f);
    fwrite(h->mpos, 1, N, f);
    fwrite(h->nxt, 4, N, f);
    fwrite(h->x, 8, N, f);
    fwrite(h->y, 8, N, f);
    fwrite(h->vx, 8, N, f);
    fwrite(h->vy, 8, N, f);
    fwrite(h->fx, 8, N, f);
    fwrite(h->fy, 8, N, f);
    fwrite("END!", 1, 4, f);
    fflush(f);
    fsync(fileno(f));
    if (fclose(f) != 0) die("write error on %s", tmp);
    if (keep) {
        char kp[2100];
        snprintf(kp, sizeof kp, "%s/ckpt_%010lld.bin", dir, (long long)s->step);
        if (link(tmp, kp) != 0 && errno != EEXIST) logmsg("warning: could not keep %s\n", kp);
    }
    if (rename(tmp, path) != 0) die("rename %s failed", tmp);
}

static void freadx(void *p, size_t sz, size_t n, FILE *f, const char *what) {
    if (fread(p, sz, n, f) != n) die("checkpoint truncated while reading %s", what);
}

/* reads a checkpoint into host arrays (allocates h); returns N */
static void read_ckpt(Sys *s, Host *h, const Params *P, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open checkpoint %s: %s", path, strerror(errno));
    char mg[4];
    int32_t ver, N, ml, nH;
    int64_t step;
    double time, L;
    uint64_t seed, rs[4];
    freadx(mg, 1, 4, f, "magic");
    if (memcmp(mg, "OCKP", 4)) die("%s is not an Oercel checkpoint", path);
    freadx(&ver, 4, 1, f, "version");
    if (ver == 1)
        die("%s is a version 1 checkpoint, written by the old engine that still had init = seeded and the flood-fill "
            "food supply; its history cannot be verified (SPEC section 0). Start from a new soup.", path);
    if (ver != CKPT_VERSION && ver != 3) die("unsupported checkpoint version %d", ver);
    freadx(&N, 4, 1, f, "N");
    freadx(&ml, 4, 1, f, "mlen");
    freadx(&nH, 4, 1, f, "nH");
    int32_t arch = ARCH_LINEAR;
    if (ver == 3) freadx(&arch, 4, 1, f, "arch");
    freadx(&step, 8, 1, f, "step");
    freadx(&time, 8, 1, f, "time");
    freadx(&L, 8, 1, f, "L");
    freadx(&seed, 8, 1, f, "seed");
    freadx(rs, 8, 4, f, "rng");
    double maxbond;
    freadx(&maxbond, 8, 1, f, "maxbond");
    freadx(&g_warm_end, 8, 1, f, "warm_end");
    double ta, da;
    int64_t sa;
    freadx(&ta, 8, 1, f, "t_anchor");
    freadx(&sa, 8, 1, f, "step_anchor");
    freadx(&da, 8, 1, f, "dt_anchor");
    uint64_t soup_seed;
    freadx(&soup_seed, 8, 1, f, "soup_seed");
    if (ml != g_mol.mlen || nH != g_mol.nH || arch != g_mol.arch) die("checkpoint lipid architecture differs from parameters");
    if (fabs(L - P->L) > 1e-12) die("checkpoint L=%g differs from parameter L=%g", L, P->L);
    sys_alloc(s, N, L, ml, nH);
    s->step = step;
    s->time = time;
    s->seed = seed;
    s->soup_seed = soup_seed;
    memcpy(s->rng.s, rs, sizeof rs);
    dset_dbl(&s->d.st->maxbond, maxbond);
    if (da == P->dt) { s->t_anchor = ta; s->step_anchor = sa; s->dt_anchor = da; }
    else { s->t_anchor = time; s->step_anchor = step; s->dt_anchor = P->dt; }
    host_alloc(h, N);
    freadx(h->gid, 4, N, f, "gid");
    freadx(h->type, 1, N, f, "type");
    freadx(h->mpos, 1, N, f, "mpos");
    freadx(h->nxt, 4, N, f, "nxt");
    freadx(h->x, 8, N, f, "x");
    freadx(h->y, 8, N, f, "y");
    freadx(h->vx, 8, N, f, "vx");
    freadx(h->vy, 8, N, f, "vy");
    freadx(h->fx, 8, N, f, "fx");
    freadx(h->fy, 8, N, f, "fy");
    char end[4];
    freadx(end, 1, 4, f, "end marker");
    if (memcmp(end, "END!", 4)) die("checkpoint end marker missing");
    fclose(f);
    int *slot = (int *)xmalloc((size_t)N * sizeof(int));
    for (int d = 0; d < N; d++) slot[d] = -1;
    for (int d = 0; d < N; d++) {
        if (h->gid[d] >= (uint32_t)N || slot[h->gid[d]] >= 0) die("checkpoint: gid table is not a permutation");
        slot[h->gid[d]] = d;
    }
    for (int d = 0; d < N; d++) {
        if (h->type[d] >= TZ) die("checkpoint: bead type %d at slot %d (Z is unused, SPEC section 6)", h->type[d], d);
        if (h->nxt[d] >= N || (h->mpos[d] < 0) != (h->type[d] != TH && h->type[d] != TT))
            die("checkpoint: inconsistent lipid links at slot %d", d);
    }
    free(slot);
}

static void truncate_csv_after(const char *path, int64_t step) {
    FILE *f = fopen(path, "r+");
    if (!f) return;
    char line[8192];
    long off = 0, cut = -1;
    int first = 1;
    while (fgets(line, sizeof line, f)) {
        size_t len = strlen(line);
        if (len == 0 || line[len - 1] != '\n') { cut = off; break; }
        if (!first) {
            long long st = strtoll(line, NULL, 10);
            if (st > step) { cut = off; break; }
        }
        first = 0;
        off += (long)len;
    }
    if (cut >= 0) {
        if (ftruncate(fileno(f), cut) != 0) logmsg("warning: could not truncate %s\n", path);
        else logmsg("truncated %s after step %lld\n", path, (long long)step);
    }
    fclose(f);
}

/* device + host events -> events.csv, sorted by (step, key): deterministic order */
static void flush_events(Sys *s) {
    Status h = get_status(s);
    const int n = h.nev < s->d.evcap ? h.nev : s->d.evcap;
    if (h.err & ERR_EVOVF) die("event buffer overflow (internal error)");
    std::vector<Event> &all = *s->hev;
    if (n > 0) {
        const size_t old = all.size();
        all.resize(old + n);
        d2h(all.data() + old, s->d.ev, (size_t)n * sizeof(Event));
    }
    if (!all.empty()) {
        std::stable_sort(all.begin(), all.end(), [](const Event &a, const Event &b) {
            return a.step != b.step ? a.step < b.step : a.key < b.key;
        });
        if (s->ef) {
            for (size_t k = 0; k < all.size(); k++) {
                const Event *e = &all[k];
                const char *v = e->var == 0 ? "a" : e->var == 1 ? "b" : "-";
                if (std::isnan(e->x)) fprintf(s->ef, "%lld,%s,%lld,nan,nan,%s\n", e->step, EVNAME[e->kind], e->i, v);
                else fprintf(s->ef, "%lld,%s,%lld,%.4f,%.4f,%s\n", e->step, EVNAME[e->kind], e->i, e->x, e->y, v);
            }
            fflush(s->ef);
        }
        all.clear();
    }
    dset_int(&s->d.st->nev, 0);
    s->nev_host = 0;
}

/* ================================================================== stats */
typedef struct {
    double k2, px, py;
    long long cnt[NTYPES + 1]; /* type counts, [NTYPES] = lipids */
} StatAcc;
struct StatComb {
    HD StatAcc operator()(const StatAcc &a, const StatAcc &b) const {
        StatAcc r;
        r.k2 = a.k2 + b.k2;
        r.px = a.px + b.px;
        r.py = a.py + b.py;
        for (int t = 0; t <= NTYPES; t++) r.cnt[t] = a.cnt[t] + b.cnt[t];
        return r;
    }
};
static StatAcc measure(Sys *s, double dt) {
    Dev D = s->d;
    const double h = 0.5 * dt;
    StatAcc z;
    memset(&z, 0, sizeof z);
    return dreduce(
        D.N, z,
        KL(int i)->StatAcc {
            StatAcc a;
            const double vx = D.vx[i] + h * D.fx[i], vy = D.vy[i] + h * D.fy[i];
            a.k2 = vx * vx + vy * vy;
            a.px = vx;
            a.py = vy;
            for (int t = 0; t <= NTYPES; t++) a.cnt[t] = 0;
            a.cnt[D.type[i]] = 1;
            a.cnt[NTYPES] = D.mpos[i] == 0;
            return a;
        },
        StatComb());
}

/* ================================================================== force self-test */
static double bonded_energy_host(const Host *h, double L, double kb) {
    double U = 0;
    for (int d0 = 0; d0 < h->N; d0++) {
        if (h->mpos[d0] != 0) continue;
        int sl[MAXMLEN], n = 0;
        for (int c = d0; c >= 0 && n < g_mol.mlen; c = h->nxt[c]) sl[n++] = c;
        for (int q = 0; q < g_mol.nb; q++) {
            const int i = sl[g_mol.bi[q]], j = sl[g_mol.bj[q]];
            const double r = hypot(minimg(h->x[j] - h->x[i], L), minimg(h->y[j] - h->y[i], L));
            U += 0.5 * kb * (r - g_mol.br0[q]) * (r - g_mol.br0[q]);
        }
        for (int q = 0; q < g_mol.na; q++) {
            const int i = sl[g_mol.ai[q]], j = sl[g_mol.aj[q]], k = sl[g_mol.ak[q]];
            const double ax = minimg(h->x[j] - h->x[i], L), ay = minimg(h->y[j] - h->y[i], L);
            const double cx = minimg(h->x[k] - h->x[j], L), cy = minimg(h->y[k] - h->y[j], L);
            const double c = (ax * cx + ay * cy) / (hypot(ax, ay) * hypot(cx, cy));
            U += g_mol.akind[q] == 0 ? g_mol.aK[q] * (1.0 - c) : g_mol.aK[q] * (c - g_mol.ac0[q]) * (c - g_mol.ac0[q]);
        }
    }
    return U;
}

/* --forcetest [L] [lip_arch]: sort integrity (local gather with R = 1..4 and the full
 * sort), pair forces vs an O(N^2) double-precision brute force (plain, and with stirring
 * + kT(t)), exact antisymmetry (sum of forces), run-to-run bitwise determinism, noise
 * statistics, bonded forces vs finite differences.  Prints FORCETEST PASS/FAIL. */
static int forcetest(int argc, char **argv) {
    Params P;
    memset(&P, 0, sizeof P);
    for (int k = 0; k < NPDEFS; k++) set_param(&P, PDEFS[k].key, PDEFS[k].def);
    default_amatrix(&P);
    P.L = argc > 2 ? atof(argv[2]) : 12.5;
    if (argc > 3) {
        snprintf(P.lip_arch, sizeof P.lip_arch, "%s", argv[3]);
        P.lip_nT = 2; P.lip_tie = 1; P.k_head = 5; P.cos_head = 0.3; P.r0_head = 0.6;
    }
    P.f_lip = 0.15; P.f_Ka = 0.02; P.f_Kb = 0.02; P.c_N = 0.1;
    P.threads = omp_get_max_threads();
    finalize_params(&P);
#if OG_CUDA
    ck(cudaMemcpyToSymbol(c_mol, &g_mol, sizeof(mol_t)), "copy molecule template");
#endif
    const int N = (int)lround(P.rho * P.L * P.L);
    Sys S, *s = &S;
    sys_alloc(s, N, P.L, g_mol.mlen, g_mol.nH);
    s->seed = 99;
    rng_seed(&s->rng, 99);
    Host H;
    host_alloc(&H, N);
    init_soup(&H, &s->rng, &P, 1);
    set_velocities(&H, &s->rng, &P);
    std::vector<float> hvtx(N), hvty(N);
    for (int i = 0; i < N; i++) { hvtx[i] = (float)(H.vx[i] + 0.3 * rng_normal(&s->rng)); hvty[i] = (float)H.vy[i]; }
    H.x[0] = 0.0; H.y[1] = P.L - 1e-13; H.x[2] = s->d.csx * 3; H.y[2] = s->d.csy * 2;
    host_upload(s, &H, 0);
    h2d(s->d.vtx, hvtx.data(), N * 4);
    h2d(s->d.vty, hvty.data(), N * 4);
    int ok = 1;
    sort_cells(s, 1, 0);
    /* local sort with displacements of up to ~0.3 / 1.5 / 3.5 cells, then a jump (full sort) */
    const double amp[6] = {0.3, 0.3, 1.2, 2.5, 3.5, 12.0};
    for (int rep = 0; rep < 6; rep++) {
        host_download(s, &H, 1);
        for (int d = 0; d < N; d++) {
            if (rng_unif(&s->rng) < 0.3) H.x[d] += amp[rep] * (rng_unif(&s->rng) - 0.5) * 2;
            H.y[d] += 0.2 * (rng_unif(&s->rng) - 0.5);
            H.x[d] = wrap_any(H.x[d], P.L);
            H.y[d] = wrap_any(H.y[d], P.L);
        }
        host_upload(s, &H, 1);
        g_t_sortfull = 0;
        sort_cells(s, 0, 0);
        check_err(s, "forcetest sort");
        const Status st = get_status(s);
        host_download(s, &H, 1);
        std::vector<int> cs(s->d.ncell + 1), cl(N);
        d2h(cs.data(), s->d.cstart, cs.size() * 4);
        d2h(cl.data(), s->d.cell, N * 4);
        int bad = 0, heads = 0;
        std::vector<char> seen(N, 0);
        for (int d = 0; d < N; d++) {
            if (H.gid[d] >= (uint32_t)N || seen[H.gid[d]]) bad++;
            else seen[H.gid[d]] = 1;
            if (H.mpos[d] < 0) { bad += H.nxt[d] != -1 || H.type[d] == TH || H.type[d] == TT; continue; }
            if (H.mpos[d] == 0) heads++;
            const int nx = H.nxt[d];
            if (H.mpos[d] < g_mol.mlen - 1) bad += nx < 0 || H.gid[nx] != H.gid[d] + 1 || H.mpos[nx] != H.mpos[d] + 1;
            else bad += nx != -1;
        }
        for (int c = 0; c < s->d.ncell; c++)
            for (int d = cs[c]; d < cs[c + 1]; d++) bad += cell_of(s->d, H.x[d], H.y[d]) != c || cl[d] != c;
        bad += cs[s->d.ncell] != N;
        printf("sort %d (moves up to %.1f): max cell displacement %d -> %s; chains/cells/permutation errors=%d (heads=%d)\n", rep,
               amp[rep], st.maxdc, g_t_sortfull > 0 ? "full sort" : "local gather", bad, heads);
        ok &= bad == 0;
    }
    /* pair forces vs brute force */
    std::vector<double> bfx(N), bfy(N), gfx(N), gfy(N), g2x(N);
    host_download(s, &H, 1);
    d2h(hvtx.data(), s->d.vtx, N * 4);
    d2h(hvty.data(), s->d.vty, N * 4);
    const uint64_t ss = step_seed(s->seed, 12345);
    for (int env = 0; env < 2; env++) {
        P.stir_A = env ? 0.7 : 0.0;
        P.stir_n = env ? 2 : 1;
        P.kT_amp = env ? 0.3 : 0.0;
        P.kT_period = 10.0;
        const double t = env ? 2.5 : 0.0;
        compute_forces(s, &P, 12345, t, 1, 0);
        d2h(gfx.data(), s->d.fx, N * 8);
        d2h(gfy.data(), s->d.fy, N * 8);
        const double kTt = P.kT + P.kT_amp * sin(2 * M_PI * t / P.kT_period);
        const double sdt = sqrt(2 * P.gamma * kTt) / sqrt(P.dt);
        double fsum = 0;
        for (int i = 0; i < N; i++) {
            bfx[i] = P.stir_A * sin(2 * M_PI * P.stir_n * H.y[i] / P.L);
            bfy[i] = 0;
            fsum += bfx[i];
        }
        for (int i = 0; i < N; i++) bfx[i] -= fsum / N;
        long npair = 0;
        for (int i = 0; i < N; i++)
            for (int j = i + 1; j < N; j++) {
                double dx = minimg(H.x[i] - H.x[j], P.L), dy = minimg(H.y[i] - H.y[j], P.L);
                double r2 = dx * dx + dy * dy;
                if (r2 >= 1.0) continue;
                npair++;
                double r = sqrt(r2), w = 1 - r;
                double ex = dx / r, ey = dy / r;
                double rv = ex * (hvtx[i] - hvtx[j]) + ey * (hvty[i] - hvty[j]);
                double th = pair_theta(ss, H.gid[i], H.gid[j]);
                double fm = P.a[H.type[i]][H.type[j]] * w - P.gamma * w * w * rv + sdt * w * th;
                bfx[i] += fm * ex; bfy[i] += fm * ey; bfx[j] -= fm * ex; bfy[j] -= fm * ey;
            }
        double maxd = 0, maxf = 0, sumx = 0, sumy = 0, rms = 0;
        for (int i = 0; i < N; i++) {
            const double e = fmax(fabs(bfx[i] - gfx[i]), fabs(bfy[i] - gfy[i]));
            maxd = fmax(maxd, e);
            rms += e * e;
            maxf = fmax(maxf, fabs(bfx[i]));
            sumx += gfx[i]; sumy += gfy[i];
        }
        rms = sqrt(rms / N);
        if (getenv("OG_DEBUG")) {
            int wi = 0; double we = 0;
            for (int i = 0; i < N; i++) { const double e = fmax(fabs(bfx[i] - gfx[i]), fabs(bfy[i] - gfy[i])); if (e > we) { we = e; wi = i; } }
            printf("worst slot %d gid %u x=%.6f y=%.6f bf=(%g,%g) gf=(%g,%g)\n", wi, H.gid[wi], H.x[wi], H.y[wi], bfx[wi], bfy[wi], gfx[wi], gfy[wi]);
            for (int j = 0; j < N; j++) { double dx = minimg(H.x[wi] - H.x[j], P.L), dy = minimg(H.y[wi] - H.y[j], P.L); if (j != wi && dx*dx+dy*dy < 1) printf("  nb slot %d x=%.6f y=%.6f r=%.4f\n", j, H.x[j], H.y[j], sqrt(dx*dx+dy*dy)); }
        }
        const int pass = maxd < 2e-3 && fabs(sumx) < 1e-8 && fabs(sumy) < 1e-8;
        printf("pair forces%s: N=%d L=%g cells=%dx%d pairs=%ld  max|F_gpu - F_brute|=%.3e rms=%.3e (max|F|=%.1f, float pair "
               "arithmetic)  sum F=(%.2e,%.2e) -> %s\n",
               env ? " + stirring (A=0.7, n=2) + kT(t)=1.3" : "", N, P.L, s->d.ncx, s->d.ncy, npair, maxd, rms, maxf, sumx, sumy,
               pass ? "ok" : "FAIL");
        ok &= pass;
        compute_forces(s, &P, 12345, t, 1, 0);
        d2h(g2x.data(), s->d.fx, N * 8);
        const int same = memcmp(g2x.data(), gfx.data(), N * 8) == 0;
        printf("pair forces%s bitwise identical on repetition: %s\n", env ? " + environment" : "", same ? "yes" : "NO");
        ok &= same;
#if !OG_CUDA
        omp_set_num_threads(1);
        compute_forces(s, &P, 12345, t, 1, 0);
        d2h(g2x.data(), s->d.fx, N * 8);
        omp_set_num_threads(P.threads);
        const int same1 = memcmp(g2x.data(), gfx.data(), N * 8) == 0;
        printf("pair forces%s bitwise identical with 1 vs %d threads: %s\n", env ? " + environment" : "", P.threads,
               same1 ? "yes" : "NO");
        ok &= same1;
#endif
    }
    P.stir_A = 0; P.kT_amp = 0;
    {
        double me = 0;
        for (long k = -200000; k <= 200000; k++) {
            const double u = k * 1.37e-5 + 1e-9 * (k % 7);
            me = fmax(me, fabs((double)sin2pi_f(u) - sin(2 * M_PI * u)));
        }
        printf("sin2pi_f vs libm sin(2 pi u): max|diff|=%.2e\n", me);
        ok &= me < 2e-6;
    }
    {
        double m1 = 0, m2 = 0, c1 = 0, prev = 0, md = 0;
        long nn = 0;
        for (uint32_t i = 0; i < 2000; i++)
            for (uint32_t j = i + 1; j < i + 500; j++) {
                double th = pair_theta_f(ss, i, j);
                md = fmax(md, fabs(th - pair_theta(ss, i, j)));
                m1 += th; m2 += th * th; c1 += th * prev; prev = th; nn++;
            }
        const int pass = fabs(m1 / nn) < 0.01 && fabs(m2 / nn - 1) < 0.01 && fabs(c1 / nn) < 0.01 && md < 1e-6 &&
                         pair_theta_f(ss, 5, 9) == pair_theta_f(ss, 9, 5);
        printf("noise: n=%ld mean=%.4f var=%.4f lag1 corr=%.4f max|float-double|=%.1e symmetric=%s -> %s\n", nn, m1 / nn, m2 / nn,
               c1 / nn, md, pair_theta_f(ss, 5, 9) == pair_theta_f(ss, 9, 5) ? "yes" : "NO", pass ? "ok" : "FAIL");
        ok &= pass;
    }
    /* bonded forces vs finite differences */
    for (int d = 0; d < N; d++)
        if (H.mpos[d] >= 0) {
            H.x[d] += 0.08 * rng_normal(&s->rng); H.y[d] += 0.08 * rng_normal(&s->rng);
            wrap1(&H.x[d], P.L); wrap1(&H.y[d], P.L);
        }
    host_upload(s, &H, 0);
    dset_dbl(&s->d.st->maxbond, 0.0);
    compute_forces(s, &P, 1, 0.0, 0, 1);
    d2h(gfx.data(), s->d.fx, N * 8);
    d2h(gfy.data(), s->d.fy, N * 8);
    double maxrel = 0;
    int nchk = 0;
    for (int d = 0; d < N && nchk < 400; d++) {
        if (H.mpos[d] < 0) continue;
        nchk++;
        const double eps = 1e-6, x0 = H.x[d], y0 = H.y[d];
        H.x[d] = x0 + eps; const double up = bonded_energy_host(&H, P.L, P.k_bond);
        H.x[d] = x0 - eps; const double um = bonded_energy_host(&H, P.L, P.k_bond);
        H.x[d] = x0;
        H.y[d] = y0 + eps; const double vp = bonded_energy_host(&H, P.L, P.k_bond);
        H.y[d] = y0 - eps; const double vm = bonded_energy_host(&H, P.L, P.k_bond);
        H.y[d] = y0;
        const double nfx = -(up - um) / (2 * eps), nfy = -(vp - vm) / (2 * eps);
        const double den = fmax(1.0, hypot(nfx, nfy));
        maxrel = fmax(maxrel, hypot(nfx - gfx[d], nfy - gfy[d]) / den);
    }
    printf("bonded forces (%s, %d bonds and %d angle terms per lipid) vs finite differences, %d beads: max rel. error %.2e -> %s\n",
           P.lip_arch, g_mol.nb, g_mol.na, nchk, maxrel, maxrel < 1e-5 ? "ok" : "FAIL");
    ok &= maxrel < 1e-5;
    printf(ok ? "FORCETEST PASS\n" : "FORCETEST FAIL\n");
    return ok ? 0 : 1;
}

/* ================================================================== main */
static int params_line_ignored(const char *l) {
    static const char *keys[] = {"restart ", "threads ", "walltime ", "log_every "};
    if (l[0] == '#') return 1;
    for (size_t k = 0; k < sizeof keys / sizeof keys[0]; k++)
        if (!strncmp(l, keys[k], strlen(keys[k]))) return 1;
    return 0;
}
static int same_params_file(const char *a, const char *b) {
    FILE *fa = fopen(a, "r"), *fb = fopen(b, "r");
    int same = fa && fb;
    char la[2048], lb[2048];
    while (same) {
        char *ra, *rb;
        do { ra = fgets(la, sizeof la, fa); } while (ra && params_line_ignored(la));
        do { rb = fgets(lb, sizeof lb, fb); } while (rb && params_line_ignored(lb));
        if (!ra || !rb) { same = !ra && !rb; break; }
        char *ha = strchr(la, '#'), *hb = strchr(lb, '#');
        if (ha) *ha = 0;
        if (hb) *hb = 0;
        if (strcmp(trim(la), trim(lb))) same = 0;
    }
    if (fa) fclose(fa);
    if (fb) fclose(fb);
    return same;
}
static void ensure_dir(const char *d) {
    if (mkdir(d, 0755) != 0 && errno != EEXIST) die("cannot create directory %s: %s", d, strerror(errno));
}
static void print_param_table(void) {
    Params P;
    memset(&P, 0, sizeof P);
    printf("| key | default | meaning |\n|---|---|---|\n");
    for (int k = 0; k < NPDEFS; k++) printf("| `%s` | %s | %s |\n", PDEFS[k].key, PDEFS[k].def[0] ? PDEFS[k].def : "(empty)", PDEFS[k].help);
    default_amatrix(&P);
    printf("\nDefault repulsion matrix a_ij (key `a_X_Y`, symmetric; `a_K_X` sets Ka and Kb at once):\n\n|    |");
    for (int j = 0; j < NTYPES; j++) printf(" %s |", TNAME[j]);
    printf("\n|---|");
    for (int j = 0; j < NTYPES; j++) printf("---|");
    printf("\n");
    for (int i = 0; i < NTYPES; i++) {
        printf("| **%s** |", TNAME[i]);
        for (int j = 0; j < NTYPES; j++) printf(" %g |", P.a[i][j]);
        printf("\n");
    }
}

static void device_init(int quiet) {
#if OG_CUDA
    int ndev = 0;
    cudaError_t e = cudaGetDeviceCount(&ndev);
    if (e != cudaSuccess || ndev == 0)
        die("no CUDA device available (%s). In WSL2 the NVIDIA Windows driver provides the GPU; check `nvidia-smi`.",
            e != cudaSuccess ? cudaGetErrorString(e) : "0 devices");
    int dev = 0;
    ck(cudaSetDevice(dev), "cudaSetDevice");
    cudaDeviceProp pr;
    ck(cudaGetDeviceProperties(&pr, dev), "cudaGetDeviceProperties");
    if (!quiet)
        logmsg("device: %s (compute capability %d.%d, %d SMs, %.1f GB); build: CUDA %d.%d\n", pr.name, pr.major, pr.minor,
               pr.multiProcessorCount, pr.totalGlobalMem / 1e9, CUDART_VERSION / 1000, (CUDART_VERSION % 1000) / 10);
    const char *ev = getenv("OERCEL_SYNC");
    g_sync_each = ev && atoi(ev) > 0;
    ev = getenv("OERCEL_TPB");
    if (ev && atoi(ev) >= 32) g_tpb = atoi(ev);
    ev = getenv("OERCEL_PAIR_TPB");
    if (ev && atoi(ev) >= 32) g_pair_tpb = atoi(ev);
    ck(cudaMemcpyToSymbol(c_mol, &g_mol, sizeof(mol_t)), "copy molecule template");
#else
    if (!quiet) logmsg("device: CPU emulation (same kernels as the CUDA build, OpenMP, %d threads)\n", omp_get_max_threads());
#endif
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "--params")) {
        print_param_table();
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "--version")) {
        printf("oercel_gpu %s, %s build\n", OG_VERSION, OG_CUDA ? "CUDA" : "CPU-emulation");
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "--forcetest")) {
        omp_set_dynamic(0);
        Params P0;
        memset(&P0, 0, sizeof P0);
        device_init(0);
        return forcetest(argc, argv);
    }
    if (argc < 3) {
        fprintf(stderr,
                "usage: %s params.ini outdir [key=value ...]\n       %s --params      (print all parameters)\n"
                "       %s --forcetest [L] [lip_arch]   (kernel self-test)\n       %s --version\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }
    {
        const uint32_t one = 1;
        if (*(const uint8_t *)&one != 1) die("big-endian machines are not supported");
    }
    const char *outdir = argv[2];
    Params P;
    memset(&P, 0, sizeof P);
    for (int k = 0; k < NPDEFS; k++) set_param(&P, PDEFS[k].key, PDEFS[k].def);
    default_amatrix(&P);
    kv_t *kv;
    int nkv = read_ini(argv[1], &kv);
    for (int a = 3; a < argc; a++) {
        char *eq = strchr(argv[a], '=');
        if (!eq) die("override '%s' is not key=value", argv[a]);
        kv = (kv_t *)realloc(kv, (nkv + 1) * sizeof(kv_t));
        char tmp[1100];
        snprintf(tmp, sizeof tmp, "%s", argv[a]);
        tmp[eq - argv[a]] = 0;
        snprintf(kv[nkv].key, sizeof kv[nkv].key, "%s", trim(tmp));
        snprintf(kv[nkv].val, sizeof kv[nkv].val, "%s", trim(tmp + (eq - argv[a]) + 1));
        nkv++;
    }
    for (int pass = 0; pass < 2; pass++)
        for (int k = 0; k < nkv; k++)
            if (is_generic_akey(kv[k].key) == (pass == 0)) set_param(&P, kv[k].key, kv[k].val);
    free(kv);
    finalize_params(&P);

    ensure_dir(outdir);
    char path[2048];
    snprintf(path, sizeof path, "%s/log.txt", outdir);
    g_log = fopen(path, "a");
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    omp_set_num_threads(P.threads);
    omp_set_dynamic(0);
    device_init(0);

    static Sys S;
    Sys *s = &S;
    const int restarting = P.restart[0] != 0;
    const int mlen = g_mol.mlen;
    double t_start = wtime();
    if (restarting) {
        Host H;
        read_ckpt(s, &H, &P, P.restart);
        host_upload(s, &H, 1);
        /* vt is not part of the state: it is recomputed by the first integration step */
        dzero(s->d.vtx, (size_t)s->d.N * 4);
        dzero(s->d.vty, (size_t)s->d.N * 4);
        host_free(&H);
        if (P.restart_reseed) {
            s->seed = P.seed;
            rng_seed(&s->rng, P.seed ^ mix13((uint64_t)s->step));
            logmsg("restart: reseeded with seed=%llu (branch, not an exact continuation)\n", (unsigned long long)P.seed);
        } else if (s->seed != P.seed) {
            logmsg("note: using checkpoint seed %llu (ini seed %llu ignored; set restart_reseed=1 to branch)\n",
                   (unsigned long long)s->seed, (unsigned long long)P.seed);
        }
        sort_cells(s, 1, 1); /* this engine's cell order (stable); forces travel with the beads */
        Dev D = s->d;
        const long long nl = dreduce(D.N, 0LL, KL(int i)->long long { return D.mpos[i] == 0; }, SumL());
        logmsg("restart from %s at step %lld (t=%.4f), N=%d, lipids=%lld, descends from the random soup with seed %llu\n",
               P.restart, (long long)s->step, s->time, s->d.N, nl, (unsigned long long)s->soup_seed);
    } else {
        const int N = (int)lround(P.rho * P.L * P.L);
        if (strcmp(P.init, "soup")) die("init = %s needs restart = <checkpoint>", P.init);
        sys_alloc(s, N, P.L, mlen, g_mol.nH);
        s->seed = P.seed;
        s->soup_seed = P.seed;
        rng_seed(&s->rng, P.seed);
        Host H;
        host_alloc(&H, N);
        init_soup(&H, &s->rng, &P, 0);
        set_velocities(&H, &s->rng, &P);
        host_upload(s, &H, 0);
        host_free(&H);
        g_warm_end = P.warmup;
        if (P.warmup > 0) logmsg("warm-up: repulsion above 25 ramped in over steps 0..%ld\n", P.warmup);
        Dev D = s->d;
        pfor(N, KL(int i) {
            D.vtx[i] = (float)D.vx[i];
            D.vty[i] = (float)D.vy[i];
        });
        s->step = 0;
        s->time = 0.0;
        s->t_anchor = 0.0;
        s->step_anchor = 0;
        s->dt_anchor = P.dt;
        sort_cells(s, 1, 0);
        compute_forces(s, &P, 0, 0.0, 1, 1);
        D = s->d;
        const double hdt = 0.5 * P.dt;
        pfor(N, KL(int i) {
            D.vx[i] -= hdt * D.fx[i];
            D.vy[i] -= hdt * D.fy[i];
        });
    }
    {
        const int rx = (int)ceil((P.r_cat + CHEM_MARGIN) * s->d.icsx), ry = (int)ceil((P.r_cat + CHEM_MARGIN) * s->d.icsy);
        if (s->d.ncx < 2 * rx + 1 || s->d.ncy < 2 * ry + 1) die("box too small for r_cat");
    }

    snprintf(path, sizeof path, "%s/params.ini", outdir);
    {
        char newp[2100];
        snprintf(newp, sizeof newp, "%s.new", path);
        write_params(&P, newp, argc - 3, argv + 3);
        if (restarting && file_exists(path) && !same_params_file(path, newp)) {
            char old[2100];
            snprintf(old, sizeof old, "%s/params_before_%010lld.ini", outdir, (long long)s->step);
            if (rename(path, old) != 0) logmsg("warning: could not keep old params.ini\n");
            else logmsg("parameters changed at restart; previous ones kept in %s\n", old);
        }
        if (rename(newp, path) != 0) die("cannot write %s", path);
    }

    char spath[2048], epath[2048];
    snprintf(spath, sizeof spath, "%s/stats.csv", outdir);
    snprintf(epath, sizeof epath, "%s/events.csv", outdir);
    FILE *sf = NULL, *ef = NULL;
    if (restarting && file_exists(spath)) {
        truncate_csv_after(spath, s->step);
        sf = fopen(spath, "a");
    } else {
        sf = fopen(spath, "w");
        if (sf) fprintf(sf, "step,time,T_kin,nW,nH,nT,nN,nKa,nKb,nZ,n_lipids,max_bond\n");
    }
    if (!sf) die("cannot open %s", spath);
    if (P.events) {
        if (restarting && file_exists(epath)) {
            truncate_csv_after(epath, s->step);
            ef = fopen(epath, "a");
        } else {
            ef = fopen(epath, "w");
            if (ef) fprintf(ef, "step,kind,i,x,y,variant\n");
        }
        if (!ef) die("cannot open %s", epath);
    }
    static char sbuf[1 << 16], ebuf[1 << 20];
    setvbuf(sf, sbuf, _IOFBF, sizeof sbuf);
    if (ef) setvbuf(ef, ebuf, _IOFBF, sizeof ebuf);
    s->ef = ef;

    logmsg("oercel_gpu %s (%s): N=%d L=%g cells=%dx%d threads=%d dt=%g gamma=%g sigma=%g lipid=%s(%d beads) steps->%ld\n", OG_VERSION,
           OG_CUDA ? "CUDA" : "CPU emulation", s->d.N, s->d.L, s->d.ncx, s->d.ncy, P.threads, P.dt, P.gamma, P.sigma, P.lip_arch,
           mlen, P.steps);
    if (P.chem && P.feed_mode == FEED_UNIFORM)
        logmsg("feed: uniform, every W -> N with p_feed=%g per check (every %ld steps), cap nN/N=%g\n", P.p_feed, P.n_chem,
               P.feed_cap);
    if (P.chem && P.feed_mode == FEED_VENT)
        logmsg("feed: vent %s at x=%g y=%g (r=%g, w=%g), W -> N with p_feed=%g per check, cap nN/N=%g\n", P.vent_shape,
               P.vent_x, P.vent_y, P.vent_r, P.vent_w, P.p_feed, P.feed_cap);
    if (P.stir_A != 0) logmsg("stirring: f_x = %g sin(2 pi %d y / L) on every bead (net force removed)\n", P.stir_A, P.stir_n);
    if (P.kT_amp != 0) logmsg("temperature cycle: kT(t) = %g + %g sin(2 pi t / %g)\n", P.kT, P.kT_amp, P.kT_period);

    if (!restarting) {
        const StatAcc a = measure(s, P.dt);
        const double T = a.k2 / (2.0 * s->d.N - 2.0);
        const Status hs = get_status(s);
        if (P.stats_every > 0)
            fprintf(sf, "0,0,%.6f,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%.6f\n", T, a.cnt[TW], a.cnt[TH], a.cnt[TT], a.cnt[TN],
                    a.cnt[TKA], a.cnt[TKB], a.cnt[TZ], a.cnt[NTYPES], hs.maxbond);
        dset_dbl(&s->d.st->maxbond, 0.0);
        if (P.snap_every > 0) write_snapshot(s, outdir);
    } else {
        char sp[2100];
        snprintf(sp, sizeof sp, "%s/snap_%010lld.bin", outdir, (long long)s->step);
        if (P.snap_every > 0 && s->step % P.snap_every == 0 && !file_exists(sp)) write_snapshot(s, outdir);
    }

    const double dt = P.dt, dt2 = dt * dt, cvt = (0.5 + P.lambda) * dt;
    const int64_t step0 = s->step;
    double t_loop0 = wtime(), t_lastlog = t_loop0;
    int64_t lastlog_step = s->step;
    int stopped_early = 0;
    const int prof = getenv("OERCEL_PROFILE") && atoi(getenv("OERCEL_PROFILE")) > 0;
    g_chem_serial = getenv("OERCEL_CHEM_SERIAL") && atoi(getenv("OERCEL_CHEM_SERIAL")) > 0;
    if (g_chem_serial) logmsg("OERCEL_CHEM_SERIAL=1: reactions run strictly serially (test mode)\n");
    double tm_integ = 0, tm_chem = 0, tm_sort = 0, tm_force = 0, tm_io = 0;
    logmsg("setup %.3f s\n", t_loop0 - t_start);

    while (s->step < P.steps) {
        const int64_t ns = s->step + 1;
        const int chem_step = P.chem && (ns % P.n_chem) == 0;
        double t0 = wtime();
        Dev D = s->d;
        const int N = D.N;
        const double L = D.L;
        if (chem_step) dset_dbl(&D.st->dmax, 0.0);
        /* 1. Groot-Warren step with stored half-step velocity vh = v - dt/2 f:
         *    x += dt vh + dt^2 f;  vt = vh + (1/2 + lambda) dt f;  vh += dt f */
        pfor(N, KL(int i) {
            const double fxi = D.fx[i], fyi = D.fy[i], vxi = D.vx[i], vyi = D.vy[i];
            const double ddx = dt * vxi + dt2 * fxi, ddy = dt * vyi + dt2 * fyi;
            if (chem_step) {
                const double adx = ddx < 0.0 ? -ddx : ddx, ady = ddy < 0.0 ? -ddy : ddy;
                at_maxpos(&D.st->dmax, adx > ady ? adx : ady);
            }
            double xi = D.x[i] + ddx, yi = D.y[i] + ddy;
            xi = xi < 0.0 ? xi + L : xi;
            yi = yi < 0.0 ? yi + L : yi;
            xi = xi >= L ? xi - L : xi;
            yi = yi >= L ? yi - L : yi;
            if (xi >= L || xi < 0.0) xi = wrap_any(xi, L); /* only for absurd displacements */
            if (yi >= L || yi < 0.0) yi = wrap_any(yi, L);
            D.x[i] = xi;
            D.y[i] = yi;
            D.vtx[i] = (float)(vxi + cvt * fxi);
            D.vty[i] = (float)(vyi + cvt * fyi);
            D.vx[i] = vxi + dt * fxi;
            D.vy[i] = vyi + dt * fyi;
        });
        if (prof) dsync();
        double t1 = wtime();
        tm_integ += t1 - t0;
        /* 2. chemistry on the new configuration, with the cell index of the previous sort */
        if (chem_step) {
            const Status hs = get_status(s);
            if (!(hs.dmax < CHEM_MARGIN)) {
                logmsg("warning: step %lld max displacement %.3f >= %.2f, extra cell sort\n", (long long)ns, hs.dmax, CHEM_MARGIN);
                sort_cells(s, 0, 0);
            }
            chemistry(s, &P, ns);
            if (prof) dsync();
        }
        double t2 = wtime();
        tm_chem += t2 - t1;
        sort_cells(s, 0, 0);
        if (prof) dsync();
        double t3 = wtime();
        tm_sort += t3 - t2;
        const double tn = s->t_anchor + (double)(ns - s->step_anchor) * dt;
        compute_forces(s, &P, ns, tn, 1, 1);
        if (prof) dsync();
        double t4 = wtime();
        tm_force += t4 - t3;
        s->step = ns;
        s->time = tn;
        if (P.stats_every > 0 && ns % P.stats_every == 0) {
            const StatAcc a = measure(s, dt);
            const double T = a.k2 / (2.0 * N - 2.0);
            const Status hs = get_status(s);
            fprintf(sf, "%lld,%.6f,%.6f,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%.6f\n", (long long)ns, s->time, T, a.cnt[TW],
                    a.cnt[TH], a.cnt[TT], a.cnt[TN], a.cnt[TKA], a.cnt[TKB], a.cnt[TZ], a.cnt[NTYPES], hs.maxbond);
            dset_dbl(&s->d.st->maxbond, 0.0);
            if (!std::isfinite(T)) die("non-finite temperature at step %lld", (long long)ns);
        }
        if (P.snap_every > 0 && ns % P.snap_every == 0) write_snapshot(s, outdir);
        if (s->nev_host > (s->d.evcap >> 1) || s->hev->size() > 100000) flush_events(s);
        const double now = wtime();
        int stop = g_stop || (P.walltime > 0 && now - t_start > P.walltime);
        if ((P.ckpt_every > 0 && ns % P.ckpt_every == 0) || stop || ns >= P.steps) {
            flush_events(s);
            fflush(sf);
            write_ckpt(s, outdir, P.ckpt_keep);
        }
        if (P.log_every > 0 && ns % P.log_every == 0) {
            const StatAcc a = measure(s, dt);
            const double T = a.k2 / (2.0 * N - 2.0);
            logmsg("step %lld t=%.2f T=%.4f (kT=%.4f) p=(%.2e,%.2e) lip=%lld Ka=%lld Kb=%lld N=%lld  %.3f ms/step\n", (long long)ns,
                   s->time, T, kT_at(&P, s->time), a.px, a.py, a.cnt[NTYPES], a.cnt[TKA], a.cnt[TKB], a.cnt[TN],
                   1e3 * (wtime() - t_lastlog) / (double)(ns - lastlog_step));
            t_lastlog = wtime();
            lastlog_step = ns;
        }
        tm_io += wtime() - t4;
        if (stop) {
            stopped_early = 1;
            logmsg("stopping at step %lld (%s), checkpoint written\n", (long long)ns, g_stop ? "signal" : "walltime");
            break;
        }
    }
    flush_events(s);
    dsync();
    if (sf) fclose(sf);
    if (ef) fclose(ef);
    const double nst = (double)(s->step - step0);
    if (nst > 0) {
        const double tot = tm_integ + tm_chem + tm_sort + tm_force + tm_io;
        logmsg("timing: %lld steps, %.4f ms/step (integrate %.4f, sort %.4f, forces %.4f, chem %.4f, io %.4f)%s\n", (long long)nst,
               1e3 * tot / nst, 1e3 * tm_integ / nst, 1e3 * tm_sort / nst, 1e3 * tm_force / nst, 1e3 * tm_chem / nst,
               1e3 * tm_io / nst, prof ? "" : " [phases overlap on the GPU unless OERCEL_PROFILE=1]");
        logmsg("chemistry per step: reactions %.4f, decay %.4f, feed %.4f ms; %ld active catalysts in %ld rounds\n",
               1e3 * g_t_react / nst, 1e3 * g_t_decay / nst, 1e3 * g_t_feed / nst, g_nact_tot, g_rounds);
        logmsg("cell sort: largest per-step cell displacement %ld; %ld host full sorts (%.3f s; start/restart included)\n", g_maxR,
               g_nsortfull, g_t_sortfull);
    }
    logmsg("done at step %lld%s\n", (long long)s->step, stopped_early ? " (stopped early; restart to continue)" : "");
    if (g_log) fclose(g_log);
    return 0;
}
