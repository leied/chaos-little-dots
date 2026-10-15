#!/bin/bash
# battery_dump.sh - dump Mac battery health + recent discharge history so it can be analyzed.
#
# Usage:  bash battery_dump.sh            # last 7 days
#         bash battery_dump.sh 14         # last 14 days
#         bash battery_dump.sh | pbcopy   # straight to clipboard, then paste
#
# No sudo needed (works on a managed/loaner Mac).
# Serial numbers, UUIDs and hostname are NOT printed.

set -u
# Force Apple's BSD tools even if Homebrew GNU coreutils/gawk are first in PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
DAYS="${1:-7}"
CUTOFF="$(date -v-"${DAYS}"d +%Y-%m-%d)"
TMP="$(mktemp /tmp/battdump.XXXXXX)" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT

section() { printf '\n===== %s =====\n' "$1"; }

# awk helper: turns ioreg's unsigned-64 amperage into a signed value exactly
# (plain float math loses precision at 1.8e19).
SIGNED_FN='function signed(v,  tail,d){ if (length(v) >= 19 && substr(v,1,4)=="1844") { tail=substr(v,length(v)-9)+0; d=3709551616-tail; if (d<0) d+=10000000000; return -d } return v+0 }'

# ---------------------------------------------------------------- system
section "SYSTEM"
echo "model:     $(sysctl -n hw.model)"
echo "chip:      $(sysctl -n machdep.cpu.brand_string)"
echo "macOS:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "uptime:    $(uptime | sed -E 's/^.*up //; s/, [0-9]+ users?.*$//')"
echo "generated: $(date '+%Y-%m-%d %H:%M %z')"

# ---------------------------------------------------------------- now
section "BATTERY NOW (pmset -g batt)"
pmset -g batt

