#!/bin/sh
# access-sched.sh — «РАСПИСАНИЯ ДОСТУПА»: when a device may go out to the internet. ONE owner of the registry, the evaluator, the
# kernel form and the per-minute tick. Design: dev notes «расписания-дизайн».
#
# Model. A schedule = devices (keyed by MAC — an address is only lent for a lease, a MAC-keyed rule does not drift to a
# neighbour) + a week of windows of three states (open · limited · closed) + the state OUTSIDE the windows (`base`). Overlap ⇒
# the stricter state wins; a window whose end is not after its start runs past midnight and belongs to the day it STARTS on
# (Fri 23:00–07:00 covers Saturday 00:00–07:00); start = end is a whole day. Actions over the schedule carry their own expiry
# (close now / open for… / postpone — `<id>.ovr`; «close all now» — `.all`; holidays — `hol`). One device = one schedule.
#
# LEVEL-TRIGGERED, not edge-triggered: there is no «close at 23:00» event pair in cron. Every minute the tick computes «what
# must be true now» and converges the kernel to it — so a reboot at 23:30, a clock step, a firewall reload that wiped our chain,
# a missed minute all heal by themselves on the next tick. The tick has its own cron line (install.sh `cron_put`): the
# watchdog's tick can run tens of minutes (failover ladder) and a 23:00 close would wait for it; heal runs once per boot.
#
# FAIL-OPEN ON AN UNSYNCED CLOCK. The router has no RTC: after a boot the clock sits on a file's mtime (a sane-looking date
# hours or days behind) until it is synced. Windows applied by that clock would close the internet in the middle of the day —
# worse than not closing. So nothing is installed until clock-lib.sh says the time is synced (`clock_trusted`), and the panel
# says so in words.
#
# Kernel form — filter FORWARD, both families (the only place every forwarded packet passes, tunnelled or not):
#   FORWARD 1: -j ENODIA_SCHED
#   ENODIA_SCHED: -o br+ -j RETURN — the home network stays (measured BE7000: bridge-nf-call-iptables=1, so bridged LAN frames
#                 traverse FORWARD too, and a bare per-MAC DROP would cut the printer and the cameras);
#                 closed — `-m mac --mac-source M` → REJECT (tcp-reset for TCP): the app fails at once instead of hanging on
#                 a TCP timeout. INPUT stays open (DNS, the panel).
# After a device's state changes, its established flows are dropped (`ct_flush_src` per address of the MAC): NSS/ECM keeps
# offloaded flows out of netfilter otherwise. Never a global flush — a 23:00 close would drop every call in the house.
# A plan that closes nobody = no chain at all (no footprint while everything is open).
#
# Usage:
#   access-sched.sh list-json | get-json <id> | dump
#   access-sched.sh save <specfile> | del <id> | toggle <id> on|off
#   access-sched.sh ovr <id> close|open|postpone|clear [minutes|HH:MM|end|0]
#   access-sched.sh all <minutes|HH:MM|0|off> | hol <id> <YYYY-MM-DD|off>
#   access-sched.sh tick | unwire
# JSON verbs print one JSON object; messages are Russian (the panel translates them by its dictionary).

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
SC_DIR="$ENODIA_STATE/sched"        # registry on /data: written only on user actions (and once per expired override)
SC_RUN=/tmp/enodia-sched            # RAM: lock, the plan now in the kernel, last states — gone with a reboot like the kernel
SC_LOCK="$SC_RUN/lock"
SC_APPLIED="$SC_RUN/applied"        # the plan in the kernel: «<mac> <state> <id>» per line, sorted
SC_CHAIN=ENODIA_SCHED
SC_MAX=16                           # schedules
SC_WIN_MAX=24                       # windows per schedule
SC_DEV_MAX=32                       # devices per schedule
SC_NAME_MAX=60                      # characters of a name (the panel's field)
SC_K=6                              # upcoming changes reported to the panel
SC_CLOCK_NOTE=600                   # s of uptime with schedules and an unsynced clock before one journal line
# DAY LIMIT — minutes of REAL activity, by the stock `trafficd` (per MAC, counts NSS-offloaded and tunnelled traffic alike —
# measured BE7000 08.10.2026: a 1 GiB download +1129 MB there, conntrack accounting −5 %). A minute is «active» when the device
# moved at least SC_ACTIVE_B in it: background sync (push, mail checks) stays far below, a video or a game far above.
SC_ACTIVE_B=262144
SC_USE_GAP=5                        # minutes one sample may cover (a missed tick); a longer gap counts as this much at most
SC_USE_SAVE=900                     # s between saves of the day's usage to the flash while it changes (a reboot loses ≤ 15 min)
SC_USE="$SC_RUN/use"                # RAM: «<date>» then «<mac> <minutes>» — the day's usage
SC_USE_LAST="$SC_RUN/use.last"      # RAM: «<epoch>» then «<mac> <bytes>» — the previous trafficd sample
SC_NL='
'

if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
# without the clock owner nobody can say the time is synced ⇒ fail-open (never close by a clock we cannot vouch for)
command -v clock_trusted >/dev/null 2>&1 || clock_trusted() { return 1; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '\000-\010\013-\037' | tr '\n\t' '  ' | cut -c1-"$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
command -v lbl_san >/dev/null 2>&1 || lbl_san() { printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\037"\\' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'; }
command -v lbl_lock_take >/dev/null 2>&1 || lbl_lock_take() { mkdir "$1" 2>/dev/null; }
command -v lbl_lock_drop >/dev/null 2>&1 || lbl_lock_drop() { rm -rf "$1" 2>/dev/null; }
if [ -f "$ENODIA_DIR/lease-lib.sh" ]; then . "$ENODIA_DIR/lease-lib.sh"; fi
command -v mac_norm >/dev/null 2>&1 || mac_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n'; }
command -v mac_ok >/dev/null 2>&1 || mac_ok() { printf '%s' "$1" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; }
# xtables lock wait (a rule must not silently fail to land while a foreign cron holds the lock) — ipt-lib.sh
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
command -v ct_flush_src >/dev/null 2>&1 || ct_flush_src() { [ -n "$1" ] && conntrack -D --src "$1" >/dev/null 2>&1; return 0; }

jstr() { printf '%s' "$1" | jtxt "${2:-200}"; }
jok() { printf '{"ok":true%s}\n' "${1:+,$1}"; }
jfail() { printf '{"ok":false,"msg":"%s"%s}\n' "$(jstr "$1" 400)" "${2:+,$2}"; exit 0; }
id_ok() { printf '%s' "$1" | grep -qE '^s[0-9]{1,6}$'; }
num_or() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
# the same into a variable, without a subshell (the tick runs every minute; every `$(…)` is a fork on the router)
sc_num() { case "$2" in ''|*[!0-9]*) eval "$1=\$3" ;; *) eval "$1=\$2" ;; esac; }
have_v6() { command -v ip6tables >/dev/null 2>&1; }

# ---- RAM dir and lock ---------------------------------------------------------------------------------------------
# /tmp is shared with stock daemons (some run as nobody): a symlink or a foreign directory laid on our name beforehand would
# turn our writes into writes as root into ITS target (the class tasks.sh::tk_rundir is built against). Ours = a real
# directory owned by root; anything else is removed and made anew, 700.
sc_rundir() {
	if [ -L "$SC_RUN" ] || { [ -e "$SC_RUN" ] && { [ ! -d "$SC_RUN" ] || [ "$(stat -c %u "$SC_RUN" 2>/dev/null)" != "$(id -u)" ]; }; }; then
		rm -rf "$SC_RUN" 2>/dev/null
	fi
	[ -d "$SC_RUN" ] || ( umask 077; mkdir "$SC_RUN" ) 2>/dev/null
	[ -d "$SC_RUN" ] && [ ! -L "$SC_RUN" ]
}
SC_LOCKED=0
sc_lock() {
	sc_rundir || return 1
	lbl_lock_take "$SC_LOCK" 'access-sched\.sh' || return 1
	SC_LOCKED=1
	trap 'sc_unlock' EXIT
	trap 'exit 1' INT TERM HUP PIPE
	return 0
}
sc_unlock() { [ "$SC_LOCKED" = 1 ] && lbl_lock_drop "$SC_LOCK"; SC_LOCKED=0; return 0; }

