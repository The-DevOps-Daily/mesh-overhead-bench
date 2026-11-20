#!/usr/bin/env bash
# Fixed-rate latency runs plus a max-throughput run, with CPU/memory snapshots
# around each run. Usage: 40-latency.sh <config>
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=$1
QPS_LEVELS=(${QPS_LEVELS:-100 500 1000})
REPS=${REPS:-5} DUR=${DUR:-60s} CONC=${CONC:-16}
OUT=results/$CONFIG/latency
mkdir -p "$OUT"
URL=http://hop-a:8080/
load() { kubectl -n bench exec deploy/client -c fortio -- fortio load -quiet -p 50,90,99,99.9 -c "$CONC" "$@" -json - "$URL"; }

scripts/podmap.sh "$OUT/podmap.json"
python3 scripts/cgsnap.py "$OUT/idle-0.json"; sleep 30; python3 scripts/cgsnap.py "$OUT/idle-1.json"

load -qps 500 -t 20s >/dev/null 2>&1   # warm-up, discarded

n=${#QPS_LEVELS[@]}
for rep in $(seq 1 "$REPS"); do
  for i in $(seq 0 $((n - 1))); do
    q=${QPS_LEVELS[$(( (i + rep - 1) % n ))]}
    f="$OUT/qps${q}-rep${rep}"
    python3 scripts/cgsnap.py "$f.cg0.json"
    load -qps "$q" -t "$DUR" > "$f.json" 2>"$f.log"
    python3 scripts/cgsnap.py "$f.cg1.json"
    echo "$CONFIG rep$rep qps$q: $(jq -r '"p50=\(.DurationHistogram.Percentiles[0].Value*1000|.*1000|round/1000)ms p99=\(.DurationHistogram.Percentiles[2].Value*1000|.*1000|round/1000)ms actual=\(.ActualQPS|round) codes=\(.RetCodes)"' "$f.json")"
  done
done

for rep in 1 2 3; do
  f="$OUT/max-rep${rep}"
  python3 scripts/cgsnap.py "$f.cg0.json"
  load -qps 0 -t 30s > "$f.json" 2>"$f.log"
  python3 scripts/cgsnap.py "$f.cg1.json"
  echo "$CONFIG max rep$rep: $(jq -r '"qps=\(.ActualQPS|round) codes=\(.RetCodes)"' "$f.json")"
done
scripts/podmap.sh "$OUT/podmap-end.json"
