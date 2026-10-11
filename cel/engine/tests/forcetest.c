/* Unit test: cell-list/strip pair forces vs O(N^2) brute force, and bonded
 * forces vs finite differences of the bonded energy.  Build: make test */
#define main oercel_main
#include "../oercel.c"
#undef main

static double bonded_energy(Sys *s, const Params *P) {
    double U = 0;
    for (int h = 0; h < s->N; h++) {
        if (s->mpos[h] != 0) continue;
        int sl[MAXMLEN], n = 0;
        for (int d = h; d >= 0 && n < s->mlen; d = s->nxt[d]) sl[n++] = d;
        double bx[MAXMLEN], by[MAXMLEN], bl[MAXMLEN];
        for (int b = 0; b < n - 1; b++) {
            int i = sl[b], j = sl[b + 1];
            bx[b] = minimg(s->x[j] - s->x[i], s->L);
            by[b] = minimg(s->y[j] - s->y[i], s->L);
            bl[b] = hypot(bx[b], by[b]);
            U += 0.5 * P->k_bond * (bl[b] - P->r0) * (bl[b] - P->r0);
        }
        for (int b = 0; b < n - 2; b++)
            U += P->k_angle * (1.0 - (bx[b] * bx[b + 1] + by[b] * by[b + 1]) / (bl[b] * bl[b + 1]));
    }
    return U;
}

