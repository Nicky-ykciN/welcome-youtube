/* micro-benchmark of engine phases on an equilibrated-ish water+lipid box */
#define main oercel_main
#include "../oercel.c"
#undef main

int main(int argc, char **argv) {
    double Lb = argc > 1 ? atof(argv[1]) : 128;
    int th = argc > 2 ? atoi(argv[2]) : 1;
    int reps = argc > 3 ? atoi(argv[3]) : 200;
    Params P;
    memset(&P, 0, sizeof P);
    for (int k = 0; k < NPDEFS; k++) set_param(&P, PDEFS[k].key, PDEFS[k].def);
    default_amatrix(&P);
    P.L = Lb; P.threads = th;
    finalize_params(&P);
    omp_set_num_threads(th);
    Sys S, *s = &S;
    int N = (int)lround(P.rho * P.L * P.L);
    sys_alloc(s, N, P.L, P.lip_nH + P.lip_nT, P.lip_nH, th);
    s->seed = 1; rng_seed(&s->rng, 1);
    init_soup(s, &P);
    for (int i = 0; i < N; i++) s->slot[s->gid[i]] = i;
    set_velocities(s, &P);
    for (int i = 0; i < N; i++) { s->vtx[i] = s->vx[i]; s->vty[i] = s->vy[i]; }
    sort_cells(s);
    /* small random displacement each rep to emulate dynamics */
    double tsort = 0, tpair = 0, tint = 0;
    for (int r = 0; r < reps; r++) {
        double t0 = wtime();
#pragma omp parallel for schedule(static)
        for (int i = 0; i < N; i++) {
            double xi = s->x[i] + 0.03 * s->vx[i], yi = s->y[i] + 0.03 * s->vy[i];
            if (xi < 0) xi += P.L; else if (xi >= P.L) xi -= P.L;
            if (yi < 0) yi += P.L; else if (yi >= P.L) yi -= P.L;
            s->x[i] = xi; s->y[i] = yi;
            s->vtx[i] = s->vx[i]; s->vty[i] = s->vy[i];
        }
        double t1 = wtime();
        sort_cells(s);
        double t2 = wtime();
        pair_forces(s, &P, r);
        double t3 = wtime();
        tint += t1 - t0; tsort += t2 - t1; tpair += t3 - t2;
    }
    printf("L=%g N=%d threads=%d: move %.4f  sort %.4f  pair %.4f ms\n", P.L, N, th, 1e3 * tint / reps, 1e3 * tsort / reps,
           1e3 * tpair / reps);
    return 0;
}
