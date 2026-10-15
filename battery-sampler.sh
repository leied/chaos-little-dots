#!/bin/bash
# battery_sampler.sh - optional: log battery %, power draw and busiest process
# every N seconds while the Mac is awake. Use this if the pmset log is thin
# (fresh loaner, recent reinstall) or you want per-workload detail.
#
# Start:  nohup bash battery_sampler.sh >/dev/null 2>&1 &      # default 300s
#         nohup bash battery_sampler.sh 120 >/dev/null 2>&1 &  # every 2 min
# Stop:   pkill -f battery_sampler.sh
# Paste:  tail -n 300 ~/battery_samples.csv | pbcopy
#
# Pauses while the Mac sleeps (that is fine, the gaps show sleep).

# Force Apple's BSD tools even if Homebrew GNU coreutils/gawk are first in PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
INTERVAL="${1:-300}"
OUT="${BATT_OUT:-$HOME/battery_samples.csv}"
[ -f "$OUT" ] || echo "time,pct,source,watts,top_proc:cpu" > "$OUT"

SIGNED_FN='function signed(v,  tail,d){ if (length(v) >= 19 && substr(v,1,4)=="1844") { tail=substr(v,length(v)-9)+0; d=3709551616-tail; if (d<0) d+=10000000000; return -d } return v+0 }'

while :; do
  b="$(pmset -g batt)"
  pct="$(printf '%s' "$b" | grep -Eo '[0-9]+%' | head -n1 | tr -d '%')"
  case "$b" in *"AC Power"*) src=AC ;; *) src=BATT ;; esac

  w="$(ioreg -rn AppleSmartBattery | awk "$SIGNED_FN"'
    /^[[:space:]]*"Voltage" = /         { v=$3 }
    /^[[:space:]]*"InstantAmperage" = / { a=signed($3) }
    END { if (v>0) printf "%.2f", v*a/1000000 }')"

  top="$(ps -Ao %cpu=,comm= -r | head -n1 | awk '{c=$1; $1=""; n=$0; sub(/^ +/,"",n); sub(/.*\//,"",n); gsub(/,/," ",n); printf "%s:%s", n, c}')"

  echo "$(date '+%Y-%m-%d %H:%M:%S'),$pct,$src,$w,$top" >> "$OUT"
  sleep "$INTERVAL"
done
