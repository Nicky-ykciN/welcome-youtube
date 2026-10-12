#!/bin/bash
# oercel_gpu self-test: run this FIRST on the GPU machine (after setup_wsl.sh).
#
#   engine_gpu/selftest_gpu.sh                full test (~10-20 min on a Threadripper + RTX 8000)
#   engine_gpu/selftest_gpu.sh --quick        shorter runs (statistics checks are weaker)
#   engine_gpu/selftest_gpu.sh --big          benchmark also L = 2048 (12.6 M beads) and 4096 (50 M beads)
#   engine_gpu/selftest_gpu.sh --emu          test the CPU-emulation build instead of the GPU build
#                                             (how this script was itself tested on a machine without GPU)
#   engine_gpu/selftest_gpu.sh --only "3 8"   run only these sections
#
# It builds the GPU engine and the CPU reference engine (from ../engine/oercel.c, into
# engine_gpu/build/, never touching engine/), runs short water and soup simulations on both,
# compares them statistically and prints PASS/FAIL per check, then prints ms/step of the GPU
# engine at L = 128, 256, 512, 1024.  Output: engine_gpu/testruns/selftest_<date>/ (summary.txt).
# Exit code = number of failed checks.
set -u
# run from a private copy, so that editing or updating this file (git pull) during a run is safe
if [ -z "${OG_SELFTEST_HERE:-}" ]; then
  export OG_SELFTEST_HERE="$(cd "$(dirname "$0")" && pwd)"
  tmp=$(mktemp "${TMPDIR:-/tmp}/oercel_selftest.XXXXXX")
  cp "$0" "$tmp"
  exec bash "$tmp" "$@"
fi
HERE="$OG_SELFTEST_HERE"
CEL="$(cd "$HERE/.." && pwd)"
cd "$HERE"
QUICK=0; BIG=0; EMU=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --big) BIG=1 ;;
    --emu) EMU=1 ;;
    --only) ONLY="$2"; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
OUT="$HERE/testruns/selftest_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
exec > >(tee -a "$OUT/selftest.log") 2>&1
NFAIL=0; NPASS=0
pass() { echo "PASS  $*"; echo "PASS  $*" >> "$SUMMARY"; NPASS=$((NPASS + 1)); }
fail() { echo "FAIL  $*"; echo "FAIL  $*" >> "$SUMMARY"; NFAIL=$((NFAIL + 1)); }
# run a python check; its PASS/FAIL lines go to the summary
pycheck() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  echo "$out"
  echo "$out" | grep -E '^(PASS|FAIL|WARN)' >> "$SUMMARY"
  NPASS=$((NPASS + $(echo "$out" | grep -c '^PASS')))
  NFAIL=$((NFAIL + $(echo "$out" | grep -c '^FAIL')))
  if [ $rc -ne 0 ] && ! echo "$out" | grep -q '^FAIL'; then fail "python check crashed: $*"; fi
}
want() { [ -z "$ONLY" ] || [[ " $ONLY " == *" $1 "* ]]; }
NPROC=$(nproc)
CT=$(( NPROC > 16 ? 16 : NPROC ))      # threads for the CPU reference engine
[ $EMU = 1 ] && CT=1                   # emulation test machine: 1 thread per engine (2 run concurrently)
export OMP_NUM_THREADS=$CT
COMPARE="python3 $HERE/tests/compare.py"
SNAPCHECK="$CEL/engine/tests/snapcheck.py"
SOUP="$CEL/engine/params/soup_small.ini";  [ -f "$SOUP" ] || SOUP="$HERE/tests/soup_small.ini"
WATER="$CEL/engine/params/water.ini";      [ -f "$WATER" ] || WATER="$HERE/tests/water.ini"
TEAMA="$CEL/notes/membranen/teamA_membranes.ini"; [ -f "$TEAMA" ] || TEAMA="$HERE/tests/teamA_membranes.ini"
echo "selftest $(date)  host $(hostname)  cores $NPROC  quick=$QUICK emu=$EMU  out=$OUT"