# ---- time ---------------------------------------------------------------------------------------------------------
# ONE `date` per call: epoch, weekday (0 = Sunday), hour, minute, second. Leading zeros go (`08` is octal in ash arithmetic).
sc_now() {
	set -- $(date '+%s %w %H %M %S %Y-%m-%d' 2>/dev/null)
	sc_num SC_E "$1" 0; sc_num SC_W "$2" 0
	sc_num SC_H "${3#0}" 0; sc_num SC_M "${4#0}" 0; sc_num SC_S "${5#0}" 0
	SC_D=${6:-}                                      # the local date: the key of the day's usage
	SC_NM=$(( SC_W * 1440 + SC_H * 60 + SC_M ))   # minute of the week, local
	SC_E0=$(( SC_E - SC_S ))                         # epoch of the start of this minute
}
# local «YYYY-MM-DD HH:MM» and weekday of an epoch -> SC_AT, SC_AW
sc_at() {
	set -- $(date -d "@$1" '+%Y-%m-%d %H:%M %w' 2>/dev/null)
	SC_AT="$1 $2"; sc_num SC_AW "$3" 0
}
# epoch of the next local HH:MM after now (today if still ahead, else tomorrow); rc 1 on a bad time
sc_next_hhmm() {
	printf '%s' "$1" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$' || return 1
	_nh=${1%%:*}; _nm=${1#*:}; _nh=${_nh#0}; _nm=${_nm#0}
	_nd=$(( ${_nh:-0} * 60 + ${_nm:-0} - SC_H * 60 - SC_M ))
	[ "$_nd" -le 0 ] && _nd=$(( _nd + 1440 ))
	SC_NEXT=$(( SC_E0 + _nd * 60 ))
}

# ---- registry -----------------------------------------------------------------------------------------------------
# <id>.sch — key=value lines; `win=` and `dev=` repeat. Read through the SAME validation as a save: the file can come from a
# backup or a hand edit, and a stray line must neither break the JSON nor reach iptables.
sc_ids() { for _f in "$SC_DIR"/s*.sch; do [ -f "$_f" ] || continue; _b=${_f##*/}; echo "${_b%.sch}"; done | sed 's/^s//' | sort -n | sed 's/^/s/'; }
# Window line «<days> <HH:MM> <HH:MM> <state>»: days are digits 0..6 (0 = Sunday), ascending, each once. ONE program for the
# load and the save — two copies of «what a window is» would let a save write what the next load silently drops. Prints the
# valid `win=` lines of a registry file (or of bare window lines with -v bare=1).
SC_WIN_AWK='
{ l = $0; if (bare != 1) { if (l !~ /^win=/) next; l = substr(l, 5) } }
l !~ /^[0-6]+ ([01][0-9]|2[0-3]):[0-5][0-9] ([01][0-9]|2[0-3]):[0-5][0-9] (open|limited|closed)$/ { next }
{ d = l; sub(/ .*/, "", d); ok = (length(d) <= 7); p = -1
  for (i = 1; i <= length(d); i++) { c = substr(d, i, 1) + 0; if (c <= p) ok = 0; p = c }
  if (ok && !(l in seen)) { seen[l] = 1; print l } }'
# Load one schedule. The whole file is read ONCE (CR from a hand edit stripped at once): the tick runs every minute, and a fork
# per line — per window, per device — cost a tenth of a second per schedule on the router. The name is kept as written and
# sanitised where it leaves (JSON, journal): the tick itself never needs it.
sc_load() {   # sc_load <id> [<file>] -> SC_* ; rc 1 = no such schedule. A file = the same schedule from elsewhere (import)
	SC_F=${2:-"$SC_DIR/$1.sch"}; [ -f "$SC_F" ] || return 1
	SC_ID=$1; SC_NAME=""; SC_ON=0; SC_BASE=open; SC_HOL=0; SC_VER=0; SC_LWD=0; SC_LWE=0
	_slt=$(tr -d '\r' < "$SC_F" 2>/dev/null)
	while IFS= read -r _sl; do
		case "$_sl" in
			name=*)       [ -n "$SC_NAME" ] || SC_NAME=${_sl#name=} ;;
			enabled=1)    SC_ON=1 ;;
			base=open|base=limited|base=closed) SC_BASE=${_sl#base=} ;;
			hol=*)        sc_num SC_HOL "${_sl#hol=}" 0 ;;
			ver=*)        sc_num SC_VER "${_sl#ver=}" 0 ;;
			lim_wd=*)     sc_num SC_LWD "${_sl#lim_wd=}" 0 ;;
			lim_we=*)     sc_num SC_LWE "${_sl#lim_we=}" 0 ;;
		esac
	done <<EOF
$_slt
EOF
	[ "$SC_LWD" -le 1440 ] || SC_LWD=0; [ "$SC_LWE" -le 1440 ] || SC_LWE=0
	SC_WINS=$(printf '%s\n' "$_slt" | awk "$SC_WIN_AWK")
	[ -n "$SC_WINS" ] && SC_WINS="$SC_WINS$SC_NL"
	# devices: `dev=mac:` lines, lowercase, valid, each once
	SC_DEVS=$(printf '%s\n' "$_slt" | awk '
		/^dev=mac:/ { m = tolower(substr($0, 9)); gsub(/[ \t]/, "", m)
		  if (m ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/ && !(m in s)) {
		    s[m] = 1; printf "%s%s", (n++ ? " " : ""), m } }')
	return 0
}
sc_name() { lbl_san "$SC_NAME" | cut -c1-200; }   # the loaded schedule's name, safe for JSON and the journal
sc_write() {   # sc_write <id> — from SC_*: atomically (write next to it, compare, mv)
	_wf="$SC_DIR/$1.sch"; _wt="$_wf.$$"
	{
		printf 'name=%s\nenabled=%s\nbase=%s\nhol=%s\nver=%s\nlim_wd=%s\nlim_we=%s\n' "$SC_NAME" "$SC_ON" "$SC_BASE" "$SC_HOL" "$SC_VER" "$SC_LWD" "$SC_LWE"
		printf '%s' "$SC_WINS" | while IFS= read -r _wl; do [ -n "$_wl" ] && printf 'win=%s\n' "$_wl"; done
		for _wm in $SC_DEVS; do printf 'dev=mac:%s\n' "$_wm"; done
	} > "$_wt" 2>/dev/null || { rm -f "$_wt"; return 1; }
	grep -q "^ver=$SC_VER\$" "$_wt" && mv -f "$_wt" "$_wf" && return 0
	rm -f "$_wt"; return 1
}
sc_new_id() {   # under the lock: the highest id ever given (`.last-id`) + 1 — never a deleted one's
	_ln=$(num_or "$(cat "$SC_DIR/.last-id" 2>/dev/null | tr -cd '0-9')" 0)
	for _li in $(sc_ids); do _lv=${_li#s}; [ "$_lv" -gt "$_ln" ] && _ln=$_lv; done
	_ln=$((_ln + 1)); echo "$_ln" > "$SC_DIR/.last-id" 2>/dev/null
	echo "s$_ln"
}
# action over one schedule: «<state> <until epoch, 0 = until cancelled> <kind>»; over all: «<until>»
sc_ovr_get() {   # <id> -> SC_OS SC_OU SC_OK (empty SC_OS = none or expired)
	SC_OS=""; SC_OU=0; SC_OK=""
	[ -f "$SC_DIR/$1.ovr" ] || return 1
	read -r _os _ou _ok < "$SC_DIR/$1.ovr" 2>/dev/null
	case "$_os" in open|limited|closed) ;; *) return 1 ;; esac
	case "$_ou" in ''|*[!0-9]*) return 1 ;; esac
	case "$_ok" in close|open|postpone) ;; *) return 1 ;; esac
	[ "$_ou" = 0 ] && [ "$_os" != closed ] && return 1           # only a close may last until cancelled
	[ "$_ou" != 0 ] && [ "$_ou" -le "$SC_E" ] && return 1         # expired
	SC_OS=$_os; SC_OU=$_ou; SC_OK=$_ok
	return 0
}
sc_all_get() {   # -> SC_AU (until; 0 = until cancelled); rc 1 = not active
	SC_AU=""
	[ -f "$SC_DIR/.all" ] || return 1
	read -r _au < "$SC_DIR/.all" 2>/dev/null
	case "$_au" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_au" != 0 ] && [ "$_au" -le "$SC_E" ] && return 1
	SC_AU=$_au; return 0
}

