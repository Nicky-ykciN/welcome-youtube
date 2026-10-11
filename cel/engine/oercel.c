/*
 * oercel.c — Oercel: 2D dissipative particle dynamics (DPD) engine with local
 * stochastic chemistry, for emergent protocells.  See ../SPEC.md and README.md.
 *
 * Units: rc = 1, kT = 1 (configurable), bead mass = 1.  Periodic square box.
 *
 * Data layout: all per-bead state lives in "slot" order and is re-sorted by
 * cell (stable counting sort; cells are 1 wide in x and split into nsub
 * sub-cells in y, column-major) every step, so the cell list is just
 * cstart[c]..cstart[c+1] and all hot loops stream contiguous memory.  Every
 * bead has a permanent id (gid, 0..N-1) used for the pair-noise hash,
 * snapshots and the event log.  Lipid chains are stored per slot (nxt = slot of
 * the next bead, mpos = position in the chain) and remapped by the sort;
 * slot[gid] is only rebuilt for output.
 *
 * Parallel pair forces: half shell per bead i = its own column upward
 * (y_i .. y_i+1) plus the next column (y_i-1 .. y_i+1), two contiguous slot
 * ranges selected through the sub-cell index.  Columns are grouped into an even number of strips; even
 * strips run concurrently, then odd strips.  A strip only writes to its own
 * columns plus the first column of the next strip, so this is race free with no
 * per-thread buffers, and the summation order per bead does not depend on the
 * thread count -> results are bit-identical for any number of threads.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <omp.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#if defined(__AVX512F__) && defined(__AVX512DQ__) && defined(__AVX512BW__) && defined(__AVX512VL__) && !defined(OERCEL_SCALAR)
#include <immintrin.h>
#define OERCEL_AVX512 1
#endif

#define NTYPES 7
enum { TW = 0, TH = 1, TT = 2, TN = 3, TKA = 4, TKB = 5, TZ = 6 };
static const char *TNAME[NTYPES] = {"W", "H", "T", "N", "Ka", "Kb", "Z"};
#define MAXMLEN 8
#define SQRT12 3.4641016151377545870548926830117

/* ------------------------------------------------------------------ util */

static FILE *g_log = NULL;
static volatile sig_atomic_t g_stop = 0;
static int64_t g_warm_end = 0; /* step at which the warm-up of a fresh start ends (0 = none) */
static void on_signal(int sig) { (void)sig; g_stop = 1; }

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
    fprintf(stderr, "oercel: error: ");
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
    if (posix_memalign(&p, 64, n) != 0 || !p) die("out of memory (%zu bytes)", n);
    return p;
}
static void *xcalloc(size_t n) {
    void *p = xmalloc(n);
    memset(p, 0, n);
    return p;
}

/* Per-bead arrays are allocated with staggered base addresses: identical
 * sizes from an aligned allocator put every array at the same address modulo
 * 4 KiB, so the ~16 streams of the sort/force loops collide in the same L1
 * sets (4K aliasing).  These arrays live for the whole run and are never freed. */
static void *xmalloc_stagger(size_t n) {
    static unsigned k = 0;
    const size_t off = (size_t)((k++ * 7u) % 61u) * 64u + 64u * 3u;
    char *p = xmalloc(n + off + 64);
    return p + off;
}