echo; echo "== 0. build =="
if [ $EMU = 1 ]; then
  make -s emu || { fail "emulation build"; exit 1; }
  ENG="$HERE/oercel_emu"; GT=1
else
  if [ ! -x "$HERE/oercel_gpu" ] || [ "$HERE/oercel_gpu.cu" -nt "$HERE/oercel_gpu" ]; then
    NVCC_BIN=$(for c in "${NVCC:-}" "$HERE/.cuda/bin/nvcc" "$(command -v nvcc)" /usr/local/cuda/bin/nvcc; do [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; break; }; done)
    [ -n "$NVCC_BIN" ] || { echo "no nvcc found: run $HERE/setup_wsl.sh first"; exit 1; }
    CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d ' .')
    make -s NVCC="$NVCC_BIN" ARCH="${ARCH:-sm_${CAP:-75}}" oercel_gpu || { fail "CUDA build"; exit 1; }
  fi
  ENG="$HERE/oercel_gpu"; GT=4
  nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>/dev/null
fi
mkdir -p build
REF_SRC="$CEL/engine/oercel.c"; [ -f "$REF_SRC" ] || REF_SRC="$HERE/ref/oercel_ref.c"
gcc -O3 -march=native -fno-math-errno -fno-trapping-math -std=gnu11 -fopenmp -o build/oercel_ref "$REF_SRC" -lm || { fail "reference build"; exit 1; }
gcc -O3 -march=native -fno-math-errno -fno-trapping-math -std=gnu11 -fopenmp -o build/oercel_memB "$HERE/ref/oercel_memB.c" -lm || fail "memB reference build"
REF="$HERE/build/oercel_ref"; MEMB="$HERE/build/oercel_memB"
"$ENG" --version; pass "build: $("$ENG" --version)"
# parameter parity: every key of the current reference engine must be known to oercel_gpu
missing=$(comm -23 <("$REF" --params | grep -o '^| `[a-zA-Z_0-9]*`' | tr -d '|` ' | sort) <("$ENG" --params | grep -o '^| `[a-zA-Z_0-9]*`' | tr -d '|` ' | sort))
[ -z "$missing" ] && pass "parameter parity: all $("$REF" --params | grep -c '^| `') reference keys known to oercel_gpu" \
                  || fail "reference engine has keys oercel_gpu does not know: $missing (the reference changed; port them)"
diffdef=$(diff <("$REF" --params | grep '^| `') <("$ENG" --params | grep '^| `' | grep -v -E '`(lip_arch|r0_head|k_head|cos_head|lip_tie|syn_nN)`' | sed 's/ (linear) or per tail (pi, y)//') | grep -c '^[<>]')
[ "$diffdef" = 0 ] && pass "parameter defaults and help texts identical to the reference" || echo "note: $diffdef parameter table lines differ from the reference (check 'diff <($REF --params) <($ENG --params)')"

if want 1; then
echo; echo "== 1. kernel self-test: pair forces vs O(N^2) brute force, exact antisymmetry, sort, bonded vs finite differences =="
for L in 9 12.5 23.7 64.3; do
  r=$("$ENG" --forcetest $L 2>&1); echo "$r" | grep -v '^sort [0-4]'
  echo "$r" | grep -q 'FORCETEST PASS' && pass "forcetest L=$L" || fail "forcetest L=$L"
done
for a in pi y bola; do
  r=$("$ENG" --forcetest 12.5 $a 2>&1); echo "$r" | grep -E 'bonded|FORCETEST'
  echo "$r" | grep -q 'FORCETEST PASS' && pass "forcetest lip_arch=$a" || fail "forcetest lip_arch=$a"
done
fi

