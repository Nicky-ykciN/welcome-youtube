/*
 * oercel.c — Oercel: 2D dissipative particle dynamics (DPD) engine with local
 * stochastic chemistry, for emergent protocells.  See ../SPEC.md and README.md.
 *
 * Units: rc = 1, kT = 1 (configurable), bead mass = 1.  Periodic square box.
 *
 * Data layout: all per-bead state lives in "slot" order and is re-sorted by
 * cell (counting sort, column-major cell index) every step, so that the cell
 * list is just cstart[c]..cstart[c+1] and all hot loops stream contiguous
 * memory.  Every bead also has a permanent global id (gid, 0..N-1) used for
 * bonds, the pair-noise hash, snapshots and the event log; slot[gid] maps back.
 *
 * Parallel pair forces: half-shell stencil (self, up, and the three cells in
 * the next column).  Columns are grouped into an even number of strips; even
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

#define NTYPES 7
enum { TW = 0, TH = 1, TT = 2, TN = 3, TKA = 4, TKB = 5, TZ = 6 };
static const char *TNAME[NTYPES] = {"W", "H", "T", "N", "Ka", "Kb", "Z"};
#define MAXMLEN 8
#define SQRT12 3.4641016151377545870548926830117

/* ------------------------------------------------------------------ util */

static FILE *g_log = NULL;
static volatile sig_atomic_t g_stop = 0;
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
    int threads;
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
    int feed;
    long feed_every;
    double c_N, feed_grid;
    int feed_tmin;
    int events;
    /* init soup */
    double f_lip, f_Ka, f_Kb;
    /* init seeded */
    double seed_R, seed_spacing, seed_cN_in;
    int seed_nKa;
    /* derived */
    double sigma;
} Params;

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
    {"threads", PT_INT, OFF(threads), "2", "OpenMP threads"},
    {"seed", PT_U64, OFF(seed), "1", "random seed"},
    {"init", PT_STR, OFF(init), "soup", "soup | seeded | restart"},
    {"restart", PT_STR, OFF(restart), "", "checkpoint file; if non-empty the run restarts from it"},
    {"restart_reseed", PT_INT, OFF(restart_reseed), "0", "1 = on restart use this ini's seed (branch) instead of the checkpoint's"},
    {"walltime", PT_DBL, OFF(walltime), "0", "stop cleanly (with checkpoint) after this many seconds (0 = off)"},
    {"chem", PT_INT, OFF(chem), "1", "1 = chemistry on"},
    {"n_chem", PT_LONG, OFF(n_chem), "10", "chemistry check interval (steps); all p_* are per check"},
    {"r_cat", PT_DBL, OFF(r_cat), "1.2", "catalyst reaction radius (<= 2 cell sides)"},
    {"p_syn_a", PT_DBL, OFF(p_syn_a), "0.02", "lipid synthesis probability per check, Ka"},
    {"p_syn_b", PT_DBL, OFF(p_syn_b), "0.06", "lipid synthesis probability per check, Kb"},
    {"p_rep_a", PT_DBL, OFF(p_rep_a), "0.001", "catalyst replication probability per check, Ka"},
    {"p_rep_b", PT_DBL, OFF(p_rep_b), "0.003", "catalyst replication probability per check, Kb"},
    {"mu", PT_DBL, OFF(mu), "0.02", "mutation probability per replication (a<->b)"},
    {"p_ld", PT_DBL, OFF(p_ld), "1e-6", "lipid decay probability per molecule per check"},
    {"p_kd", PT_DBL, OFF(p_kd), "1e-5", "catalyst decay probability per check"},
    {"p_nd", PT_DBL, OFF(p_nd), "1e-5", "nutrient decay probability per check"},
    {"feed", PT_INT, OFF(feed), "1", "1 = food supply in the outside medium"},
    {"feed_every", PT_LONG, OFF(feed_every), "0", "food supply interval in steps (0 = n_chem)"},
    {"c_N", PT_DBL, OFF(c_N), "0.12", "target nutrient fraction in the outside medium"},
    {"feed_grid", PT_DBL, OFF(feed_grid), "1.6", "coarse grid cell size for the outside flood fill"},
    {"feed_tmin", PT_INT, OFF(feed_tmin), "1", "a grid cell with >= feed_tmin T beads is membrane"},
    {"events", PT_INT, OFF(events), "1", "1 = write events.csv"},
    {"f_lip", PT_DBL, OFF(f_lip), "0.10", "soup: fraction of beads in lipids"},
    {"f_Ka", PT_DBL, OFF(f_Ka), "0.005", "soup: fraction of beads that are Ka"},
    {"f_Kb", PT_DBL, OFF(f_Kb), "0", "soup: fraction of beads that are Kb"},
    {"seed_R", PT_DBL, OFF(seed_R), "10", "seeded: vesicle bilayer mid-plane radius"},
    {"seed_spacing", PT_DBL, OFF(seed_spacing), "0.7", "seeded: lipid spacing along each leaflet"},
    {"seed_cN_in", PT_DBL, OFF(seed_cN_in), "-1", "seeded: nutrient fraction inside (-1 = c_N)"},
    {"seed_nKa", PT_INT, OFF(seed_nKa), "6", "seeded: number of Ka placed in the lumen"},
};
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
    if (P->feed_every <= 0) P->feed_every = P->n_chem;
    if (P->seed_cN_in < 0) P->seed_cN_in = P->c_N;
    int mlen = P->lip_nH + P->lip_nT;
    if (P->lip_nH < 1 || P->lip_nT < 1 || mlen > MAXMLEN) die("lipid length must be 2..%d with >=1 head and tail", MAXMLEN);
    if (P->L < 8) die("L must be >= 8");
    if (P->dt <= 0) die("dt must be > 0");
    if (P->threads < 1) P->threads = 1;
    if (P->n_chem < 1) P->n_chem = 1;
    if (strcmp(P->init, "soup") && strcmp(P->init, "seeded") && strcmp(P->init, "restart"))
        die("init must be soup, seeded or restart");
    if (!strcmp(P->init, "restart") && !P->restart[0]) die("init = restart needs restart = <checkpoint>");
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
    fprintf(f, "# derived: sigma = %.17g\n", P->sigma);
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
    /* slot-ordered state */
    double *x, *y, *vx, *vy, *fx, *fy, *vtx, *vty;
    uint8_t *type;
    uint32_t *gid;
    /* sort buffers */
    double *x2, *y2, *vx2, *vy2, *vtx2, *vty2;
    uint8_t *type2;
    uint32_t *gid2;
    int *cellof;
    int *slot; /* slot[gid] */
    /* cells */
    int ncx, ncy, ncell;
    double icsx, icsy, csx, csy;
    int *cstart;     /* ncell+1 */
    int *hist;       /* nthreads * ncell, parallel sort */
    int nthr_alloc;
    int nstrip;
    int *strip_c0;   /* nstrip+1 */
    /* molecules (lipids) */
    int mlen, nH;
    int nmol, molcap;
    int32_t *mol;    /* nmol*mlen gids, head first */
    int32_t *mol_of; /* per gid: molecule index or -1 */
    /* time */
    int64_t step;
    double time;
    uint64_t seed;
    rng_t rng;
    double maxbond;  /* running max since last stats row */
    /* events */
    event_t *ev;
    int nev, evcap;
} Sys;