# ---- evaluator ----------------------------------------------------------------------------------------------------
# From SC_WINS, SC_BASE and the minute of the week -> SC_CUR (state by the week alone), SC_INWIN (1 = a window decides) and
# SC_CHG («<minutes ahead> <state>» per line, the next $1 changes). Minutes of the week 0..10079, Sunday 00:00 = 0; a window
# may end past 10080 (Saturday night) — coverage is checked at t and t+week. Change points are window edges; the state is
# re-evaluated at each, and only real changes are reported (adjacent windows of one state are one stretch).
sc_eval() {
	_sev=$(printf '%s' "$SC_WINS" | awk -v base="$SC_BASE" -v now="$SC_NM" -v K="${1:-1}" '
	BEGIN { rk["open"] = 0; rk["limited"] = 1; rk["closed"] = 2; nm[0] = "open"; nm[1] = "limited"; nm[2] = "closed"; n = 0; W = 10080 }
	NF == 4 && ($4 in rk) {
		a = substr($2, 1, 2) * 60 + substr($2, 4, 2); b = substr($3, 1, 2) * 60 + substr($3, 4, 2)
		len = (b > a) ? b - a : 1440 - a + b
		for (i = 1; i <= length($1); i++) { d = substr($1, i, 1) + 0; n++; S[n] = d * 1440 + a; E[n] = S[n] + len; R[n] = rk[$4] }
	}
	END {
		b0 = (base in rk) ? rk[base] : 0
		st = -1
		for (j = 1; j <= n; j++) if ((now >= S[j] && now < E[j]) || (now + W >= S[j] && now + W < E[j])) { if (R[j] > st) st = R[j] }
		inw = (st >= 0) ? 1 : 0; if (st < 0) st = b0
		print "cur " nm[st] " " inw
		m = 0
		for (j = 1; j <= n; j++) {
			o = (S[j] - now) % W; if (o <= 0) o += W; m++; P[m] = o
			o = (E[j] - now) % W; if (o <= 0) o += W; m++; P[m] = o
		}
		prev = st; last = 0; out = 0
		while (out < K) {
			best = W + 1
			for (q = 1; q <= m; q++) if (P[q] > last && P[q] < best) best = P[q]
			if (best > W) break
			last = best; t = (now + best) % W; s2 = -1
			for (j = 1; j <= n; j++) if ((t >= S[j] && t < E[j]) || (t + W >= S[j] && t + W < E[j])) { if (R[j] > s2) s2 = R[j] }
			if (s2 < 0) s2 = b0
			if (s2 != prev) { print "chg " best " " nm[s2]; prev = s2; out++ }
		}
	}')
	SC_CUR=open; SC_INWIN=0; SC_CHG=""
	_sevl=$(printf '%s\n' "$_sev" | sed -n 's/^cur //p')
	set -- $_sevl; case "$1" in open|limited|closed) SC_CUR=$1 ;; esac; [ "${2:-0}" = 1 ] && SC_INWIN=1
	SC_CHG=$(printf '%s\n' "$_sev" | sed -n 's/^chg //p')
}
# The effective state of the loaded schedule NOW: SC_ST + SC_WHY (off|hol|all|ovr|win|base). Needs sc_now + sc_eval.
sc_effective() {
	SC_ST=open; SC_WHY=base
	if [ "$SC_ON" != 1 ]; then SC_WHY=off; return 0; fi
	if [ "$SC_HOL" -gt "$SC_E" ] 2>/dev/null; then SC_WHY=hol; return 0; fi
	if sc_all_get; then SC_ST=closed; SC_WHY=all; return 0; fi
	if sc_ovr_get "$SC_ID"; then SC_ST=$SC_OS; SC_WHY=ovr; return 0; fi
	SC_ST=$SC_CUR
	if [ "$SC_INWIN" = 1 ]; then SC_WHY=win; else SC_WHY=base; fi
}
# epoch of the first upcoming change of the week (empty = the week never changes)
sc_first_change() { _fc=$(printf '%s\n' "$SC_CHG" | awk 'NF==2{print $1; exit}'); [ -n "$_fc" ] && echo $(( SC_E0 + _fc * 60 )); }