if want 2; then
echo; echo "== 2. determinism: same parameters twice -> bitwise identical output =="
OV="steps=1500 snap_every=500 stats_every=10 ckpt_every=0 log_every=0 c_N=0.2 p_syn_a=0.5 p_rep_a=0.2 mu=0.3 p_ld=0.01 p_kd=0.01 p_nd=0.01 feed=uniform p_feed=0.01 feed_cap=0.2 stir_A=0.05 stir_n=2 kT_amp=0.2 kT_period=5"
"$ENG" "$SOUP" "$OUT/det_A" $OV threads=$GT > /dev/null && "$ENG" "$SOUP" "$OUT/det_B" $OV threads=$GT > /dev/null
pycheck $COMPARE ident "$OUT/det_A" "$OUT/det_B"
echo "-- parallel chemistry (cell-lock rounds) vs the plain serial loop in priority order (OERCEL_CHEM_SERIAL=1): must be identical"
OERCEL_CHEM_SERIAL=1 "$ENG" "$SOUP" "$OUT/det_S" $OV threads=$GT > /dev/null
pycheck $COMPARE ident "$OUT/det_A" "$OUT/det_S"
fi

if want 3; then
echo; echo "== 3. pure water L=64: temperature, momentum, g(r), pressure vs the CPU reference =="
ST=30000; [ $QUICK = 1 ] && ST=10000
for dt in 0.03; do
  "$REF" "$WATER" "$OUT/water_ref" L=64 dt=$dt steps=$ST snap_every=$((ST / 10)) stats_every=10 log_every=$((ST / 10)) ckpt_every=0 threads=$CT > /dev/null
  "$ENG" "$WATER" "$OUT/water_gpu" L=64 dt=$dt steps=$ST snap_every=$((ST / 10)) stats_every=10 log_every=$((ST / 10)) ckpt_every=0 threads=$GT > /dev/null
  pycheck $COMPARE water "$OUT/water_ref" "$OUT/water_gpu" --teq 30
done
fi

if want 4; then
echo; echo "== 4. lipid soup L=64 without chemistry: bonds, aggregation, temperature vs the CPU reference =="
ST=60000; [ $QUICK = 1 ] && ST=20000
"$REF" "$SOUP" "$OUT/soup_ref" chem=0 steps=$ST snap_every=$((ST / 20)) stats_every=100 log_every=0 ckpt_every=0 threads=$CT > /dev/null & bgpid=$!
"$ENG" "$SOUP" "$OUT/soup_gpu" chem=0 steps=$ST snap_every=$((ST / 20)) stats_every=100 log_every=0 ckpt_every=0 threads=$GT > /dev/null
wait $bgpid
pycheck $COMPARE bonds "$OUT/soup_ref" "$OUT/soup_gpu" --teq 30
fi

if want 5; then
echo; echo "== 5. chemistry: reaction, decay and feed rates vs the CPU reference (soup_small.ini, 2 seeds each) =="
ST=40000; [ $QUICK = 1 ] && ST=15000
CO="p_rep_a=1.5e-3 steps=$ST snap_every=0 stats_every=100 log_every=0 ckpt_every=0"
for sd in 1 2; do
  "$REF" "$SOUP" "$OUT/chem_ref_s$sd" $CO seed=$sd threads=$CT > /dev/null & bgpid=$!
  "$ENG" "$SOUP" "$OUT/chem_gpu_s$sd" $CO seed=$sd threads=$GT > /dev/null
  wait $bgpid
done
pycheck $COMPARE chem "$OUT/chem_ref_s1,$OUT/chem_ref_s2" "$OUT/chem_gpu_s1,$OUT/chem_gpu_s2"
# low-noise version: well-mixed water, synthesis-only and replication-only runs (rates per
# catalyst-check, mutation fraction = mu)
ST=20000
pycheck "$HERE/tests/chemstat.sh" "$ENG" "$REF" "$OUT/chemstat" $ST $CT
fi

