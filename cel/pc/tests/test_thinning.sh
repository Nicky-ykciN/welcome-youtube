#!/bin/bash
# Disk-bounding test for pc/longrun.py on REAL engine output with a detected division:
# a copy of runs/memA_F0 (L=100, 51 snapshots, tools/analyze.py finds a division at step 92000)
# is adopted by longrun.py (--adopteer); the run is already complete, so the supervisor does its
# final maintenance: analysis, images (micro, goodsell, timelapse), thinning.
# Checks: snapshots around the division and the newest ones are kept, older ones are thinned on the
# power-of-two schedule, step 0 is kept, the analysis cache of removed snapshots is removed, a fresh
# analysis of the thinned run still finds the division, and a second invocation changes nothing.
# usage: pc/tests/test_thinning.sh [outdir]      (default pc/_test/thin; ~1 minute)
set -u
cd "$(dirname "$0")/../.."     # -> cel/
OUT=${1:-pc/_test/thin}
SRC=runs/memA_F0
[ -f $SRC/snap_0000092000.bin ] || { echo "SKIP: $SRC not present"; exit 0; }
rm -rf "$OUT"; mkdir -p "$OUT/runs/f0"
cp $SRC/snap_*.bin $SRC/ckpt.bin $SRC/params.ini $SRC/stats.csv $SRC/log.txt "$OUT/runs/f0/"
fails=0
python3 pc/longrun.py f0 --adopteer --steps 100000 --engine cpu --runs-dir "$OUT/runs" --beelden-dir "$OUT/beelden" \
  --keep-recent 5 --max-stride 8 --analyse-jobs 1 --width 1000 --images-keep 2 > "$OUT/longrun.txt" 2>&1 || fails=$((fails + 1))
tail -5 "$OUT/longrun.txt"
python3 - "$OUT" <<'EOF' || fails=$((fails + 1))
import glob, json, os, subprocess, sys
sys.path.insert(0, 'pc')
import pclib as P
out = sys.argv[1]; rd = out + '/runs/f0'
fails = 0
def check(ok, msg):
    global fails
    print(('PASS  ' if ok else 'FAIL  ') + msg)
    fails += not ok
st = json.load(open(rd + '/pc_longrun.json'))
steps = [s for s, _ in P.list_snaps(rd)]
check(st['status'] == 'klaar', f"status {st['status']}")
check(92000 in st.get('division_steps', []), f"division steps recorded: {st.get('division_steps')}")
prot = set(st.get('protected', []))
check(set(range(72000, 100001, 2000)) <= prot, f"protected window 72000..100000 ({len(prot)} steps)")
check(all(s in steps for s in range(72000, 100001, 2000)), "every snapshot in the division window still exists")
check(0 in steps, "first snapshot (step 0) kept")
check(len(steps) < 51, f"thinned: 51 -> {len(steps)} snapshots ({st.get('thinned_total')} removed)")
old = [s for s in steps if s < 72000]
check(all((s // 2000) % 8 == 0 or s == 0 for s in old if 100000 - s >= 5 * 2000 * 4), f"oldest snapshots on stride <= 8: {old}")
cache = {int(os.path.basename(p)[6:16]) for p in glob.glob(rd + '/analysis_cache/cells_*.json')}
check(cache <= set(steps), f"analysis cache only for existing snapshots ({len(cache)} entries)")
imgs = st.get('images', {})
for k in ('micro', 'goodsell', 'timelapse'):
    f = (imgs.get(k) or [None])[-1]
    check(f is not None and os.path.exists(f) and os.path.getsize(f) > 10000, f"image {k}: {f}")
# a fresh analysis of the thinned run must still find the division
r = subprocess.run([sys.executable, 'tools/analyze.py', rd, '--jobs', '1', '--quiet'], capture_output=True, text=True)
lin = json.load(open(rd + '/lineage.json'))
d = [e['step'] for e in lin['events'] if e['kind'] == 'deling']
check(92000 in d, f"re-analysis after thinning still finds the division (deling at {d})")
open(out + '/before.txt', 'w').write(' '.join(map(str, steps)))
sys.exit(fails)
EOF
# second invocation: nothing new -> nothing removed, no new analysis
python3 pc/longrun.py f0 --runs-dir "$OUT/runs" > "$OUT/longrun2.txt" 2>&1 || fails=$((fails + 1))
after=$(ls $OUT/runs/f0/snap_*.bin | sed 's/.*snap_0*\([0-9]\)/\1/; s/\.bin//' | sort -n | tr '\n' ' ' | sed 's/ $//')
before=$(cat $OUT/before.txt | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')
[ "$after" = "$before" ] && echo "PASS  second invocation left the snapshots unchanged" || { echo "FAIL  second invocation changed snapshots"; fails=$((fails + 1)); }
cat $OUT/runs/f0/STATUS.md | head -30
echo "== summary: $fails failed check(s) =="
exit $fails