# ---- day limit: usage ---------------------------------------------------------------------------------------------
sc_lim_today() { if [ "$SC_W" -ge 1 ] && [ "$SC_W" -le 5 ]; then SC_LT=$SC_LWD; else SC_LT=$SC_LWE; fi; }   # weekdays / weekend
# Does today's limit act now? Only while the WEEK decides (holidays rest it, a hand action beats it) and nothing closes anyway.
sc_lim_applies() { [ "$SC_LT" -gt 0 ] && [ "$SC_ST" != closed ] && { [ "$SC_WHY" = win ] || [ "$SC_WHY" = base ]; }; }
# The day's usage -> SC_USED («<mac> <minutes>» lines): RAM first (fresh), the flash copy after a reboot; another date = none yet.
sc_use_load() {
	SC_USED=""
	for _uf in "$SC_USE" "$SC_DIR/.use"; do
		[ -f "$_uf" ] || continue
		[ "$(head -n 1 "$_uf" 2>/dev/null)" = "$SC_D" ] || continue
		SC_USED=$(sed 1d "$_uf" 2>/dev/null); return 0
	done
	return 0
}
sc_used_of() { printf '%s\n' "$SC_USED" | awk -v m="$1" '$1 == m { print $2 + 0; f = 1; exit } END { if (!f) print 0 }'; }
# trafficd -> «<mac> <bytes in+out>» per MAC, lowercase (it answers MACs in capitals). The counters pass 32 bits: awk's doubles,
# printed as integers. A device's own `hw` line and its addresses' lines carry the same MAC — the sum is over its addresses.
sc_traffic() {
	ubus call trafficd hw 2>/dev/null | awk '
		/"hw":/ { m = $0; sub(/.*"hw": *"/, "", m); sub(/".*/, "", m); mac = tolower(m) }
		/"(rx|tx)_bytes":/ { v = $0; gsub(/[^0-9]/, "", v); if (mac != "") s[mac] += v }
		END { for (k in s) printf "%s %.0f\n", k, s[k] }'
}
# Save the day's usage to the flash: every SC_USE_SAVE while it changes, at once when $1 = now (a device just ran out — a
# reboot must not hand it a new day).
sc_use_save() {
	[ -f "$SC_USE" ] || return 0
	_usv=$(cat "$SC_RUN/use.saved" 2>/dev/null); case "$_usv" in ''|*[!0-9]*) _usv=0 ;; esac
	[ "${1:-}" = now ] || [ $(( SC_E - _usv )) -ge "$SC_USE_SAVE" ] || return 0   # clock-raw: both are this boot's synced clock
	cmp -s "$SC_USE" "$SC_DIR/.use" 2>/dev/null && return 0
	mkdir -p "$SC_DIR" 2>/dev/null
	cp "$SC_USE" "$SC_DIR/.use.$$" 2>/dev/null && mv -f "$SC_DIR/.use.$$" "$SC_DIR/.use" && echo "$SC_E" > "$SC_RUN/use.saved"
	rm -f "$SC_DIR/.use.$$" 2>/dev/null
	return 0
}
# One sample per tick, only for the devices of enabled schedules with a limit today. A minute counts when the device moved at
# least SC_ACTIVE_B per minute of the gap since the previous sample (the gap capped at SC_USE_GAP: a stalled tick must neither
# grant nor take an hour). A device's first sample only records; a counter that went back (trafficd restarted, the device
# came back) counts from zero. Two ticks within one minute: the second waits — its delta belongs to the next one.
sc_use_tick() {
	_um=""
	for _ui in $SC_IDS; do
		sc_load "$_ui" || continue
		[ "$SC_ON" = 1 ] || continue
		sc_lim_today; [ "$SC_LT" -gt 0 ] || continue
		_um="$_um $SC_DEVS"
	done
	if [ -z "$_um" ]; then rm -f "$SC_USE_LAST" 2>/dev/null; return 0; fi
	sc_use_load
	_upe=$(head -n 1 "$SC_USE_LAST" 2>/dev/null); case "$_upe" in ''|*[!0-9]*) _upe=0 ;; esac
	_uel=0
	if [ "$_upe" -gt 0 ]; then
		_uel=$(( (SC_E - _upe + 30) / 60 ))   # clock-raw: two samples of this boot's synced clock
		if [ "$_uel" -lt 0 ]; then _uel=0       # the clock went back: resync the sample, count nothing
		elif [ "$_uel" = 0 ]; then return 0     # the same minute: its delta belongs to the next tick
		fi
	fi
	_ucur=$(sc_traffic)
	[ -n "$_ucur" ] || return 0      # trafficd silent: nothing counted (an unknown minute is not an active one)
	_uout=$( {
		for _uk in $_um; do echo "L $_uk"; done
		printf '%s\n' "$SC_USED" | sed -n 's/^\([0-9a-f:]* [0-9]*\)$/U \1/p'
		sed -n '2,$s/^/P /p' "$SC_USE_LAST" 2>/dev/null
		printf '%s\n' "$_ucur" | sed 's/^/C /'
	} | awk -v el="$_uel" -v gap="$SC_USE_GAP" -v act="$SC_ACTIVE_B" '
		$1 == "L" { lim[$2] = 1; next }
		$1 == "U" { u[$2] = $3 + 0; next }
		$1 == "P" { p[$2] = $3 + 0; next }
		$1 == "C" { c[$2] = $3 + 0; next }
		END {
			m = el; if (m > gap) m = gap
			for (k in lim) if (k in c) {
				if (m >= 1 && (k in p)) { d = c[k] - p[k]; if (d < 0) d = c[k]; if (d >= act * m) u[k] += m }
				printf "C %s %.0f\n", k, c[k]
			}
			for (k in u) if (u[k] > 0) printf "U %s %d\n", k, u[k]
		}')
	{ echo "$SC_E"; printf '%s\n' "$_uout" | sed -n 's/^C //p'; } > "$SC_USE_LAST.$$" && mv -f "$SC_USE_LAST.$$" "$SC_USE_LAST"
	_unew=$(printf '%s\n' "$_uout" | sed -n 's/^U //p' | sort)
	if [ "$_unew" != "$(printf '%s\n' "$SC_USED" | grep . | sort)" ] || [ "$(head -n 1 "$SC_USE" 2>/dev/null)" != "$SC_D" ]; then
		# `[ -z ] ||`, not `[ -n ] &&`: the group's status is its last command's — nobody's minutes yet would fail the write,
		# skip the mv and leave a temp file in RAM on every tick until the first active minute (BE7000, 08.10.2026)
		{ echo "$SC_D"; [ -z "$_unew" ] || printf '%s\n' "$_unew"; } > "$SC_USE.$$" && mv -f "$SC_USE.$$" "$SC_USE"
	fi
	SC_USED=$_unew
	sc_use_save
}

# ---- kernel -------------------------------------------------------------------------------------------------------
# The plan: every device of an enabled schedule whose state is not open — «<mac> <state> <id>», sorted (stable comparison).
# A device whose day limit ran out is closed till the end of the day — but only while the WEEK decides (a window or the base
# state): holidays rest the limit too, and an «open for…» by hand beats it («добавляет время»). SC_OVER — «<mac> <id>» of those.
sc_plan() {
	SC_PLAN=""; SC_OVER=""
	clock_trusted || return 0
	sc_use_load
	for _pi in $(sc_ids); do
		sc_load "$_pi" || continue
		[ "$SC_ON" = 1 ] && [ -n "$SC_DEVS" ] || continue
		sc_eval 1; sc_effective; sc_lim_today
		_plm=0; sc_lim_applies && _plm=1
		[ "$SC_ST" = open ] && [ "$_plm" = 0 ] && continue
		for _pm in $SC_DEVS; do
			_ps=$SC_ST
			if [ "$_plm" = 1 ] && [ "$(sc_used_of "$_pm")" -ge "$SC_LT" ]; then _ps=closed; SC_OVER="$SC_OVER$_pm $_pi$SC_NL"; fi
			[ "$_ps" = open ] && continue
			SC_PLAN="$SC_PLAN$_pm $_ps $_pi$SC_NL"
		done
	done
	SC_PLAN=$(printf '%s' "$SC_PLAN" | sort)
}
# rules of one family into the chain (the chain exists and is empty). $1 = iptables|ip6tables
sc_fill() {
	"$1" -A "$SC_CHAIN" -o br+ -j RETURN 2>/dev/null || return 1
	printf '%s\n' "$SC_PLAN" | while read -r _km _ks _ki; do
		[ -n "$_km" ] || continue
		case "$_ks" in
			closed|limited)
				# limited = closed for now: its per-category sets arrive with the «Ограничено» phase
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -j REJECT 2>/dev/null ;;
		esac
	done
	return 0
}
sc_rules_n() { printf '%s\n' "$SC_PLAN" | awk 'NF==3{n+=2} END{print n+1}'; }   # rules per family the plan makes
# Is the plan's form standing in the kernel of one family? Jump in FORWARD + the expected count of rules in the chain.
sc_wired() {   # $1 = iptables|ip6tables -> 0 standing, 1 not
	"$1" -C FORWARD -j "$SC_CHAIN" 2>/dev/null || return 1
	[ "$("$1" -S "$SC_CHAIN" 2>/dev/null | grep -c '^-A ' || true)" = "$(sc_rules_n)" ]
}
sc_drop_fam() {   # $1 = iptables|ip6tables — jump(s) and chain away
	_dn=0; while "$1" -D FORWARD -j "$SC_CHAIN" 2>/dev/null; do _dn=$((_dn + 1)); [ "$_dn" -ge 8 ] && break; done
	"$1" -F "$SC_CHAIN" 2>/dev/null; "$1" -X "$SC_CHAIN" 2>/dev/null
	return 0
}
sc_put_fam() {   # $1 = iptables|ip6tables
	"$1" -N "$SC_CHAIN" 2>/dev/null || "$1" -F "$SC_CHAIN" 2>/dev/null || return 1
	sc_fill "$1" || return 1
	# at the TOP: every forwarded packet of the house passes here before any ACCEPT (fw3 accepts ESTABLISHED early, and the
	# stock `--physdev-is-bridged -j ACCEPT` sits high); ipt-lib.sh::ipt_top puts our ACCEPTs below the block chains
	"$1" -C FORWARD -j "$SC_CHAIN" 2>/dev/null || "$1" -I FORWARD 1 -j "$SC_CHAIN" 2>/dev/null
}
# addresses a MAC holds now (both families; neighbour table first, the lease too — a device that just woke up)
sc_mac_ips() {
	ip neigh show 2>/dev/null | awk -v m="$1" '$4 == "lladdr" && tolower($5) == m && $NF != "FAILED" && $NF != "INCOMPLETE" { print $1 }'
	command -v lease_ip_of_mac >/dev/null 2>&1 && lease_ip_of_mac "$1"
	return 0
}
# Converge the kernel to SC_PLAN. Rebuild only when the plan changed or the form is gone (a firewall reload); flows of devices
# whose state changed are dropped AFTER the rules stand (dropped before, the next packet would be offloaded again unjudged).
sc_apply() {
	_aold=$(cat "$SC_APPLIED" 2>/dev/null)
	if [ -z "$SC_PLAN" ]; then
		[ -z "$_aold" ] && return 0
		sc_drop_fam iptables; have_v6 && sc_drop_fam ip6tables
	else
		if [ "$SC_PLAN" = "$_aold" ] && sc_wired iptables && { ! have_v6 || sc_wired ip6tables; }; then return 0; fi
		sc_put_fam iptables; have_v6 && sc_put_fam ip6tables
	fi
	printf '%s\n' "$SC_PLAN" > "$SC_APPLIED.$$" && mv -f "$SC_APPLIED.$$" "$SC_APPLIED"
	# devices whose line changed (new, gone, other state): only a stricter state needs the flush, but opening is rare and a
	# flush there is harmless — one rule, no second copy of «stricter»
	{ printf '%s\n' "$_aold"; printf '%s\n' "$SC_PLAN"; } | awk 'NF==3' | sort | uniq -u | awk '{print $1}' | sort -u |
	while read -r _am; do
		for _aip in $(sc_mac_ips "$_am" | sort -u); do ct_flush_src "$_aip"; done
	done
	return 0
}