if want 6; then
echo; echo "== 6. checkpoint/restart: identical continuation; interrupted run + restarts identical =="
OV="steps=600 snap_every=100 stats_every=10 ckpt_every=300 log_every=0 c_N=0.2 p_syn_a=0.5 p_rep_a=0.2 mu=0.3 p_ld=0.01 p_kd=0.01 p_nd=0.01 feed=uniform p_feed=0.01 feed_cap=0.2 stir_A=0.05 stir_n=2 kT_amp=0.2 kT_period=5"
"$ENG" "$SOUP" "$OUT/restart_A" $OV threads=$GT ckpt_keep=1 > /dev/null
"$ENG" "$SOUP" "$OUT/restart_B" $OV threads=1 restart="$OUT/restart_A/ckpt_0000000300.bin" > /dev/null
pycheck $COMPARE ident "$OUT/restart_A" "$OUT/restart_B" --after 300
OV="steps=3000 snap_every=500 stats_every=50 ckpt_every=1000 log_every=0 c_N=0.2 p_syn_a=0.3 p_rep_a=0.05 mu=0.3 p_ld=0.001 p_kd=0.001 p_nd=0.001 feed=vent vent_shape=vstrip vent_x=1 vent_w=6 p_feed=0.05 feed_cap=0 stir_A=0.03 kT_amp=0.1 kT_period=20"
t0=$(date +%s.%N)
"$ENG" "$SOUP" "$OUT/chunk_C" $OV threads=$GT > /dev/null
tC=$(python3 -c "import time; print(f'{time.time() - $t0:.2f}')")
# interrupt with SIGTERM at ~45% and ~35% of the uninterrupted run time, then finish
T1=$(python3 -c "print(f'{0.45 * $tC:.2f}')"); T2=$(python3 -c "print(f'{0.35 * $tC:.2f}')")
timeout -s TERM $T1 "$ENG" "$SOUP" "$OUT/chunk_D" $OV threads=$GT > /dev/null
for attempt in 1 2 3 4 5 6; do
  grep -q "done at step 3000" "$OUT/chunk_D/log.txt" 2>/dev/null && break
  if [ -f "$OUT/chunk_D/ckpt.bin" ]; then RS="restart=$OUT/chunk_D/ckpt.bin"; else RS=""; fi
  if [ $attempt -lt 3 ]; then timeout -s TERM $T2 "$ENG" "$SOUP" "$OUT/chunk_D" $OV threads=$GT $RS > /dev/null
  else "$ENG" "$SOUP" "$OUT/chunk_D" $OV threads=$GT $RS > /dev/null; fi
done
stops=$(grep -c "stopping at step" "$OUT/chunk_D/log.txt")
echo "uninterrupted run ${tC}s; SIGTERM after ${T1}s and ${T2}s; $stops clean stop(s) with checkpoint"
okc=1; for f in stats.csv events.csv snap_0000003000.bin ckpt.bin; do cmp -s "$OUT/chunk_C/$f" "$OUT/chunk_D/$f" || okc=0; done
[ $okc = 1 ] && pass "$stops interruption(s) by SIGTERM + restarts into the same directory: stats.csv, events.csv, final snapshot, ckpt.bin identical to the uninterrupted run" \
             || fail "interrupted + restarted run differs from the uninterrupted one (stops=$stops)"
[ "$stops" -ge 1 ] || fail "no interruption happened (run too short?) - the SIGTERM path was not tested"
fi

if want 7; then
echo; echo "== 7. checkpoint compatibility with the CPU reference engine (both directions) =="
OV="steps=1000 snap_every=500 stats_every=50 ckpt_every=500 log_every=0"
"$ENG" "$SOUP" "$OUT/x_gpu" $OV threads=$GT > /dev/null
"$REF" "$SOUP" "$OUT/x_gpu2ref" steps=1500 snap_every=500 stats_every=1 ckpt_every=0 log_every=0 threads=$CT restart="$OUT/x_gpu/ckpt.bin" > "$OUT/x_gpu2ref.out" 2>&1 \
  && grep -q "done at step 1500" "$OUT/x_gpu2ref/log.txt" && pass "CPU reference engine restarts from an oercel_gpu checkpoint and runs on" \
  || fail "CPU reference engine cannot restart from an oercel_gpu checkpoint ($(tail -n 1 "$OUT/x_gpu2ref.out"))"
