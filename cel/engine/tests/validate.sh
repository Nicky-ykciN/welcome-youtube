#!/bin/bash
# Oercel engine validation suite (SPEC section 2 checks + restart identity).
# usage: engine/tests/validate.sh [outdir]     (default runs/validate; takes ~2-3 min with 2 threads)
# Every check prints PASS/FAIL; the script exits non-zero if any check fails.
# Build: tests/forcetest and tests/molforcetest are ALWAYS rebuilt from source here (make -B), so a
# stale binary or one built on another machine (e.g. with AVX-512) is never what gets tested.
# engine/oercel is rebuilt when oercel.c is newer, and also when it does not run on this machine
# (e.g. an AVX-512 build copied to a CPU without AVX-512). To validate other compiler flags, pass
# them in the ENVIRONMENT (not as make arguments: those would drop -fopenmp) and rebuild the engine
# with them first, e.g. (from cel/):
#   export CFLAGS="-O3 -march=x86-64-v3 -fno-math-errno -fno-trapping-math"
#   make -B -C engine oercel && engine/tests/validate.sh
set -u
cd "$(dirname "$0")/../.."           # -> cel/
ENG=engine/oercel
OUT=${1:-runs/validate}
CHK="python3 engine/tests/snapcheck.py"
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
rm -rf "$OUT"; mkdir -p "$OUT"
make -s -C engine oercel >/dev/null || { echo "build failed (engine/oercel)"; exit 1; }
smoke() { $ENG engine/params/water.ini "$OUT/_smoke" L=8 steps=20 snap_every=0 stats_every=0 ckpt_every=0 log_every=0 threads=1 >/dev/null 2>&1; }
if ! smoke; then
  echo "engine/oercel does not run on this machine (stale or foreign build?): rebuilding it from source"
  { make -s -B -C engine oercel >/dev/null && smoke; } || { echo "build failed: engine/oercel still does not run after a rebuild"; exit 1; }
fi
rm -rf "$OUT/_smoke"
make -s -B -C engine tests/forcetest tests/molforcetest >/dev/null || { echo "build failed (test binaries)"; exit 1; }
# which force kernel the test binaries were just compiled with (engine/oercel: the same, unless it was built with other flags)
cflags=$(make -s -C engine --no-print-directory --eval '_print_cflags: ; @echo $(CC) $(CFLAGS)' _print_cflags 2>/dev/null)
n512=$(echo | ${cflags:-gcc} -dM -E -x c - 2>/dev/null | grep -cE '^#define __AVX512(F|DQ|BW|VL)__ 1')
case "$n512 $cflags" in
  *OERCEL_SCALAR*) kern="scalar force kernel (-DOERCEL_SCALAR)" ;;
  4\ *) kern="AVX-512 force kernel" ;;
  *) kern="scalar force kernel (this build has no AVX-512 F/DQ/BW/VL)" ;;
esac
echo "build: $cflags -> $kern"

echo "== 1. force kernel vs O(N^2) brute force, bonded forces vs finite differences =="
for L in 9 12.5 23.7; do
  for ns in 1 4; do
    r=$(engine/tests/forcetest $L $ns)
    if echo "$r" | grep -q "FORCETEST PASS"; then pass "forcetest L=$L nsub=$ns: $(echo "$r" | grep -o 'max|F_cell - F_brute|=[0-9.e+-]*')"
    else fail "forcetest L=$L nsub=$ns"; echo "$r"; fi
  done
done

echo "== 2. pure water box L=64: kinetic temperature, momentum, drift, g(r) =="
for dt in 0.03 0.04; do
  W=$OUT/water_dt$dt
  steps=$(python3 -c "print(int(900/$dt))")
  $ENG engine/params/water.ini $W L=64 dt=$dt steps=$steps snap_every=$((steps/6)) stats_every=10 log_every=$((steps/3)) threads=2 >/dev/null
  python3 - "$W" "$dt" <<'EOF' || fails=$((fails + 1))