int main(int argc, char **argv) {
    Params P;
    memset(&P, 0, sizeof P);
    for (int k = 0; k < NPDEFS; k++) set_param(&P, PDEFS[k].key, PDEFS[k].def);
    default_amatrix(&P);
    P.L = argc > 1 ? atof(argv[1]) : 12.5; /* non-integer L: cell side != 1 */
    P.f_lip = 0.15; P.f_Ka = 0.02; P.f_Kb = 0.02; P.c_N = 0.1;
    P.threads = 4;
    if (argc > 2) P.nsub = atoi(argv[2]);
    finalize_params(&P);
    omp_set_num_threads(P.threads);
    Sys S, *s = &S;
    int N = (int)lround(P.rho * P.L * P.L);
    sys_alloc(s, N, P.L, P.lip_nH + P.lip_nT, P.lip_nH, P.threads, P.nsub);
    s->seed = 99; rng_seed(&s->rng, 99);
    init_soup(s, &P);
    set_velocities(s, &P);
    for (int i = 0; i < N; i++) { s->vtx[i] = s->vx[i] + 0.3 * rng_normal(&s->rng); s->vty[i] = s->vy[i]; }
    /* put some beads exactly on cell boundaries / box edge to stress wrapping */
    s->x[0] = 0.0; s->y[1] = P.L - 1e-13; s->x[2] = s->csx * 3; s->y[2] = s->csy * 2;
    sort_cells(s);
    /* chain integrity after several sorts with moved beads */
    for (int rep = 0; rep < 5; rep++) {
        for (int d = 0; d < N; d++) { s->x[d] += 0.3 * rng_normal(&s->rng); wrap1(&s->x[d], P.L); }
        sort_cells(s);
    }
    {
        int bad = 0, heads = 0;
        for (int d = 0; d < N; d++) {
            if (s->mpos[d] < 0) { bad += s->nxt[d] != -1 || s->type[d] == TH || s->type[d] == TT; continue; }
            if (s->mpos[d] == 0) heads++;
            const int nx = s->nxt[d];
            if (s->mpos[d] < s->mlen - 1) bad += nx < 0 || s->gid[nx] != s->gid[d] + 1 || s->mpos[nx] != s->mpos[d] + 1;
            else bad += nx != -1;
        }
        /* cells: every bead inside its cell */
        for (int c = 0; c < s->ncell; c++)
            for (int d = s->cstart[c]; d < s->cstart[c + 1]; d++) bad += cell_of_pos(s, s->x[d], s->y[d]) != c;
        printf("chain/cell integrity after sorts: heads=%d errors=%d\n", heads, bad);
        if (bad) { printf("FORCETEST FAIL\n"); return 1; }
    }
    /* pair forces (+ stirring body force, + kT(t) in sigma) vs O(N^2) brute force,
     * for plain physics and with the environmental physics switched on */
    int ok = 1;
    const uint64_t ss = step_seed(s->seed, 12345);
    double *bfx = calloc(N, sizeof(double)), *bfy = calloc(N, sizeof(double));
    for (int env = 0; env < 2; env++) {
        P.stir_A = env ? 0.7 : 0.0;
        P.stir_n = env ? 2 : 1;
        P.kT_amp = env ? 0.3 : 0.0;
        P.kT_period = 10.0;
        const double t = env ? 2.5 : 0.0; /* sin(2 pi 2.5/10) = 1 -> kT = 1.3 */
        omp_set_num_threads(P.threads);
        pair_forces(s, &P, 12345, t);
        const double kTt = P.kT + P.kT_amp * sin(2 * M_PI * t / P.kT_period);
        const double sdt = sqrt(2 * P.gamma * kTt) / sqrt(P.dt);
        long npair = 0;
        double fsum = 0;
        for (int i = 0; i < N; i++) {
            bfx[i] = P.stir_A * sin(2 * M_PI * P.stir_n * s->y[i] / P.L);
            bfy[i] = 0;
            fsum += bfx[i];
        }
        for (int i = 0; i < N; i++) bfx[i] -= fsum / N;
        for (int i = 0; i < N; i++)
            for (int j = i + 1; j < N; j++) {
                double dx = minimg(s->x[i] - s->x[j], P.L), dy = minimg(s->y[i] - s->y[j], P.L);
                double r2 = dx * dx + dy * dy;
                if (r2 >= 1.0) continue;
                npair++;
                double r = sqrt(r2), w = 1 - r;
                double ex = dx / r, ey = dy / r;
                double rv = ex * (s->vtx[i] - s->vtx[j]) + ey * (s->vty[i] - s->vty[j]);
                double th = pair_theta(ss, s->gid[i], s->gid[j]);
                double fm = P.a[s->type[i]][s->type[j]] * w - P.gamma * w * w * rv + sdt * w * th;
                bfx[i] += fm * ex; bfy[i] += fm * ey; bfx[j] -= fm * ex; bfy[j] -= fm * ey;
            }
        double maxd = 0, maxf = 0, sumx = 0, sumy = 0;
        for (int i = 0; i < N; i++) {
            maxd = fmax(maxd, fmax(fabs(bfx[i] - s->fx[i]), fabs(bfy[i] - s->fy[i])));
            maxf = fmax(maxf, fabs(bfx[i]));
            sumx += s->fx[i]; sumy += s->fy[i];
        }
        printf("pair forces%s: N=%d L=%g cells=%dx%d pairs=%ld  max|F_cell - F_brute|=%.3e (max|F|=%.1f)  sum F=(%.2e,%.2e)\n",
               env ? " + stirring (A=0.7, n=2) + kT(t)=1.3" : "", N, P.L, s->ncx, s->ncy, npair, maxd, maxf, sumx, sumy);
        ok &= maxd < 1e-9 && fabs(sumx) < 1e-9 && fabs(sumy) < 1e-9;
        /* thread-count independence of the kernel */
        double *f4 = malloc(N * sizeof(double));
        memcpy(f4, s->fx, N * sizeof(double));
        omp_set_num_threads(1);
        pair_forces(s, &P, 12345, t);
        int same = memcmp(f4, s->fx, N * sizeof(double)) == 0;
        printf("pair forces%s bitwise identical with 1 vs %d threads: %s\n", env ? " + environment" : "", P.threads,
               same ? "yes" : "NO");
        ok &= same;
        free(f4);
    }
    P.stir_A = 0; P.kT_amp = 0;
    /* fast sine of the stirring force vs libm */
    {
        double me = 0;
        for (long k = -2000000; k <= 2000000; k++) {
            const double u = k * 1.37e-6 + 1e-9 * (k % 7);
            me = fmax(me, fabs(sin2pi(u) - sin(2 * M_PI * u)));
        }
        printf("sin2pi vs libm sin(2 pi u), u in [-2.74, 2.74]: max|diff|=%.2e\n", me);
        ok &= me < 1e-14;
    }
    /* noise statistics */
    double m1 = 0, m2 = 0, c1 = 0;
    long nn = 0;
    double prev = 0;
    for (uint32_t i = 0; i < 2000; i++)
        for (uint32_t j = i + 1; j < i + 500; j++) {
            double th = pair_theta(ss, i, j);
            m1 += th; m2 += th * th; c1 += th * prev; prev = th; nn++;
        }
    printf("noise: n=%ld mean=%.4f var=%.4f lag1 corr=%.4f  symmetric=%s\n", nn, m1 / nn, m2 / nn, c1 / nn,
           pair_theta(ss, 5, 9) == pair_theta(ss, 9, 5) ? "yes" : "NO");
    /* bonded forces vs finite differences */
    for (int i = 0; i < N; i++) { s->fx[i] = s->fy[i] = 0; }
    /* distort molecules a bit */
    for (int d = 0; d < N; d++)
        if (s->mpos[d] >= 0) {
            s->x[d] += 0.15 * rng_normal(&s->rng); s->y[d] += 0.15 * rng_normal(&s->rng);
            wrap1(&s->x[d], P.L); wrap1(&s->y[d], P.L);
        }
    int nlip = count_lipids(s);
    bonded_forces(s, &P);
    double maxe = 0, maxbf = 0;
    const double h = 1e-6;
    int checked = 0;
    for (int sl = 0; sl < N && checked < 80; sl++) {
        if (s->mpos[sl] < 0) continue;
        checked++;
        for (int c = 0; c < 2; c++) {
            double *q = c ? &s->y[sl] : &s->x[sl];
            double q0 = *q;
            *q = q0 + h; double Up = bonded_energy(s, &P);
            *q = q0 - h; double Um = bonded_energy(s, &P);
            *q = q0;
            double fnum = -(Up - Um) / (2 * h);
            double fan = c ? s->fy[sl] : s->fx[sl];
            maxe = fmax(maxe, fabs(fnum - fan));
            maxbf = fmax(maxbf, fabs(fan));
        }
    }
    printf("lipids=%d, checked %d lipid beads\n", nlip, checked);
    printf("bonded forces: max|F_analytic - F_numeric|=%.3e (max|F|=%.2f)\n", maxe, maxbf);
    ok &= maxe < 1e-5 * fmax(1, maxbf);
    printf("%s\n", ok ? "FORCETEST PASS" : "FORCETEST FAIL");
    return ok ? 0 : 1;
}