"$REF" "$SOUP" "$OUT/x_ref" $OV threads=$CT > /dev/null
"$ENG" "$SOUP" "$OUT/x_ref2gpu" steps=1500 snap_every=500 stats_every=50 ckpt_every=0 log_every=0 threads=$GT restart="$OUT/x_ref/ckpt.bin" > "$OUT/x_ref2gpu.out" 2>&1 \
  && grep -q "done at step 1500" "$OUT/x_ref2gpu/log.txt" && pass "oercel_gpu restarts from a CPU reference checkpoint and runs on" \
  || fail "oercel_gpu cannot restart from a CPU reference checkpoint ($(tail -n 1 "$OUT/x_ref2gpu.out"))"
pycheck python3 - "$OUT/x_gpu2ref" "$OUT/x_ref2gpu" <<'EOF'
import sys, numpy as np
for r in sys.argv[1:]:
    a = np.genfromtxt(r + '/stats.csv', delimiter=',', names=True)
    m = a['step'] > 1000
    T = a['T_kin'][m].mean(); mb = a['max_bond'][m].max()
    ok = abs(T - 1) < 0.05 and mb < 1.5
    print(('PASS' if ok else 'FAIL') + f'  continuation {r.split("/")[-1]}: <T> = {T:.4f}, max bond {mb:.3f}')
EOF
# exactness of the first steps after the engine switch; the GPU engine's own continuation of the
# same checkpoint is the yardstick (the two engines agree to ~5 digits for a few steps).
# engine/oercel.c does not carry fx, fy through its restart sort, so a GPU checkpoint must first be
# put into the CPU engine's slot order (ckpt_to_cpu.py); without that, the first CPU step uses the
# forces of other beads (a reference-engine issue: reported as WARN, not counted as a failure).
"$ENG" "$SOUP" "$OUT/x_gpu_cont" steps=1005 snap_every=0 stats_every=1 ckpt_every=0 log_every=0 threads=$GT restart="$OUT/x_gpu/ckpt.bin" > /dev/null 2>&1
python3 "$HERE/ckpt_to_cpu.py" "$OUT/x_gpu/ckpt.bin" "$OUT/x_gpu/ckpt_cpu.bin" --nsub 4
"$REF" "$SOUP" "$OUT/x_gpu2ref_conv" steps=1005 snap_every=0 stats_every=1 ckpt_every=0 log_every=0 nsub=4 threads=$CT restart="$OUT/x_gpu/ckpt_cpu.bin" > /dev/null 2>&1
pycheck python3 - "$OUT/x_gpu_cont" "$OUT/x_gpu2ref_conv" "$OUT/x_gpu2ref" <<'EOF'
import sys, numpy as np
def T5(r):
    a = np.genfromtxt(r + '/stats.csv', delimiter=',', names=True)
    m = (a['step'] > 1000) & (a['step'] <= 1005)
    return a['T_kin'][m]
g, c, u = (T5(r) for r in sys.argv[1:4])
dc, du = np.abs(c - g).max(), np.abs(u - g).max()
print(('PASS' if len(c) == 5 and dc < 2e-3 else 'FAIL') + f'  CPU engine continues a ckpt_to_cpu.py-converted GPU checkpoint exactly: max|T_cpu - T_gpu| over the first 5 steps = {dc:.1e}')
if du < 2e-3:
    print(f'PASS  CPU engine continues an unconverted GPU checkpoint exactly as well (engine/oercel.c carries the forces at restart): {du:.1e}')
else:
    print(f'WARN  CPU engine on an UNCONVERTED GPU checkpoint: first-step T {u[0]:.4f} vs {g[0]:.4f} (it uses forces of other beads for one step: engine/oercel.c restart issue) -> convert with ckpt_to_cpu.py first')