# ---- journal ------------------------------------------------------------------------------------------------------
SC_WD_RU="вс пн вт ср чт пт сб"; SC_WD_EN="Sun Mon Tue Wed Thu Fri Sat"
sc_wd() { _wdi=$1; set -- $2; shift "$_wdi"; echo "$1"; }   # sc_wd <0..6> "<names>"
sc_lang() {
	SC_LANG=ru
	if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; command -v nf_lang >/dev/null 2>&1 && SC_LANG=$(nf_lang); fi
}
sc_note() {   # <key> <title> <text>
	[ -f "$ENODIA_DIR/events.sh" ] && sh "$ENODIA_DIR/events.sh" add "$1" 0 "$2" "$3" >/dev/null 2>&1
	return 0
}
# A schedule's state changed since the last tick of this boot ⇒ one journal line. The first tick of a boot only records: a
# line per schedule after every reboot would bury the real changes.
sc_journal() {   # needs SC_ID SC_NAME SC_ST SC_WHY SC_CHG loaded
	_jf="$SC_RUN/st.$SC_ID"; _jnew="$SC_ST $SC_WHY"
	_jold=$(cat "$_jf" 2>/dev/null)
	[ "$_jold" = "$_jnew" ] && return 0
	echo "$_jnew" > "$_jf" 2>/dev/null
	[ -n "$_jold" ] || return 0
	[ "${_jold%% *}" = "$SC_ST" ] && return 0      # same state, other reason (an override ran out into the same window)
	[ -n "$SC_LANG" ] || sc_lang
	_jt=""; _jc=$(sc_first_change)
	if [ -n "$_jc" ]; then
		sc_at "$_jc"
		if [ "$SC_LANG" = en ]; then _jt=" until $(sc_wd "$SC_AW" "$SC_WD_EN") ${SC_AT#* }"; else _jt=" до $(sc_wd "$SC_AW" "$SC_WD_RU") ${SC_AT#* }"; fi
	fi
	[ "$SC_WHY" = ovr ] && _jt=""                  # an override's own end is not the week's next change
	if [ "$SC_LANG" = en ]; then
		case "$SC_ST" in closed) _js="closed" ;; limited) _js="limited" ;; *) _js="open" ;; esac
		case "$SC_WHY" in ovr) _jw="by hand" ;; all) _jw="«close all now»" ;; hol) _jw="holidays" ;; off) _jw="schedule switched off" ;; *) _jw="by the schedule" ;; esac
		sc_note "sched-$SC_ID" "Schedule «$(sc_name)»: $_js" "Devices of the schedule are $_js$_jt ($_jw)."
	else
		case "$SC_ST" in closed) _js="закрыто" ;; limited) _js="ограничено" ;; *) _js="открыто" ;; esac
		case "$SC_WHY" in ovr) _jw="вручную" ;; all) _jw="«Закрыть всем сейчас»" ;; hol) _jw="каникулы" ;; off) _jw="расписание выключено" ;; *) _jw="по расписанию" ;; esac
		sc_note "sched-$SC_ID" "Расписание «$(sc_name)»: $_js" "Устройствам расписания $_js$_jt ($_jw)."
	fi
}
# The clock is still not synced long after the boot while schedules exist ⇒ one line per boot: «why did nothing close».
sc_clock_note() {
	[ -f "$SC_RUN/clock-noted" ] && return 0
	[ "$(uptime_s)" -ge "$SC_CLOCK_NOTE" ] || return 0
	: > "$SC_RUN/clock-noted" 2>/dev/null
	sc_lang
	if [ "$SC_LANG" = en ]; then
		sc_note sched-clock "Access schedules are not acting: the router clock is not synced" "The router has no clock of its own: after a boot the time comes from the network. It has not come yet, so the schedules close nothing — closing the internet by a wrong clock is worse than not closing. They start acting by themselves once the time is synced."
	else
		sc_note sched-clock "Расписания доступа не действуют: время роутера не сверено" "Своих часов у роутера нет: после загрузки время приходит из сети. Оно ещё не пришло, поэтому расписания ничего не закрывают — закрыть интернет по неверным часам хуже, чем не закрыть. Как только время сверится, они начнут действовать сами."
	fi
}