section "BATTERY HEALTH (ioreg)"
ioreg -rn AppleSmartBattery | awk "$SIGNED_FN"'
  /^[[:space:]]*"(CycleCount|DesignCycleCount9C|DesignCapacity|AppleRawMaxCapacity|NominalChargeCapacity|AppleRawCurrentCapacity|MaxCapacity|CurrentCapacity|Temperature|Voltage|InstantAmperage|Amperage|IsCharging|ExternalConnected|FullyCharged|AvgTimeToEmpty)" = / {
    k=$1; gsub(/"/,"",k); v=$3
    if (k ~ /Amperage/) v=signed(v)
    val[k]=v; printf "%-24s %s\n", k, v
  }
  END {
    if (val["DesignCapacity"]>0 && val["AppleRawMaxCapacity"]>0)
      printf "%-24s %.1f%%\n", "health (raw/design)", 100*val["AppleRawMaxCapacity"]/val["DesignCapacity"]
    if (val["Temperature"]!="") printf "%-24s %.1f C\n", "temp", val["Temperature"]/100
    a = ("InstantAmperage" in val) ? val["InstantAmperage"] : val["Amperage"]
    if (val["Voltage"]>0 && a!="") printf "%-24s %.2f W (negative = discharging)\n", "power now", val["Voltage"]*a/1000000
  }'

section "SYSTEM_PROFILER POWER"
system_profiler SPPowerDataType 2>/dev/null | grep -viE 'serial|uuid' | grep -vE '^[[:space:]]*$'

section "POWER SETTINGS (pmset -g custom)"
pmset -g custom

section "SLEEP PREVENTERS RIGHT NOW"
pmset -g assertions | sed -n '/Listed by owning process/,/Kernel Assertions/p' \
  | grep 'pid ' | sed -E 's/[[:space:]]+/ /g' | head -n 20

section "TOP ENERGY USERS (5s sample)"
top -l 2 -s 5 -o power -stats command,power,cpu -n 12 | awk '/^COMMAND/{n++} n==2'

# ---------------------------------------------------------------- history
# Pull every pmset log line that carries "Using AC/Batt (Charge:NN%)".
pmset -g log 2>/dev/null | awk -v cutoff="$CUTOFF" '
  function dfc(y,m,d,  era,yoe,mp,doy,doe){
    y -= (m<=2); era=int((y>=0?y:y-399)/400); yoe=y-era*400; mp=(m+9)%12
    doy=int((153*mp+2)/5)+d-1; doe=yoe*365+int(yoe/4)-int(yoe/100)+doy
    return era*146097+doe-719468 }
  $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $1 >= cutoff {
    l=tolower($0)
    if (!match(l, /using (ac|batt?)[^%]*charge: ?[0-9]+/)) next
    seg=substr(l,RSTART,RLENGTH)
    src=(seg ~ /using ac/) ? "AC" : "BATT"
    match(seg,/[0-9]+$/); pct=substr(seg,RSTART,RLENGTH)+0
    split($1,D,"-"); split($2,T,":")
    tz=$3; sg=(substr(tz,1,1)=="-") ? -1 : 1
    off=sg*(substr(tz,2,2)*3600+substr(tz,4,2)*60)
    ep=dfc(D[1]+0,D[2]+0,D[3]+0)*86400+T[1]*3600+T[2]*60+T[3]-off
    printf "%d|%s %s|%s|%s|%d\n", ep, $1, substr($2,1,5), $4, src, pct
  }' > "$TMP"

section "DISCHARGE TIMELINE (last $DAYS days, DarkWakes folded in, newest 150 rows)"
echo "time | event | source | %"
awk -F'|' '
  { show = ($3!="DarkWake" && !($3=="Sleep" && pe=="DarkWake")) || $4!=ps
    if (show) printf "%s | %s | %s | %d\n", $2, $3, $4, $5
    pe=$3; ps=$4 }' "$TMP" | tail -n 150

section "SUMMARY (computed from the log above)"
awk -F'|' '
  function flush(label){
    if (sess_on) { ns++; S[ns]=sprintf("%s  %5.1fh  %3d%% -> %3d%%  (-%d%%)%s", s_start, (pt-s_t)/3600, s_p, pp, s_p-pp, label) }
    sess_on=0 }
  {
    t=$1; ev=$3; src=$4; p=$5
    # drain between two consecutive on-battery points, bucketed by awake/asleep
    if (NR>1 && ps=="BATT" && src=="BATT" && p<=pp) {
      dt=t-pt
      if (dt>0 && dt<36*3600) {
        if (state=="awake") { at+=dt; ad+=pp-p } else { st+=dt; sd+=pp-p }
      }
    }
    # unplug-to-plug sessions
    if (src=="AC" && sess_on) flush("")
    if (src=="BATT" && !sess_on) { sess_on=1; s_t=t; s_p=p; s_start=$2 }
    if (ev=="Sleep" || ev=="DarkWake") state="sleep"
    else if (ev=="Wake" || ev=="Start") state="awake"
    pt=t; pp=p; ps=src
  }
  END {
    if (NR==0) { print "No usable pmset log entries. Run battery_sampler.sh for a day instead."; exit }
    flush("  (ongoing)")
    ar=(at>0)? ad/(at/3600) : 0; sr=(st>0)? sd/(st/3600) : 0
    printf "rows parsed: %d\n", NR
    printf "awake on battery:  %6.1f h, used %4d%%  -> %.1f %%/h\n", at/3600, ad, ar
    printf "asleep on battery: %6.1f h, used %4d%%  -> %.2f %%/h\n", st/3600, sd, sr
    if (ar>0) {
      printf "rough full-charge awake runtime: ~%.1f h\n", 100/ar
      print "24h projection (awake + asleep, from 100%):"
      for (h=4; h<=12; h+=2) printf "  %2dh awake + %2dh asleep -> ~%d%% used\n", h, 24-h, h*ar+(24-h)*sr
    }
    print ""
    print "battery sessions (unplug -> plug), newest 10:"
    for (i=(ns>10?ns-9:1); i<=ns; i++) print "  " S[i]
  }' "$TMP"