static void sys_alloc(Sys *s, int N, double L, int mlen, int nH, int nthreads) {
    memset(s, 0, sizeof *s);
    s->N = N;
    s->L = L;
    s->mlen = mlen;
    s->nH = nH;
    size_t dn = (size_t)N * sizeof(double);
    s->x = xmalloc(dn); s->y = xmalloc(dn); s->vx = xmalloc(dn); s->vy = xmalloc(dn);
    s->fx = xcalloc(dn); s->fy = xcalloc(dn); s->vtx = xmalloc(dn); s->vty = xmalloc(dn);
    s->x2 = xmalloc(dn); s->y2 = xmalloc(dn); s->vx2 = xmalloc(dn); s->vy2 = xmalloc(dn);
    s->vtx2 = xmalloc(dn); s->vty2 = xmalloc(dn);
    s->type = xmalloc(N); s->type2 = xmalloc(N);
    s->gid = xmalloc(N * sizeof(uint32_t)); s->gid2 = xmalloc(N * sizeof(uint32_t));
    s->cellof = xmalloc(N * sizeof(int));
    s->slot = xmalloc(N * sizeof(int));
    s->mol_of = xmalloc(N * sizeof(int32_t));
    for (int i = 0; i < N; i++) s->mol_of[i] = -1;
    s->ncx = (int)floor(L);
    s->ncy = (int)floor(L);
    s->ncell = s->ncx * s->ncy;
    s->csx = L / s->ncx;
    s->csy = L / s->ncy;
    s->icsx = s->ncx / L;
    s->icsy = s->ncy / L;
    s->cstart = xcalloc((size_t)(s->ncell + 1) * sizeof(int));
    s->nthr_alloc = nthreads;
    s->hist = xmalloc((size_t)nthreads * s->ncell * sizeof(int));
    /* strips: even count, width >= 1 column */
    int ns = s->ncx;
    if (ns % 2) ns--;
    if (ns < 2) die("box too small for strip decomposition");
    s->nstrip = ns;
    s->strip_c0 = xmalloc((ns + 1) * sizeof(int));
    for (int k = 0; k <= ns; k++) s->strip_c0[k] = (int)(((long)k * s->ncx) / ns);
    s->molcap = 1024;
    s->mol = xmalloc((size_t)s->molcap * mlen * sizeof(int32_t));
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

static int add_molecule(Sys *s, const int32_t *g) {
    if (s->nmol == s->molcap) {
        s->molcap *= 2;
        int32_t *n = xmalloc((size_t)s->molcap * s->mlen * sizeof(int32_t));
        memcpy(n, s->mol, (size_t)s->nmol * s->mlen * sizeof(int32_t));
        free(s->mol);
        s->mol = n;
    }
    int m = s->nmol++;
    for (int b = 0; b < s->mlen; b++) {
        s->mol[(size_t)m * s->mlen + b] = g[b];
        s->mol_of[g[b]] = m;
    }
    return m;
}

static void remove_molecule(Sys *s, int m) {
    const int ml = s->mlen;
    for (int b = 0; b < ml; b++) s->mol_of[s->mol[(size_t)m * ml + b]] = -1;
    int last = s->nmol - 1;
    if (m != last) {
        for (int b = 0; b < ml; b++) {
            int32_t g = s->mol[(size_t)last * ml + b];
            s->mol[(size_t)m * ml + b] = g;
            s->mol_of[g] = m;
        }
    }
    s->nmol--;
}

/* ------------------------------------------------------------------ sort */

/* Stable parallel counting sort of all slot arrays by cell index.  The result
 * is the unique stable order, independent of the thread count. */
static void sort_cells(Sys *s) {
    const int N = s->N, nc = s->ncell;
    int nth = omp_get_max_threads();
    if (nth > s->nthr_alloc) nth = s->nthr_alloc;
    int *hist = s->hist;
    int *cs = s->cstart;
#pragma omp parallel num_threads(nth)
    {
        const int t = omp_get_thread_num(), nt = omp_get_num_threads();
        const int lo = (int)(((long)t * N) / nt), hi = (int)(((long)(t + 1) * N) / nt);
        int *h = hist + (size_t)t * nc;
        memset(h, 0, nc * sizeof(int));
        for (int i = lo; i < hi; i++) {
            int c = cell_of_pos(s, s->x[i], s->y[i]);
            s->cellof[i] = c;
            h[c]++;
        }
#pragma omp barrier
        /* exclusive scan over (cell, thread): parallel over cell blocks */
#pragma omp single
        {
            int run = 0;
            for (int c = 0; c < nc; c++) {
                cs[c] = run;
                for (int tt = 0; tt < nt; tt++) {
                    int v = hist[(size_t)tt * nc + c];
                    hist[(size_t)tt * nc + c] = run;
                    run += v;
                }
            }
            cs[nc] = run;
        }
        for (int i = lo; i < hi; i++) {
            const int d = h[s->cellof[i]]++;
            s->x2[d] = s->x[i];
            s->y2[d] = s->y[i];
            s->vx2[d] = s->vx[i];
            s->vy2[d] = s->vy[i];
            s->vtx2[d] = s->vtx[i];
            s->vty2[d] = s->vty[i];
            s->type2[d] = s->type[i];
            s->gid2[d] = s->gid[i];
            s->slot[s->gid[i]] = d;
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
}

/* ------------------------------------------------------------------ forces */

typedef struct {
    double a[8 * 8];
    double gamma, sdt;
    uint64_t sseed;
} pairpar_t;

static inline __attribute__((always_inline)) void
pair_seg(const int j0, const int j1, const double xi, const double yi, const double vxi, const double vyi,
         const uint32_t gi, const double *restrict arow, const double gam, const double sdt, const uint64_t sseed,
         const double *restrict x, const double *restrict y, const double *restrict vx, const double *restrict vy,
         const uint8_t *restrict ty, const uint32_t *restrict gid, double *restrict fx, double *restrict fy,
         double *fxi, double *fyi) {
    double ax = 0.0, ay = 0.0;
    for (int j = j0; j < j1; j++) {
        const double dx = xi - x[j], dy = yi - y[j];
        const double r2 = dx * dx + dy * dy;
        if (r2 >= 1.0 || r2 < 1e-24) continue;
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
    *fxi += ax;
    *fyi += ay;
}

static void pair_column(Sys *s, const pairpar_t *pp, const int cx) {
    const int ncx = s->ncx, ncy = s->ncy;
    const double L = s->L;
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
    for (int cy = 0; cy < ncy; cy++) {
        const int c = base + cy;
        const int i0 = cs[c], i1 = cs[c + 1];
        if (i0 == i1) continue;
        int sj0[3], sj1[3], nseg = 0;
        double ssx[3], ssy[3];
        int selfend;
        if (cy + 1 < ncy) selfend = cs[c + 2];
        else {
            selfend = i1;
            sj0[nseg] = cs[base]; sj1[nseg] = cs[base + 1]; ssx[nseg] = 0.0; ssy[nseg] = L; nseg++;
        }
        if (cy >= 1 && cy + 1 < ncy) {
            sj0[nseg] = cs[nb + cy - 1]; sj1[nseg] = cs[nb + cy + 2]; ssx[nseg] = shx; ssy[nseg] = 0.0; nseg++;
        } else if (cy == 0) {
            sj0[nseg] = cs[nb]; sj1[nseg] = cs[nb + 2]; ssx[nseg] = shx; ssy[nseg] = 0.0; nseg++;
            sj0[nseg] = cs[nb + ncy - 1]; sj1[nseg] = cs[nb + ncy]; ssx[nseg] = shx; ssy[nseg] = -L; nseg++;
        } else {
            sj0[nseg] = cs[nb + ncy - 2]; sj1[nseg] = cs[nb + ncy]; ssx[nseg] = shx; ssy[nseg] = 0.0; nseg++;
            sj0[nseg] = cs[nb]; sj1[nseg] = cs[nb + 1]; ssx[nseg] = shx; ssy[nseg] = L; nseg++;
        }
        for (int i = i0; i < i1; i++) {
            const double xi = x[i], yi = y[i], vxi = vx[i], vyi = vy[i];
            const uint32_t gi = gid[i];
            const double *arow = pp->a + 8 * ty[i];
            double fxi = 0.0, fyi = 0.0;
            pair_seg(i + 1, selfend, xi, yi, vxi, vyi, gi, arow, gam, sdt, sseed, x, y, vx, vy, ty, gid, fx, fy, &fxi, &fyi);
            for (int k = 0; k < nseg; k++)
                pair_seg(sj0[k], sj1[k], xi - ssx[k], yi - ssy[k], vxi, vyi, gi, arow, gam, sdt, sseed, x, y, vx, vy, ty,
                         gid, fx, fy, &fxi, &fyi);
            fx[i] += fxi;
            fy[i] += fyi;
        }
    }
}

static void pair_forces(Sys *s, const Params *P, int64_t step) {
    pairpar_t pp;
    memset(&pp, 0, sizeof pp);
    for (int i = 0; i < NTYPES; i++)
        for (int j = 0; j < NTYPES; j++) pp.a[8 * i + j] = P->a[i][j];
    pp.gamma = P->gamma;
    pp.sdt = P->sigma / sqrt(P->dt);
    pp.sseed = step_seed(s->seed, step);
    const int ns = s->nstrip;
#pragma omp parallel
    {
#pragma omp for schedule(static)
        for (int i = 0; i < s->N; i++) {
            s->fx[i] = 0.0;
            s->fy[i] = 0.0;
        }
        for (int ph = 0; ph < 2; ph++) {
#pragma omp for schedule(dynamic, 1)
            for (int st = ph; st < ns; st += 2)
                for (int cx = s->strip_c0[st]; cx < s->strip_c0[st + 1]; cx++) pair_column(s, &pp, cx);
        }
    }
}

static void bonded_forces(Sys *s, const Params *P) {
    const int ml = s->mlen;
    const double L = s->L, kb = P->k_bond, r0 = P->r0, ka = P->k_angle;
    double *x = s->x, *y = s->y, *fx = s->fx, *fy = s->fy;
    double mb = s->maxbond;
    for (int m = 0; m < s->nmol; m++) {
        const int32_t *g = s->mol + (size_t)m * ml;
        int sl[MAXMLEN];
        double bx[MAXMLEN], by[MAXMLEN], bl[MAXMLEN];
        for (int b = 0; b < ml; b++) sl[b] = s->slot[g[b]];
        for (int b = 0; b < ml - 1; b++) {
            const int i = sl[b], j = sl[b + 1];
            const double dx = minimg(x[j] - x[i], L), dy = minimg(y[j] - y[i], L);
            const double r = sqrt(dx * dx + dy * dy);
            bx[b] = dx; by[b] = dy; bl[b] = r;
            if (r > mb) mb = r;
            const double f = -kb * (r - r0) / r; /* force on j along (dx,dy) */
            fx[j] += f * dx; fy[j] += f * dy;
            fx[i] -= f * dx; fy[i] -= f * dy;
        }
        if (ka != 0.0) {
            for (int b = 0; b < ml - 2; b++) {
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
    s->maxbond = mb;
}

/* ------------------------------------------------------------------ chemistry */

typedef struct { int slot; double d2; } nbr_t;

/* all N beads within r of slot ks, sorted by distance (needs fresh cell sort) */
static int find_type_near(Sys *s, int ks, double rcut, int type, nbr_t *out, int maxout) {
    const double xk = s->x[ks], yk = s->y[ks], L = s->L, r2c = rcut * rcut;
    const int c = cell_of_pos(s, xk, yk);
    const int cx = c / s->ncy, cy = c % s->ncy;
    const int rx = (int)ceil(rcut * s->icsx), ry = (int)ceil(rcut * s->icsy);
    int n = 0;
    for (int ox = -rx; ox <= rx; ox++) {
        const int cxx = ((cx + ox) % s->ncx + s->ncx) % s->ncx;
        for (int oy = -ry; oy <= ry; oy++) {
            const int cyy = ((cy + oy) % s->ncy + s->ncy) % s->ncy;
            const int cc = cxx * s->ncy + cyy;
            for (int j = s->cstart[cc]; j < s->cstart[cc + 1]; j++) {
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

static int feed_outside(Sys *s, const Params *P, int64_t step);

/* returns 1 if any bead was moved (cells must be re-sorted) */
static int chemistry(Sys *s, const Params *P, int64_t step, int do_react, int do_feed) {
    int moved = 0;
    const int ml = s->mlen;
    const double L = s->L;
    const int N = s->N;
    if (do_react) {
        /* collect catalysts */
        int nk = 0;
        for (int i = 0; i < N; i++)
            if (s->type[i] == TKA || s->type[i] == TKB) nk++;
        int *ks = xmalloc((nk + 1) * sizeof(int));
        nk = 0;
        for (int i = 0; i < N; i++)
            if (s->type[i] == TKA || s->type[i] == TKB) ks[nk++] = i;
        for (int a = nk - 1; a > 0; a--) { /* shuffle */
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
                /* lipid synthesis from the ml nearest N */
                double cxm = 0, cym = 0, mvx = 0, mvy = 0, mtx = 0, mty = 0;
                for (int b = 0; b < ml; b++) {
                    const int j = nb[b].slot;
                    cxm += minimg(s->x[j] - xk, L);
                    cym += minimg(s->y[j] - yk, L);
                    mvx += s->vx[j]; mvy += s->vy[j];
                    mtx += s->vtx[j]; mty += s->vty[j];
                }
                cxm = xk + cxm / ml; cym = yk + cym / ml;
                mvx /= ml; mvy /= ml; mtx /= ml; mty /= ml;
                const double phi = 2.0 * M_PI * rng_unif(&s->rng);
                const double ux = cos(phi), uy = sin(phi);
                int32_t g[MAXMLEN];
                for (int b = 0; b < ml; b++) {
                    const int j = nb[b].slot;
                    const double off = (b - 0.5 * (ml - 1)) * P->r0;
                    s->x[j] = cxm + off * ux;
                    s->y[j] = cym + off * uy;
                    wrap1(&s->x[j], L);
                    wrap1(&s->y[j], L);
                    s->vx[j] = mvx; s->vy[j] = mvy;
                    s->vtx[j] = mtx; s->vty[j] = mty;
                    s->type[j] = b < s->nH ? TH : TT;
                    g[b] = (int32_t)s->gid[j];
                }
                add_molecule(s, g);
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
        /* decay */
        if (P->p_ld > 0) {
            for (int m = s->nmol - 1; m >= 0; m--) {
                if (rng_unif(&s->rng) < P->p_ld) {
                    const int32_t *g = s->mol + (size_t)m * ml;
                    const int h = s->slot[g[0]];
                    const double hx = s->x[h], hy = s->y[h];
                    const int32_t g0 = g[0];
                    for (int b = 0; b < ml; b++) s->type[s->slot[g[b]]] = TW;
                    remove_molecule(s, m);
                    add_event(s, step, EV_DLIP, g0, hx, hy, -1);
                }
            }
        }
        if (P->p_kd > 0 || P->p_nd > 0) {
            for (int i = 0; i < N; i++) {
                const int t = s->type[i];
                if ((t == TKA || t == TKB) && P->p_kd > 0) {
                    if (rng_unif(&s->rng) < P->p_kd) {
                        s->type[i] = TW;
                        add_event(s, step, EV_DK, s->gid[i], s->x[i], s->y[i], t == TKB);
                    }
                } else if (t == TN && P->p_nd > 0) {
                    if (rng_unif(&s->rng) < P->p_nd) {
                        s->type[i] = TW;
                        add_event(s, step, EV_DN, s->gid[i], s->x[i], s->y[i], -1);
                    }
                }
            }
        }
    }
    if (do_feed) feed_outside(s, P, step);
    return moved;
}

/* Food supply: coarse grid, cells holding >= feed_tmin T beads are membrane;
 * the largest 4-connected (periodic) region of non-membrane cells is the
 * outside medium; W there is converted to N until the N fraction among all
 * beads in that region reaches c_N. */
static int feed_outside(Sys *s, const Params *P, int64_t step) {
    const double L = s->L;
    int ng = (int)floor(L / P->feed_grid);
    if (ng < 3) ng = 3;
    const double ig = ng / L;
    const int ngc = ng * ng;
    int *tcnt = xcalloc(ngc * sizeof(int));
    int *lab = xmalloc(ngc * sizeof(int));
    int *queue = xmalloc(ngc * sizeof(int));
    int *gc = xmalloc(s->N * sizeof(int));
    for (int i = 0; i < s->N; i++) {
        int gx = (int)(s->x[i] * ig), gy = (int)(s->y[i] * ig);
        if (gx >= ng) gx = ng - 1;
        if (gy >= ng) gy = ng - 1;
        gc[i] = gx * ng + gy;
        if (s->type[i] == TT) tcnt[gc[i]]++;
    }
    for (int c = 0; c < ngc; c++) lab[c] = tcnt[c] >= P->feed_tmin ? -2 : -1;
    int nlab = 0, best = -1, bestsize = 0;
    for (int c0 = 0; c0 < ngc; c0++) {
        if (lab[c0] != -1) continue;
        int qh = 0, qt = 0, size = 0;
        lab[c0] = nlab;
        queue[qt++] = c0;
        while (qh < qt) {
            const int c = queue[qh++];
            size++;
            const int gx = c / ng, gy = c % ng;
            const int nbs[4] = {((gx + 1) % ng) * ng + gy, ((gx + ng - 1) % ng) * ng + gy, gx * ng + (gy + 1) % ng,
                                gx * ng + (gy + ng - 1) % ng};
            for (int k = 0; k < 4; k++)
                if (lab[nbs[k]] == -1) {
                    lab[nbs[k]] = nlab;
                    queue[qt++] = nbs[k];
                }
        }
        if (size > bestsize) { bestsize = size; best = nlab; }
        nlab++;
    }
    int added = 0;
    if (best >= 0) {
        long tot = 0, nN = 0, nW = 0;
        int *wl = xmalloc(s->N * sizeof(int));
        for (int i = 0; i < s->N; i++) {
            if (lab[gc[i]] != best) continue;
            tot++;
            if (s->type[i] == TN) nN++;
            else if (s->type[i] == TW) wl[nW++] = i;
        }
        long need = (long)ceil(P->c_N * (double)tot - 1e-9) - nN;
        if (need > nW) need = nW;
        for (long a = 0; a < need; a++) {
            long b = a + rng_below(&s->rng, nW - a);
            int t = wl[a]; wl[a] = wl[b]; wl[b] = t;
            s->type[wl[a]] = TN;
        }
        if (need > 0) added = (int)need;
        free(wl);
    }
    if (added > 0) add_event(s, step, EV_FEED, added, NAN, NAN, -1);
    free(tcnt); free(lab); free(queue); free(gc);
    return added;
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
        int32_t g[MAXMLEN];
        for (int b = 0; b < ml; b++) {
            s->x[gi] = hx + b * P->r0 * cos(phi);
            s->y[gi] = hy + b * P->r0 * sin(phi);
            wrap1(&s->x[gi], L);
            wrap1(&s->y[gi], L);
            s->type[gi] = b < s->nH ? TH : TT;
            s->gid[gi] = gi;
            g[b] = gi;
            gi++;
        }
        add_molecule(s, g);
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

static void init_seeded(Sys *s, const Params *P) {
    const int N = s->N, ml = s->mlen;
    const double L = s->L, R = P->seed_R, c0 = 0.5 * L;
    const double sp = P->seed_spacing;
    const int nout = (int)lround(2.0 * M_PI * (R + 1.0) / sp), nin = (int)lround(2.0 * M_PI * (R - 1.0) / sp);
    const double hw = 0.25 + (ml - 1) * P->r0 + 0.25; /* half width of the excluded annulus */
    if (R - hw < 2.0 || R + hw > 0.5 * L - 2.0) die("seed_R does not fit in the box");
    if ((long)(nout + nin) * ml >= N) die("vesicle larger than system");
    int gi = 0;
    for (int leaf = 0; leaf < 2; leaf++) {
        const int n = leaf == 0 ? nout : nin;
        for (int k = 0; k < n; k++) {
            const double phi = 2.0 * M_PI * (k + 0.5 * leaf) / n;
            int32_t g[MAXMLEN];
            for (int b = 0; b < ml; b++) {
                const double depth = 0.25 + (ml - 1 - b) * P->r0;
                const double rad = leaf == 0 ? R + depth : R - depth;
                s->x[gi] = c0 + rad * cos(phi);
                s->y[gi] = c0 + rad * sin(phi);
                s->type[gi] = b < s->nH ? TH : TT;
                s->gid[gi] = gi;
                g[b] = gi;
                gi++;
            }
            add_molecule(s, g);
        }
    }
    int nKa = 0;
    long nin_s = 0, nout_s = 0;
    for (; gi < N; gi++) {
        double x, y, rr;
        do {
            x = L * rng_unif(&s->rng);
            y = L * rng_unif(&s->rng);
            rr = hypot(x - c0, y - c0);
        } while (fabs(rr - R) < hw);
        s->x[gi] = x;
        s->y[gi] = y;
        s->gid[gi] = gi;
        if (rr < R) {
            nin_s++;
            if (nKa < P->seed_nKa && rr < R - hw - 0.5) { s->type[gi] = TKA; nKa++; }
            else s->type[gi] = rng_unif(&s->rng) < P->seed_cN_in ? TN : TW;
        } else {
            nout_s++;
            s->type[gi] = rng_unif(&s->rng) < P->c_N ? TN : TW;
        }
    }
    logmsg("init seeded: N=%d vesicle R=%.2f lipids out=%d in=%d, solvent inside=%ld outside=%ld, Ka=%d\n", N, R, nout,
           nin, nin_s, nout_s, nKa);
    if (nKa < P->seed_nKa) logmsg("warning: only %d Ka could be placed\n", nKa);
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
    const int N = s->N, ml = s->mlen;
    const int32_t nb = s->nmol * (ml - 1);
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
    int32_t *bb = xmalloc((size_t)(nb + 1) * 2 * sizeof(int32_t));
    int k = 0;
    for (int m = 0; m < s->nmol; m++) {
        const int32_t *g = s->mol + (size_t)m * ml;
        for (int b = 0; b < ml - 1; b++) {
            int32_t i = g[b], j = g[b + 1];
            bb[2 * k] = i < j ? i : j;
            bb[2 * k + 1] = i < j ? j : i;
            k++;
        }
    }
    fwrite(bb, 4, 2 * (size_t)nb, f);
    free(bb);
    if (fclose(f) != 0) die("write error on %s", tmp);
    if (rename(tmp, path) != 0) die("rename %s failed", tmp);
}

#define CKPT_VERSION 1
static void write_ckpt(Sys *s, const char *dir, int keep) {
    char path[2048], tmp[2100];
    snprintf(path, sizeof path, "%s/ckpt.bin", dir);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) die("cannot write %s", tmp);
    const int32_t ver = CKPT_VERSION, N = s->N, ml = s->mlen, nH = s->nH, nmol = s->nmol;
    fwrite("OCKP", 1, 4, f);
    fwrite(&ver, 4, 1, f);
    fwrite(&N, 4, 1, f);
    fwrite(&ml, 4, 1, f);
    fwrite(&nH, 4, 1, f);
    fwrite(&nmol, 4, 1, f);
    fwrite(&s->step, 8, 1, f);
    fwrite(&s->time, 8, 1, f);
    fwrite(&s->L, 8, 1, f);
    fwrite(&s->seed, 8, 1, f);
    fwrite(s->rng.s, 8, 4, f);
    fwrite(s->gid, 4, N, f);
    fwrite(s->type, 1, N, f);
    fwrite(s->x, 8, N, f);
    fwrite(s->y, 8, N, f);
    fwrite(s->vx, 8, N, f);
    fwrite(s->vy, 8, N, f);
    fwrite(s->fx, 8, N, f);
    fwrite(s->fy, 8, N, f);
    fwrite(s->mol, 4, (size_t)nmol * ml, f);
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
    int32_t ver, N, ml, nH, nmol;
    int64_t step;
    double time, L;
    uint64_t seed, rs[4];
    freadx(mg, 1, 4, f, "magic");
    if (memcmp(mg, "OCKP", 4)) die("%s is not an Oercel checkpoint", path);
    freadx(&ver, 4, 1, f, "version");
    if (ver != CKPT_VERSION) die("unsupported checkpoint version %d", ver);
    freadx(&N, 4, 1, f, "N");
    freadx(&ml, 4, 1, f, "mlen");
    freadx(&nH, 4, 1, f, "nH");
    freadx(&nmol, 4, 1, f, "nmol");
    freadx(&step, 8, 1, f, "step");
    freadx(&time, 8, 1, f, "time");
    freadx(&L, 8, 1, f, "L");
    freadx(&seed, 8, 1, f, "seed");
    freadx(rs, 8, 4, f, "rng");
    if (ml != P->lip_nH + P->lip_nT || nH != P->lip_nH) die("checkpoint lipid architecture differs from parameters");
    if (fabs(L - P->L) > 1e-12) die("checkpoint L=%g differs from parameter L=%g", L, P->L);
    sys_alloc(s, N, L, ml, nH, P->threads);
    s->step = step;
    s->time = time;
    s->seed = seed;
    memcpy(s->rng.s, rs, sizeof rs);
    freadx(s->gid, 4, N, f, "gid");
    freadx(s->type, 1, N, f, "type");
    freadx(s->x, 8, N, f, "x");
    freadx(s->y, 8, N, f, "y");
    freadx(s->vx, 8, N, f, "vx");
    freadx(s->vy, 8, N, f, "vy");
    freadx(s->fx, 8, N, f, "fx");
    freadx(s->fy, 8, N, f, "fy");
    int32_t *mol = xmalloc(((size_t)nmol * ml + 1) * sizeof(int32_t));
    freadx(mol, 4, (size_t)nmol * ml, f, "molecules");
    char end[4];
    freadx(end, 1, 4, f, "end marker");
    if (memcmp(end, "END!", 4)) die("checkpoint end marker missing");
    fclose(f);
    for (int i = 0; i < N; i++) s->slot[s->gid[i]] = i;
    for (int m = 0; m < nmol; m++) add_molecule(s, mol + (size_t)m * ml);
    free(mol);
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

static double kinetic_T(const Sys *s, double *px, double *py) {
    double k2 = 0, sx = 0, sy = 0;
    for (int i = 0; i < s->N; i++) {
        k2 += s->vx[i] * s->vx[i] + s->vy[i] * s->vy[i];
        sx += s->vx[i];
        sy += s->vy[i];
    }
    if (px) *px = sx;
    if (py) *py = sy;
    return k2 / (2.0 * s->N - 2.0);
}

static void ensure_dir(const char *d) {
    if (mkdir(d, 0755) != 0 && errno != EEXIST) die("cannot create directory %s: %s", d, strerror(errno));
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s params.ini outdir [key=value ...]\n", argv[0]);
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
        logmsg("restart from %s at step %lld (t=%.4f), N=%d, lipids=%d\n", P.restart, (long long)s->step, s->time, s->N,
               s->nmol);
    } else {
        const int N = (int)lround(P.rho * P.L * P.L);
        sys_alloc(s, N, P.L, mlen, P.lip_nH, P.threads);
        s->seed = P.seed;
        rng_seed(&s->rng, P.seed);
        if (!strcmp(P.init, "soup")) init_soup(s, &P);
        else init_seeded(s, &P);
        for (int i = 0; i < N; i++) s->slot[s->gid[i]] = i;
        set_velocities(s, &P);
        for (int i = 0; i < N; i++) { s->vtx[i] = s->vx[i]; s->vty[i] = s->vy[i]; }
        s->step = 0;
        s->time = 0.0;
        sort_cells(s);
        pair_forces(s, &P, 0);
        bonded_forces(s, &P);
    }
    {
        const int rx = (int)ceil(P.r_cat * s->icsx), ry = (int)ceil(P.r_cat * s->icsy);
        if (s->ncx < 2 * rx + 1 || s->ncy < 2 * ry + 1) die("box too small for r_cat");
    }

    /* parameters used */
    snprintf(path, sizeof path, "%s/params.ini", outdir);
    if (restarting && file_exists(path)) {
        char old[2100];
        snprintf(old, sizeof old, "%s/params_before_%010lld.ini", outdir, (long long)s->step);
        if (rename(path, old) != 0) logmsg("warning: could not keep old params.ini\n");
    }
    write_params(&P, path, argc - 3, argv + 3);

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

    long cnt[NTYPES];
    if (!restarting) {
        double px, py;
        double T = kinetic_T(s, &px, &py);
        count_types(s, cnt);
        if (P.stats_every > 0)
            fprintf(sf, "0,0,%.6f,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d,%.6f\n", T, cnt[TW], cnt[TH], cnt[TT], cnt[TN], cnt[TKA],
                    cnt[TKB], cnt[TZ], s->nmol, s->maxbond);
        s->maxbond = 0;
        if (P.snap_every > 0) write_snapshot(s, outdir);
    } else {
        char sp[2100];
        snprintf(sp, sizeof sp, "%s/snap_%010lld.bin", outdir, (long long)s->step);
        if (P.snap_every > 0 && !file_exists(sp)) write_snapshot(s, outdir);
    }

    const double dt = P.dt, hdt = 0.5 * dt, hdt2 = 0.5 * dt * dt, ldt = P.lambda * dt, L = s->L;
    timers_t tm = {0, 0, 0, 0, 0, 0};
    const int64_t step0 = s->step;
    double t_loop0 = wtime(), t_lastlog = t_loop0;
    int64_t lastlog_step = s->step;
    int stopped_early = 0;
    logmsg("setup %.3f s\n", t_loop0 - t_start);

    while (s->step < P.steps) {
        const int64_t ns = s->step + 1;
        double t0 = wtime();
        /* 1. positions, half-kick, velocity prediction */
        const int N = s->N;
        double *restrict x = s->x, *restrict y = s->y, *restrict vx = s->vx, *restrict vy = s->vy;
        double *restrict fx = s->fx, *restrict fy = s->fy, *restrict vtx = s->vtx, *restrict vty = s->vty;
#pragma omp parallel for schedule(static)
        for (int i = 0; i < N; i++) {
            double xi = x[i] + dt * vx[i] + hdt2 * fx[i];
            double yi = y[i] + dt * vy[i] + hdt2 * fy[i];
            if (xi < 0.0) { xi += L; if (xi >= L) xi -= L; }
            else if (xi >= L) xi -= L;
            if (yi < 0.0) { yi += L; if (yi >= L) yi -= L; }
            else if (yi >= L) yi -= L;
            x[i] = xi;
            y[i] = yi;
            vtx[i] = vx[i] + ldt * fx[i];
            vty[i] = vy[i] + ldt * fy[i];
            vx[i] += hdt * fx[i];
            vy[i] += hdt * fy[i];
        }
        double t1 = wtime();
        tm.integ += t1 - t0;
        sort_cells(s);
        double t2 = wtime();
        tm.sort += t2 - t1;
        /* 2. chemistry on the new configuration */
        if (P.chem) {
            const int do_react = (ns % P.n_chem) == 0;
            const int do_feed = P.feed && (ns % P.feed_every) == 0;
            if (do_react || do_feed) {
                if (chemistry(s, &P, ns, do_react, do_feed)) sort_cells(s);
            }
        }
        double t3 = wtime();
        tm.chem += t3 - t2;
        /* 3. forces */
        pair_forces(s, &P, ns);
        double t4 = wtime();
        tm.pair += t4 - t3;
        bonded_forces(s, &P);
        double t5 = wtime();
        tm.bond += t5 - t4;
        /* 4. second half-kick */
        {
            double *restrict vx2 = s->vx, *restrict vy2 = s->vy;
            const double *restrict fx2 = s->fx, *restrict fy2 = s->fy;
#pragma omp parallel for schedule(static)
            for (int i = 0; i < N; i++) {
                vx2[i] += hdt * fx2[i];
                vy2[i] += hdt * fy2[i];
            }
        }
        s->step = ns;
        s->time += dt;
        double t6 = wtime();
        tm.integ += t6 - t5;
        /* 5. output */
        if (P.stats_every > 0 && ns % P.stats_every == 0) {
            double px, py;
            double T = kinetic_T(s, &px, &py);
            count_types(s, cnt);
            fprintf(sf, "%lld,%.6f,%.6f,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d,%.6f\n", (long long)ns, s->time, T, cnt[TW], cnt[TH],
                    cnt[TT], cnt[TN], cnt[TKA], cnt[TKB], cnt[TZ], s->nmol, s->maxbond);
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
            double T = kinetic_T(s, &px, &py);
            count_types(s, cnt);
            logmsg("step %lld t=%.2f T=%.4f p=(%.2e,%.2e) lip=%d Ka=%ld Kb=%ld N=%ld  %.3f ms/step\n", (long long)ns,
                   s->time, T, px, py, s->nmol, cnt[TKA], cnt[TKB], cnt[TN],
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
    }
    logmsg("done at step %lld%s\n", (long long)s->step, stopped_early ? " (stopped early; restart to continue)" : "");
    if (g_log) fclose(g_log);
    return 0;
}