# ---- tick ---------------------------------------------------------------------------------------------------------
# Under the lock: expired actions go, the plan converges, transitions go to the journal. Cheap when nothing changes: one
# `date`, the registry read, one `-C` and one `-S` per family — and no iptables call at all while nobody is closed.
sc_tick_locked() {
	sc_now
	if clock_trusted; then
		# expired actions leave the registry (one write per action's life); the panel then shows the week, not a dead override
		for _ti in $(sc_ids); do
			[ -f "$SC_DIR/$_ti.ovr" ] && ! sc_ovr_get "$_ti" && rm -f "$SC_DIR/$_ti.ovr"
		done
		[ -f "$SC_DIR/.all" ] && ! sc_all_get && rm -f "$SC_DIR/.all"
		rm -f "$SC_RUN/clock-noted" 2>/dev/null
	elif [ -n "$(sc_ids)" ]; then
		sc_clock_note
	fi
	SC_IDS=$(sc_ids)
	clock_trusted && sc_use_tick
	sc_plan
	sc_apply
	clock_trusted || return 0
	SC_LANG=""
	for _ti in $SC_IDS; do
		sc_load "$_ti" || continue
		sc_eval 1; sc_effective; sc_journal
	done
	sc_over_note
	return 0
}
# A device newly out of its day limit ⇒ one journal line (the first tick of a boot only records), and the day's usage goes to the
# flash at once: a reboot must not hand the device a fresh day.
sc_over_note() {
	_on=$(printf '%s' "$SC_OVER" | grep . | sort)
	# the first tick of a boot writes its record even when nobody is over — otherwise the first real crossing would read as
	# «the first tick» and stay silent
	if [ ! -f "$SC_RUN/over" ]; then
		printf '%s\n' "$_on" > "$SC_RUN/over" 2>/dev/null
		[ -n "$_on" ] && sc_use_save now
		return 0
	fi
	_oo=$(cat "$SC_RUN/over" 2>/dev/null)
	[ "$_on" = "$_oo" ] && return 0
	printf '%s\n' "$_on" > "$SC_RUN/over" 2>/dev/null
	[ -n "$_on" ] && sc_use_save now
	printf '%s\n' "$_on" | while read -r _om _oi; do
		[ -n "$_om" ] || continue
		case "$SC_NL$_oo$SC_NL" in *"$SC_NL$_om $_oi$SC_NL"*) continue ;; esac
		sc_load "$_oi" || continue
		_onm=""; [ -f "$ENODIA_DIR/dev-names.sh" ] && _onm=$(sh "$ENODIA_DIR/dev-names.sh" get "$_om" 2>/dev/null)
		[ -n "$_onm" ] || _onm=$(printf '%s' "$_om" | tr 'a-f' 'A-F')
		[ -n "$SC_LANG" ] || sc_lang
		if [ "$SC_LANG" = en ]; then
			sc_note "sched-lim-$_oi" "Schedule «$(sc_name)»: the day's limit is used up" "$_onm has used up today's limit — closed until the end of the day. «Open for…» on the schedule adds time."
		else
			sc_note "sched-lim-$_oi" "Расписание «$(sc_name)»: лимит на сегодня исчерпан" "$_onm исчерпало лимит на сегодня — закрыто до конца дня. «Открыть на…» на экране расписания добавит время."
		fi
	done
	return 0
}
cmd_tick() {
	# nothing registered and nothing in the kernel: the per-minute cron line costs one directory listing
	[ -n "$(sc_ids)" ] || [ -s "$SC_APPLIED" ] || return 0
	sc_lock || return 0      # another tick or a save holds it — it converges for us
	sc_tick_locked
}
cmd_unwire() {
	sc_lock || true
	sc_drop_fam iptables; have_v6 && sc_drop_fam ip6tables
	rm -f "$SC_APPLIED" "$SC_RUN"/st.* 2>/dev/null
	echo "Расписания доступа: правила сняты."
}