EOF
fi

if want 8; then
echo; echo "== 8. membranes: teamA physics, L=64, closed vesicles by tools/analyze.py, 2 seeds x 2 engines =="
ST=60000; [ $QUICK = 1 ] && ST=30000
VO="L=64 steps=$ST snap_every=2000 stats_every=500 ckpt_every=0 log_every=0"
for sd in 1 2; do
  "$REF" "$TEAMA" "$OUT/ves_ref_s$sd" $VO seed=$sd threads=$CT > /dev/null & bgpid=$!
  "$ENG" "$TEAMA" "$OUT/ves_gpu_s$sd" $VO seed=$sd threads=$GT > /dev/null
  wait $bgpid
done
okt=1
for r in ves_ref_s1 ves_ref_s2 ves_gpu_s1 ves_gpu_s2; do
  python3 "$CEL/tools/analyze.py" "$OUT/$r" --quiet --jobs 4 > "$OUT/$r.analyze.txt" 2>&1 || okt=0
done
[ $okt = 1 ] && pass "tools/analyze.py accepts all four runs" || fail "tools/analyze.py failed (see $OUT/*.analyze.txt)"
pycheck $COMPARE vesicles "$OUT/ves_ref_s1,$OUT/ves_ref_s2" "$OUT/ves_gpu_s1,$OUT/ves_gpu_s2"
pycheck $COMPARE bonds "$OUT/ves_ref_s1" "$OUT/ves_gpu_s1" --teq 30
python3 "$CEL/tools/render.py" "$OUT/ves_gpu_s1" --kind micro --width 800 --out "$OUT/ves_gpu_s1_micro.png" > "$OUT/render.txt" 2>&1 \
  && [ -s "$OUT/ves_gpu_s1_micro.png" ] && pass "tools/render.py --kind micro renders oercel_gpu output ($OUT/ves_gpu_s1_micro.png)" \
  || fail "tools/render.py failed on oercel_gpu output (see $OUT/render.txt)"
fi

