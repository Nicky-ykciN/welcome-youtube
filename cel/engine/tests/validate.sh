#!/bin/bash
# Oercel engine validation suite (SPEC section 2 checks + restart identity).
# usage: engine/tests/validate.sh [outdir]     (default runs/validate; takes ~3-4 min)
# Every check prints PASS/FAIL; the script exits non-zero if any check fails.
set -u
cd "$(dirname "$0")/../.."           # -> cel/
ENG=engine/oercel
OUT=${1:-runs/validate}
CHK="python3 engine/tests/snapcheck.py"
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
rm -rf "$OUT"; mkdir -p "$OUT"
make -s -C engine oercel tests/forcetest >/dev/null || { echo "build failed"; exit 1; }

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
OV="steps=600 snap_every=100 stats_every=10 ckpt_every=300 log_every=0 c_N=0.2 p_syn_a=0.5 p_rep_a=0.2 mu=0.3 p_ld=0.01 p_kd=0.01 p_nd=0.01"
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
OV="steps=3000 snap_every=500 stats_every=50 ckpt_every=1000 log_every=0 c_N=0.2 p_syn_a=0.3 p_rep_a=0.05 mu=0.3 p_ld=0.001 p_kd=0.001 p_nd=0.001"
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

echo "== summary: $fails failed check(s) =="
exit $fails