# ---- JSON -----------------------------------------------------------------------------------------------------------
sc_at_json() {   # <epoch> -> {"at":"…","w":N,"ue":E}
	sc_at "$1"; printf '{"at":"%s","w":%s,"ue":%s}' "$SC_AT" "$SC_AW" "$1"
}
sc_item_json() {   # the loaded schedule, after sc_now + sc_use_load
	sc_eval "$SC_K"; sc_effective; sc_lim_today
	printf '{"id":"%s","name":"%s","on":%s,"ver":%s,"base":"%s",' "$SC_ID" "$(jstr "$(sc_name)" 200)" "$SC_ON" "$SC_VER" "$SC_BASE"
	# the day limit: minutes per weekday / weekend day, today's; every device's minutes today; who is closed by it NOW
	printf '"lim":{"wd":%s,"we":%s,"today":%s},"used":{' "$SC_LWD" "$SC_LWE" "$SC_LT"
	_ij=0; _iov=""
	for _im in $SC_DEVS; do
		_iu=$(sc_used_of "$_im")
		[ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s":%s' "$_im" "$_iu"
		sc_lim_applies && [ "$_iu" -ge "$SC_LT" ] && _iov="${_iov:+$_iov,}\"$_im\""
	done
	printf '},"over":[%s],"wins":[' "$_iov"
	_ij=0
	printf '%s' "$SC_WINS" | while read -r _id _ia _ib _is; do
		[ -n "$_is" ] || continue
		[ "$_ij" = 1 ] && printf ','; _ij=1
		printf '{"d":"%s","a":"%s","b":"%s","s":"%s"}' "$_id" "$_ia" "$_ib" "$_is"
	done
	printf '],"devs":['
	_ij=0; for _im in $SC_DEVS; do [ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s"' "$_im"; done
	printf '],"st":"%s","why":"%s","hol":' "$SC_ST" "$SC_WHY"
	if [ "$SC_HOL" -gt "$SC_E" ] 2>/dev/null; then sc_at_json "$SC_HOL"; else printf 'null'; fi
	printf ',"ovr":'
	if sc_ovr_get "$SC_ID"; then
		printf '{"s":"%s","kind":"%s","until":' "$SC_OS" "$SC_OK"
		if [ "$SC_OU" = 0 ]; then printf 'null'; else sc_at_json "$SC_OU"; fi
		printf '}'
	else printf 'null'; fi
	# the week's upcoming changes — the router's calendar and TZ, so the panel shows them without arithmetic
	printf ',"next":['
	_ij=0
	printf '%s\n' "$SC_CHG" | while read -r _io _is; do
		[ -n "$_is" ] || continue
		[ "$_ij" = 1 ] && printf ','; _ij=1
		sc_at "$(( SC_E0 + _io * 60 ))"; printf '{"at":"%s","w":%s,"s":"%s"}' "$SC_AT" "$SC_AW" "$_is"
	done
	printf ']}'
}
sc_head_json() {   # router clock + «close all» + limits, after sc_now
	_hc=0; clock_trusted && _hc=1
	sc_at "$SC_E"
	# `ne` — «now» as an epoch: «in 20 min» is then one subtraction of two router numbers in the panel, not a calendar
	printf '"clock":%s,"now":"%s","w":%s,"ne":%s,"max":%s,"wmax":%s,"dmax":%s,"all":' "$_hc" "$SC_AT" "$SC_AW" "$SC_E" "$SC_MAX" "$SC_WIN_MAX" "$SC_DEV_MAX"
	if [ "$_hc" = 1 ] && sc_all_get; then
		if [ "$SC_AU" = 0 ]; then printf '{"until":null}'; else printf '{"until":'; sc_at_json "$SC_AU"; printf '}'; fi
	else printf 'null'; fi
}
cmd_list_json() {
	sc_now; sc_use_load
	printf '{"ok":true,'; sc_head_json; printf ',"items":['
	_lj=0
	for _li in $(sc_ids); do
		sc_load "$_li" || continue
		[ "$_lj" = 1 ] && printf ','; _lj=1
		sc_item_json
	done
	printf ']}\n'
}
cmd_get_json() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_now; sc_use_load
	sc_load "$1" || jfail "нет такого расписания"
	printf '{"ok":true,'; sc_head_json; printf ',"item":'; sc_item_json; printf '}\n'
}

# ---- writes -------------------------------------------------------------------------------------------------------
# Spec from the CGI (key=value lines, values already charset-checked there; meaning is checked HERE):
#   id=<sN|new> ver=<n the panel opened> name_b64=… enabled=0|1 base=open|limited|closed
#   wins=<d>.<HHMM>.<HHMM>.<o|l|c>[;…]   devs=<mac>[,<mac>…]
sc_spec() { sed -n "s/^$1=//p" "$SC_SPEC" | head -n 1 | tr -d '\r'; }
sc_st_of() { case "$1" in o) echo open ;; l) echo limited ;; c) echo closed ;; *) return 1 ;; esac; }
cmd_save() {
	SC_SPEC=$1; [ -f "$SC_SPEC" ] || jfail "нет данных расписания"
	_vid=$(sc_spec id); _vver=$(num_or "$(sc_spec ver)" 0)
	_vname=$(sc_spec name_b64 | base64 -d 2>/dev/null); _vname=$(lbl_san "$_vname")
	[ -n "$_vname" ] || jfail "нужно имя расписания"
	# characters, not bytes: UTF-8 continuation bytes (0x80–0xBF) do not start a character (busybox `wc` has no -m)
	[ "$(printf '%s' "$_vname" | tr -d '\200-\277' | wc -c | tr -d ' ')" -le "$SC_NAME_MAX" ] || jfail "имя длиннее $SC_NAME_MAX знаков"
	_von=$(sc_spec enabled); case "$_von" in 0|1) ;; *) jfail "неверный выключатель" ;; esac
	_vbase=$(sc_spec base); case "$_vbase" in open|limited|closed) ;; *) jfail "неверное состояние вне окон" ;; esac
	# day limits, minutes (0 = none); absent from the spec = the schedule keeps its own (an older panel knows nothing of them)
	_vlwd=$(sc_spec lim_wd | sed 's/^0*\([0-9]\)/\1/'); _vlwe=$(sc_spec lim_we | sed 's/^0*\([0-9]\)/\1/')   # «090» is octal to $((…))
	for _vlv in "$_vlwd" "$_vlwe"; do
		case "$_vlv" in '') continue ;; *[!0-9]*) jfail "неверный лимит" ;; esac
		[ "$_vlv" -le 1440 ] || jfail "лимит — не больше суток"
	done
	# windows: «days.HHMM.HHMM.s» → registry lines (days sorted, each once), then through the SAME check as a load (SC_WIN_AWK)
	_vwn=$(sc_spec wins | tr ';' '\n' | grep -c . || true)
	[ "${_vwn:-0}" -le "$SC_WIN_MAX" ] || jfail "окон больше $SC_WIN_MAX"
	_vconv=$(sc_spec wins | tr ';' '\n' | awk -F. '
		NF == 0 { next }
		NF != 4 || $1 !~ /^[0-6]+$/ || $2 !~ /^[0-9][0-9][0-9][0-9]$/ || $3 !~ /^[0-9][0-9][0-9][0-9]$/ || $4 !~ /^[olc]$/ { print "BAD " $0; next }
		{ d = ""; for (c = 0; c <= 6; c++) { f = 0; for (i = 1; i <= length($1); i++) if (substr($1, i, 1) == c "") f = 1; if (f) d = d c }
		  s = ($4 == "o") ? "open" : ($4 == "l") ? "limited" : "closed"
		  print d " " substr($2, 1, 2) ":" substr($2, 3, 2) " " substr($3, 1, 2) ":" substr($3, 3, 2) " " s }')
	_vbad=$(printf '%s\n' "$_vconv" | sed -n 's/^BAD //p' | head -n 1)
	[ -z "$_vbad" ] || jfail "неверное окно: $_vbad"
	_vwins=$(printf '%s\n' "$_vconv" | awk -v bare=1 "$SC_WIN_AWK")
	[ "$(printf '%s\n' "$_vconv" | grep . | sort -u | grep -c . || true)" = "$(printf '%s\n' "$_vwins" | grep -c . || true)" ] || jfail "неверное время окна"
	[ -n "$_vwins" ] && _vwins="$_vwins$SC_NL"
	_vdevs=""; _vdn=0
	for _vm in $(sc_spec devs | tr ',' ' '); do
		_vm=$(mac_norm "$_vm"); mac_ok "$_vm" || jfail "неверный MAC: $_vm"
		case " $_vdevs " in *" $_vm "*) continue ;; esac
		_vdn=$((_vdn + 1)); [ "$_vdn" -le "$SC_DEV_MAX" ] || jfail "устройств больше $SC_DEV_MAX"
		_vdevs="${_vdevs:+$_vdevs }$_vm"
	done
	mkdir -p "$SC_DIR" 2>/dev/null || jfail "не удалось создать $SC_DIR"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	if [ "$_vid" = new ]; then
		[ "$(sc_ids | wc -l | tr -d ' ')" -lt "$SC_MAX" ] || jfail "расписаний не больше $SC_MAX"
		_vid=$(sc_new_id); SC_VER=0; SC_HOL=0; SC_LWD=0; SC_LWE=0
	else
		id_ok "$_vid" || jfail "неверный номер расписания"
		sc_load "$_vid" || jfail "расписание удалено — откройте список заново"
		[ "$SC_VER" = "$_vver" ] || jfail "расписание изменили в другой вкладке — откройте его заново"
	fi
	# one device = one schedule: two of them would fight over its rule, and the panel shows ONE schedule per device
	for _vo in $(sc_ids); do
		[ "$_vo" = "$_vid" ] && continue
		_vown=$(grep -h '^dev=mac:' "$SC_DIR/$_vo.sch" 2>/dev/null | sed 's/^dev=mac://' | tr 'A-Z' 'a-z')
		for _vm in $_vdevs; do
			case "$SC_NL$_vown$SC_NL" in *"$SC_NL$_vm$SC_NL"*)
				_von2=$(sed -n 's/^name=//p' "$SC_DIR/$_vo.sch" | head -n 1)
				jfail "устройство $_vm уже в расписании «$(lbl_san "$_von2")»" ;; esac
		done
	done
	SC_ID=$_vid; SC_NAME=$_vname; SC_ON=$_von; SC_BASE=$_vbase; SC_WINS=$_vwins; SC_DEVS=$_vdevs; SC_VER=$((SC_VER + 1))
	[ -n "$_vlwd" ] && SC_LWD=$_vlwd; [ -n "$_vlwe" ] && SC_LWE=$_vlwe
	sc_write "$_vid" || jfail "не удалось записать расписание"
	sc_tick_locked
	jok "\"id\":\"$_vid\",\"ver\":$SC_VER"
}
cmd_del() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	[ -f "$SC_DIR/$1.sch" ] || jfail "нет такого расписания"
	rm -f "$SC_DIR/$1.sch" "$SC_DIR/$1.ovr" "$SC_RUN/st.$1" 2>/dev/null
	sc_tick_locked
	jok
}
cmd_toggle() {
	id_ok "$1" || jfail "неверный номер расписания"
	case "$2" in on) _tv=1 ;; off) _tv=0 ;; *) jfail "нужно on|off" ;; esac
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_load "$1" || jfail "нет такого расписания"
	SC_ON=$_tv; SC_VER=$((SC_VER + 1))
	sc_write "$1" || jfail "не удалось записать расписание"
	sc_tick_locked
	jok "\"ver\":$SC_VER"
}
# minutes|HH:MM|0 -> SC_UNTIL (epoch; 0 = until cancelled). `end` is handled by the caller (it needs the week).
sc_until() {
	case "$1" in
		0) SC_UNTIL=0 ;;
		*:*) sc_next_hhmm "$1" || return 1; SC_UNTIL=$SC_NEXT ;;
		*) case "$1" in ''|*[!0-9]*) return 1 ;; esac
		   [ "$1" -ge 1 ] && [ "$1" -le 10080 ] || return 1
		   SC_UNTIL=$(( SC_E + $1 * 60 )) ;;
	esac
}
cmd_ovr() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	clock_trusted || jfail "время роутера ещё не сверено — расписания не действуют"
	sc_load "$1" || jfail "нет такого расписания"
	sc_eval 1
	case "$2" in
		clear) rm -f "$SC_DIR/$1.ovr" ;;
		close)
			sc_until "${3:-0}" || jfail "неверный срок"
			echo "closed $SC_UNTIL close" > "$SC_DIR/$1.ovr" ;;
		open)
			if [ "${3:-}" = end ]; then
				# «до конца окна»: until the week itself next changes the state
				SC_UNTIL=$(sc_first_change); [ -n "$SC_UNTIL" ] || jfail "у этого расписания закрытое время не кончается — выберите срок"
			else
				sc_until "${3:-}" && [ "$SC_UNTIL" != 0 ] || jfail "неверный срок"
			fi
			echo "open $SC_UNTIL open" > "$SC_DIR/$1.ovr" ;;
		postpone)
			# «отложить закрытие»: the week is open now and is about to get stricter — stay open N minutes past that change
			_pm=$(num_or "${3:-}" 0); [ "$_pm" -ge 1 ] && [ "$_pm" -le 1440 ] || jfail "неверный срок"
			[ "$SC_CUR" = open ] || jfail "сейчас не открыто — откладывать нечего"
			_pc=$(sc_first_change); [ -n "$_pc" ] || jfail "закрытия впереди нет"
			echo "open $(( _pc + _pm * 60 )) postpone" > "$SC_DIR/$1.ovr" ;;
		*) jfail "неизвестное действие" ;;
	esac
	sc_tick_locked
	jok
}
cmd_all() {
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	clock_trusted || jfail "время роутера ещё не сверено — расписания не действуют"
	mkdir -p "$SC_DIR" 2>/dev/null
	if [ "$1" = off ]; then rm -f "$SC_DIR/.all"
	else
		sc_until "$1" || jfail "неверный срок"
		echo "$SC_UNTIL" > "$SC_DIR/.all.$$" && mv -f "$SC_DIR/.all.$$" "$SC_DIR/.all"
	fi
	sc_tick_locked
	jok
}
cmd_hol() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	sc_load "$1" || jfail "нет такого расписания"
	if [ "$2" = off ]; then SC_HOL=0
	else
		clock_trusted || jfail "время роутера ещё не сверено — расписания не действуют"
		printf '%s' "$2" | grep -qE '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$' || jfail "неверная дата"
		_hd=$(date -d "$2 23:59" +%s 2>/dev/null); _hd=$(num_or "$_hd" 0)
		[ "$_hd" -gt "$SC_E" ] || jfail "дата уже прошла"
		SC_HOL=$(( _hd + 60 ))       # the whole chosen day rests; the schedule acts again at 00:00 after it
	fi
	SC_VER=$((SC_VER + 1))
	sc_write "$1" || jfail "не удалось записать расписание"
	sc_tick_locked
	jok "\"ver\":$SC_VER"
}