static double wtime(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

/* ------------------------------------------------------------------ RNG */

/* splitmix64 finaliser (Stafford "Mix13"), a bijection on 64 bits */
static inline uint64_t mix13(uint64_t z) {
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

/* per-step key for the pair noise */
static inline uint64_t step_seed(uint64_t seed, int64_t step) {
    return mix13(mix13(seed ^ 0x5851f42d4c957f2dULL) ^ mix13((uint64_t)step + 0x632be59bd9b4e019ULL));
}

/* symmetric pair noise: uniform on [-sqrt3, sqrt3) (unit variance), a pure
 * function of (seed, step, min(gi,gj), max(gi,gj)) */
static inline double pair_theta(uint64_t sseed, uint32_t gi, uint32_t gj) {
    const uint64_t key = gi < gj ? (((uint64_t)gi << 32) | gj) : (((uint64_t)gj << 32) | gi);
    const uint64_t h = mix13((key * 0x9e3779b97f4a7c15ULL) ^ sseed);
    return (double)(int64_t)h * (SQRT12 / 18446744073709551616.0);
}

/* xoshiro256** for the serial chemistry / initialisation */
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
static long rng_below(rng_t *r, long n) {
    long k = (long)(rng_unif(r) * (double)n);
    return k >= n ? n - 1 : k;
}
static double rng_normal(rng_t *r) {
    double u1 = rng_unif(r), u2 = rng_unif(r);
    if (u1 < 1e-300) u1 = 1e-300;
    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

/* ------------------------------------------------------------------ params */

typedef struct {
    /* physics */
    double L, rho, dt, lambda, gamma, kT;
    double k_bond, r0, k_angle;
    int lip_nH, lip_nT;
    double a[NTYPES][NTYPES];
    /* run control */
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
    /* chemistry */
    int chem;
    long n_chem;
    double r_cat;
    double p_syn_a, p_syn_b, p_rep_a, p_rep_b, mu, p_ld, p_kd, p_nd;
    /* food supply (structure blind, SPEC 3.4) */
    char feed[16];
    double p_feed, feed_cap;
    char vent_shape[16];
    double vent_x, vent_y, vent_r, vent_w;
    int events;
    /* environment (uniform for every bead, SPEC 0/6) */
    double stir_A;
    int stir_n;
    double kT_amp, kT_period;
    /* init soup */
    double f_lip, f_Ka, f_Kb, c_N;
    /* derived */
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
    {"lip_nT", PT_INT, OFF(lip_nT), "3", "tail beads per lipid"},
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

/* keys of removed features (SPEC section 0): a clear error instead of "unknown" */
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
    if (strcmp(s, "K") == 0) return -2; /* generic: Ka and Kb */
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
            double v = strtod(val, &end); /* allow 1e6 */
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
    kv_t *kv = malloc(cap * sizeof(kv_t));
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
        if (n == cap) kv = realloc(kv, (cap *= 2) * sizeof(kv_t));
        snprintf(kv[n].key, sizeof kv[n].key, "%s", k);
        snprintf(kv[n].val, sizeof kv[n].val, "%s", v);
        n++;
    }
    fclose(f);
    *out = kv;
    return n;
}

static void finalize_params(Params *P) {
    P->sigma = sqrt(2.0 * P->gamma * P->kT);
    int mlen = P->lip_nH + P->lip_nT;
    if (P->lip_nH < 1 || P->lip_nT < 1 || mlen > MAXMLEN) die("lipid length must be 2..%d with >=1 head and tail", MAXMLEN);
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
    /* food supply */
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
    /* environment */
    if (P->stir_n < 1) die("stir_n must be >= 1");
    if (P->kT <= 0) die("kT must be > 0");
    if (fabs(P->kT_amp) >= P->kT) die("|kT_amp| must be < kT (the temperature must stay positive)");
    if (P->kT_amp != 0 && P->kT_period <= 0) die("kT_period must be > 0");
}

/* thermostat temperature at time t (slow global cycle, SPEC section 0/6) */
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

/* ------------------------------------------------------------------ system */

typedef struct { int64_t step; int kind; int64_t i; double x, y; int variant; } event_t;
enum { EV_SYN, EV_REP, EV_MUT, EV_DLIP, EV_DK, EV_DN, EV_FEED };
static const char *EVNAME[] = {"syn", "rep", "mut", "dlip", "dK", "dN", "feed"};

typedef struct {
    int N;
    double L;
    /* slot-ordered state (permuted by the cell sort every step) */
    double *x, *y;     /* positions in [0, L) */
    double *vx, *vy;   /* half-step velocity vh; full v = vh + dt/2 f */
    double *fx, *fy;   /* forces of the current configuration */
    double *vtx, *vty; /* Groot-Warren predicted velocity (force input) */
    uint8_t *type;
    uint32_t *gid;     /* permanent bead id */
    int32_t *nxt;      /* slot of the next bead in the lipid chain, -1 if none */
    int8_t *mpos;      /* position in the lipid (0 = first head), -1 = not a lipid */
    /* sort buffers / scratch */
    double *x2, *y2, *vx2, *vy2, *vtx2, *vty2;
    uint8_t *type2;
    uint32_t *gid2;
    int32_t *nxt2;
    int8_t *mpos2;
    int *cellof;
    int *src;  /* old slot of each new slot */
    int *dest; /* new slot of each old slot */
    int *slot; /* slot[gid], rebuilt on demand (output only) */
    int blocksum[256];
    /* cells */
    int ncx, ncy, ncell;
    double icsx, icsy, csx, csy;
    int *cstart;     /* ncell+1 */
    int *hist;       /* nthreads * ncell, parallel sort */
    int nthr_alloc;
    int nstrip;
    int *strip_c0;   /* nstrip+1 */
    /* lipid architecture */
    int mlen, nH;
    /* time */
    int64_t step;
    double time;
    double t_anchor, dt_anchor; /* time = t_anchor + (step - step_anchor) * dt */
    int64_t step_anchor;
    uint64_t seed;
    uint64_t soup_seed; /* provenance: seed of the random soup this run descends from */
    rng_t rng;
    double maxbond;  /* running max since last stats row */
    /* events */
    event_t *ev;
    int nev, evcap;
    /* chemistry scratch */
    int *tlist;      /* per-thread lists, nthreads * N */
    int tcount[256];
    int *glist;      /* merged list, N */
    double bsum[64]; /* fixed-block partial sums of the stirring force (thread-count independent) */
} Sys;
#define NBSUM 64

static void sys_alloc(Sys *s, int N, double L, int mlen, int nH, int nthreads, int nsub) {
    memset(s, 0, sizeof *s);
    s->N = N;
    s->L = L;
    s->mlen = mlen;
    s->nH = nH;
    size_t dn = (size_t)N * sizeof(double);
#define SA(n) xmalloc_stagger(n)
    s->x = SA(dn); s->y = SA(dn); s->vx = SA(dn); s->vy = SA(dn);
    s->fx = SA(dn); s->fy = SA(dn); s->vtx = SA(dn); s->vty = SA(dn);
    memset(s->fx, 0, dn); memset(s->fy, 0, dn);
    s->x2 = SA(dn); s->y2 = SA(dn); s->vx2 = SA(dn); s->vy2 = SA(dn);
    s->vtx2 = SA(dn); s->vty2 = SA(dn);
    s->type = SA(N); s->type2 = SA(N);
    s->mpos = SA(N); s->mpos2 = SA(N);
    s->gid = SA(N * sizeof(uint32_t)); s->gid2 = SA(N * sizeof(uint32_t));
    s->nxt = SA(N * sizeof(int32_t)); s->nxt2 = SA(N * sizeof(int32_t));
    s->cellof = SA(N * sizeof(int));
    s->src = SA(N * sizeof(int));
    s->dest = SA(N * sizeof(int));
    s->slot = SA(N * sizeof(int));
    s->glist = SA(N * sizeof(int));
    s->tlist = SA((size_t)nthreads * N * sizeof(int));
#undef SA
    for (int i = 0; i < N; i++) { s->nxt[i] = -1; s->mpos[i] = -1; }
    s->ncx = (int)floor(L);
    s->ncy = (int)floor(L) * nsub; /* fine y sub-cells, see pair_column() */
    s->ncell = s->ncx * s->ncy;
    s->csx = L / s->ncx;
    s->csy = L / s->ncy;
    s->icsx = s->ncx / L;
    s->icsy = s->ncy / L;
    s->cstart = xcalloc((size_t)(s->ncell + 1) * sizeof(int));
    if (nthreads > 256) die("at most 256 threads");
    s->nthr_alloc = nthreads;
    s->hist = xmalloc((size_t)nthreads * s->ncell * sizeof(int));
    /* strips: even count, width >= 1 column */
    int ns = s->ncx;
    if (ns % 2) ns--;
    if (ns < 2) die("box too small for strip decomposition");
    s->nstrip = ns;
    s->strip_c0 = xmalloc((ns + 1) * sizeof(int));
    for (int k = 0; k <= ns; k++) s->strip_c0[k] = (int)(((long)k * s->ncx) / ns);
    s->evcap = 4096;
    s->ev = xmalloc(s->evcap * sizeof(event_t));
}

static inline void wrap1(double *p, double L) {
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
static inline double minimg(double d, double L) {
    const double h = 0.5 * L;
    if (d > h) d -= L;
    else if (d < -h) d += L;
    return d;
}

static inline int cell_of_pos(const Sys *s, double x, double y) {
    int cx = (int)(x * s->icsx), cy = (int)(y * s->icsy);
    if (cx >= s->ncx) cx = s->ncx - 1;
    if (cy >= s->ncy) cy = s->ncy - 1;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    return cx * s->ncy + cy;
}

static void add_event(Sys *s, int64_t step, int kind, int64_t i, double x, double y, int variant) {
    if (s->nev == s->evcap) {
        s->evcap *= 2;
        event_t *n = xmalloc(s->evcap * sizeof(event_t));
        memcpy(n, s->ev, s->nev * sizeof(event_t));
        free(s->ev);
        s->ev = n;
    }
    event_t *e = &s->ev[s->nev++];
    e->step = step; e->kind = kind; e->i = i; e->x = x; e->y = y; e->variant = variant;
}

/* make slots sl[0..mlen-1] one lipid chain (types set by the caller) */
static void link_lipid(Sys *s, const int *sl) {
    for (int b = 0; b < s->mlen; b++) {
        s->mpos[sl[b]] = (int8_t)b;
        s->nxt[sl[b]] = b + 1 < s->mlen ? sl[b + 1] : -1;
    }
}

static int count_lipids(const Sys *s) {
    int n = 0;
    for (int i = 0; i < s->N; i++) n += s->mpos[i] == 0;
    return n;
}

/* rebuild slot[gid] (needed only for output) */
static void build_slot(Sys *s) {
    for (int d = 0; d < s->N; d++) s->slot[s->gid[d]] = d;
}

/* counter-based uniform deviate for parallel, order-independent decisions:
 * u = hash_u01(hash_key(seed, step, salt), gid) */
static inline uint64_t hash_key(uint64_t seed, int64_t step, uint64_t salt) {
    return mix13(seed ^ mix13((uint64_t)step * 0x9e3779b97f4a7c15ULL + salt));
}
static inline double hash_u01(uint64_t key, uint32_t g) {
    return (double)(mix13(key ^ ((uint64_t)g * 0xd1b54a32d192ed03ULL)) >> 11) * 0x1.0p-53;
}

/* Stable parallel counting sort of all slot arrays by cell index (column-major).
 * The result is the unique stable order, independent of the thread count.
 * Implemented in "gather form" (src[] = inverse permutation): contiguous
 * stores and nearly contiguous loads, one array at a time. */
static void sort_cells(Sys *s) {
    const int N = s->N, nc = s->ncell, ncx = s->ncx, ncy = s->ncy;
    const double icsx = s->icsx, icsy = s->icsy;
    int nth = omp_get_max_threads();
    if (nth > s->nthr_alloc) nth = s->nthr_alloc;
    int *restrict hist = s->hist;
    int *restrict cs = s->cstart;
    int *restrict cellof = s->cellof;
    int *restrict src = s->src;
    int *restrict dest = s->dest;
    const double *restrict x = s->x, *restrict y = s->y, *restrict vx = s->vx, *restrict vy = s->vy;
    const double *restrict vtx = s->vtx, *restrict vty = s->vty;
    const uint8_t *restrict type = s->type;
    const uint32_t *restrict gid = s->gid;
    const int32_t *restrict nxt = s->nxt;
    const int8_t *restrict mpos = s->mpos;
    double *restrict x2 = s->x2, *restrict y2 = s->y2, *restrict vx2 = s->vx2, *restrict vy2 = s->vy2;
    double *restrict vtx2 = s->vtx2, *restrict vty2 = s->vty2;
    uint8_t *restrict type2 = s->type2;
    uint32_t *restrict gid2 = s->gid2;
    int32_t *restrict nxt2 = s->nxt2;
    int8_t *restrict mpos2 = s->mpos2;
#pragma omp parallel num_threads(nth)
    {
        const int t = omp_get_thread_num(), nt = omp_get_num_threads();
        const int lo = (int)(((long)t * N) / nt), hi = (int)(((long)(t + 1) * N) / nt);
        int *restrict h = hist + (size_t)t * nc;
        memset(h, 0, nc * sizeof(int));
        for (int i = lo; i < hi; i++) {
            int cx = (int)(x[i] * icsx), cy = (int)(y[i] * icsy);
            cx = cx >= ncx ? ncx - 1 : cx;
            cy = cy >= ncy ? ncy - 1 : cy;
            const int c = cx * ncy + cy;
            cellof[i] = c;
            h[c]++;
        }
#pragma omp barrier
        /* exclusive scan over (cell, thread) in parallel: block sums first */
        {
            const int c0 = (int)(((long)t * nc) / nt), c1 = (int)(((long)(t + 1) * nc) / nt);
            int sum = 0;
            for (int tt = 0; tt < nt; tt++) {
                const int *restrict ht = hist + (size_t)tt * nc;
                for (int c = c0; c < c1; c++) sum += ht[c];
            }
            s->blocksum[t] = sum;
#pragma omp barrier
            int run = 0;
            for (int tt = 0; tt < t; tt++) run += s->blocksum[tt];
            for (int c = c0; c < c1; c++) {
                cs[c] = run;
                for (int tt = 0; tt < nt; tt++) {
                    const int v = hist[(size_t)tt * nc + c];
                    hist[(size_t)tt * nc + c] = run;
                    run += v;
                }
            }
            if (t == nt - 1) cs[nc] = run;
        }
#pragma omp barrier
        for (int i = lo; i < hi; i++) {
            const int d = h[cellof[i]]++;
            src[d] = i;
            dest[i] = d;
        }
#pragma omp barrier
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) x2[d] = x[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) y2[d] = y[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) vx2[d] = vx[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) vy2[d] = vy[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) vtx2[d] = vtx[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) vty2[d] = vty[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) type2[d] = type[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) gid2[d] = gid[src[d]];
#pragma omp for schedule(static) nowait
        for (int d = 0; d < N; d++) mpos2[d] = mpos[src[d]];
#pragma omp for schedule(static)
        for (int d = 0; d < N; d++) {
            const int32_t o = nxt[src[d]];
            nxt2[d] = o < 0 ? -1 : dest[o];
        }
    }
    double *t;
    t = s->x; s->x = s->x2; s->x2 = t;
    t = s->y; s->y = s->y2; s->y2 = t;
    t = s->vx; s->vx = s->vx2; s->vx2 = t;
    t = s->vy; s->vy = s->vy2; s->vy2 = t;
    t = s->vtx; s->vtx = s->vtx2; s->vtx2 = t;
    t = s->vty; s->vty = s->vty2; s->vty2 = t;
    uint8_t *tu = s->type; s->type = s->type2; s->type2 = tu;
    uint32_t *tg = s->gid; s->gid = s->gid2; s->gid2 = tg;
    int32_t *tn = s->nxt; s->nxt = s->nxt2; s->nxt2 = tn;
    int8_t *tm = s->mpos; s->mpos = s->mpos2; s->mpos2 = tm;
}

/* ------------------------------------------------------------------ forces */

typedef struct {
    double a[8 * 8];
    double gamma, sdt;
    uint64_t sseed;
} pairpar_t;

#ifndef OERCEL_AVX512
#define PBUF 128
static inline __attribute__((always_inline)) void
pair_seg(const int j0, const int j1, const double xi, const double yi, const double vxi, const double vyi,
         const uint32_t gi, const double *restrict arow, const double gam, const double sdt, const uint64_t sseed,
         const double *restrict x, const double *restrict y, const double *restrict vx, const double *restrict vy,
         const uint8_t *restrict ty, const uint32_t *restrict gid, double *restrict fx, double *restrict fy,
         double *fxi, double *fyi) {
    double ax = 0.0, ay = 0.0;
    int jb[PBUF];
    double dxb[PBUF], dyb[PBUF], r2b[PBUF];
    for (int c0 = j0; c0 < j1; c0 += PBUF) {
        const int c1 = j1 - c0 > PBUF ? c0 + PBUF : j1;
        int n = 0;
        /* branchless compaction of candidates inside the cutoff */
        for (int j = c0; j < c1; j++) {
            const double dx = xi - x[j], dy = yi - y[j];
            const double r2 = dx * dx + dy * dy;
            jb[n] = j;
            dxb[n] = dx;
            dyb[n] = dy;
            r2b[n] = r2;
            n += (r2 < 1.0) & (r2 > 1e-24);
        }
        for (int k = 0; k < n; k++) {
            const int j = jb[k];
            const double dx = dxb[k], dy = dyb[k], r2 = r2b[k];
            const double r = sqrt(r2);
            const double ir = 1.0 / r;
            const double w = 1.0 - r;
            const double rv = (dx * (vxi - vx[j]) + dy * (vyi - vy[j])) * ir;
            const double th = pair_theta(sseed, gi, gid[j]);
            const double fm = w * (arow[ty[j]] - gam * w * rv + sdt * th) * ir;
            const double ffx = fm * dx, ffy = fm * dy;
            ax += ffx;
            ay += ffy;
            fx[j] -= ffx;
            fy[j] -= ffy;
        }
    }
    *fxi += ax;
    *fyi += ay;
}

#endif

#ifdef OERCEL_AVX512
/* AVX-512 version: the j candidates of bead i form contiguous slot ranges, so
 * 8 of them are processed per vector with masked contiguous loads/stores. */
typedef struct {
    __m512d xi, yi, vxi, vyi, arow;
    __m256i gi;
    __m512d ax, ay;
} ivec_t;

static inline __attribute__((always_inline)) void
pair_seg_v(const int j0, const int j1, ivec_t *iv, const double shx, const double shy, const double gam,
           const double sdt, const uint64_t sseed, const double *restrict x, const double *restrict y,
           const double *restrict vx, const double *restrict vy, const uint8_t *restrict ty,
           const uint32_t *restrict gid, double *restrict fx, double *restrict fy) {
    const __m512d one = _mm512_set1_pd(1.0), tiny = _mm512_set1_pd(1e-24);
    const __m512d half = _mm512_set1_pd(0.5), c15 = _mm512_set1_pd(1.5);
    const __m512d xi = _mm512_sub_pd(iv->xi, _mm512_set1_pd(shx));
    const __m512d yi = _mm512_sub_pd(iv->yi, _mm512_set1_pd(shy));
    for (int j = j0; j < j1; j += 8) {
        const int rem = j1 - j;
        const __mmask8 tail = rem >= 8 ? (__mmask8)0xFF : (__mmask8)((1u << rem) - 1u);
        const __m512d dx = _mm512_sub_pd(xi, _mm512_maskz_loadu_pd(tail, x + j));
        const __m512d dy = _mm512_sub_pd(yi, _mm512_maskz_loadu_pd(tail, y + j));
        const __m512d r2 = _mm512_fmadd_pd(dx, dx, _mm512_mul_pd(dy, dy));
        __mmask8 m = _mm512_mask_cmp_pd_mask(tail, r2, one, _CMP_LT_OQ);
        m = _mm512_mask_cmp_pd_mask(m, r2, tiny, _CMP_GT_OQ);
        if (!m) continue;
        /* 1/r: rsqrt14 + two Newton steps (full double precision) */
        __m512d ir = _mm512_rsqrt14_pd(r2);
        const __m512d hr2 = _mm512_mul_pd(half, r2);
        ir = _mm512_mul_pd(ir, _mm512_fnmadd_pd(hr2, _mm512_mul_pd(ir, ir), c15));
        ir = _mm512_mul_pd(ir, _mm512_fnmadd_pd(hr2, _mm512_mul_pd(ir, ir), c15));
        const __m512d r = _mm512_mul_pd(r2, ir);
        const __m512d w = _mm512_sub_pd(one, r);
        const __m512d dvx = _mm512_sub_pd(iv->vxi, _mm512_maskz_loadu_pd(m, vx + j));
        const __m512d dvy = _mm512_sub_pd(iv->vyi, _mm512_maskz_loadu_pd(m, vy + j));
        const __m512d rv = _mm512_mul_pd(_mm512_fmadd_pd(dx, dvx, _mm512_mul_pd(dy, dvy)), ir);
        /* repulsion parameter from the 8-entry row of bead i */
        const __m512i tj = _mm512_cvtepu8_epi64(_mm_maskz_loadu_epi8(m, ty + j));
        const __m512d aij = _mm512_permutexvar_pd(tj, iv->arow);
        /* symmetric pair noise, identical to pair_theta() */
        const __m256i gj = _mm256_maskz_loadu_epi32(m, gid + j);
        const __m512i lo = _mm512_cvtepu32_epi64(_mm256_min_epu32(iv->gi, gj));
        const __m512i hi = _mm512_cvtepu32_epi64(_mm256_max_epu32(iv->gi, gj));
        __m512i h = _mm512_or_si512(_mm512_slli_epi64(lo, 32), hi);
        h = _mm512_xor_si512(_mm512_mullo_epi64(h, _mm512_set1_epi64((long long)0x9e3779b97f4a7c15ULL)),
                             _mm512_set1_epi64((long long)sseed));
        h = _mm512_mullo_epi64(_mm512_xor_si512(h, _mm512_srli_epi64(h, 30)), _mm512_set1_epi64((long long)0xbf58476d1ce4e5b9ULL));
        h = _mm512_mullo_epi64(_mm512_xor_si512(h, _mm512_srli_epi64(h, 27)), _mm512_set1_epi64((long long)0x94d049bb133111ebULL));
        h = _mm512_xor_si512(h, _mm512_srli_epi64(h, 31));
        const __m512d th = _mm512_mul_pd(_mm512_cvtepi64_pd(h), _mm512_set1_pd(SQRT12 / 18446744073709551616.0));
        /* fm = w (a - gamma w rv + sdt th) / r */
        __m512d fm = _mm512_fmadd_pd(_mm512_set1_pd(sdt), th, aij);
        fm = _mm512_fnmadd_pd(_mm512_mul_pd(_mm512_set1_pd(gam), w), rv, fm);
        fm = _mm512_mul_pd(_mm512_mul_pd(w, fm), ir);
        const __m512d ffx = _mm512_maskz_mul_pd(m, fm, dx);
        const __m512d ffy = _mm512_maskz_mul_pd(m, fm, dy);
        iv->ax = _mm512_add_pd(iv->ax, ffx);
        iv->ay = _mm512_add_pd(iv->ay, ffy);
        _mm512_mask_storeu_pd(fx + j, m, _mm512_sub_pd(_mm512_maskz_loadu_pd(m, fx + j), ffx));
        _mm512_mask_storeu_pd(fy + j, m, _mm512_sub_pd(_mm512_maskz_loadu_pd(m, fy + j), ffy));
    }
}
#endif

/* Pair forces of all beads i in column cx.  Columns are 1 cell wide in x and
 * sorted by fine y sub-cells (height csy = 1/nsub), so the candidates of bead i
 * are two contiguous slot ranges selected by its own y window:
 *   own column:  j > i with sub-cell <= floor((y_i + 1)/csy)   (upward only)
 *   next column: sub-cells floor((y_i - 1)/csy) .. floor((y_i + 1)/csy)
 * (plus periodic wrap pieces).  Every pair with r < 1 is visited exactly once. */
static void pair_column(Sys *s, const pairpar_t *pp, const int cx) {
    const int ncx = s->ncx, ncy = s->ncy;
    const double L = s->L, icsy = s->icsy;
    const int *restrict cs = s->cstart;
    const double *restrict x = s->x, *restrict y = s->y, *restrict vx = s->vtx, *restrict vy = s->vty;
    const uint8_t *restrict ty = s->type;
    const uint32_t *restrict gid = s->gid;
    double *restrict fx = s->fx, *restrict fy = s->fy;
    const double gam = pp->gamma, sdt = pp->sdt;
    const uint64_t sseed = pp->sseed;
    int cxn = cx + 1;
    double shx = 0.0;
    if (cxn == ncx) { cxn = 0; shx = L; }
    const int base = cx * ncy, nb = cxn * ncy;
    const int i0 = cs[base], i1 = cs[base + ncy];
    for (int i = i0; i < i1; i++) {
        const double yi = y[i];
        const int khi = (int)((yi + 1.0) * icsy);              /* yi + 1 > 0: truncation = floor */
        const int klo = (int)((yi - 1.0) * icsy + ncy) - ncy;  /* floor, may be negative */
        int sj0[4], sj1[4], nseg = 0;
        double ssx[4], ssy[4];
        /* own column, upward */
        sj0[nseg] = i + 1; sj1[nseg] = cs[base + (khi < ncy ? khi + 1 : ncy)]; ssx[nseg] = 0.0; ssy[nseg] = 0.0; nseg++;
        if (khi >= ncy) { sj0[nseg] = cs[base]; sj1[nseg] = cs[base + khi - ncy + 1]; ssx[nseg] = 0.0; ssy[nseg] = L; nseg++; }
        /* next column, full window */
        if (klo >= 0 && khi < ncy) {
            sj0[nseg] = cs[nb + klo]; sj1[nseg] = cs[nb + khi + 1]; ssx[nseg] = shx; ssy[nseg] = 0.0; nseg++;
        } else if (klo < 0) {
            sj0[nseg] = cs[nb + klo + ncy]; sj1[nseg] = cs[nb + ncy]; ssx[nseg] = shx; ssy[nseg] = -L; nseg++;
            sj0[nseg] = cs[nb]; sj1[nseg] = cs[nb + khi + 1]; ssx[nseg] = shx; ssy[nseg] = 0.0; nseg++;
        } else {
            sj0[nseg] = cs[nb + klo]; sj1[nseg] = cs[nb + ncy]; ssx[nseg] = shx; ssy[nseg] = 0.0; nseg++;
            sj0[nseg] = cs[nb]; sj1[nseg] = cs[nb + khi - ncy + 1]; ssx[nseg] = shx; ssy[nseg] = L; nseg++;
        }
#ifdef OERCEL_AVX512
        ivec_t iv;
        iv.xi = _mm512_set1_pd(x[i]);
        iv.yi = _mm512_set1_pd(yi);
        iv.vxi = _mm512_set1_pd(vx[i]);
        iv.vyi = _mm512_set1_pd(vy[i]);
        iv.arow = _mm512_loadu_pd(pp->a + 8 * ty[i]);
        iv.gi = _mm256_set1_epi32((int)gid[i]);
        iv.ax = _mm512_setzero_pd();
        iv.ay = _mm512_setzero_pd();
        for (int k = 0; k < nseg; k++)
            pair_seg_v(sj0[k], sj1[k], &iv, ssx[k], ssy[k], gam, sdt, sseed, x, y, vx, vy, ty, gid, fx, fy);
        fx[i] += _mm512_reduce_add_pd(iv.ax);
        fy[i] += _mm512_reduce_add_pd(iv.ay);
#else
        const double xi = x[i], vxi = vx[i], vyi = vy[i];
        const uint32_t gi = gid[i];
        const double *arow = pp->a + 8 * ty[i];
        double fxi = 0.0, fyi = 0.0;
        for (int k = 0; k < nseg; k++)
            pair_seg(sj0[k], sj1[k], xi - ssx[k], yi - ssy[k], vxi, vyi, gi, arow, gam, sdt, sseed, x, y, vx, vy, ty, gid,
                     fx, fy, &fxi, &fyi);
        fx[i] += fxi;
        fy[i] += fyi;
#endif
    }
}

/* repulsion used at a given step: during the warm-up of a fresh random start
 * the part of a_ij above the water value 25 is ramped in linearly */
static double a_eff(const Params *P, int i, int j, int64_t step, int64_t warm_end) {
    const double a = P->a[i][j];
    if (step >= warm_end || P->warmup <= 0 || a <= 25.0) return a;
    const double f = 1.0 - (double)(warm_end - step) / (double)P->warmup;
    return 25.0 + (a - 25.0) * (f < 0 ? 0 : f);
}

/* sin(2 pi u) for any finite u, branch free (vectorisable): reduce to
 * |2 pi r| <= pi/2 and use the Taylor series up to x^21 (truncation < 2e-18;
 * agrees with libm sin(2 pi u) to < 3e-15, which is the rounding of 2 pi u
 * itself, see tests/forcetest.c) */
static inline double sin2pi(double u) {
    u -= rint(u);                              /* [-1/2, 1/2] */
    const double a = fabs(u);
    const double r = a > 0.25 ? 0.5 - a : a;   /* sin(2 pi (1/2 - a)) = sin(2 pi a) */
    const double x = 6.283185307179586476925286766559 * r, x2 = x * x;
    double p = -1.9572941063391261e-20;         /* -1/21! */
    p = p * x2 + 8.2206352466243298e-18;        /* 1/19! */
    p = p * x2 - 2.8114572543455206e-15;        /* -1/17! */
    p = p * x2 + 7.6471637318198164e-13;        /* 1/15! */
    p = p * x2 - 1.6059043836821613e-10;        /* -1/13! */
    p = p * x2 + 2.5052108385441720e-08;        /* 1/11! */
    p = p * x2 - 2.7557319223985893e-06;        /* -1/9! */
    p = p * x2 + 1.9841269841269841e-04;        /* 1/7! */
    p = p * x2 - 8.3333333333333333e-03;        /* -1/5! */
    p = p * x2 + 1.6666666666666667e-01;        /* 1/3! */
    const double v = x - x * x2 * p;           /* x - x^3/3! + ... */
    return u < 0.0 ? -v : v;
}

/* Pair forces of the configuration at time t (step), plus the stirring body
 * force.  kT(t) enters only through sigma = sqrt(2 gamma kT(t)).
 * Stirring (Kolmogorov flow): every bead gets f_x = A sin(2 pi n y / L); the
 * net force of the finite sample (sum over beads, ~A sqrt(N/2), zero on
 * average) is subtracted uniformly from every bead so total momentum stays
 * exactly conserved.  The sum runs over NBSUM fixed blocks -> the result does
 * not depend on the thread count. */
/* Start of the force computation, called by every thread inside the parallel
 * region of pair_forces (orphaned worksharing loops): f = 0, or f = stirring
 * force minus its mean.  Kept out of line so that the hot pair kernel of the
 * region is compiled exactly as without stirring. */
static void __attribute__((noinline)) force_init(Sys *s, const Params *P) {
    const int N = s->N;
    const double A = P->stir_A, kn = (double)P->stir_n / s->L;
    double *restrict fx = s->fx, *restrict fy = s->fy;
    if (A == 0.0) {
#pragma omp for schedule(static)
        for (int i = 0; i < N; i++) {
            fx[i] = 0.0;
            fy[i] = 0.0;
        }
        return;
    }
    const double *restrict y = s->y;
#pragma omp for schedule(static)
    for (int b = 0; b < NBSUM; b++) {
        const int lo = (int)(((long)b * N) / NBSUM), hi = (int)(((long)(b + 1) * N) / NBSUM);
        double sum = 0.0;
#pragma omp simd reduction(+ : sum)
        for (int i = lo; i < hi; i++) {
            const double f = A * sin2pi(kn * y[i]);
            fx[i] = f;
            fy[i] = 0.0;
            sum += f;
        }
        s->bsum[b] = sum;
    }
    double tot = 0.0; /* every thread sums the NBSUM blocks in the same order */
    for (int b = 0; b < NBSUM; b++) tot += s->bsum[b];
    const double mean = tot / N;
#pragma omp for schedule(static)
    for (int i = 0; i < N; i++) fx[i] -= mean;
}

static void pair_forces(Sys *s, const Params *P, int64_t step, double t) {
    pairpar_t pp;
    memset(&pp, 0, sizeof pp);
    for (int i = 0; i < NTYPES; i++)
        for (int j = 0; j < NTYPES; j++) pp.a[8 * i + j] = a_eff(P, i, j, step, g_warm_end);
    pp.gamma = P->gamma;
    pp.sdt = sqrt(2.0 * P->gamma * kT_at(P, t)) / sqrt(P->dt);
    pp.sseed = step_seed(s->seed, step);
    const int ns = s->nstrip;
#pragma omp parallel
    {
        force_init(s, P);
        for (int ph = 0; ph < 2; ph++) {
#pragma omp for schedule(static)
            for (int st = ph; st < ns; st += 2)
                for (int cx = s->strip_c0[st]; cx < s->strip_c0[st + 1]; cx++) pair_column(s, &pp, cx);
        }
    }
}

/* harmonic bonds + angle term of the lipid chain starting at slot h */
static inline void chain_forces(Sys *s, const int h, const double kb, const double r0, const double ka, double *mb) {
    const int ml = s->mlen;
    const double L = s->L;
    const double *restrict x = s->x, *restrict y = s->y;
    double *restrict fx = s->fx, *restrict fy = s->fy;
    int sl[MAXMLEN];
    double bx[MAXMLEN], by[MAXMLEN], bl[MAXMLEN];
    int n = 0;
    for (int d = h; d >= 0 && n < ml; d = s->nxt[d]) sl[n++] = d;
    for (int b = 0; b < n - 1; b++) {
        const int i = sl[b], j = sl[b + 1];
        const double dx = minimg(x[j] - x[i], L), dy = minimg(y[j] - y[i], L);
        const double r = sqrt(dx * dx + dy * dy);
        bx[b] = dx; by[b] = dy; bl[b] = r;
        if (r > *mb) *mb = r;
        const double f = -kb * (r - r0) / r; /* force on j along (dx,dy) */
        fx[j] += f * dx; fy[j] += f * dy;
        fx[i] -= f * dx; fy[i] -= f * dy;
    }
    if (ka != 0.0) {
        for (int b = 0; b < n - 2; b++) {
            const int i = sl[b], j = sl[b + 1], k = sl[b + 2];
            const double ax = bx[b], ay = by[b], cxv = bx[b + 1], cyv = by[b + 1];
            const double la = bl[b], lc = bl[b + 1];
            const double ilac = 1.0 / (la * lc);
            const double cs = (ax * cxv + ay * cyv) * ilac;
            /* U = ka (1 - cos); dU/da = -ka (c/(la lc) - cos a/la^2) */
            const double dUax = -ka * (cxv * ilac - cs * ax / (la * la));
            const double dUay = -ka * (cyv * ilac - cs * ay / (la * la));
            const double dUcx = -ka * (ax * ilac - cs * cxv / (lc * lc));
            const double dUcy = -ka * (ay * ilac - cs * cyv / (lc * lc));
            fx[i] += dUax; fy[i] += dUay;
            fx[j] += -dUax + dUcx; fy[j] += -dUay + dUcy;
            fx[k] -= dUcx; fy[k] -= dUcy;
        }
    }
}

/* Bonded forces.  Every bead belongs to at most one chain, so chains can be
 * processed concurrently without write conflicts; each thread takes the chains
 * whose first bead lies in its slot range (cache locality, the beads of a chain
 * are spatial neighbours), and the per-bead summation order is fixed ->
 * deterministic for any thread count. */
static void bonded_forces(Sys *s, const Params *P) {
    const int N = s->N;
    const double kb = P->k_bond, r0 = P->r0, ka = P->k_angle;
    double mbt = s->maxbond;
#pragma omp parallel reduction(max : mbt)
    {
        const int t = omp_get_thread_num(), nt = omp_get_num_threads();
        const int lo = (int)(((long)t * N) / nt), hi = (int)(((long)(t + 1) * N) / nt);
        const int8_t *restrict mpos = s->mpos;
        double mb = 0.0;
        for (int d = lo; d < hi; d++)
            if (mpos[d] == 0) chain_forces(s, d, kb, r0, ka, &mb);
        if (mb > mbt) mbt = mb;
    }
    s->maxbond = mbt;
}

/* ------------------------------------------------------------------ chemistry */

typedef struct { int slot; double d2; } nbr_t;
#define CHEM_MARGIN 0.5 /* max displacement since the last cell sort that chemistry tolerates */

/* all beads of the given type within rcut of slot ks, sorted by distance (ties
 * by gid).  Uses the cell index of the last sort: the sub-cells of a column are
 * contiguous in slot order, so each column contributes one or two slot ranges. */
static int find_type_near(Sys *s, int ks, double rcut, int type, nbr_t *out, int maxout) {
    const double xk = s->x[ks], yk = s->y[ks], L = s->L, r2c = rcut * rcut;
    const int ncx = s->ncx, ncy = s->ncy;
    const int c = cell_of_pos(s, xk, yk);
    const int cx = c / ncy, cy = c % ncy;
    const int rx = (int)ceil((rcut + CHEM_MARGIN) * s->icsx), ry = (int)ceil((rcut + CHEM_MARGIN) * s->icsy);
    int n = 0;
    for (int ox = -rx; ox <= rx; ox++) {
        int cxx = cx + ox;
        cxx += cxx < 0 ? ncx : 0;
        cxx -= cxx >= ncx ? ncx : 0;
        const int base = cxx * ncy;
        int r0[2], r1[2], nr = 0;
        const int lo = cy - ry, hi = cy + ry; /* inclusive sub-cell window */
        if (lo >= 0 && hi < ncy) { r0[nr] = s->cstart[base + lo]; r1[nr] = s->cstart[base + hi + 1]; nr++; }
        else if (lo < 0) {
            r0[nr] = s->cstart[base + lo + ncy]; r1[nr] = s->cstart[base + ncy]; nr++;
            r0[nr] = s->cstart[base]; r1[nr] = s->cstart[base + hi + 1]; nr++;
        } else {
            r0[nr] = s->cstart[base + lo]; r1[nr] = s->cstart[base + ncy]; nr++;
            r0[nr] = s->cstart[base]; r1[nr] = s->cstart[base + hi - ncy + 1]; nr++;
        }
        for (int q = 0; q < nr; q++)
            for (int j = r0[q]; j < r1[q]; j++) {
                if (s->type[j] != type || j == ks) continue;
                const double dx = minimg(s->x[j] - xk, L), dy = minimg(s->y[j] - yk, L);
                const double d2 = dx * dx + dy * dy;
                if (d2 < r2c && n < maxout) {
                    out[n].slot = j;
                    out[n].d2 = d2;
                    n++;
                }
            }
    }
    /* insertion sort by distance, ties by gid for determinism */
    for (int a = 1; a < n; a++) {
        nbr_t t = out[a];
        int b = a - 1;
        while (b >= 0 && (out[b].d2 > t.d2 || (out[b].d2 == t.d2 && s->gid[out[b].slot] > s->gid[t.slot]))) {
            out[b + 1] = out[b];
            b--;
        }
        out[b + 1] = t;
    }
    return n;
}

/* Parallel scan: slots d for which COND holds go to s->glist in increasing
 * slot order (independent of the thread count); the count goes to nout. */
#define COLLECT_SLOTS(s, COND, nout)                                                    \
    do {                                                                                \
        int nth_ = omp_get_max_threads();                                               \
        if (nth_ > (s)->nthr_alloc) nth_ = (s)->nthr_alloc;                             \
        int tot_ = 0;                                                                   \
        _Pragma("omp parallel num_threads(nth_) reduction(+ : tot_)") {                 \
            const int t_ = omp_get_thread_num(), nt_ = omp_get_num_threads();          \
            const int lo_ = (int)(((long)t_ * (s)->N) / nt_);                           \
            const int hi_ = (int)(((long)(t_ + 1) * (s)->N) / nt_);                     \
            int *lst_ = (s)->tlist + (size_t)t_ * (s)->N, n_ = 0;                       \
            for (int d = lo_; d < hi_; d++)                                             \
                if (COND) lst_[n_++] = d;                                               \
            (s)->tcount[t_] = n_;                                                       \
            tot_ += n_;                                                                 \
            _Pragma("omp barrier") int off_ = 0;                                        \
            for (int tt_ = 0; tt_ < t_; tt_++) off_ += (s)->tcount[tt_];                \
            memcpy((s)->glist + off_, lst_, (size_t)n_ * sizeof(int));                  \
        }                                                                               \
        (nout) = tot_;                                                                  \
    } while (0)

/* conservative overlap energy sum 1/2 a (1-r)^2 between a would-be lipid chain
 * (centre c, direction u) and all other beads within rc (excluding the beads
 * sl[] that will form it).  Uses the cell index of the last sort. */
static double chain_overlap_energy(Sys *s, const Params *P, double cx0, double cy0, double ux, double uy,
                                   const int *sl) {
    const int ml = s->mlen, ncx = s->ncx, ncy = s->ncy;
    const double L = s->L;
    double U = 0.0;
    for (int b = 0; b < ml; b++) {
        const double off = (b - 0.5 * (ml - 1)) * P->r0;
        double px = cx0 + off * ux, py = cy0 + off * uy;
        wrap1(&px, L);
        wrap1(&py, L);
        const int tb = b < s->nH ? TH : TT;
        const int c = cell_of_pos(s, px, py);
        const int cx = c / ncy, cy = c % ncy;
        const int rx = (int)ceil((1.0 + CHEM_MARGIN) * s->icsx), ry = (int)ceil((1.0 + CHEM_MARGIN) * s->icsy);
        for (int ox = -rx; ox <= rx; ox++) {
            int cxx = cx + ox;
            cxx += cxx < 0 ? ncx : 0;
            cxx -= cxx >= ncx ? ncx : 0;
            const int base = cxx * ncy;
            for (int oy = -ry; oy <= ry; oy++) {
                int cyy = cy + oy;
                cyy += cyy < 0 ? ncy : 0;
                cyy -= cyy >= ncy ? ncy : 0;
                for (int j = s->cstart[base + cyy]; j < s->cstart[base + cyy + 1]; j++) {
                    int skip = 0;
                    for (int q = 0; q < ml; q++) skip |= j == sl[q];
                    if (skip) continue;
                    const double dx = minimg(s->x[j] - px, L), dy = minimg(s->y[j] - py, L);
                    const double r2 = dx * dx + dy * dy;
                    if (r2 >= 1.0) continue;
                    const double w = 1.0 - sqrt(r2);
                    U += 0.5 * P->a[tb][s->type[j]] * w * w;
                }
            }
        }
    }
    return U;
}

/* Local insertion relaxation of a newly synthesised chain: steepest descent on
 * (pair overlap with the frozen surroundings + its own bonds and angles),
 * moving only the chain's beads, displacement per bead per iteration <= 0.05. */
static void relax_new_chain(Sys *s, const Params *P, const int *sl) {
    const int ml = s->mlen, ncx = s->ncx, ncy = s->ncy;
    const double L = s->L, cap = 0.05, alpha = 0.002;
    enum { MAXNB = 512 };
    int nbj[MAXNB];
    int nnb = 0;
    /* neighbours within 1 + (iterations * cap) of any chain bead, collected once */
    const double reach = 1.0 + cap * P->syn_relax;
    const double reach2 = reach * reach;
    for (int b = 0; b < ml && nnb < MAXNB; b++) {
        const double px = s->x[sl[b]], py = s->y[sl[b]];
        const int c = cell_of_pos(s, px, py);
        const int cx = c / ncy, cy = c % ncy;
        const int rx = (int)ceil((reach + CHEM_MARGIN) * s->icsx), ry = (int)ceil((reach + CHEM_MARGIN) * s->icsy);
        for (int ox = -rx; ox <= rx; ox++) {
            int cxx = cx + ox;
            cxx += cxx < 0 ? ncx : 0;
            cxx -= cxx >= ncx ? ncx : 0;
            for (int oy = -ry; oy <= ry; oy++) {
                int cyy = cy + oy;
                cyy += cyy < 0 ? ncy : 0;
                cyy -= cyy >= ncy ? ncy : 0;
                const int cc = cxx * ncy + cyy;
                for (int j = s->cstart[cc]; j < s->cstart[cc + 1]; j++) {
                    int skip = 0;
                    for (int q = 0; q < ml; q++) skip |= j == sl[q];
                    for (int q = 0; q < nnb && !skip; q++) skip |= nbj[q] == j;
                    if (skip) continue;
                    const double dx = minimg(s->x[j] - px, L), dy = minimg(s->y[j] - py, L);
                    if (dx * dx + dy * dy < reach2 && nnb < MAXNB) nbj[nnb++] = j;
                }
            }
        }
    }
    for (int it = 0; it < P->syn_relax; it++) {
        double fx[MAXMLEN] = {0}, fy[MAXMLEN] = {0};
        for (int b = 0; b < ml; b++) {
            const int i = sl[b];
            for (int q = 0; q < nnb; q++) {
                const int j = nbj[q];
                const double dx = minimg(s->x[i] - s->x[j], L), dy = minimg(s->y[i] - s->y[j], L);
                const double r2 = dx * dx + dy * dy;
                if (r2 >= 1.0 || r2 < 1e-24) continue;
                const double r = sqrt(r2);
                const double f = P->a[s->type[i]][s->type[j]] * (1.0 - r) / r;
                fx[b] += f * dx;
                fy[b] += f * dy;
            }
        }
        double bx[MAXMLEN], by[MAXMLEN], bl[MAXMLEN];
        for (int b = 0; b < ml - 1; b++) {
            const int i = sl[b], j = sl[b + 1];
            bx[b] = minimg(s->x[j] - s->x[i], L);
            by[b] = minimg(s->y[j] - s->y[i], L);
            bl[b] = sqrt(bx[b] * bx[b] + by[b] * by[b]);
            const double f = -P->k_bond * (bl[b] - P->r0) / bl[b];
            fx[b + 1] += f * bx[b]; fy[b + 1] += f * by[b];
            fx[b] -= f * bx[b]; fy[b] -= f * by[b];
        }
        for (int b = 0; b < ml - 2 && P->k_angle != 0.0; b++) {
            const double ax = bx[b], ay = by[b], cxv = bx[b + 1], cyv = by[b + 1], la = bl[b], lc = bl[b + 1];
            const double ilac = 1.0 / (la * lc), cs = (ax * cxv + ay * cyv) * ilac, ka = P->k_angle;
            const double dUax = -ka * (cxv * ilac - cs * ax / (la * la)), dUay = -ka * (cyv * ilac - cs * ay / (la * la));
            const double dUcx = -ka * (ax * ilac - cs * cxv / (lc * lc)), dUcy = -ka * (ay * ilac - cs * cyv / (lc * lc));
            fx[b] += dUax; fy[b] += dUay;
            fx[b + 1] += -dUax + dUcx; fy[b + 1] += -dUay + dUcy;
            fx[b + 2] -= dUcx; fy[b + 2] -= dUcy;
        }
        for (int b = 0; b < ml; b++) {
            double mx = alpha * fx[b], my = alpha * fy[b];
            const double m = sqrt(mx * mx + my * my);
            if (m > cap) { mx *= cap / m; my *= cap / m; }
            s->x[sl[b]] += mx;
            s->y[sl[b]] += my;
            wrap1(&s->x[sl[b]], L);
            wrap1(&s->y[sl[b]], L);
        }
    }
}

static int feed_supply(Sys *s, const Params *P, int64_t step);
static double g_t_react = 0, g_t_decay = 0, g_t_feed = 0;

/* One chemistry check: lipid synthesis / catalyst replication, decay, food
 * supply.  Returns 1 if beads moved. */
static int chemistry(Sys *s, const Params *P, int64_t step) {
    int moved = 0;
    const int ml = s->mlen;
    const double L = s->L;
    double tc0 = wtime();
    {
        /* catalysts, in slot order, then shuffled with the serial RNG */
        int nk;
        const uint8_t *ty = s->type;
        COLLECT_SLOTS(s, (ty[d] == TKA || ty[d] == TKB), nk);
        int *ks = xmalloc((nk + 1) * sizeof(int));
        memcpy(ks, s->glist, nk * sizeof(int));
        for (int a = nk - 1; a > 0; a--) {
            int b = (int)rng_below(&s->rng, a + 1);
            int t = ks[a]; ks[a] = ks[b]; ks[b] = t;
        }
        nbr_t nb[256];
        for (int q = 0; q < nk; q++) {
            const int k = ks[q];
            if (s->type[k] != TKA && s->type[k] != TKB) continue;
            const int var = s->type[k] == TKB;
            const double psyn = var ? P->p_syn_b : P->p_syn_a;
            const double prep = var ? P->p_rep_b : P->p_rep_a;
            int nn = find_type_near(s, k, P->r_cat, TN, nb, 256);
            if (nn < 2) continue;
            int used = 0;
            const double xk = s->x[k], yk = s->y[k];
            if (nn >= ml && rng_unif(&s->rng) < psyn) {
                /* lipid synthesis from the ml nearest N: straight chain with
                 * spacing r0 through their centroid, random orientation, mean
                 * velocity (momentum conserving), bonds at rest length */
                double cxm = 0, cym = 0, mvx = 0, mvy = 0, mtx = 0, mty = 0;
                int sl[MAXMLEN];
                for (int b = 0; b < ml; b++) {
                    const int j = nb[b].slot;
                    sl[b] = j;
                    cxm += minimg(s->x[j] - xk, L);
                    cym += minimg(s->y[j] - yk, L);
                    mvx += s->vx[j]; mvy += s->vy[j];
                    mtx += s->vtx[j]; mty += s->vty[j];
                }
                cxm = xk + cxm / ml; cym = yk + cym / ml;
                mvx /= ml; mvy /= ml; mtx /= ml; mty /= ml;
                /* orientation: lowest conservative overlap energy with the
                 * surroundings among syn_tries random orientations */
                double ux = 1.0, uy = 0.0, ubest = INFINITY;
                for (int tr = 0; tr < P->syn_tries; tr++) {
                    const double phi = 2.0 * M_PI * rng_unif(&s->rng);
                    const double cx_ = cos(phi), cy_ = sin(phi);
                    const double U = P->syn_tries > 1 ? chain_overlap_energy(s, P, cxm, cym, cx_, cy_, sl) : 0.0;
                    if (U < ubest) { ubest = U; ux = cx_; uy = cy_; }
                }
                for (int b = 0; b < ml; b++) {
                    const int j = sl[b];
                    const double off = (b - 0.5 * (ml - 1)) * P->r0;
                    s->x[j] = cxm + off * ux;
                    s->y[j] = cym + off * uy;
                    wrap1(&s->x[j], L);
                    wrap1(&s->y[j], L);
                    s->vx[j] = mvx; s->vy[j] = mvy;
                    s->vtx[j] = mtx; s->vty[j] = mty;
                    s->type[j] = b < s->nH ? TH : TT;
                }
                link_lipid(s, sl);
                if (P->syn_relax > 0) relax_new_chain(s, P, sl);
                add_event(s, step, EV_SYN, s->gid[k], xk, yk, var);
                used = ml;
                moved = 1;
            }
            if (nn - used >= 2 && rng_unif(&s->rng) < prep) {
                int nv = var;
                int mut = 0;
                if (rng_unif(&s->rng) < P->mu) { nv = 1 - var; mut = 1; }
                const int j1 = nb[used].slot, j2 = nb[used + 1].slot;
                s->type[j1] = nv ? TKB : TKA;
                s->type[j2] = TW;
                add_event(s, step, mut ? EV_MUT : EV_REP, s->gid[j1], xk, yk, nv);
            }
        }
        free(ks);
        g_t_react += wtime() - tc0;
        tc0 = wtime();
        /* decay: independent per-bead decisions from a counter-based hash of
         * (seed, step, gid), so the scan is parallel and order independent */
        if (P->p_ld > 0 || P->p_kd > 0 || P->p_nd > 0) {
            const int8_t *mp = s->mpos;
            const uint32_t *gd = s->gid;
            const uint64_t kl = hash_key(s->seed, step, 11), kk = hash_key(s->seed, step, 12),
                           kn = hash_key(s->seed, step, 13);
            const double pld = P->p_ld, pkd = P->p_kd, pnd = P->p_nd;
            int nd;
            COLLECT_SLOTS(s,
                          ((mp[d] == 0 && pld > 0 && hash_u01(kl, gd[d]) < pld) ||
                           ((ty[d] == TKA || ty[d] == TKB) && pkd > 0 && hash_u01(kk, gd[d]) < pkd) ||
                           (ty[d] == TN && pnd > 0 && hash_u01(kn, gd[d]) < pnd)),
                          nd);
            for (int q = 0; q < nd; q++) {
                const int d = s->glist[q];
                const int t = s->type[d];
                if (s->mpos[d] == 0) {
                    const double hx = s->x[d], hy = s->y[d];
                    const uint32_t g0 = s->gid[d];
                    int c = d, n = 0;
                    while (c >= 0 && n < ml) {
                        const int nx = s->nxt[c];
                        s->type[c] = TW;
                        s->mpos[c] = -1;
                        s->nxt[c] = -1;
                        c = nx;
                        n++;
                    }
                    add_event(s, step, EV_DLIP, g0, hx, hy, -1);
                } else if (t == TKA || t == TKB) {
                    s->type[d] = TW;
                    add_event(s, step, EV_DK, s->gid[d], s->x[d], s->y[d], t == TKB);
                } else if (t == TN) {
                    s->type[d] = TW;
                    add_event(s, step, EV_DN, s->gid[d], s->x[d], s->y[d], -1);
                }
            }
        }
    }
    g_t_decay += wtime() - tc0;
    tc0 = wtime();
    if (P->feed_mode != FEED_NONE) feed_supply(s, P, step);
    g_t_feed += wtime() - tc0;
    return moved;
}

/* is (x, y) inside the fixed vent region?  Fixed box coordinates, periodic. */
static inline int in_vent(const Params *P, double L, double x, double y) {
    if (P->vent_kind == VENT_DISK) {
        const double dx = minimg(x - P->vent_x, L), dy = minimg(y - P->vent_y, L);
        return dx * dx + dy * dy < P->vent_r * P->vent_r;
    }
    if (P->vent_kind == VENT_VSTRIP) return fabs(minimg(x - P->vent_x, L)) < 0.5 * P->vent_w;
    return fabs(minimg(y - P->vent_y, L)) < 0.5 * P->vent_w;
}

/* Food supply (SPEC 3.4), a local, structure-blind law: every eligible W bead
 * (feed = uniform: any W anywhere; feed = vent: any W inside the fixed vent
 * region) becomes N with probability p_feed per check.  Each decision is a
 * counter-based hash of (seed, step, gid): parallel, order and thread-count
 * independent.  Optional global cap: if the conversions would raise the total
 * number of N above feed_cap * N_beads, a uniformly random subset of them
 * (serial RNG) is kept.  The only inputs are a bead's own type and position
 * and the global N count; nothing here knows about membranes or compartments. */
static int feed_supply(Sys *s, const Params *P, int64_t step) {
    const int N = s->N;
    const double L = s->L, pf = P->p_feed;
    const uint8_t *restrict ty = s->type;
    const uint32_t *restrict gd = s->gid;
    const double *restrict x = s->x, *restrict y = s->y;
    const uint64_t kf = hash_key(s->seed, step, 14);
    if (pf <= 0.0) return 0;
    int nc;
    if (P->feed_mode == FEED_UNIFORM) COLLECT_SLOTS(s, (ty[d] == TW && hash_u01(kf, gd[d]) < pf), nc);
    else COLLECT_SLOTS(s, (ty[d] == TW && in_vent(P, L, x[d], y[d]) && hash_u01(kf, gd[d]) < pf), nc);
    long add = nc;
    if (P->feed_cap > 0.0 && nc > 0) {
        int nth = omp_get_max_threads();
        if (nth > s->nthr_alloc) nth = s->nthr_alloc;
        long nN = 0;
#pragma omp parallel for schedule(static) num_threads(nth) reduction(+ : nN)
        for (int i = 0; i < N; i++) nN += ty[i] == TN;
        long room = (long)floor(P->feed_cap * (double)N + 1e-9) - nN;
        if (room < 0) room = 0;
        if (add > room) {
            int *wl = s->glist; /* partial Fisher-Yates: a random subset of size room */
            for (long a = 0; a < room; a++) {
                const long b = a + rng_below(&s->rng, nc - a);
                const int t = wl[a]; wl[a] = wl[b]; wl[b] = t;
            }
            add = room;
        }
    }
    for (long a = 0; a < add; a++) s->type[s->glist[a]] = TN;
    if (add > 0) add_event(s, step, EV_FEED, add, NAN, NAN, -1);
    return (int)add;
}

/* ------------------------------------------------------------------ init */

static void set_velocities(Sys *s, const Params *P) {
    double px = 0, py = 0;
    for (int i = 0; i < s->N; i++) {
        s->vx[i] = rng_normal(&s->rng) * sqrt(P->kT);
        s->vy[i] = rng_normal(&s->rng) * sqrt(P->kT);
        px += s->vx[i]; py += s->vy[i];
    }
    px /= s->N; py /= s->N;
    double k2 = 0;
    for (int i = 0; i < s->N; i++) {
        s->vx[i] -= px; s->vy[i] -= py;
        k2 += s->vx[i] * s->vx[i] + s->vy[i] * s->vy[i];
    }
    const double sc = sqrt(P->kT * (2.0 * s->N - 2.0) / k2);
    for (int i = 0; i < s->N; i++) { s->vx[i] *= sc; s->vy[i] *= sc; }
}

static void init_soup(Sys *s, const Params *P) {
    const int N = s->N, ml = s->mlen;
    const double L = s->L;
    const long nlip = lround(P->f_lip * N / ml);
    const long nKa = lround(P->f_Ka * N), nKb = lround(P->f_Kb * N), nN = lround(P->c_N * N);
    if (nlip * ml + nKa + nKb + nN > N) die("soup composition exceeds N");
    int gi = 0;
    for (long m = 0; m < nlip; m++) {
        const double hx = L * rng_unif(&s->rng), hy = L * rng_unif(&s->rng);
        const double phi = 2.0 * M_PI * rng_unif(&s->rng);
        int sl[MAXMLEN];
        for (int b = 0; b < ml; b++) {
            s->x[gi] = hx + b * P->r0 * cos(phi);
            s->y[gi] = hy + b * P->r0 * sin(phi);
            wrap1(&s->x[gi], L);
            wrap1(&s->y[gi], L);
            s->type[gi] = b < s->nH ? TH : TT;
            s->gid[gi] = gi;
            sl[b] = gi;
            gi++;
        }
        link_lipid(s, sl);
    }
    long cnt = 0;
    for (; gi < N; gi++, cnt++) {
        s->x[gi] = L * rng_unif(&s->rng);
        s->y[gi] = L * rng_unif(&s->rng);
        s->gid[gi] = gi;
        if (cnt < nKa) s->type[gi] = TKA;
        else if (cnt < nKa + nKb) s->type[gi] = TKB;
        else if (cnt < nKa + nKb + nN) s->type[gi] = TN;
        else s->type[gi] = TW;
    }
    logmsg("init soup: N=%d lipids=%ld (%ld beads) Ka=%ld Kb=%ld N=%ld\n", N, nlip, nlip * ml, nKa, nKb, nN);
}

/* ------------------------------------------------------------------ IO */

static int file_exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

static void write_snapshot(Sys *s, const char *dir) {
    char path[2048], tmp[2100];
    snprintf(path, sizeof path, "%s/snap_%010lld.bin", dir, (long long)s->step);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) die("cannot write %s", tmp);
    const int N = s->N;
    build_slot(s);
    int32_t nb = 0;
    for (int d = 0; d < N; d++) nb += s->nxt[d] >= 0;
    const int32_t ver = 1, n32 = N;
    const int64_t st = s->step;
    fwrite("OCEL", 1, 4, f);
    fwrite(&ver, 4, 1, f);
    fwrite(&n32, 4, 1, f);
    fwrite(&nb, 4, 1, f);
    fwrite(&st, 8, 1, f);
    fwrite(&s->time, 8, 1, f);
    fwrite(&s->L, 8, 1, f);
    float *buf = xmalloc((size_t)N * sizeof(float));
    for (int g = 0; g < N; g++) buf[g] = (float)s->x[s->slot[g]];
    fwrite(buf, 4, N, f);
    for (int g = 0; g < N; g++) buf[g] = (float)s->y[s->slot[g]];
    fwrite(buf, 4, N, f);
    uint8_t *tb = (uint8_t *)buf;
    for (int g = 0; g < N; g++) tb[g] = s->type[s->slot[g]];
    fwrite(tb, 1, N, f);
    free(buf);
    /* bonds in order of the first bead's id */
    int32_t *bb = xmalloc((size_t)(nb + 1) * 2 * sizeof(int32_t));
    int k = 0;
    for (int g = 0; g < N; g++) {
        const int d = s->slot[g];
        if (s->nxt[d] < 0) continue;
        const int32_t i = (int32_t)g, j = (int32_t)s->gid[s->nxt[d]];
        bb[2 * k] = i < j ? i : j;
        bb[2 * k + 1] = i < j ? j : i;
        k++;
    }
    fwrite(bb, 4, 2 * (size_t)nb, f);
    free(bb);
    if (fclose(f) != 0) die("write error on %s", tmp);
    if (rename(tmp, path) != 0) die("rename %s failed", tmp);
}

/* Version 2: written only by engines without any placed-structure start
 * (init = seeded removed) and without the flood-fill food supply, so a v2
 * checkpoint always descends from a random soup.  Version 1 files (older
 * engine) are refused: their history cannot be verified (SPEC section 0). */
#define CKPT_VERSION 2
static void write_ckpt(Sys *s, const char *dir, int keep) {
    char path[2048], tmp[2100];
    snprintf(path, sizeof path, "%s/ckpt.bin", dir);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) die("cannot write %s", tmp);
    const int32_t ver = CKPT_VERSION, N = s->N, ml = s->mlen, nH = s->nH;
    fwrite("OCKP", 1, 4, f);
    fwrite(&ver, 4, 1, f);
    fwrite(&N, 4, 1, f);
    fwrite(&ml, 4, 1, f);
    fwrite(&nH, 4, 1, f);
    fwrite(&s->step, 8, 1, f);
    fwrite(&s->time, 8, 1, f);
    fwrite(&s->L, 8, 1, f);
    fwrite(&s->seed, 8, 1, f);
    fwrite(s->rng.s, 8, 4, f);
    fwrite(&s->maxbond, 8, 1, f);
    fwrite(&g_warm_end, 8, 1, f);
    fwrite(&s->t_anchor, 8, 1, f);
    fwrite(&s->step_anchor, 8, 1, f);
    fwrite(&s->dt_anchor, 8, 1, f);
    fwrite(&s->soup_seed, 8, 1, f);
    fwrite(s->gid, 4, N, f);
    fwrite(s->type, 1, N, f);
    fwrite(s->mpos, 1, N, f);
    fwrite(s->nxt, 4, N, f);
    fwrite(s->x, 8, N, f);
    fwrite(s->y, 8, N, f);
    fwrite(s->vx, 8, N, f);
    fwrite(s->vy, 8, N, f);
    fwrite(s->fx, 8, N, f);
    fwrite(s->fy, 8, N, f);
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

static void read_ckpt(Sys *s, const Params *P, const char *path) {
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
    if (ver != CKPT_VERSION) die("unsupported checkpoint version %d", ver);
    freadx(&N, 4, 1, f, "N");
    freadx(&ml, 4, 1, f, "mlen");
    freadx(&nH, 4, 1, f, "nH");
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
    if (ml != P->lip_nH + P->lip_nT || nH != P->lip_nH) die("checkpoint lipid architecture differs from parameters");
    if (fabs(L - P->L) > 1e-12) die("checkpoint L=%g differs from parameter L=%g", L, P->L);
    sys_alloc(s, N, L, ml, nH, P->threads, P->nsub);
    s->step = step;
    s->time = time;
    s->seed = seed;
    s->soup_seed = soup_seed;
    memcpy(s->rng.s, rs, sizeof rs);
    s->maxbond = maxbond;
    if (da == P->dt) { s->t_anchor = ta; s->step_anchor = sa; s->dt_anchor = da; }
    else { s->t_anchor = time; s->step_anchor = step; s->dt_anchor = P->dt; } /* dt changed: new anchor */
    freadx(s->gid, 4, N, f, "gid");
    freadx(s->type, 1, N, f, "type");
    freadx(s->mpos, 1, N, f, "mpos");
    freadx(s->nxt, 4, N, f, "nxt");
    freadx(s->x, 8, N, f, "x");
    freadx(s->y, 8, N, f, "y");
    freadx(s->vx, 8, N, f, "vx");
    freadx(s->vy, 8, N, f, "vy");
    freadx(s->fx, 8, N, f, "fx");
    freadx(s->fy, 8, N, f, "fy");
    char end[4];
    freadx(end, 1, 4, f, "end marker");
    if (memcmp(end, "END!", 4)) die("checkpoint end marker missing");
    fclose(f);
    /* consistency checks */
    build_slot(s);
    for (int d = 0; d < N; d++) {
        if (s->gid[d] >= (uint32_t)N || s->slot[s->gid[d]] != d) die("checkpoint: gid table is not a permutation");
        if (s->type[d] >= TZ) die("checkpoint: bead type %d at slot %d (Z is unused, SPEC section 6)", s->type[d], d);
        if (s->nxt[d] >= N || (s->mpos[d] < 0) != (s->type[d] != TH && s->type[d] != TT))
            die("checkpoint: inconsistent lipid links at slot %d", d);
    }
}

/* truncate a csv (header + rows whose first field is the step) after step */
static void truncate_csv_after(const char *path, int64_t step) {
    FILE *f = fopen(path, "r+");
    if (!f) return;
    char line[8192];
    long off = 0, cut = -1;
    int first = 1;
    while (fgets(line, sizeof line, f)) {
        size_t len = strlen(line);
        if (len == 0 || line[len - 1] != '\n') { cut = off; break; } /* partial line */
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

static void flush_events(Sys *s, FILE *ef) {
    if (ef) {
        for (int k = 0; k < s->nev; k++) {
            const event_t *e = &s->ev[k];
            const char *v = e->variant == 0 ? "a" : e->variant == 1 ? "b" : "-";
            if (isnan(e->x)) fprintf(ef, "%lld,%s,%lld,nan,nan,%s\n", (long long)e->step, EVNAME[e->kind], (long long)e->i, v);
            else fprintf(ef, "%lld,%s,%lld,%.4f,%.4f,%s\n", (long long)e->step, EVNAME[e->kind], (long long)e->i, e->x, e->y, v);
        }
        fflush(ef);
    }
    s->nev = 0;
}

/* ------------------------------------------------------------------ main */

typedef struct { double integ, sort, pair, bond, chem, io; } timers_t;

static void count_types(const Sys *s, long *cnt) {
    for (int t = 0; t < NTYPES; t++) cnt[t] = 0;
    for (int i = 0; i < s->N; i++) cnt[s->type[i]]++;
}

/* kinetic temperature from the full velocity v = vh + dt/2 f (2D, 2N-2 dof) */
static double kinetic_T(const Sys *s, double dt, double *px, double *py) {
    double k2 = 0, sx = 0, sy = 0;
    const double h = 0.5 * dt;
    for (int i = 0; i < s->N; i++) {
        const double vx = s->vx[i] + h * s->fx[i], vy = s->vy[i] + h * s->fy[i];
        k2 += vx * vx + vy * vy;
        sx += vx;
        sy += vy;
    }
    if (px) *px = sx;
    if (py) *py = sy;
    return k2 / (2.0 * s->N - 2.0);
}

/* lines that do not affect the trajectory: comments, restart, performance keys */
static int params_line_ignored(const char *l) {
    static const char *keys[] = {"restart ", "threads ", "walltime ", "log_every "}; /* nsub changes round-off order */
    if (l[0] == '#') return 1;
    for (size_t k = 0; k < sizeof keys / sizeof keys[0]; k++)
        if (!strncmp(l, keys[k], strlen(keys[k]))) return 1;
    return 0;
}

/* compare two params files ignoring lines that do not affect the trajectory
 * and the trailing help comments (only "key = value" counts) */
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

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--params")) {
        print_param_table();
        return 0;
    }
    if (argc < 3) {
        fprintf(stderr, "usage: %s params.ini outdir [key=value ...]\n       %s --params   (print all parameters)\n", argv[0], argv[0]);
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
        kv = realloc(kv, (nkv + 1) * sizeof(kv_t));
        char tmp[1100];
        snprintf(tmp, sizeof tmp, "%s", argv[a]);
        tmp[eq - argv[a]] = 0;
        snprintf(kv[nkv].key, sizeof kv[nkv].key, "%s", trim(tmp));
        snprintf(kv[nkv].val, sizeof kv[nkv].val, "%s", trim(tmp + (eq - argv[a]) + 1));
        nkv++;
    }
    for (int pass = 0; pass < 2; pass++) /* generic catalyst keys (a_K_X) first, then the rest */
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

    Sys S, *s = &S;
    const int restarting = P.restart[0] != 0;
    const int mlen = P.lip_nH + P.lip_nT;
    double t_start = wtime();
    if (restarting) {
        read_ckpt(s, &P, P.restart);
        if (P.restart_reseed) {
            s->seed = P.seed;
            rng_seed(&s->rng, P.seed ^ mix13((uint64_t)s->step));
            logmsg("restart: reseeded with seed=%llu (branch, not an exact continuation)\n", (unsigned long long)P.seed);
        } else if (s->seed != P.seed) {
            logmsg("note: using checkpoint seed %llu (ini seed %llu ignored; set restart_reseed=1 to branch)\n",
                   (unsigned long long)s->seed, (unsigned long long)P.seed);
        }
        logmsg("restart from %s at step %lld (t=%.4f), N=%d, lipids=%d, descends from the random soup with seed %llu\n",
               P.restart, (long long)s->step, s->time, s->N, count_lipids(s), (unsigned long long)s->soup_seed);
    } else {
        const int N = (int)lround(P.rho * P.L * P.L);
        if (strcmp(P.init, "soup")) die("init = %s needs restart = <checkpoint>", P.init);
        sys_alloc(s, N, P.L, mlen, P.lip_nH, P.threads, P.nsub);
        s->seed = P.seed;
        s->soup_seed = P.seed;
        rng_seed(&s->rng, P.seed);
        init_soup(s, &P); /* the only start state (SPEC section 0) */
        set_velocities(s, &P);
        g_warm_end = P.warmup;
        if (P.warmup > 0) logmsg("warm-up: repulsion above 25 ramped in over steps 0..%ld\n", P.warmup);
        for (int i = 0; i < N; i++) { s->vtx[i] = s->vx[i]; s->vty[i] = s->vy[i]; }
        s->step = 0;
        s->time = 0.0;
        s->t_anchor = 0.0;
        s->step_anchor = 0;
        s->dt_anchor = P.dt;
        sort_cells(s);
        pair_forces(s, &P, 0, 0.0);
        bonded_forces(s, &P);
        /* stored velocity is the half-step one: vh = v - dt/2 f */
        for (int i = 0; i < N; i++) {
            s->vx[i] -= 0.5 * P.dt * s->fx[i];
            s->vy[i] -= 0.5 * P.dt * s->fy[i];
        }
    }
    {
        const int rx = (int)ceil((P.r_cat + CHEM_MARGIN) * s->icsx), ry = (int)ceil((P.r_cat + CHEM_MARGIN) * s->icsy);
        if (s->ncx < 2 * rx + 1 || s->ncy < 2 * ry + 1) die("box too small for r_cat");
    }
    if (restarting) sort_cells(s); /* identity permutation; builds the cell index for chemistry */

    /* parameters used */
    snprintf(path, sizeof path, "%s/params.ini", outdir);
    {
        /* keep the previous params.ini (as params_before_<step>.ini) only if the
         * parameters actually changed at this restart */
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

    /* stats / events files */
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

    logmsg("oercel: N=%d L=%g cells=%dx%d strips=%d threads=%d dt=%g gamma=%g sigma=%g steps->%ld\n", s->N, s->L, s->ncx,
           s->ncy, s->nstrip, P.threads, P.dt, P.gamma, P.sigma, P.steps);
    if (P.chem && P.feed_mode == FEED_UNIFORM)
        logmsg("feed: uniform, every W -> N with p_feed=%g per check (every %ld steps), cap nN/N=%g\n", P.p_feed, P.n_chem,
               P.feed_cap);
    if (P.chem && P.feed_mode == FEED_VENT)
        logmsg("feed: vent %s at x=%g y=%g (r=%g, w=%g), W -> N with p_feed=%g per check, cap nN/N=%g\n", P.vent_shape,
               P.vent_x, P.vent_y, P.vent_r, P.vent_w, P.p_feed, P.feed_cap);
    if (P.stir_A != 0) logmsg("stirring: f_x = %g sin(2 pi %d y / L) on every bead (net force removed)\n", P.stir_A, P.stir_n);
    if (P.kT_amp != 0) logmsg("temperature cycle: kT(t) = %g + %g sin(2 pi t / %g)\n", P.kT, P.kT_amp, P.kT_period);

    long cnt[NTYPES];
    if (!restarting) {
        double px, py;
        double T = kinetic_T(s, P.dt, &px, &py);
        count_types(s, cnt);
        if (P.stats_every > 0)
            fprintf(sf, "0,0,%.6f,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d,%.6f\n", T, cnt[TW], cnt[TH], cnt[TT], cnt[TN], cnt[TKA],
                    cnt[TKB], cnt[TZ], count_lipids(s), s->maxbond);
        s->maxbond = 0;
        if (P.snap_every > 0) write_snapshot(s, outdir);
    } else {
        /* a restart into a fresh directory gets the starting snapshot, but only
         * on the regular snapshot cadence (never an off-cadence file) */
        char sp[2100];
        snprintf(sp, sizeof sp, "%s/snap_%010lld.bin", outdir, (long long)s->step);
        if (P.snap_every > 0 && s->step % P.snap_every == 0 && !file_exists(sp)) write_snapshot(s, outdir);
    }

    const double dt = P.dt, dt2 = dt * dt, cvt = (0.5 + P.lambda) * dt, L = s->L;
    timers_t tm = {0, 0, 0, 0, 0, 0};
    const int64_t step0 = s->step;
    double t_loop0 = wtime(), t_lastlog = t_loop0;
    int64_t lastlog_step = s->step;
    int stopped_early = 0;
    logmsg("setup %.3f s\n", t_loop0 - t_start);

    while (s->step < P.steps) {
        const int64_t ns = s->step + 1;
        double t0 = wtime();
        /* 1. Groot-Warren step with stored half-step velocity vh = v - dt/2 f:
         *    x += dt v + dt^2/2 f = dt vh + dt^2 f
         *    vt = v + lambda dt f = vh + (1/2 + lambda) dt f    (force input)
         *    vh' = v + dt/2 f      = vh + dt f
         *  after the new forces f' the full velocity is v' = vh' + dt/2 f'. */
        const int N = s->N;
        double dmax = 0.0;
        {
            double *restrict x = s->x, *restrict y = s->y, *restrict vx = s->vx, *restrict vy = s->vy;
            const double *restrict fx = s->fx, *restrict fy = s->fy;
            double *restrict vtx = s->vtx, *restrict vty = s->vty;
#pragma omp parallel for schedule(static) reduction(max : dmax)
            for (int i = 0; i < N; i++) {
                const double ddx = dt * vx[i] + dt2 * fx[i], ddy = dt * vy[i] + dt2 * fy[i];
                const double adx = ddx < 0.0 ? -ddx : ddx, ady = ddy < 0.0 ? -ddy : ddy;
                const double dd = adx > ady ? adx : ady;
                dmax = dd > dmax ? dd : dmax;
                /* periodic wrap into [0, L), branch free (vectorisable); the
                 * second select catches x = -tiny -> x + L == L */
                double xi = x[i] + ddx, yi = y[i] + ddy;
                xi = xi < 0.0 ? xi + L : xi;
                yi = yi < 0.0 ? yi + L : yi;
                xi = xi >= L ? xi - L : xi;
                yi = yi >= L ? yi - L : yi;
                x[i] = xi;
                y[i] = yi;
                vtx[i] = vx[i] + cvt * fx[i];
                vty[i] = vy[i] + cvt * fy[i];
                vx[i] += dt * fx[i];
                vy[i] += dt * fy[i];
            }
        }
        double t1 = wtime();
        tm.integ += t1 - t0;
        /* 2. chemistry on the new configuration, using the cell index of the
         *    previous sort (valid: every bead moved less than CHEM_MARGIN) */
        if (P.chem && (ns % P.n_chem) == 0) {
            if (dmax >= CHEM_MARGIN) {
                logmsg("warning: step %lld max displacement %.3f >= %.2f, extra cell sort\n", (long long)ns, dmax,
                       CHEM_MARGIN);
                sort_cells(s);
            }
            chemistry(s, &P, ns);
        }
        double t2 = wtime();
        tm.chem += t2 - t1;
        sort_cells(s);
        double t3 = wtime();
        tm.sort += t3 - t2;
        /* 3. forces (pair + stirring body force, noise amplitude from kT(t)) */
        const double tn = s->t_anchor + (double)(ns - s->step_anchor) * dt;
        pair_forces(s, &P, ns, tn);
        double t4 = wtime();
        tm.pair += t4 - t3;
        bonded_forces(s, &P);
        double t5 = wtime();
        tm.bond += t5 - t4;
        double t6 = t5;
        s->step = ns;
        s->time = tn;
        /* 5. output */
        if (P.stats_every > 0 && ns % P.stats_every == 0) {
            double px, py;
            double T = kinetic_T(s, dt, &px, &py);
            count_types(s, cnt);
            fprintf(sf, "%lld,%.6f,%.6f,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d,%.6f\n", (long long)ns, s->time, T, cnt[TW], cnt[TH],
                    cnt[TT], cnt[TN], cnt[TKA], cnt[TKB], cnt[TZ], count_lipids(s), s->maxbond);
            s->maxbond = 0;
            if (!isfinite(T)) die("non-finite temperature at step %lld", (long long)ns);
        }
        if (P.snap_every > 0 && ns % P.snap_every == 0) write_snapshot(s, outdir);
        if (s->nev > 100000) flush_events(s, ef);
        const double now = wtime();
        int stop = g_stop || (P.walltime > 0 && now - t_start > P.walltime);
        if ((P.ckpt_every > 0 && ns % P.ckpt_every == 0) || stop || ns >= P.steps) {
            flush_events(s, ef);
            fflush(sf);
            write_ckpt(s, outdir, P.ckpt_keep);
        }
        if (P.log_every > 0 && ns % P.log_every == 0) {
            double px, py;
            double T = kinetic_T(s, dt, &px, &py);
            count_types(s, cnt);
            logmsg("step %lld t=%.2f T=%.4f (kT=%.4f) p=(%.2e,%.2e) lip=%d Ka=%ld Kb=%ld N=%ld  %.3f ms/step\n",
                   (long long)ns, s->time, T, kT_at(&P, s->time), px, py, count_lipids(s), cnt[TKA], cnt[TKB], cnt[TN],
                   1e3 * (now - t_lastlog) / (double)(ns - lastlog_step));
            t_lastlog = now;
            lastlog_step = ns;
        }
        tm.io += wtime() - t6;
        if (stop) {
            stopped_early = 1;
            logmsg("stopping at step %lld (%s), checkpoint written\n", (long long)ns, g_stop ? "signal" : "walltime");
            break;
        }
    }
    flush_events(s, ef);
    if (sf) fclose(sf);
    if (ef) fclose(ef);
    const double nst = (double)(s->step - step0);
    if (nst > 0) {
        const double tot = tm.integ + tm.sort + tm.pair + tm.bond + tm.chem + tm.io;
        logmsg("timing: %lld steps, %.4f ms/step (integrate %.4f, sort %.4f, pair %.4f, bonded %.4f, chem %.4f, io %.4f)\n",
               (long long)nst, 1e3 * tot / nst, 1e3 * tm.integ / nst, 1e3 * tm.sort / nst, 1e3 * tm.pair / nst,
               1e3 * tm.bond / nst, 1e3 * tm.chem / nst, 1e3 * tm.io / nst);
        logmsg("chemistry per step: reactions %.4f, decay %.4f, feed %.4f ms\n", 1e3 * g_t_react / nst,
               1e3 * g_t_decay / nst, 1e3 * g_t_feed / nst);
    }
    logmsg("done at step %lld%s\n", (long long)s->step, stopped_early ? " (stopped early; restart to continue)" : "");
    if (g_log) fclose(g_log);
    return 0;
}
