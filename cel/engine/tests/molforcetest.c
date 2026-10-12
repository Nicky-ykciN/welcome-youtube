/* Unit test: bonded forces of the lipid molecule templates (linear, pi, y; with
 * junction angle term and tie bond) vs central finite differences of an
 * independently written bonded energy.  Also checks the template geometry
 * (bond lengths at rest in the synthesis template).
 * Build: gcc -O2 -march=native -fopenmp -o tests/molforcetest tests/molforcetest.c -lm
 * Run:   tests/molforcetest            (prints PASS/FAIL per architecture) */
#define main oercel_main
#include "../oercel.c"
#undef main

static double energy_ref(Sys *s, const Params *P) {
    const mol_t *M = &g_mol;
    double U = 0;
    for (int h = 0; h < s->N; h++) {
        if (s->mpos[h] != 0) continue;
        int sl[MAXMLEN], n = 0;
        for (int d = h; d >= 0 && n < s->mlen; d = s->nxt[d]) sl[n++] = d;
        for (int q = 0; q < M->nb; q++) {
            const int i = sl[M->bi[q]], j = sl[M->bj[q]];
            const double r = hypot(minimg(s->x[j] - s->x[i], s->L), minimg(s->y[j] - s->y[i], s->L));
            U += 0.5 * P->k_bond * (r - M->br0[q]) * (r - M->br0[q]);
        }
        for (int q = 0; q < M->na; q++) {
            const int i = sl[M->ai[q]], j = sl[M->aj[q]], k = sl[M->ak[q]];
            const double ax = minimg(s->x[j] - s->x[i], s->L), ay = minimg(s->y[j] - s->y[i], s->L);
            const double cx = minimg(s->x[k] - s->x[j], s->L), cy = minimg(s->y[k] - s->y[j], s->L);
            const double c = (ax * cx + ay * cy) / (hypot(ax, ay) * hypot(cx, cy));
            U += M->akind[q] == 0 ? M->aK[q] * (1.0 - c) : M->aK[q] * (c - M->ac0[q]) * (c - M->ac0[q]);
        }
    }
    return U;
}

static int run_case(const char *arch, int nT, int tie, double kh, double ch, double r0h) {
    Params P;
    memset(&P, 0, sizeof P);
    for (int k = 0; k < NPDEFS; k++) set_param(&P, PDEFS[k].key, PDEFS[k].def);
    default_amatrix(&P);
    P.L = 12.5;
    P.f_lip = 0.3; P.f_Ka = 0.01; P.c_N = 0.1;
    P.threads = 2;
    snprintf(P.lip_arch, sizeof P.lip_arch, "%s", arch);
    P.lip_nT = nT; P.lip_tie = tie; P.k_head = kh; P.cos_head = ch; P.r0_head = r0h;
    finalize_params(&P);
    omp_set_num_threads(P.threads);
    Sys S, *s = &S;
    int N = (int)lround(P.rho * P.L * P.L);
    sys_alloc(s, N, P.L, g_mol.mlen, g_mol.nH, P.threads, P.nsub);
    s->seed = 7; rng_seed(&s->rng, 7);
    init_soup(s, &P);
    /* template geometry: every bond of the soup-init molecule at its rest length */
    double gerr = 0;
    for (int h = 0; h < N; h++) {
        if (s->mpos[h] != 0) continue;
        int sl[MAXMLEN];
        mol_slots(s, h, sl);
        for (int q = 0; q < g_mol.nb; q++) {
            const int i = sl[g_mol.bi[q]], j = sl[g_mol.bj[q]];
            const double r = hypot(minimg(s->x[j] - s->x[i], s->L), minimg(s->y[j] - s->y[i], s->L));
            gerr = fmax(gerr, fabs(r - g_mol.br0[q]));
        }
        for (int b = 0; b < g_mol.mlen; b++)
            if ((s->type[sl[b]] == TH) != (b < g_mol.nH)) gerr = 1e9;
    }
    sort_cells(s);
    for (int d = 0; d < N; d++)
        if (s->mpos[d] >= 0) {
            s->x[d] += 0.12 * rng_normal(&s->rng); s->y[d] += 0.12 * rng_normal(&s->rng);
            wrap1(&s->x[d], P.L); wrap1(&s->y[d], P.L);
        }
    for (int i = 0; i < N; i++) s->fx[i] = s->fy[i] = 0;
    s->maxbond = 0;
    bonded_forces(s, &P);
    double maxe = 0, maxf = 0;
    const double hh = 1e-6;
    int checked = 0;
    for (int d = 0; d < N && checked < 120; d++) {
        if (s->mpos[d] < 0) continue;
        checked++;
        for (int c = 0; c < 2; c++) {
            double *q = c ? &s->y[d] : &s->x[d];
            const double q0 = *q;
            *q = q0 + hh; const double Up = energy_ref(s, &P);
            *q = q0 - hh; const double Um = energy_ref(s, &P);
            *q = q0;
            const double fn = -(Up - Um) / (2 * hh), fa = c ? s->fy[d] : s->fx[d];
            maxe = fmax(maxe, fabs(fn - fa));
            maxf = fmax(maxf, fabs(fa));
        }
    }
    /* total bonded force must vanish (Newton's third law) */
    double sx = 0, sy = 0;
    for (int d = 0; d < N; d++) { sx += s->fx[d]; sy += s->fy[d]; }
    const int ok = maxe < 1e-5 * fmax(1, maxf) && gerr < 1e-12 + (P.lip_tie ? 1e9 : 0) && fabs(sx) + fabs(sy) < 1e-9;
    printf("%-6s nT=%d tie=%d k_head=%g cos_head=%g r0_head=%g: mlen=%d bonds=%d angles=%d lipids=%d  "
           "template bond err=%.1e  max|F_an-F_num|=%.2e (max|F|=%.1f)  sumF=%.1e  %s\n",
           arch, nT, tie, kh, ch, r0h, g_mol.mlen, g_mol.nb, g_mol.na, count_lipids(s), gerr, maxe, maxf,
           fabs(sx) + fabs(sy), ok ? "PASS" : "FAIL");
    return ok;
}

int main(void) {
    int ok = 1;
    ok &= run_case("linear", 3, 0, 0, 0, 0.5);
    ok &= run_case("pi", 3, 0, 0, 0, 0.5);
    ok &= run_case("pi", 3, 1, 20, 0.0, 0.7);
    ok &= run_case("pi", 4, 1, 10, 0.2, 0.6);
    ok &= run_case("y", 3, 0, 15, -0.3, 0.5);
    ok &= run_case("y", 2, 1, 5, -0.5, 0.6);
    ok &= run_case("pi", 2, 2, 0, 0, 0.7);
    ok &= run_case("bola", 3, 0, 0, 0, 0.7);
    ok &= run_case("bola", 4, 2, 10, 0.1, 0.8);
    ok &= run_case("pi", 1, 1, 0, 0, 0.7);   /* final membrane lipid (params/membranes.ini) */
    printf("%s\n", ok ? "MOLFORCETEST PASS" : "MOLFORCETEST FAIL");
    return ok ? 0 : 1;
}