if want 9; then
echo; echo "== 9. food supply (engine/tests/feedcheck.py), stirring profile, temperature cycle =="
FO="chem=1 f_lip=0 f_Ka=0 f_Kb=0 c_N=0 p_nd=0 p_ld=0 p_kd=0 feed_cap=0 n_chem=10 steps=600 snap_every=10 stats_every=10 ckpt_every=0 log_every=0 L=48"
"$ENG" "$WATER" "$OUT/feed_uniform" $FO feed=uniform p_feed=0.003 threads=$GT > /dev/null
"$ENG" "$WATER" "$OUT/feed_cap" $FO feed=uniform p_feed=0.01 feed_cap=0.05 threads=$GT > /dev/null
"$ENG" "$WATER" "$OUT/feed_disk" $FO feed=vent vent_shape=disk vent_x=10 vent_y=40 vent_r=5 p_feed=0.05 threads=$GT > /dev/null
"$ENG" "$WATER" "$OUT/feed_vstrip" $FO feed=vent vent_shape=vstrip vent_x=1 vent_w=4 p_feed=0.05 threads=$GT > /dev/null
"$ENG" "$WATER" "$OUT/feed_hstrip" $FO feed=vent vent_shape=hstrip vent_y=47 vent_w=3 p_feed=0.05 threads=$GT > /dev/null
for f in uniform cap disk vstrip hstrip; do pycheck python3 "$CEL/engine/tests/feedcheck.py" "$OUT/feed_$f"; rm -f "$OUT"/feed_$f/snap_*.bin; done
ST=20000   # the flow needs ~1/(nu k^2) = 180 t.u. to develop; the fit uses t >= 300
"$ENG" "$WATER" "$OUT/stir" L=48 stir_A=0.0015 steps=$ST snap_every=0 stats_every=10 ckpt_every=1000 ckpt_keep=1 log_every=1000 threads=$GT > /dev/null
pycheck python3 - "$OUT/stir" "$SNAPCHECK" <<'PYEOF'
import sys, glob, re, os, numpy as np
sys.path.insert(0, os.path.dirname(sys.argv[2]))
from snapcheck import read_ckpt
run, A = sys.argv[1], 0.0015
cks = [read_ckpt(c) for c in sorted(glob.glob(run + '/ckpt_*.bin'))]
cks = [d for d in cks if d['time'] >= 300]
L = cks[0]['L']; k = 2 * np.pi / L
y = np.concatenate([d['y'] for d in cks]); vx = np.concatenate([d['vx'] for d in cks])
M = np.c_[np.sin(k * y), np.cos(k * y), np.ones_like(y)]
c, *_ = np.linalg.lstsq(M, vx, rcond=None)
err = np.sqrt(np.diag(np.linalg.inv(M.T @ M)) * (vx - M @ c).var())
p = [tuple(map(float, m)) for m in re.findall(r'p=\(([-0-9.e+]+),([-0-9.e+]+)\)', open(run + '/log.txt').read())]
pmax = max(max(abs(u), abs(v)) for u, v in p)
nu = A / (c[0] * k * k)
# honest error bar: scatter of per-checkpoint fits (bead velocities are correlated within a snapshot)
u = [np.linalg.lstsq(np.c_[np.sin(k * d['y']), np.cos(k * d['y']), np.ones_like(d['y'])], d['vx'], rcond=None)[0][0] for d in cks]
sem = np.std(u, ddof=1) / np.sqrt(len(u))
# reference engine, same procedure (water L=48, A=0.0015, 20000 steps): u0 = 0.266 +- 0.009, nu = 0.33
z = (c[0] - 0.266) / np.hypot(sem, 0.0088)
ok = abs(z) < 4 and abs(c[1]) < 0.05 and pmax < 1e-8
print(('PASS' if ok else 'FAIL') + f'  stirring A={A}: u0={c[0]:.4f}+-{sem:.4f} vs reference 0.266+-0.009 (z={z:+.2f}), cos part {c[1]:+.4f}, nu={nu:.3f} (ref 0.33), max|P|={pmax:.1e}')
PYEOF
rm -f "$OUT"/stir/ckpt_0*.bin
"$ENG" "$WATER" "$OUT/kTcycle" L=32 kT_amp=0.2 kT_period=30 steps=10000 snap_every=0 stats_every=10 ckpt_every=0 log_every=0 threads=$GT > /dev/null
pycheck python3 - "$OUT/kTcycle" <<'PYEOF'
import sys, numpy as np
a = np.genfromtxt(sys.argv[1] + '/stats.csv', delimiter=',', names=True)
m = a['time'] >= 30
t, T = a['time'][m], a['T_kin'][m]
w = 2 * np.pi / 30
M = np.c_[np.ones_like(t), np.sin(w * t), np.cos(w * t)]
c, *_ = np.linalg.lstsq(M, T, rcond=None)
amp, lag = np.hypot(c[1], c[2]), np.arctan2(-c[2], c[1])
ok = abs(amp - 0.2) < 0.01 and abs(c[0] - 1) < 0.03 and 0 <= lag < 0.2
print(('PASS' if ok else 'FAIL') + f'  temperature cycle: T_kin = {c[0]:.4f} + {amp:.4f} sin(2 pi t/30 - {lag:.3f}) (reference 0.9953 + 0.1961, lag 0.10)')
PYEOF
fi