import sys, numpy as np, re
run, dt = sys.argv[1], sys.argv[2]
a = np.genfromtxt(run + '/stats.csv', delimiter=',', names=True)
T = a['T_kin'][a['time'] >= 30]
blk = np.array([c.mean() for c in np.array_split(T, 20)])
err = blk.std(ddof=1) / np.sqrt(20)
h1, h2 = T[:len(T)//2].mean(), T[len(T)//2:].mean()
p = [tuple(map(float, m)) for m in re.findall(r'p=\(([-0-9.e+]+),([-0-9.e+]+)\)', open(run + '/log.txt').read())]
pmax = max(max(abs(u), abs(v)) for u, v in p)
ok = abs(T.mean() - 1) < 0.03 and abs(h1 - h2) < 0.01 and pmax < 1e-8
print(('PASS' if ok else 'FAIL') + f'  water dt={dt}: <T>={T.mean():.4f} +- {err:.4f} ({100*(T.mean()-1):+.2f}%), halves {h1:.4f}/{h2:.4f}, max|P_total|={pmax:.1e}')
sys.exit(0 if ok else 1)
EOF
done
$CHK rdf $(ls $OUT/water_dt0.03/snap_*.bin | tail -n +2) > $OUT/water_rdf.txt   # skip the random step-0 state
python3 - $OUT/water_rdf.txt <<'EOF' || fails=$((fails + 1))
import sys, numpy as np
d = np.loadtxt(sys.argv[1], skiprows=1, usecols=(0, 1))
r, g = d[:, 0], d[:, 1]
pk = g.argmax()
ok = g[0] < 0.1 and 1.03 < g[pk] < 1.2 and 0.7 < r[pk] < 1.0 and abs(g[r > 2.0].mean() - 1) < 0.02
print(('PASS' if ok else 'FAIL') + f'  water g(r): g(0.05)={g[0]:.3f}, first peak {g[pk]:.3f} at r={r[pk]:.2f}, <g(r>2)>={g[r>2].mean():.3f} (soft DPD fluid)')
sys.exit(0 if ok else 1)
EOF

echo "== 3. checkpoint/restart: identical continuation, independent of thread count =="
# every reaction type, the uniform feed with a binding global cap, stirring and the temperature cycle are active
OV="steps=600 snap_every=100 stats_every=10 ckpt_every=300 log_every=0 c_N=0.2 p_syn_a=0.5 p_rep_a=0.2 mu=0.3 p_ld=0.01 p_kd=0.01 p_nd=0.01"
OV="$OV feed=uniform p_feed=0.01 feed_cap=0.2 stir_A=0.05 stir_n=2 kT_amp=0.2 kT_period=5"
$ENG engine/params/soup_small.ini $OUT/restart_A $OV threads=3 ckpt_keep=1 >/dev/null
$ENG engine/params/soup_small.ini $OUT/restart_B $OV threads=1 restart=$OUT/restart_A/ckpt_0000000300.bin >/dev/null
ok=1
for st in 0000000400 0000000500 0000000600; do $CHK cmp $OUT/restart_A/snap_$st.bin $OUT/restart_B/snap_$st.bin >/dev/null || ok=0; done
cmp -s $OUT/restart_A/ckpt.bin $OUT/restart_B/ckpt.bin || ok=0
diff -q <(tail -n +2 $OUT/restart_A/stats.csv | awk -F, '$1+0>300') <(tail -n +2 $OUT/restart_B/stats.csv | awk -F, '$1+0>300') >/dev/null || ok=0
diff -q <(tail -n +2 $OUT/restart_A/events.csv | awk -F, '$1+0>300') <(tail -n +2 $OUT/restart_B/events.csv | awk -F, '$1+0>300') >/dev/null || ok=0
nev=$(tail -n +2 $OUT/restart_A/events.csv | awk -F, '$1+0>300' | wc -l)
kinds=$(tail -n +2 $OUT/restart_A/events.csv | cut -d, -f2 | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
[ $ok = 1 ] && pass "restart at 300 (3 threads -> 1 thread): snapshots 400-600, stats, $nev events, final checkpoint bitwise identical ($kinds)" || fail "restart identity"

echo "== 4. interrupted run (SIGTERM via timeout) + restarts into the same directory =="
# vent feed (a strip across the periodic boundary), stirring and the temperature cycle active
OV="steps=3000 snap_every=500 stats_every=50 ckpt_every=1000 log_every=0 c_N=0.2 p_syn_a=0.3 p_rep_a=0.05 mu=0.3 p_ld=0.001 p_kd=0.001 p_nd=0.001"
OV="$OV feed=vent vent_shape=vstrip vent_x=1 vent_w=6 p_feed=0.05 feed_cap=0 stir_A=0.03 kT_amp=0.1 kT_period=20"
$ENG engine/params/soup_small.ini $OUT/chunk_C $OV threads=2 >/dev/null
timeout 0.7 $ENG engine/params/soup_small.ini $OUT/chunk_D $OV threads=2 >/dev/null
timeout 0.5 $ENG engine/params/soup_small.ini $OUT/chunk_D $OV threads=3 restart=$OUT/chunk_D/ckpt.bin >/dev/null
$ENG engine/params/soup_small.ini $OUT/chunk_D $OV threads=1 restart=$OUT/chunk_D/ckpt.bin >/dev/null
stops=$(grep -c "stopping at step" $OUT/chunk_D/log.txt)
ok=1; for f in stats.csv events.csv snap_0000003000.bin ckpt.bin; do cmp -s $OUT/chunk_C/$f $OUT/chunk_D/$f || ok=0; done
[ $ok = 1 ] && [ "$stops" -ge 1 ] && pass "$stops interruption(s) + restarts: complete stats.csv, events.csv, final snapshot and checkpoint identical to the uninterrupted run" || fail "interrupted run differs (stops=$stops)"

echo "== 5. lipid soup L=64 (no chemistry): aggregation, bond lengths, temperature =="
S=$OUT/soup_nochem
$ENG engine/params/soup_small.ini $S chem=0 steps=60000 snap_every=5000 log_every=0 threads=2 >/dev/null
python3 - $S <<'EOF' || fails=$((fails + 1))
import sys, glob, numpy as np
sys.path.insert(0, 'engine/tests')
from snapcheck import read_snap
from scipy.spatial import cKDTree
run = sys.argv[1]
def tfrac(p):
    s = read_snap(p); L = s['L']
    pos = (np.c_[s['x'], s['y']].astype(float)) % L
    tt = pos[s['t'] == 2]
    a = cKDTree(pos, boxsize=L).query_ball_point(tt, 1.0, return_length=True) - 1
    b = cKDTree(tt, boxsize=L).query_ball_point(tt, 1.0, return_length=True) - 1
    return b.sum() / a.sum()
snaps = sorted(glob.glob(run + '/snap_*.bin'))
f0, f1 = tfrac(snaps[0]), tfrac(snaps[-1])
a = np.genfromtxt(run + '/stats.csv', delimiter=',', names=True)
mb = a['max_bond'].max(); T = a['T_kin'][a['time'] >= 30].mean()
ok = f1 > 0.6 and f0 < 0.3 and mb < 1.5 and abs(T - 1) < 0.03
print(('PASS' if ok else 'FAIL') + f'  soup: T-neighbour fraction {f0:.3f} -> {f1:.3f}, max bond over run {mb:.3f} (< 1.5), <T>={T:.4f}')
sys.exit(0 if ok else 1)
EOF

echo "== 6. food supply: structure blind, exact region, rate, cap (tests/feedcheck.py) =="
FO="chem=1 f_lip=0 f_Ka=0 f_Kb=0 c_N=0 p_nd=0 p_ld=0 p_kd=0 feed_cap=0 n_chem=10 steps=600 snap_every=10 stats_every=10 ckpt_every=0 log_every=0 threads=2 L=48"
$ENG engine/params/water.ini $OUT/feed_uniform $FO feed=uniform p_feed=0.003 >/dev/null
$ENG engine/params/water.ini $OUT/feed_cap $FO feed=uniform p_feed=0.01 feed_cap=0.05 >/dev/null
$ENG engine/params/water.ini $OUT/feed_disk $FO feed=vent vent_shape=disk vent_x=10 vent_y=40 vent_r=5 p_feed=0.05 >/dev/null
$ENG engine/params/water.ini $OUT/feed_vstrip $FO feed=vent vent_shape=vstrip vent_x=1 vent_w=4 p_feed=0.05 >/dev/null
$ENG engine/params/water.ini $OUT/feed_hstrip $FO feed=vent vent_shape=hstrip vent_y=47 vent_w=3 p_feed=0.05 >/dev/null
python3 engine/tests/feedcheck.py $OUT/feed_uniform $OUT/feed_cap $OUT/feed_disk $OUT/feed_vstrip $OUT/feed_hstrip
fails=$((fails + $?))
rm -f "$OUT"/feed_*/snap_*.bin    # 61 snapshots per run, only needed for the check above

echo "== 7. environment: Kolmogorov stirring profile, temperature cycle =="
S=$OUT/stir
$ENG engine/params/water.ini $S L=48 stir_A=0.0015 steps=20000 snap_every=0 stats_every=10 ckpt_every=1000 ckpt_keep=1 log_every=1000 threads=2 >/dev/null
python3 - $S <<'PYEOF' || fails=$((fails + 1))
import sys, glob, re, numpy as np
sys.path.insert(0, 'engine/tests')
from snapcheck import read_ckpt
run, A = sys.argv[1], 0.0015
cks = [read_ckpt(c) for c in sorted(glob.glob(run + '/ckpt_*.bin'))]
cks = [d for d in cks if d['time'] >= 300]        # the flow develops on 1/(nu k^2) ~ 200 t.u.
L = cks[0]['L']; k = 2 * np.pi / L
y = np.concatenate([d['y'] for d in cks]); vx = np.concatenate([d['vx'] for d in cks]); vy = np.concatenate([d['vy'] for d in cks])
M = np.c_[np.sin(k * y), np.cos(k * y), np.ones_like(y)]
c, *_ = np.linalg.lstsq(M, vx, rcond=None)
err = np.sqrt(np.diag(np.linalg.inv(M.T @ M)) * (vx - M @ c).var())
nb = 16; b = (y / L * nb).astype(int) % nb
prof = np.array([vx[b == i].mean() for i in range(nb)]); pe = np.array([vx[b == i].std() / np.sqrt((b == i).sum()) for i in range(nb)])
pred = c[0] * np.sin(k * (np.arange(nb) + 0.5) * L / nb) * np.sinc(1 / nb) + c[2]
chi2 = (((prof - pred) / pe)**2).sum()
p = [tuple(map(float, m)) for m in re.findall(r'p=\(([-0-9.e+]+),([-0-9.e+]+)\)', open(run + '/log.txt').read())]
pmax = max(max(abs(u), abs(v)) for u, v in p)
a = np.genfromtxt(run + '/stats.csv', delimiter=',', names=True)
T = a['T_kin'][a['time'] >= 300].mean()
nu = A / (c[0] * k * k)
ok = c[0] > 10 * err[0] and abs(c[1]) < 4 * err[1] and chi2 < 2.5 * (nb - 2) and pmax < 1e-8 and abs(T - c[0]**2 / 4 - 1) < 0.03
print(('PASS' if ok else 'FAIL') + f'  stirring A={A}, L={L:g}: <v_x>(y) = u0 sin(2 pi y/L), u0={c[0]:.4f}+-{err[0]:.4f}, cos part {c[1]:+.4f}+-{err[1]:.4f}, '
      f'profile chi2={chi2:.1f} (dof {nb-2}), <v_y>={vy.mean():+.4f}; nu = A/(u0 k^2) = {nu:.3f}; max|P_total|={pmax:.1e}; T_kin - u0^2/4 = {T - c[0]**2/4:.4f}')
sys.exit(0 if ok else 1)
PYEOF
rm -f "$S"/ckpt_0*.bin
K=$OUT/kTcycle
$ENG engine/params/water.ini $K L=32 kT_amp=0.2 kT_period=30 steps=10000 snap_every=0 stats_every=10 ckpt_every=0 log_every=0 threads=2 >/dev/null
python3 - $K <<'PYEOF' || fails=$((fails + 1))
import sys, numpy as np
a = np.genfromtxt(sys.argv[1] + '/stats.csv', delimiter=',', names=True)
m = a['time'] >= 30
t, T = a['time'][m], a['T_kin'][m]
w = 2 * np.pi / 30
M = np.c_[np.ones_like(t), np.sin(w * t), np.cos(w * t)]
c, *_ = np.linalg.lstsq(M, T, rcond=None)
amp, lag = np.hypot(c[1], c[2]), np.arctan2(-c[2], c[1])
ok = abs(amp - 0.2) < 0.01 and abs(c[0] - 1) < 0.03 and 0 <= lag < 0.2
print(('PASS' if ok else 'FAIL') + f'  temperature cycle kT(t) = 1 + 0.2 sin(2 pi t/30): T_kin = {c[0]:.4f} + {amp:.4f} sin(2 pi t/30 - {lag:.3f})  (lag {lag/w:.2f} t.u.)')
sys.exit(0 if ok else 1)
PYEOF

echo "== 8. membrane lipid (params/membranes.ini: tied H2T2 'pi' lipid, k_bond 300, two-phase nutrient) =="
r=$(engine/tests/molforcetest)
if echo "$r" | grep -q "MOLFORCETEST PASS"; then pass "molforcetest: bonded forces of $(echo "$r" | grep -c 'r0_head=.*PASS$') lipid templates (linear, pi, y, bola, ties, junction angles) vs finite differences"
else fail "molforcetest"; echo "$r"; fi
# restart identity with the template lipid (checkpoint version 3) and every reaction active
OV="L=32 steps=600 snap_every=100 stats_every=10 ckpt_every=300 log_every=0 warmup=200 chem=1 events=1 p_syn_a=0.5 p_rep_a=0.2 mu=0.3 p_ld=0.01 p_kd=0.01 p_nd=0.01"
OV="$OV feed=uniform p_feed=0.01 feed_cap=0.2 stir_A=0.05 stir_n=2 kT_amp=0.2 kT_period=5"
$ENG engine/params/membranes.ini $OUT/mem_restart_A $OV threads=3 ckpt_keep=1 >/dev/null
$ENG engine/params/membranes.ini $OUT/mem_restart_B $OV threads=1 restart=$OUT/mem_restart_A/ckpt_0000000300.bin >/dev/null
ok=1
for st in 0000000400 0000000500 0000000600; do $CHK cmp $OUT/mem_restart_A/snap_$st.bin $OUT/mem_restart_B/snap_$st.bin >/dev/null || ok=0; done
cmp -s $OUT/mem_restart_A/ckpt.bin $OUT/mem_restart_B/ckpt.bin || ok=0
diff -q <(tail -n +2 $OUT/mem_restart_A/stats.csv | awk -F, '$1+0>300') <(tail -n +2 $OUT/mem_restart_B/stats.csv | awk -F, '$1+0>300') >/dev/null || ok=0
diff -q <(tail -n +2 $OUT/mem_restart_A/events.csv | awk -F, '$1+0>300') <(tail -n +2 $OUT/mem_restart_B/events.csv | awk -F, '$1+0>300') >/dev/null || ok=0
ver=$(python3 -c "import struct;print(struct.unpack_from('<i',open('$OUT/mem_restart_A/ckpt.bin','rb').read(),4)[0])")
nsyn=$(tail -n +2 $OUT/mem_restart_A/events.csv | awk -F, '$1+0>300 && $2=="syn"' | wc -l)
[ $ok = 1 ] && [ "$ver" = 3 ] && pass "pi lipid: restart at 300 (3 threads -> 1 thread), checkpoint version $ver: snapshots, stats, events ($nsyn syntheses after 300), final checkpoint bitwise identical" || fail "pi lipid restart identity (ckpt version $ver)"
# soup with fast synthesis: bond lengths, temperature, every molecule an intact template
M=$OUT/mem_soup
$ENG engine/params/membranes.ini $M L=48 steps=20000 snap_every=5000 stats_every=50 log_every=0 chem=1 events=1 p_syn_a=0.02 p_rep_a=2e-4 p_ld=2e-5 feed=uniform p_feed=1e-3 feed_cap=0.11 threads=2 >/dev/null
python3 - $M <<'PYEOF' || fails=$((fails + 1))
import sys, glob, numpy as np
sys.path.insert(0, 'engine/tests')
from snapcheck import read_snap
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
run = sys.argv[1]
a = np.genfromtxt(run + '/stats.csv', delimiter=',', names=True)
mb_all = a['max_bond'].max(); mb = a['max_bond'][a['step'] > 3000].max(); T = a['T_kin'][a['time'] >= 90].mean()
nsyn = sum(1 for l in open(run + '/events.csv') if ',syn,' in l)
bad = 0; nmol = 0
for p in sorted(glob.glob(run + '/snap_*.bin')):
    s = read_snap(p); t = s['t']; b = s['bonds'].astype(np.int64); n = len(t)
    lip = np.nonzero((t == 1) | (t == 2))[0]
    g = coo_matrix((np.ones(len(b)), (b[:, 0], b[:, 1])), shape=(n, n))
    nc, lab = connected_components(g, directed=False)
    nbond = np.bincount(lab[b[:, 0]], minlength=nc)
    size = np.bincount(lab[lip], minlength=nc)
    nhead = np.bincount(lab[lip[t[lip] == 1]], minlength=nc)
    mols = np.unique(lab[lip])
    bad += int(np.sum((size[mols] != 4) | (nhead[mols] != 2) | (nbond[mols] != 4)))
    nmol = len(mols)
ok = mb < 1.5 and abs(T - 1) < 0.03 and bad == 0 and nsyn > 100
print(('PASS' if ok else 'FAIL') + f'  pi-lipid soup L=48 with {nsyn} syntheses: max bond after warm-up {mb:.3f} (whole run {mb_all:.3f}; < 1.5), <T>={T:.4f}, '
      f'{nmol} molecules in the last snapshot, {bad} molecule-snapshots not an intact H2T2 template (4 beads, 2 H, 4 bonds)')
sys.exit(0 if ok else 1)
PYEOF

echo "== summary: $fails failed check(s) =="
exit $fails