# Backup import (cgi-bin/backup): a schedule from the archive replaces the one under its id, written through the SAME load
# (a foreign or old file loads only what is valid) and sc_write. Actions over a schedule (`.ovr`, `.all`) are «now», not settings
# — the export leaves them out, and an action of the replaced schedule goes with it. One device = one schedule after the
# merge too: a device the archive puts in a schedule leaves a local one. The id counter keeps the higher of both.
cmd_import() {
	[ -d "$1" ] || jfail "нет каталога расписаний"
	mkdir -p "$SC_DIR" 2>/dev/null || jfail "не удалось создать $SC_DIR"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	_mi=""; _mdevs=""
	for _mf in "$1"/s*.sch; do
		[ -f "$_mf" ] || continue
		_mid=${_mf##*/}; _mid=${_mid%.sch}
		id_ok "$_mid" || continue
		sc_load "$_mid" "$_mf" || continue
		SC_NAME=$(sc_name); [ -n "$SC_NAME" ] || SC_NAME=$_mid
		SC_HOL=0                                   # a holiday of the archive's past means nothing here
		# the version moves past BOTH: a panel tab open on the local schedule must see «changed elsewhere», not save over it
		_mlv=$(sed -n 's/^ver=//p' "$SC_DIR/$_mid.sch" 2>/dev/null | head -n 1 | tr -cd '0-9')
		[ "${_mlv:-0}" -gt "$SC_VER" ] 2>/dev/null && SC_VER=$_mlv
		SC_VER=$((SC_VER + 1))
		[ "$(sc_ids | grep -cx "$_mid" || true)" = 0 ] && [ "$(sc_ids | wc -l | tr -d ' ')" -ge "$SC_MAX" ] && continue
		sc_write "$_mid" || continue
		rm -f "$SC_DIR/$_mid.ovr" 2>/dev/null
		_mi="$_mi $_mid"; _mdevs="$_mdevs $SC_DEVS"
	done
	for _mo in $(sc_ids); do
		case " $_mi " in *" $_mo "*) continue ;; esac
		sc_load "$_mo" || continue
		_mk=""; _mch=0
		for _mm in $SC_DEVS; do case " $_mdevs " in *" $_mm "*) _mch=1 ;; *) _mk="${_mk:+$_mk }$_mm" ;; esac; done
		[ "$_mch" = 1 ] || continue
		SC_DEVS=$_mk; SC_VER=$((SC_VER + 1)); sc_write "$_mo"
	done
	_ma=$(cat "$1/.last-id" 2>/dev/null | tr -cd '0-9'); _ml=$(cat "$SC_DIR/.last-id" 2>/dev/null | tr -cd '0-9')
	[ "${_ma:-0}" -gt "${_ml:-0}" ] 2>/dev/null && echo "$_ma" > "$SC_DIR/.last-id"
	sc_tick_locked
	jok "\"n\":$(set -- $_mi; echo $#)"
}

# ---- diagnostics --------------------------------------------------------------------------------------------------
cmd_dump() {
	sc_now
	echo "время: $(date '+%Y-%m-%d %H:%M %Z' 2>/dev/null) · сверено: $(clock_trusted && echo да || echo НЕТ — расписания не действуют)"
	sc_all_get && echo "«Закрыть всем»: до $([ "$SC_AU" = 0 ] && echo 'отмены' || { sc_at "$SC_AU"; echo "$SC_AT"; })"
	for _di in $(sc_ids); do
		sc_load "$_di" || continue
		sc_eval 1; sc_effective
		# by id, not by name: the dump goes into a chat, and a schedule is named after a person («Маша») more often than not
		echo "$_di: вкл=$SC_ON вне окон=$SC_BASE сейчас=$SC_ST ($SC_WHY) устройств=$(set -- $SC_DEVS; echo $#) окон=$(printf '%s' "$SC_WINS" | grep -c . || true)"
	done
	_dn=$(grep -c . "$SC_APPLIED" 2>/dev/null || true)
	echo "в ядре (план): ${_dn:-0} устройств закрыто/ограничено"
	# MACs as they are: dump.sh masks its whole output with the one redact() of the project
	iptables -S "$SC_CHAIN" 2>/dev/null | sed 's/^/  v4 /'
	iptables -C FORWARD -j "$SC_CHAIN" 2>/dev/null && echo "  v4 прыжок из FORWARD: есть"
	have_v6 && ip6tables -C FORWARD -j "$SC_CHAIN" 2>/dev/null && echo "  v6 прыжок из FORWARD: есть"
	[ -f /etc/config/parentalctl ] && [ "$(uci -q get parentalctl.global.disabled 2>/dev/null)" = 0 ] && \
		echo "ВНИМАНИЕ: включено стоковое родительское управление Xiaomi (parentalctl) — два движка правил одновременно"
	return 0
}

SC_VERB=${1:-}; [ $# -gt 0 ] && shift
case "$SC_VERB" in
	list-json) cmd_list_json ;;
	get-json)  cmd_get_json "${1:-}" ;;
	save)      cmd_save "${1:-}" ;;
	del)       cmd_del "${1:-}" ;;
	toggle)    cmd_toggle "$@" ;;
	ovr)       cmd_ovr "$@" ;;
	all)       cmd_all "${1:-}" ;;
	hol)       cmd_hol "$@" ;;
	import)    cmd_import "${1:-}" ;;
	tick)      cmd_tick ;;
	unwire)    cmd_unwire ;;
	dump)      cmd_dump ;;
	*) echo "usage: access-sched.sh list-json|get-json <id>|save <spec>|del <id>|toggle <id> on|off|ovr <id> …|all …|hol <id> …|import <dir>|tick|unwire|dump"; exit 1 ;;
esac