if want 10; then
echo; echo "== 10. lipid architectures (memB extension): pi and y lipids vs the memB CPU engine =="
ST=20000; [ $QUICK = 1 ] && ST=8000
for arch in "pi lip_nT=2 lip_tie=1 r0_head=0.7 k_head=5" "y lip_nT=2 k_head=5 cos_head=0.3"; do
  nm=${arch%% *}
  AO="lip_arch=$arch chem=1 syn_nN=2 p_syn_a=0.05 steps=$ST snap_every=$((ST / 20)) stats_every=100 log_every=0 ckpt_every=0"
  "$MEMB" "$SOUP" "$OUT/arch_${nm}_ref" $AO threads=$CT > /dev/null & bgpid=$!
  "$ENG" "$SOUP" "$OUT/arch_${nm}_gpu" $AO threads=$GT > /dev/null
  wait $bgpid
  pycheck $COMPARE bonds "$OUT/arch_${nm}_ref" "$OUT/arch_${nm}_gpu" --teq 30
  pycheck $COMPARE chem "$OUT/arch_${nm}_ref" "$OUT/arch_${nm}_gpu"
done
fi

if want 11; then
echo; echo "== 11. performance: ms/step (soup_small.ini physics with chemistry) =="
if [ $EMU = 1 ]; then SIZES="64 128"; else SIZES="128 256 512 1024"; [ $BIG = 1 ] && SIZES="$SIZES 2048 4096"; fi
printf "%-6s %-10s %-12s %-14s %s\n" L N "ms/step" "Mbead-steps/s" "phases (OERCEL_PROFILE=1 run, ms/step)" | tee -a "$SUMMARY"
for L in $SIZES; do
  N=$(python3 -c "print(round(3*$L*$L))")
  ns=$(python3 -c "print(max(200, min(3000, int(3e8 / ($N * 20)))))")
  [ $EMU = 1 ] && ns=200
  "$ENG" "$SOUP" "$OUT/bench_$L" L=$L steps=$((1000 + ns)) warmup=1000 snap_every=0 stats_every=0 ckpt_every=0 log_every=0 events=0 threads=$GT > /dev/null 2>&1 || { fail "benchmark L=$L crashed"; continue; }
  # time only the last ns steps: restart from the warmed-up checkpoint
  "$ENG" "$SOUP" "$OUT/bench_$L" L=$L steps=$((1000 + 2 * ns)) snap_every=0 stats_every=0 ckpt_every=0 log_every=0 events=0 threads=$GT restart="$OUT/bench_$L/ckpt.bin" > /dev/null 2>&1
  ms=$(grep "^timing" "$OUT/bench_$L/log.txt" | tail -n 1 | sed 's/.*steps, \([0-9.]*\) ms.*/\1/')
  OERCEL_PROFILE=1 "$ENG" "$SOUP" "$OUT/bench_$L" L=$L steps=$((1000 + 2 * ns + 100)) snap_every=0 stats_every=0 ckpt_every=0 log_every=0 events=0 threads=$GT restart="$OUT/bench_$L/ckpt.bin" > /dev/null 2>&1
  ph=$(grep "^timing" "$OUT/bench_$L/log.txt" | tail -n 1 | sed 's/.*(\(.*\)).*/\1/')
  mbs=$(python3 -c "print(f'{$N / ($ms * 1e-3) / 1e6:.1f}')" 2>/dev/null)
  printf "%-6s %-10s %-12s %-14s %s\n" $L $N $ms $mbs "$ph" | tee -a "$SUMMARY"
  rm -f "$OUT/bench_$L/ckpt.bin"
done
for L in 128 256; do
  [ $EMU = 1 ] && break
  BT=$(( NPROC < L / 2 ? NPROC : L / 2 ))   # the reference runs at most L/2 strips concurrently
  "$REF" "$SOUP" "$OUT/bench_ref_$L" L=$L steps=2000 snap_every=0 stats_every=0 ckpt_every=0 log_every=0 events=0 threads=$BT > /dev/null 2>&1
  echo "CPU reference L=$L, $BT threads: $(grep '^timing' "$OUT/bench_ref_$L/log.txt" | sed 's/.*steps, \([0-9.]*\) ms.*/\1/') ms/step (includes warm-up)" | tee -a "$SUMMARY"
done
fi

echo
echo "== summary: $NPASS passed, $NFAIL failed  ($SUMMARY) =="
grep -E '^(FAIL|WARN)' "$SUMMARY" || true
exit $NFAIL
