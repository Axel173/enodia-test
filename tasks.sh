#!/bin/sh
# tasks.sh — «ЗАДАЧИ»: the panel's cron manager. ONE owner of the user's schedule and THE runner of user tasks.
#
# Why a registry and not "edit crontab lines": a cron line can carry neither a name, nor a script body, nor a timeout, nor
# «at boot» (busybox crond has no @reboot), nor «mail me on failure». So a task lives in a REGISTRY on /data
# ($ENODIA_STATE/tasks/: <id>.task settings, <id>.body script, <id>.env variables), and its cron line is DERIVED from it
# (`apply`). The line goes through the resident bootstrap like every line of ours (`boot.sh tasks.sh run <id> sched`):
# code may live on a USB drive, and `uninstall.sh::cron_ours` recognises our lines by that very path — so deactivation and
# removal take user tasks along without a second list.
#
# Three kinds of crontab lines, and this file is honest about all of them (decision 07.10.2026, «risk is on the user»):
#   * task lines (signature TK_SIG) — rewritten from the registry on every save; editing them by hand is pointless;
#   * Enodia lines (bootstrap / code dir) — their OWNERS rewrite them (install, update-sched, cron-restore); read-only here;
#   * every other line — FOREIGN (firmware, hand-made, the SSH-access patch): edit, disable (`# `), delete, adopt — by
#     EXACT CONTENT, not by line number: the file can change between the panel's read and its write (another writer,
#     a firmware update), and a number would then hit a different line.
# The raw tab saves the whole file, but every line is validated FIRST: busybox crond silently skips a line it cannot
# parse, so a typo would look like «the task just never runs».
#
# Cron syntax = what busybox 1.25 crond ACCEPTS, not vixie: lists, ranges, `*/n`, `a-b/n`, 3-letter names; NO @macros,
# NO `VAR=value` lines, day of week 0..6 (7 is rejected by crond), a step only after `*` or a range (busybox reads `5/10`
# as just 5 — vixie as 5..59/10; rejecting it beats a schedule that silently means something else), ranges ascending.
# Day-of-month and day-of-week combine like busybox FixDayDow: one of them restricted ⇒ only it counts, both ⇒ OR.
# The next runs are computed HERE, in the router's own calendar (its TZ), so the panel shows them without arithmetic.
#
# Runner (`run <id> <sched|boot|manual>`): per-task lock (skip / wait / run alongside), optional wait for sane clocks
# (after a reboot the clock sits in the past until synced — clock-lib.sh), timeout that kills the WHOLE process tree
# (a script's `ping` would outlive a killed `sh`), output cap while running (/tmp is RAM: `yes` in a task would eat it),
# last 32 KB of output kept per run in RAM (no flash writes per run), history in RAM, failure → events journal / mail.
#
# Usage:
#   tasks.sh list-json | get-json <id> | explain "<m h dom mon dow>" | raw-get
#   tasks.sh save <specfile> | del <id> | toggle <id> on|off | dup <id> | run-bg <id> | stop <id>
#   tasks.sh line-set <old_b64> <new_b64> | line-toggle <old_b64> | adopt <old_b64> | raw-save <b64file>
#   tasks.sh file-get <path> | file-put <path> <b64file>
#   tasks.sh apply | boot | run <id> <trigger> | run-delayed <id> <sec>
# JSON verbs print one JSON object; messages are Russian (the panel translates them by its dictionary).

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}
TK_DIR="$ENODIA_STATE/tasks"
TK_RUN=/tmp/enodia-tasks            # RAM: locks, history, outputs — gone with a reboot by design
TK_LOCK=/tmp/enodia-tasks.lock      # serialises registry + crontab writes of this owner
CRON=/etc/crontabs/root
CRON_RUN="$ENODIA_BOOT/boot.sh"
TK_SIG="boot.sh tasks.sh run "      # signature of task lines: the owner key for `apply`
TK_BODY_MAX=16384                   # script size (the CGI body is 32 KB, base64 adds a third)
TK_OUT_KEEP=32768                   # output kept per run
TK_OUT_CAP=524288                   # output allowed WHILE running; beyond it the run is cut (RAM)
TK_FILE_MAX=65536                   # «open and edit the file» limit

if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '\000-\010\013-\037' | tr '\n\t' '  ' | cut -c1-"$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
# the tree walk's owner is daemon-lib.sh (same package); without it a timeout kills the top process only
command -v proc_tree >/dev/null 2>&1 || proc_tree() { echo "$1"; }

b64() { base64 2>/dev/null | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }
jstr() { printf '%s' "$1" | jtxt "${2:-200}"; }
jok() { printf '{"ok":true%s}\n' "${1:+,$1}"; }
jfail() { printf '{"ok":false,"msg":"%s"%s}\n' "$(jstr "$1" 400)" "${2:+,$2}"; exit 0; }
id_ok() { printf '%s' "$1" | grep -qE '^t[0-9]{1,6}$'; }
now_local() { date '+%Y-%m-%d %H:%M' 2>/dev/null; }
# sh single-quote: the path goes into a command line the user's shell syntax surrounds
tk_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- RAM dir, lock, cleanup ---------------------------------------------------------------------------------------
# /tmp is shared with stock daemons (some run as nobody): a symlink or a foreign directory laid on our name beforehand would
# turn every write of ours into a write as root into ITS target (the class cap_run in cgi-bin/action is built against).
# So the directory is ours only when it is a real directory owned by root; anything else is removed and made anew, 700.
tk_rundir() {
	if [ -L "$TK_RUN" ] || { [ -e "$TK_RUN" ] && { [ ! -d "$TK_RUN" ] || [ "$(stat -c %u "$TK_RUN" 2>/dev/null)" != "$(id -u)" ]; }; }; then
		rm -rf "$TK_RUN" 2>/dev/null
	fi
	[ -d "$TK_RUN" ] || ( umask 077; mkdir "$TK_RUN" ) 2>/dev/null
	[ -d "$TK_RUN" ] && [ ! -L "$TK_RUN" ]
}
TK_LOCKED=0; TK_TMP=""
tk_exit() { _xr=$?; [ "$TK_LOCKED" = 1 ] && rm -rf "$TK_LOCK" 2>/dev/null; [ -n "$TK_TMP" ] && rm -rf "$TK_TMP" 2>/dev/null; return "$_xr"; }
# mkdir + pid: a killed holder is recognised by /proc, not by age
tk_lock() {
	_lw=0
	[ -L "$TK_LOCK" ] && rm -f "$TK_LOCK" 2>/dev/null
	while ! mkdir "$TK_LOCK" 2>/dev/null; do
		_lp=$(cat "$TK_LOCK/pid" 2>/dev/null)
		if [ -n "$_lp" ] && [ ! -d "/proc/$_lp" ]; then rm -rf "$TK_LOCK" 2>/dev/null; continue; fi
		_lw=$((_lw + 1)); [ "$_lw" -gt 20 ] && jfail "задачи сейчас меняет другой запрос — повторите через минуту"
		sleep 1
	done
	echo $$ > "$TK_LOCK/pid"; TK_LOCKED=1
}
tk_unlock() { [ "$TK_LOCKED" = 1 ] && rm -rf "$TK_LOCK" 2>/dev/null; TK_LOCKED=0; return 0; }

# ---- cron field expansion (busybox 1.25 grammar, see the header) --------------------------------------------------
# tk_num <token> <kind> -> number (names allowed for mon/dow), rc 1 on garbage
tk_num() {
	case "$1" in
		''|*[!0-9A-Za-z]*) return 1 ;;
		*[!0-9]*)
			_tn=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
			case "$2" in
				mon) case "$_tn" in jan) echo 1;; feb) echo 2;; mar) echo 3;; apr) echo 4;; may) echo 5;; jun) echo 6;;
				                    jul) echo 7;; aug) echo 8;; sep) echo 9;; oct) echo 10;; nov) echo 11;; dec) echo 12;; *) return 1;; esac ;;
				dow) case "$_tn" in sun) echo 0;; mon) echo 1;; tue) echo 2;; wed) echo 3;; thu) echo 4;; fri) echo 5;; sat) echo 6;; *) return 1;; esac ;;
				*) return 1 ;;
			esac ;;
		*) [ "${#1}" -le 4 ] || return 1
		   _tz=$(printf '%s' "$1" | sed 's/^0*//'); echo "${_tz:-0}" ;;   # textually: `$((08))` is an octal error in ash
	esac
}
# tk_expand <field> <lo> <hi> <kind> -> TKX=" n n n " (ascending, de-duplicated), TKE = reason on failure (rc 1)
tk_expand() {
	TKX=" "; TKE=""; _xf=$1; _xlo=$2; _xhi=$3; _xk=$4
	[ -n "$_xf" ] || { TKE="пустое поле"; return 1; }
	_xrest="$_xf,"
	while [ -n "$_xrest" ]; do
		_xit=${_xrest%%,*}; _xrest=${_xrest#*,}
		[ -n "$_xit" ] || { TKE="пустой элемент списка: $_xf"; return 1; }
		_xst=1; _xhas=0
		case "$_xit" in */*) _xst=${_xit#*/}; _xit=${_xit%/*}; _xhas=1
			case "$_xst" in ''|*[!0-9]*) TKE="шаг — число: $_xf"; return 1 ;; esac
			_xst=$(tk_num "$_xst" min) || { TKE="шаг — число: $_xf"; return 1; }
			[ "$_xst" -ge 1 ] || { TKE="шаг — от 1: $_xf"; return 1; } ;;
		esac
		case "$_xit" in
			'*') _xa=$_xlo; _xb=$_xhi ;;
			*-*) _xa=$(tk_num "${_xit%%-*}" "$_xk") || { TKE="не число: $_xf"; return 1; }
			     _xb=$(tk_num "${_xit#*-}" "$_xk") || { TKE="не число: $_xf"; return 1; } ;;
			*)   [ "$_xhas" = 1 ] && { TKE="шаг — только после «*» или диапазона (например 0-59/10): $_xf"; return 1; }
			     _xa=$(tk_num "$_xit" "$_xk") || { TKE="не число: $_xf"; return 1; }; _xb=$_xa ;;
		esac
		{ [ "$_xa" -ge "$_xlo" ] && [ "$_xb" -le "$_xhi" ]; } || { TKE="вне диапазона $_xlo–$_xhi: $_xf"; return 1; }
		[ "$_xa" -le "$_xb" ] || { TKE="диапазон — по возрастанию: $_xf"; return 1; }
		_xi=$_xa
		while [ "$_xi" -le "$_xb" ]; do
			case "$TKX" in *" $_xi "*) ;; *) TKX="$TKX$_xi " ;; esac
			_xi=$((_xi + _xst))
		done
	done
	# ascending order (busybox sort has no -k, a plain numeric sort of one column is fine)
	TKX=" $(printf '%s\n' $TKX | sort -n | tr '\n' ' ')"
	return 0
}
# tk_sched_parse "<m h dom mon dow>" -> TK_M TK_H TK_D TK_MO TK_W lists, TK_DU/TK_WU «restricted» flags; TKE on failure
tk_sched_parse() {
	set -f; set -- $1; set +f
	[ "$#" -eq 5 ] || { TKE="в расписании нужно ровно пять полей: минута, час, день месяца, месяц, день недели"; return 1; }
	tk_expand "$1" 0 59 min || { TKE="минута: $TKE"; return 1; }; TK_M=$TKX
	tk_expand "$2" 0 23 hour || { TKE="час: $TKE"; return 1; }; TK_H=$TKX
	tk_expand "$3" 1 31 dom || { TKE="день месяца: $TKE"; return 1; }; TK_D=$TKX
	tk_expand "$4" 1 12 mon || { TKE="месяц: $TKE"; return 1; }; TK_MO=$TKX
	tk_expand "$5" 0 6 dow || { TKE="день недели (0–6, воскресенье — 0): $TKE"; return 1; }; TK_W=$TKX
	# busybox FixDayDow: «used» = not every slot set. For days crond's array has a slot 0 nothing but `*` fills.
	case "$3" in '*'|'*/1') TK_DU=0 ;; *) TK_DU=1 ;; esac
	if [ "$TK_W" = " 0 1 2 3 4 5 6 " ]; then TK_WU=0; else TK_WU=1; fi
	return 0
}
tk_dim() {   # days in month <y> <m> -> TKD (a variable, not stdout: the next-run loop calls it per day, a fork each was slow)
	case "$2" in 4|6|9|11) TKD=30 ;;
		2) if [ $(($1 % 4)) -eq 0 ] && { [ $(($1 % 100)) -ne 0 ] || [ $(($1 % 400)) -eq 0 ]; }; then TKD=29; else TKD=28; fi ;;
		*) TKD=31 ;; esac
}
# tk_next <count> -> lines "YYYY-MM-DD HH:MM" of the next runs after now (router calendar), from the parsed TK_* lists.
# Day by day up to ~4 years (29 Feb), then hour and minute lists: cheap even on the slowest supported router.
tk_next() {
	_nc=$1; _nf=0
	set -- $(date '+%Y %m %d %H %M %w')
	_ny=$1; _nm=$(tk_num "$2" min); _nd=$(tk_num "$3" min); _nH=$(tk_num "$4" min); _nM=$(tk_num "$5" min); _nw=$6
	_nday=0
	while [ "$_nday" -le 1470 ] && [ "$_nf" -lt "$_nc" ]; do
		_nok=0
		case "$TK_MO" in *" $_nm "*)
			_dm=0; _wm=0
			case "$TK_D" in *" $_nd "*) _dm=1 ;; esac
			case "$TK_W" in *" $_nw "*) _wm=1 ;; esac
			if [ "$TK_DU" = "$TK_WU" ]; then
				if [ "$TK_DU" = 0 ] || [ "$_dm" = 1 ] || [ "$_wm" = 1 ]; then _nok=1; fi
			elif [ "$TK_DU" = 1 ]; then _nok=$_dm
			else _nok=$_wm
			fi ;;
		esac
		if [ "$_nok" = 1 ]; then
			for _hh in $TK_H; do
				[ "$_nday" = 0 ] && [ "$_hh" -lt "$_nH" ] && continue
				for _mm in $TK_M; do
					[ "$_nday" = 0 ] && [ "$_hh" -eq "$_nH" ] && [ "$_mm" -le "$_nM" ] && continue
					printf '%04d-%02d-%02d %02d:%02d\n' "$_ny" "$_nm" "$_nd" "$_hh" "$_mm"
					_nf=$((_nf + 1)); [ "$_nf" -ge "$_nc" ] && return 0
				done
			done
		fi
		_nd=$((_nd + 1)); _nw=$(( (_nw + 1) % 7 )); _nday=$((_nday + 1))
		tk_dim "$_ny" "$_nm"
		if [ "$_nd" -gt "$TKD" ]; then _nd=1; _nm=$((_nm + 1)); [ "$_nm" -gt 12 ] && { _nm=1; _ny=$((_ny + 1)); }; fi
	done
	return 0
}
tk_next_json() {   # "<sched>" <count> -> JSON array of local times (empty array for no schedule / no run soon)
	[ -n "$1" ] || { printf '[]'; return 0; }
	tk_sched_parse "$1" || { printf '[]'; return 0; }
	printf '['; _nj=0
	for _nt in $(tk_next "$2" | tr ' ' '_'); do
		[ "$_nj" = 1 ] && printf ','; _nj=1; printf '"%s"' "$(printf '%s' "$_nt" | tr '_' ' ')"
	done
	printf ']'
}

# ---- crontab lines ----------------------------------------------------------------------------------------------
# tk_line_check <line> -> TKL = blank|comment|cron ; for cron: TKL_S (5 fields), TKL_C (command); TKE on invalid (rc 1)
tk_line_check() {
	TKL=""; TKL_S=""; TKL_C=""; TKE=""
	_lc=$(printf '%s' "$1" | sed 's/^[[:space:]]*//')
	case "$_lc" in
		'') TKL=blank; return 0 ;;
		'#'*) TKL=comment; return 0 ;;
		'@'*) TKE="@-сокращения busybox cron не понимает — нужны пять полей; «при загрузке» — настройка задачи"; return 1 ;;
	esac
	if printf '%s' "$_lc" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
		TKE="строки-переменные cron этого роутера не понимает — переменные задаются в настройках задачи"; return 1
	fi
	set -f; set -- $_lc; set +f
	[ "$#" -ge 6 ] || { TKE="нужны пять полей расписания и команда"; return 1; }
	TKL_S="$1 $2 $3 $4 $5"
	tk_sched_parse "$TKL_S" || return 1
	TKL_C=$(printf '%s' "$_lc" | sed 's/^\([^[:space:]][^[:space:]]*[[:space:]][[:space:]]*\)\{5\}//')
	[ -n "$TKL_C" ] || { TKE="нет команды"; return 1; }
	TKL=cron; return 0
}
# an Enodia line = the bootstrap or the code dir (the same test as uninstall.sh::cron_ours), but not a task line
tk_is_ours() { case "$1" in *"$TK_SIG"*) return 1 ;; *"$ENODIA_BOOT/boot.sh"*|*"$ENODIA_DIR/"*) return 0 ;; esac; return 1; }
tk_is_task() { case "$1" in *"$TK_SIG"*) return 0 ;; esac; return 1; }
restart_cron() {
	/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/crond restart >/dev/null 2>&1 \
		|| killall -HUP crond 2>/dev/null || true
}
# tk_cron_put <newfile> — replace the crontab if it changed (atomic: rename in /etc/crontabs), restart crond
tk_cron_put() {
	mkdir -p "${CRON%/*}" 2>/dev/null
	if [ -f "$CRON" ] && cmp -s "$1" "$CRON"; then rm -f "$1"; return 0; fi
	mv -f "$1" "$CRON" || { rm -f "$1"; return 1; }
	restart_cron; return 0
}
tk_each_line() {   # print the crontab line by line, the last line too even without a trailing newline
	[ -f "$CRON" ] || return 0
	while IFS= read -r _el || [ -n "$_el" ]; do printf '%s\n' "$_el"; done < "$CRON"
}

# ---- registry ---------------------------------------------------------------------------------------------------
tk_defaults() {
	T_NAME=""; T_ENABLED=1; T_KIND=script; T_LANG=sh; T_TARGET=""; T_ARGS=""; T_SCHED=""; T_BOOT=0; T_DELAY=60
	T_TIMEOUT=300; T_OVERLAP=skip; T_PRIO=low; T_CLOCK=1; T_WORKDIR=""; T_KEEP=5; T_MAIL=fail; T_JOURNAL=0
}
tk_load() {   # tk_load <id> -> T_* ; rc 1 when there is no such task
	tk_defaults
	[ -f "$TK_DIR/$1.task" ] || return 1
	while IFS= read -r _tl || [ -n "$_tl" ]; do
		_tv=${_tl#*=}
		case "${_tl%%=*}" in
			name) T_NAME=$_tv ;; enabled) T_ENABLED=$_tv ;; kind) T_KIND=$_tv ;; lang) T_LANG=$_tv ;;
			target) T_TARGET=$_tv ;; args) T_ARGS=$_tv ;; sched) T_SCHED=$_tv ;; boot) T_BOOT=$_tv ;; delay) T_DELAY=$_tv ;;
			timeout) T_TIMEOUT=$_tv ;; overlap) T_OVERLAP=$_tv ;; prio) T_PRIO=$_tv ;; clockwait) T_CLOCK=$_tv ;;
			workdir) T_WORKDIR=$_tv ;; keep) T_KEEP=$_tv ;; mail) T_MAIL=$_tv ;; journal) T_JOURNAL=$_tv ;;
		esac
	done < "$TK_DIR/$1.task"
	return 0
}
tk_write() {   # tk_write <id> — registry file atomically (write next to it + mv)
	mkdir -p "$TK_DIR" 2>/dev/null
	{ printf 'name=%s\nenabled=%s\nkind=%s\nlang=%s\ntarget=%s\nargs=%s\nsched=%s\nboot=%s\ndelay=%s\n' \
		"$T_NAME" "$T_ENABLED" "$T_KIND" "$T_LANG" "$T_TARGET" "$T_ARGS" "$T_SCHED" "$T_BOOT" "$T_DELAY"
	  printf 'timeout=%s\noverlap=%s\nprio=%s\nclockwait=%s\nworkdir=%s\nkeep=%s\nmail=%s\njournal=%s\n' \
		"$T_TIMEOUT" "$T_OVERLAP" "$T_PRIO" "$T_CLOCK" "$T_WORKDIR" "$T_KEEP" "$T_MAIL" "$T_JOURNAL"; } > "$TK_DIR/$1.task.new" \
		&& mv -f "$TK_DIR/$1.task.new" "$TK_DIR/$1.task"
}
tk_ids() { for _f in "$TK_DIR"/t*.task; do [ -f "$_f" ] || continue; _b=${_f##*/}; echo "${_b%.task}"; done | sed 's/^t//' | sort -n | sed 's/^/t/'; }
tk_new_id() { _ni=$(tk_ids | sed 's/^t//' | tail -n 1); echo "t$(( ${_ni:-0} + 1 ))"; }

# apply: our task lines rewritten from the registry, every other line kept in place and order (call under the lock)
tk_apply() {
	_ta="$CRON.tk.$$"
	{ tk_each_line | grep -vF "$TK_SIG"
	  for _ai in $(tk_ids); do
		tk_load "$_ai" || continue
		[ "$T_ENABLED" = 1 ] && [ -n "$T_SCHED" ] || continue
		printf '%s %s tasks.sh run %s sched >/dev/null 2>&1\n' "$T_SCHED" "$CRON_RUN" "$_ai"
	  done; } > "$_ta"
	tk_cron_put "$_ta"
}

# ---- interpreters -----------------------------------------------------------------------------------------------
tk_langs() { printf '"sh"'; command -v lua >/dev/null 2>&1 && printf ',"lua"'; return 0; }
# tk_interp <file> <lang> -> TKI = interpreter command line part ("sh", "lua", shebang); TKE when unusable
tk_interp() {
	TKI=""; TKE=""
	case "$2" in
		sh) TKI=sh ;;
		lua) command -v lua >/dev/null 2>&1 || { TKE="Lua на этом роутере нет"; return 1; }; TKI=lua ;;
		*)  _sb=$(head -n 1 "$1" 2>/dev/null | tr -d '\r')
		    case "$_sb" in
			'#!'*) _sb=$(printf '%s' "$_sb" | sed 's/^#![[:space:]]*//'); set -f; set -- $_sb; set +f
			       [ -n "$1" ] || { TKE="в строке #! нет интерпретатора"; return 1; }
			       [ -x "$1" ] || command -v "$1" >/dev/null 2>&1 || { TKE="интерпретатора из строки #! на роутере нет: $1"; return 1; }
			       TKI="$*" ;;
			*) TKI=sh ;;
		    esac ;;
	esac
	return 0
}
# tk_syntax <file> -> TKE with the interpreter's own words on a syntax error (sh -n / Lua loadfile); others unchecked
tk_syntax() {
	tk_interp "$1" "$2" || return 1
	case "${TKI%% *}" in
		sh|*/sh|ash|*/ash|bash|*/bash) _se=$(sh -n "$1" 2>&1) || { TKE="ошибка синтаксиса: $(printf '%s' "$_se" | sed "s#$1: ##" | head -n 3)"; return 1; } ;;
		lua|*/lua) _se=$(lua -e "local f,e=loadfile('$1') if not f then io.stderr:write(e) os.exit(1) end" 2>&1) \
		           || { TKE="ошибка синтаксиса: $(printf '%s' "$_se" | sed "s#$1:#строка #" | head -n 3)"; return 1; } ;;
	esac
	return 0
}

# ---- JSON views -------------------------------------------------------------------------------------------------
tk_hist_last() {   # tk_hist_last <id> -> TH_* of the last history line; rc 1 when none
	_hl=$(tail -n 1 "$TK_RUN/$1.hist" 2>/dev/null)
	[ -n "$_hl" ] || return 1
	TH_TS=$(printf '%s' "$_hl" | cut -f1); TH_DUR=$(printf '%s' "$_hl" | cut -f2); TH_CODE=$(printf '%s' "$_hl" | cut -f3)
	TH_TRIG=$(printf '%s' "$_hl" | cut -f4); TH_FLAG=$(printf '%s' "$_hl" | cut -f6)
	return 0
}
# tk_running_json <id> [out] -> {"since":..,"trig":..,"dur":..[,"out":..]} | null — by the runner's pid, not by a stale file.
# dur comes from the uptime the runner noted (a clock step after boot would lie). `out` = the output SO FAR (the task screen
# follows it; without it the screen said «running» above «no runs» for the whole run) — not in the list: 32 KB per task.
tk_running_json() {
	_rc=$(cat "$TK_RUN/$1.cur" 2>/dev/null)
	_rp=$(printf '%s' "$_rc" | cut -f3)
	if [ -n "$_rp" ] && [ -d "/proc/$_rp" ]; then
		_ru=$(uptime_s); _rd=$(( _ru - $(tk_num_or "$(printf '%s' "$_rc" | cut -f2)" "$_ru") )); [ "$_rd" -ge 0 ] || _rd=0
		printf '{"since":"%s","trig":"%s","dur":%s' "$(printf '%s' "$_rc" | cut -f1)" "$(printf '%s' "$_rc" | cut -f4)" "$_rd"
		if [ "$2" = out ]; then
			_rs=$(printf '%s' "$_rc" | cut -f5)
			case "$_rs" in ''|*[!0-9]*) printf ',"out":""' ;;
				*) printf ',"out":"%s"' "$(tail -c "$TK_OUT_KEEP" "$TK_RUN/$1.out.$_rs.run" 2>/dev/null | b64)" ;; esac
		fi
		printf '}'
	else printf 'null'; fi
}
tk_num_or() { case "$1" in ''|*[!0-9-]*) echo "$2" ;; *) echo "$1" ;; esac; }
cmd_list_json() {
	printf '{"ok":true,"now":"%s","langs":[%s],"tasks":[' "$(now_local)" "$(tk_langs)"
	_lf=1
	for _li in $(tk_ids); do
		tk_load "$_li" || continue
		[ "$_lf" = 1 ] || printf ','; _lf=0
		printf '{"id":"%s","name":"%s","enabled":%s,"kind":"%s","lang":"%s","sched":"%s","boot":%s,"next":%s' \
			"$_li" "$(jstr "$T_NAME" 120)" "$([ "$T_ENABLED" = 1 ] && echo true || echo false)" "$T_KIND" "$T_LANG" \
			"$T_SCHED" "$([ "$T_BOOT" = 1 ] && echo true || echo false)" \
			"$([ "$T_ENABLED" = 1 ] && tk_next_json "$T_SCHED" 1 || printf '[]')"
		if tk_hist_last "$_li"; then
			printf ',"last":{"ts":"%s","dur":%s,"code":%s,"trig":"%s","flag":"%s"}' "$TH_TS" "$(tk_num_or "$TH_DUR" 0)" \
				"$(tk_num_or "$TH_CODE" 0)" "$TH_TRIG" "$TH_FLAG"
		else printf ',"last":null'; fi
		printf ',"running":%s}' "$(tk_running_json "$_li")"
	done
	printf '],"ours":['
	_lf=1
	tk_rundir; TK_TMP="$TK_RUN/.list.$$"
	tk_each_line > "$TK_TMP"
	while IFS= read -r _ll || [ -n "$_ll" ]; do
		tk_is_ours "$_ll" || continue
		tk_line_check "$_ll" || continue
		[ "$TKL" = cron ] || continue
		_ls=$(printf '%s' "$TKL_C" | sed 's/[[:space:]]*[0-9]*>.*$//; s#^.*boot\.sh[[:space:]][[:space:]]*##; s#^[^[:space:]]*/##')
		[ "$_lf" = 1 ] || printf ','; _lf=0
		printf '{"sched":"%s","cmd":"%s"}' "$TKL_S" "$(jstr "$_ls" 120)"
	done < "$TK_TMP"
	printf '],"foreign":['
	_lf=1
	while IFS= read -r _ll || [ -n "$_ll" ]; do
		tk_is_task "$_ll" && continue
		tk_is_ours "$_ll" && continue
		_on=true; _bad=false; _lb=$_ll
		if tk_line_check "$_ll"; then
			case "$TKL" in
				blank) continue ;;
				comment)   # a commented-out VALID cron line is a disabled line; any other comment is just a comment
					_lu=$(printf '%s' "$_ll" | sed 's/^[[:space:]]*#[[:space:]]*//')
					tk_line_check "$_lu" && [ "$TKL" = cron ] || continue
					tk_is_task "$_lu" && continue; tk_is_ours "$_lu" && continue
					_on=false ;;
			esac
		else _bad=true; fi
		[ "$_lf" = 1 ] || printf ','; _lf=0
		printf '{"line":"%s","on":%s,"bad":%s}' "$(printf '%s' "$_lb" | b64)" "$_on" "$_bad"
	done < "$TK_TMP"
	printf ']}\n'
}
cmd_get_json() {
	id_ok "$1" && tk_load "$1" || jfail "такой задачи нет"
	_body=""; [ -f "$TK_DIR/$1.body" ] && _body=$(b64 < "$TK_DIR/$1.body")
	_env=""; [ -f "$TK_DIR/$1.env" ] && _env=$(b64 < "$TK_DIR/$1.env")
	printf '{"ok":true,"now":"%s","langs":[%s],"task":{"id":"%s","name":"%s","enabled":%s,"kind":"%s","lang":"%s",' \
		"$(now_local)" "$(tk_langs)" "$1" "$(jstr "$T_NAME" 120)" "$([ "$T_ENABLED" = 1 ] && echo true || echo false)" "$T_KIND" "$T_LANG"
	printf '"target":"%s","args":"%s","workdir":"%s","sched":"%s","boot":%s,"delay":%s,"timeout":%s,"overlap":"%s",' \
		"$(printf '%s' "$T_TARGET" | b64)" "$(printf '%s' "$T_ARGS" | b64)" "$(printf '%s' "$T_WORKDIR" | b64)" "$T_SCHED" \
		"$([ "$T_BOOT" = 1 ] && echo true || echo false)" "$(tk_num_or "$T_DELAY" 60)" "$(tk_num_or "$T_TIMEOUT" 300)" "$T_OVERLAP"
	printf '"prio":"%s","clockwait":%s,"keep":%s,"mail":"%s","journal":%s,"body":"%s","env":"%s"},' \
		"$T_PRIO" "$([ "$T_CLOCK" = 1 ] && echo true || echo false)" "$(tk_num_or "$T_KEEP" 5)" "$T_MAIL" \
		"$([ "$T_JOURNAL" = 1 ] && echo true || echo false)" "$_body" "$_env"
	printf '"next":%s,"running":%s,"runs":[' "$([ "$T_ENABLED" = 1 ] && tk_next_json "$T_SCHED" 3 || printf '[]')" "$(tk_running_json "$1" out)"
	_gf=1
	# newest first; a run's output is there only while its file lives (keep setting, RAM)
	TK_TMP="$TK_RUN/.hist.$$"
	[ -f "$TK_RUN/$1.hist" ] && sed '1!G;h;$!d' "$TK_RUN/$1.hist" > "$TK_TMP" 2>/dev/null
	if [ -f "$TK_TMP" ]; then
		while IFS= read -r _gl || [ -n "$_gl" ]; do
			[ -n "$_gl" ] || continue
			_gs=$(printf '%s' "$_gl" | cut -f5); _go=""; _gk=false   # kept = the file lives (an EMPTY output is still kept)
			case "$_gs" in ''|*[!0-9]*) ;; *) [ -f "$TK_RUN/$1.out.$_gs" ] && { _go=$(b64 < "$TK_RUN/$1.out.$_gs"); _gk=true; } ;; esac
			[ "$_gf" = 1 ] || printf ','; _gf=0
			printf '{"ts":"%s","dur":%s,"code":%s,"trig":"%s","flag":"%s","kept":%s,"out":"%s"}' "$(printf '%s' "$_gl" | cut -f1)" \
				"$(tk_num_or "$(printf '%s' "$_gl" | cut -f2)" 0)" "$(tk_num_or "$(printf '%s' "$_gl" | cut -f3)" 0)" \
				"$(printf '%s' "$_gl" | cut -f4)" "$(printf '%s' "$_gl" | cut -f6)" "$_gk" "$_go"
		done < "$TK_TMP"
	fi
	printf ']}\n'
}
cmd_explain() {
	tk_sched_parse "$1" || jfail "$TKE"
	printf '{"ok":true,"now":"%s","next":%s}\n' "$(now_local)" "$(tk_next_json "$1" 3)"
}

# ---- save / edit --------------------------------------------------------------------------------------------------
# spec = key=value lines from the CGI (enums/numbers as is, free text as base64 with the _b64 suffix). EVERY value is
# validated here: the owner checks, the CGI only carries.
cmd_save() {
	[ -f "$1" ] || jfail "нет данных задачи"
	_sid=""; _sbody=""; _senv=""; _srun=0; _snew=0
	tk_defaults; _sset=""
	while IFS= read -r _sl || [ -n "$_sl" ]; do
		_sv=${_sl#*=}
		case "${_sl%%=*}" in
			id) _sid=$_sv ;;
			run) _srun=$_sv ;;
			name_b64) T_NAME=$(b64d "$_sv" | tr -d '\000-\037' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') ;;
			enabled) T_ENABLED=$_sv ;; kind) T_KIND=$_sv ;; lang) T_LANG=$_sv ;;
			target_b64) T_TARGET=$(b64d "$_sv" | tr -d '\r') ;;
			args_b64) T_ARGS=$(b64d "$_sv" | tr -d '\r') ;;
			sched_b64) T_SCHED=$(b64d "$_sv" | tr -s ' \t' '  ' | sed 's/^ *//; s/ *$//') ;;
			boot) T_BOOT=$_sv ;; delay) T_DELAY=$_sv ;; timeout) T_TIMEOUT=$_sv ;; overlap) T_OVERLAP=$_sv ;;
			prio) T_PRIO=$_sv ;; clockwait) T_CLOCK=$_sv ;; keep) T_KEEP=$_sv ;; mail) T_MAIL=$_sv ;; journal) T_JOURNAL=$_sv ;;
			workdir_b64) T_WORKDIR=$(b64d "$_sv" | tr -d '\r') ;;
			body_b64) _sbody=$_sv; _sset="$_sset body" ;;
			env_b64) _senv=$_sv; _sset="$_sset env" ;;
		esac
	done < "$1"
	[ -n "$_sid" ] && { id_ok "$_sid" || jfail "неверный номер задачи"; }
	[ -n "$T_NAME" ] || jfail "введите название задачи"
	[ "${#T_NAME}" -le 240 ] || jfail "название длиннее 80 знаков"
	case "$T_ENABLED$T_BOOT$T_CLOCK$T_JOURNAL" in *[!01]*) jfail "неверные данные задачи" ;; esac
	[ "${#T_ENABLED}${#T_BOOT}${#T_CLOCK}${#T_JOURNAL}" = 1111 ] || jfail "неверные данные задачи"
	case "$T_KIND" in script|file|cmd) ;; *) jfail "неверный вид задачи" ;; esac
	case "$T_LANG" in sh|lua|auto) ;; *) jfail "неверный язык" ;; esac
	case "$T_OVERLAP" in skip|wait|par) ;; *) jfail "неверная настройка наложения" ;; esac
	case "$T_PRIO" in normal|low) ;; *) jfail "неверный приоритет" ;; esac
	case "$T_MAIL" in never|fail|always) ;; *) jfail "неверная настройка писем" ;; esac
	case "$T_KEEP" in 0|1|5) ;; *) jfail "неверная настройка вывода" ;; esac
	case "$T_DELAY" in ''|*[!0-9]*) jfail "задержка — число секунд" ;; esac
	[ "$T_DELAY" -le 3600 ] || jfail "задержка — не больше 3600 секунд"
	case "$T_TIMEOUT" in ''|*[!0-9]*) jfail "ограничение по времени — число секунд" ;; esac
	[ "$T_TIMEOUT" -le 86400 ] || jfail "ограничение по времени — не больше суток"
	if [ -n "$T_SCHED" ]; then tk_sched_parse "$T_SCHED" || jfail "расписание: $TKE"; fi
	case "$T_WORKDIR" in ''|/*) ;; *) jfail "рабочий каталог — полный путь, от /" ;; esac
	[ "$(printf '%s' "$T_WORKDIR$T_TARGET$T_ARGS" | wc -l)" -eq 0 ] || jfail "путь, команда и аргументы — одной строкой"
	tk_rundir || jfail "не удалось создать каталог задач в памяти"
	_stmp="$TK_RUN/.save.$$"; rm -rf "$_stmp"; ( umask 077; mkdir "$_stmp" ) || jfail "не удалось создать временный каталог"
	TK_TMP=$_stmp
	case "$T_KIND" in
		script)
			T_TARGET=""; T_ARGS=""
			b64d "$_sbody" | tr -d '\r' > "$_stmp/body"
			[ -s "$_stmp/body" ] || jfail "скрипт пустой"
			[ "$(wc -c < "$_stmp/body")" -le "$TK_BODY_MAX" ] || jfail "скрипт больше 16 КБ"
			[ -n "$(tail -c 1 "$_stmp/body")" ] && echo >> "$_stmp/body"   # a last line without \n is lost by `read`
			tk_syntax "$_stmp/body" "$T_LANG" || jfail "$TKE" ;;
		file)
			case "$T_TARGET" in /*) ;; *) jfail "путь к файлу — полный, от /" ;; esac
			[ -f "$T_TARGET" ] || jfail "файла нет: $T_TARGET"
			tk_interp "$T_TARGET" "$T_LANG" || jfail "$TKE" ;;
		cmd)
			T_ARGS=""
			[ -n "$(printf '%s' "$T_TARGET" | tr -d ' \t')" ] || jfail "введите команду"
			[ "${#T_TARGET}" -le 2000 ] || jfail "команда длиннее 2000 знаков — сделайте её скриптом" ;;
	esac
	case "$_sset" in *env*)
		b64d "$_senv" | tr -d '\r' | sed '/^[[:space:]]*$/d' > "$_stmp/env"
		[ "$(wc -c < "$_stmp/env")" -le 4096 ] || jfail "переменных больше 4 КБ"
		_bad=$(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' "$_stmp/env" | head -n 1)
		[ -z "$_bad" ] || jfail "переменная — ИМЯ=значение, латиницей: $_bad" ;;
	esac
	tk_lock
	if [ -z "$_sid" ]; then _sid=$(tk_new_id); _snew=1
	else [ -f "$TK_DIR/$_sid.task" ] || jfail "такой задачи нет — её удалили, пока вы правили"; fi
	mkdir -p "$TK_DIR" 2>/dev/null
	if [ "$T_KIND" = script ]; then mv -f "$_stmp/body" "$TK_DIR/$_sid.body"; else rm -f "$TK_DIR/$_sid.body"; fi
	case "$_sset" in *env*) if [ -s "$_stmp/env" ]; then mv -f "$_stmp/env" "$TK_DIR/$_sid.env"; else rm -f "$TK_DIR/$_sid.env"; fi ;; esac
	tk_write "$_sid" || jfail "не удалось записать задачу на флеш"
	tk_apply || jfail "задача сохранена, но расписание не записалось (crontab)"
	tk_unlock
	[ "$_srun" = 1 ] && cmd_run_bg "$_sid" quiet
	jok "\"id\":\"$_sid\",\"new\":$([ "$_snew" = 1 ] && echo true || echo false),\"msg\":\"$([ "$_snew" = 1 ] && echo 'задача создана' || echo 'задача сохранена')$([ "$_srun" = 1 ] && echo ' и запущена')\""
}
cmd_del() {
	id_ok "$1" && [ -f "$TK_DIR/$1.task" ] || jfail "такой задачи нет"
	tk_rundir && : > "$TK_RUN/$1.stop"   # a running copy stops itself (the runner reads the flag)
	tk_lock
	rm -f "$TK_DIR/$1.task" "$TK_DIR/$1.body" "$TK_DIR/$1.env"
	tk_apply || jfail "задача удалена, но расписание не записалось (crontab)"
	tk_unlock
	( sleep 3; rm -f "$TK_RUN/$1".* ) >/dev/null 2>&1 &
	jok '"msg":"задача удалена"'
}
cmd_toggle() {
	case "$2" in on|off) ;; *) jfail "неверное действие" ;; esac
	id_ok "$1" || jfail "такой задачи нет"
	tk_lock
	tk_load "$1" || jfail "такой задачи нет"
	if [ "$2" = on ]; then T_ENABLED=1; else T_ENABLED=0; fi
	tk_write "$1" && tk_apply || jfail "не удалось записать задачу"
	tk_unlock
	jok "\"msg\":\"$([ "$T_ENABLED" = 1 ] && echo 'задача включена' || echo 'задача выключена')\""
}
cmd_dup() {   # a copy is born DISABLED: two identical tasks running side by side is never what a click on «copy» meant
	id_ok "$1" && tk_load "$1" || jfail "такой задачи нет"
	tk_lock
	_nid=$(tk_new_id); tk_load "$1"
	T_NAME="$T_NAME (копия)"; T_ENABLED=0
	[ -f "$TK_DIR/$1.body" ] && cp "$TK_DIR/$1.body" "$TK_DIR/$_nid.body"
	[ -f "$TK_DIR/$1.env" ] && cp "$TK_DIR/$1.env" "$TK_DIR/$_nid.env"
	tk_write "$_nid" || jfail "не удалось записать копию"
	tk_unlock
	jok "\"id\":\"$_nid\",\"msg\":\"копия создана выключенной\""
}

# ---- foreign lines ------------------------------------------------------------------------------------------------
tk_lines_without() {   # the crontab without the FIRST exact match of $1
	_wd=0
	tk_each_line | while IFS= read -r _wl || [ -n "$_wl" ]; do
		if [ "$_wd" = 0 ] && [ "$_wl" = "$1" ]; then _wd=1; continue; fi
		printf '%s\n' "$_wl"
	done
}
# tk_line_find <line> -> rc 0 when the crontab has this exact line
tk_line_find() { tk_each_line | grep -qxF -- "$1"; }
tk_line_guard() {   # refuse lines this owner does not own: tasks (edit the task) and Enodia (their owners rewrite them)
	tk_is_task "$1" && jfail "это строка задачи — меняйте саму задачу"
	tk_is_ours "$1" && jfail "строки Enodia меняет их владелец — расписание правится на их экране"
	return 0
}
# tk_line_replace <old> <new|""> -> new crontab with the FIRST exact match replaced (empty = removed)
tk_line_replace() {
	_rt="$CRON.tk.$$"; _rdone=0
	tk_each_line > "$_rt.src"
	while IFS= read -r _rl || [ -n "$_rl" ]; do
		if [ "$_rdone" = 0 ] && [ "$_rl" = "$1" ]; then
			_rdone=1; [ -n "$2" ] && printf '%s\n' "$2"
		else printf '%s\n' "$_rl"; fi
	done < "$_rt.src" > "$_rt"
	rm -f "$_rt.src"
	[ "$_rdone" = 1 ] || { rm -f "$_rt"; return 1; }
	tk_cron_put "$_rt"
}
cmd_line_set() {
	_old=$(b64d "$1"); _new=$(b64d "$2" | tr -d '\r\n')
	[ -n "$_old" ] || jfail "нет строки"
	tk_line_guard "$_old"
	if [ -n "$_new" ]; then
		tk_line_check "$_new" || jfail "$TKE"
		case "$TKL" in cron|comment) ;; *) jfail "пустая строка — для удаления есть своя кнопка" ;; esac
		tk_is_task "$_new" && jfail "строку задачи так не завести — создайте задачу"
	fi
	tk_lock
	tk_line_find "$_old" || jfail "строка изменилась с тех пор, как вы открыли экран — обновите его"
	tk_line_replace "$_old" "$_new" || jfail "не удалось записать crontab"
	tk_unlock
	jok "\"msg\":\"$([ -n "$_new" ] && echo 'строка сохранена' || echo 'строка удалена')\",\"line\":\"$(printf '%s' "$_new" | b64)\""
}
cmd_line_toggle() {
	_old=$(b64d "$1"); [ -n "$_old" ] || jfail "нет строки"
	tk_line_guard "$_old"
	case "$(printf '%s' "$_old" | sed 's/^[[:space:]]*//')" in
		'#'*) _new=$(printf '%s' "$_old" | sed 's/^[[:space:]]*#[[:space:]]*//')
		      tk_line_check "$_new" && [ "$TKL" = cron ] || jfail "после снятия «#» строка не годится: $TKE"
		      tk_line_guard "$_new"; _what='строка включена' ;;
		*) _new="# $_old"; _what='строка выключена' ;;
	esac
	tk_lock
	tk_line_find "$_old" || jfail "строка изменилась с тех пор, как вы открыли экран — обновите его"
	tk_line_replace "$_old" "$_new" || jfail "не удалось записать crontab"
	tk_unlock
	jok "\"msg\":\"$_what\",\"line\":\"$(printf '%s' "$_new" | b64)\""
}
# adopt: a foreign line becomes a task (kind=cmd, same schedule and command, disabled if the line was) — the line is
# replaced by the task's line in the SAME crontab write, so there is no minute where both or neither run.
cmd_adopt() {
	_old=$(b64d "$1"); [ -n "$_old" ] || jfail "нет строки"
	tk_line_guard "$_old"
	_aon=1; _al=$_old
	case "$(printf '%s' "$_old" | sed 's/^[[:space:]]*//')" in '#'*) _aon=0; _al=$(printf '%s' "$_old" | sed 's/^[[:space:]]*#[[:space:]]*//') ;; esac
	tk_line_check "$_al" && [ "$TKL" = cron ] || jfail "строку не разобрать: $TKE"
	tk_defaults
	T_KIND=cmd; T_TARGET=$TKL_C; T_SCHED=$TKL_S; T_ENABLED=$_aon; T_TIMEOUT=0; T_PRIO=normal
	T_NAME=$(printf '%s' "$TKL_C" | sed 's/^.*&&[[:space:]]*//; s/[[:space:]].*$//; s#^.*/##')
	[ -n "$T_NAME" ] || T_NAME="задача из crontab"
	tk_lock
	tk_line_find "$_old" || jfail "строка изменилась с тех пор, как вы открыли экран — обновите его"
	_aid=$(tk_new_id)
	tk_write "$_aid" || jfail "не удалось записать задачу"
	_at="$CRON.tk.$$"
	{ tk_lines_without "$_old" | grep -vF "$TK_SIG"
	  for _ai in $(tk_ids); do
		tk_load "$_ai" || continue
		[ "$T_ENABLED" = 1 ] && [ -n "$T_SCHED" ] || continue
		printf '%s %s tasks.sh run %s sched >/dev/null 2>&1\n' "$T_SCHED" "$CRON_RUN" "$_ai"
	  done; } > "$_at"
	tk_cron_put "$_at" || { rm -f "$TK_DIR/$_aid.task"; jfail "не удалось записать crontab"; }
	tk_unlock
	jok "\"id\":\"$_aid\",\"msg\":\"строка стала задачей\""
}
cmd_raw_get() { printf '{"ok":true,"text":"%s"}\n' "$(tk_each_line | b64)"; }
cmd_raw_save() {
	[ -f "$1" ] || jfail "нет текста"
	tk_rundir || jfail "не удалось создать каталог задач в памяти"
	_rw="$TK_RUN/.raw.$$"; TK_TMP=$_rw
	base64 -d < "$1" 2>/dev/null | tr -d '\r' > "$_rw"
	[ "$(wc -c < "$_rw")" -le 65536 ] || { rm -f "$_rw"; jfail "файл больше 64 КБ"; }
	_rn=0
	while IFS= read -r _rl || [ -n "$_rl" ]; do
		_rn=$((_rn + 1))
		tk_line_check "$_rl" || { rm -f "$_rw"; jfail "строка $_rn: $TKE" "\"line\":$_rn"; }
	done < "$_rw"
	[ -n "$(tail -c 1 "$_rw")" ] && echo >> "$_rw"
	tk_lock
	cp "$_rw" "$CRON.tk.$$"
	tk_cron_put "$CRON.tk.$$" || jfail "не удалось записать crontab"
	tk_unlock
	jok '"msg":"crontab сохранён"'
}

# ---- «open and edit the file» --------------------------------------------------------------------------------------
cmd_file_get() {
	case "$1" in /*) ;; *) jfail "путь — полный, от /" ;; esac
	[ -f "$1" ] || jfail "файла нет: $1"
	_fs=$(wc -c < "$1" | tr -d ' '); [ "$_fs" -le "$TK_FILE_MAX" ] || jfail "файл больше 64 КБ — правьте его по SSH"
	[ "$(tr -d '\000' < "$1" | wc -c | tr -d ' ')" = "$_fs" ] || jfail "файл не текстовый"
	printf '{"ok":true,"size":%s,"text":"%s"}\n' "$_fs" "$(b64 < "$1")"
}
cmd_file_put() {
	case "$1" in /*) ;; *) jfail "путь — полный, от /" ;; esac
	[ -f "$1" ] || jfail "файла нет: $1"
	[ -f "$2" ] || jfail "нет текста"
	_ft="$1.enodia-new.$$"
	base64 -d < "$2" 2>/dev/null | tr -d '\r' > "$_ft" || { rm -f "$_ft"; jfail "не удалось записать файл"; }
	[ "$(wc -c < "$_ft")" -le "$TK_FILE_MAX" ] || { rm -f "$_ft"; jfail "файл больше 64 КБ"; }
	cp -p "$1" "$1.bak" 2>/dev/null
	chmod --reference="$1" "$_ft" 2>/dev/null || chmod "$(stat -c %a "$1" 2>/dev/null || echo 644)" "$_ft" 2>/dev/null
	mv -f "$_ft" "$1" || { rm -f "$_ft"; jfail "не удалось записать файл"; }
	jok '"msg":"файл сохранён, прежняя версия — рядом с суффиксом .bak"'
}

# ---- runner -------------------------------------------------------------------------------------------------------
tk_hist_add() {   # <id> <ts> <dur> <code> <trig> <seq> <flag> — RAM history, last 20 lines
	tk_rundir || return 0
	case "$7" in skip-*) [ "$(tail -n 1 "$TK_RUN/$1.hist" 2>/dev/null | cut -f6)" = "$7" ] && sed -i '$d' "$TK_RUN/$1.hist" ;; esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >> "$TK_RUN/$1.hist"
	tail -n 20 "$TK_RUN/$1.hist" > "$TK_RUN/$1.hist.new" 2>/dev/null && mv -f "$TK_RUN/$1.hist.new" "$TK_RUN/$1.hist"
}
tk_kill_tree() { _kt=$(proc_tree "$1"); kill -TERM $_kt 2>/dev/null; sleep 1; kill -KILL $_kt 2>/dev/null; return 0; }
# alive = a process that is not a zombie: our finished background child stays in /proc as Z until `wait`
tk_alive() { [ -d "/proc/$1" ] && [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]; }
tk_notify() {   # <id> <ok|fail> <ts> <dur> <code> <flag> <trig> <outfile>
	_nk="task-$2-$1"
	if [ "$2" = fail ]; then
		case "$T_MAIL" in fail|always) _nhow=mail ;; *) _nhow=journal ;; esac
	else
		case "$T_MAIL" in always) _nhow=mail ;; *) [ "$T_JOURNAL" = 1 ] && _nhow=journal || return 0 ;; esac
	fi
	NF_LANG=ru
	if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; command -v nf_lang >/dev/null 2>&1 && NF_LANG=$(nf_lang); fi
	_ntail=$(tail -n 15 "$8" 2>/dev/null)
	case "$6" in killed) _nwhy=$( [ "$NF_LANG" = en ] && echo "stopped by the time limit" || echo "оборвана по ограничению времени") ;;
		cut) _nwhy=$( [ "$NF_LANG" = en ] && echo "output over 512 KB — the run was cut" || echo "вывод больше 512 КБ — оборвана") ;;
		nodir) _nwhy=$( [ "$NF_LANG" = en ] && echo "no working directory" || echo "нет рабочего каталога") ;;
		*) _nwhy="" ;; esac
	if [ "$NF_LANG" = en ]; then
		_ntitle="BE7000: task «$T_NAME» $([ "$2" = fail ] && echo failed || echo done)"
		_ntext="Task «$T_NAME» ($1), started $3 ($7): exit code $5, $4 s${_nwhy:+, $_nwhy}.
${_ntail:+Output (last lines):
$_ntail}"
	else
		_ntitle="BE7000: задача «$T_NAME» $([ "$2" = fail ] && echo 'не удалась' || echo 'выполнена')"
		_ntext="Задача «$T_NAME» ($1), запуск $3 ($7): код выхода $5, $4 с${_nwhy:+, $_nwhy}.
${_ntail:+Вывод (последние строки):
$_ntail}"
	fi
	_nthr=0; [ "$2" = fail ] && _nthr=3600   # a task failing every minute must not send 60 letters an hour
	if [ "$_nhow" = mail ] && [ -f "$ENODIA_DIR/notify-event.sh" ]; then
		sh "$ENODIA_DIR/notify-event.sh" "$_nk" "$_nthr" "$_ntitle" "$_ntext" >/dev/null 2>&1
	elif [ -f "$ENODIA_DIR/events.sh" ]; then
		sh "$ENODIA_DIR/events.sh" add "$_nk" "$_nthr" "$_ntitle" "$_ntext" >/dev/null 2>&1
	fi
	return 0
}
cmd_run() {
	_id=$1; _trig=${2:-manual}
	id_ok "$_id" && tk_load "$_id" || exit 1
	case "$_trig" in sched|boot|manual) ;; *) _trig=manual ;; esac
	[ "$_trig" != manual ] && [ "$T_ENABLED" != 1 ] && exit 0
	tk_rundir || exit 1
	_ts=$(date '+%Y-%m-%d %H:%M:%S')
	if [ "$_trig" = sched ] && [ "$T_CLOCK" = 1 ] && ! clock_sane; then
		tk_hist_add "$_id" "$_ts" 0 0 "$_trig" - skip-clock; exit 0
	fi
	# overlap: the lock is a directory with the runner's pid; a dead holder's lock is taken over
	_lk="$TK_RUN/$_id.lock"; _mine=0
	if [ "$T_OVERLAP" != par ]; then
		_ww=0
		while :; do
			if mkdir "$_lk" 2>/dev/null; then echo $$ > "$_lk/pid"; _mine=1; break; fi
			_lp=$(cat "$_lk/pid" 2>/dev/null)
			if [ -z "$_lp" ] || [ ! -d "/proc/$_lp" ]; then rm -rf "$_lk" 2>/dev/null; continue; fi
			if [ "$T_OVERLAP" = skip ]; then tk_hist_add "$_id" "$_ts" 0 0 "$_trig" - skip-busy; exit 0; fi
			_ww=$((_ww + 2)); [ "$_ww" -gt 86400 ] && exit 0
			sleep 2
		done
	fi
	_seq=$(( $(cat "$TK_RUN/$_id.seq" 2>/dev/null || echo 0) + 1 )); echo "$_seq" > "$TK_RUN/$_id.seq"
	_out="$TK_RUN/$_id.out.$_seq"; _rcf="$TK_RUN/$_id.rc.$_seq"; rm -f "$TK_RUN/$_id.stop" "$_rcf"
	trap 'rm -f "$TK_RUN/$_id.cur" "$_rcf" "$_out.run"; [ "$_mine" = 1 ] && rm -rf "$_lk"' EXIT
	trap 'exit 1' INT TERM HUP PIPE
	# what to execute: one command line for `sh -c` — the user's own shell syntax around a quoted file path
	case "$T_KIND" in
		script) tk_interp "$TK_DIR/$_id.body" "$T_LANG" || { printf '%s\n' "$TKE" > "$_out"; tk_hist_add "$_id" "$_ts" 0 127 "$_trig" "$_seq" err; tk_notify "$_id" fail "$_ts" 0 127 err "$_trig" "$_out"; exit 0; }
		        _cl="$TKI $(tk_sq "$TK_DIR/$_id.body")" ;;
		file)   tk_interp "$T_TARGET" "$T_LANG" || { printf '%s\n' "$TKE" > "$_out"; tk_hist_add "$_id" "$_ts" 0 127 "$_trig" "$_seq" err; tk_notify "$_id" fail "$_ts" 0 127 err "$_trig" "$_out"; exit 0; }
		        _cl="$TKI $(tk_sq "$T_TARGET")${T_ARGS:+ $T_ARGS}" ;;
		*)      _cl=$T_TARGET ;;
	esac
	_wd=${T_WORKDIR:-/tmp}; _nice=""; [ "$T_PRIO" = low ] && command -v nice >/dev/null 2>&1 && _nice="nice -n 19"
	_up0=$(uptime_s)
	(
		cd "$_wd" 2>/dev/null || { echo "нет рабочего каталога: $_wd"; echo 126 > "$_rcf"; exit 126; }
		if [ -f "$TK_DIR/$_id.env" ]; then
			while IFS= read -r _ev || [ -n "$_ev" ]; do case "$_ev" in [A-Za-z_]*=*) export "$_ev" ;; esac; done < "$TK_DIR/$_id.env"
		fi
		$_nice sh -c "$_cl" </dev/null; echo $? > "$_rcf"
	) > "$_out.run" 2>&1 &
	_wp=$!
	printf '%s\t%s\t%s\t%s\t%s\n' "$_ts" "$_up0" "$$" "$_trig" "$_seq" > "$TK_RUN/$_id.cur"
	_flag=""
	while [ ! -s "$_rcf" ]; do
		if [ -e "$TK_RUN/$_id.stop" ]; then _flag=stopped; tk_kill_tree "$_wp"; break; fi
		if [ "$T_TIMEOUT" -gt 0 ] 2>/dev/null && [ $(( $(uptime_s) - _up0 )) -ge "$T_TIMEOUT" ]; then _flag=killed; tk_kill_tree "$_wp"; break; fi
		if [ "$(wc -c < "$_out.run" 2>/dev/null)" -gt "$TK_OUT_CAP" ] 2>/dev/null; then _flag=cut; tk_kill_tree "$_wp"; break; fi
		tk_alive "$_wp" || { sleep 1; [ -s "$_rcf" ] || { _flag=err; break; }; }
		sleep 1
	done
	wait "$_wp" 2>/dev/null
	_code=$(cat "$_rcf" 2>/dev/null | tr -d ' \r\n'); case "$_code" in ''|*[!0-9]*) _code=143 ;; esac
	_dur=$(( $(uptime_s) - _up0 ))
	[ "$_code" = 126 ] && grep -q '^нет рабочего каталога' "$_out.run" 2>/dev/null && _flag=nodir
	[ -n "$_flag" ] || { [ "$_code" = 0 ] && _flag=ok || _flag=err; }
	tail -c "$TK_OUT_KEEP" "$_out.run" > "$_out" 2>/dev/null; rm -f "$_out.run"
	tk_hist_add "$_id" "$_ts" "$_dur" "$_code" "$_trig" "$_seq" "$_flag"
	# outputs: the newest N of this task (keep setting; 0 = none), the rest goes
	_kp=$(tk_num_or "$T_KEEP" 5); _kk=$_kp; [ "$_kk" -ge 1 ] || _kk=1   # the current one stays for the letter
	for _of in "$TK_RUN/$_id".out.*; do
		[ -f "$_of" ] || continue
		_os=${_of##*.}; case "$_os" in ''|*[!0-9]*) continue ;; esac
		[ "$_os" -le $((_seq - _kk)) ] && rm -f "$_of"
	done
	case "$_flag" in
		ok) tk_notify "$_id" ok "$_ts" "$_dur" "$_code" "$_flag" "$_trig" "$_out" ;;
		stopped) ;;   # the human pressed «stop» — not news for them
		*) tk_notify "$_id" fail "$_ts" "$_dur" "$_code" "$_flag" "$_trig" "$_out" ;;
	esac
	[ "$_kp" = 0 ] && rm -f "$_out"
	exit 0
}
# background start for the panel and boot: start-stop-daemon -b (no nohup/setsid here), -m -p MANDATORY (else -x /bin/sh
# matches every sh); `quiet` = called from save, which prints its own JSON
cmd_run_bg() {
	id_ok "$1" && [ -f "$TK_DIR/$1.task" ] || { [ "$2" = quiet ] && return 0; jfail "такой задачи нет"; }
	tk_rundir || { [ "$2" = quiet ] && return 0; jfail "не удалось создать каталог задач в памяти"; }
	_bp="$TK_RUN/$1.bg.pid"
	if [ -s "$TK_RUN/$1.cur" ] && _bc=$(cut -f3 "$TK_RUN/$1.cur") && [ -n "$_bc" ] && [ -d "/proc/$_bc" ]; then
		[ "$2" = quiet ] && return 0; jfail "задача уже выполняется"
	fi
	rm -f "$_bp"
	start-stop-daemon -S -b -m -p "$_bp" -x /bin/sh -- "$ENODIA_DIR/tasks.sh" run "$1" "${3:-manual}" >/dev/null 2>&1 \
		|| ( sh "$ENODIA_DIR/tasks.sh" run "$1" "${3:-manual}" >/dev/null 2>&1 & )
	[ "$2" = quiet ] && return 0
	jok '"msg":"задача запущена"'
}
cmd_stop() {
	id_ok "$1" || jfail "такой задачи нет"
	_sc=$(cut -f3 "$TK_RUN/$1.cur" 2>/dev/null)
	[ -n "$_sc" ] && [ -d "/proc/$_sc" ] || jfail "задача сейчас не выполняется"
	: > "$TK_RUN/$1.stop"
	jok '"msg":"останавливаю задачу"'
}
cmd_boot() {   # heal.sh at boot: every enabled task with «at boot» — each in its own background with its own delay
	for _bi in $(tk_ids); do
		tk_load "$_bi" || continue
		[ "$T_ENABLED" = 1 ] && [ "$T_BOOT" = 1 ] || continue
		tk_rundir || return 0; rm -f "$TK_RUN/$_bi.boot.pid"
		start-stop-daemon -S -b -m -p "$TK_RUN/$_bi.boot.pid" -x /bin/sh -- "$ENODIA_DIR/tasks.sh" run-delayed "$_bi" "$(tk_num_or "$T_DELAY" 60)" >/dev/null 2>&1
		echo "задача $_bi «$T_NAME»: запуск через $(tk_num_or "$T_DELAY" 60) с"
	done
	return 0
}

case "$1" in run|run-delayed) ;; *) trap tk_exit EXIT; trap 'exit 1' INT TERM HUP PIPE ;; esac
case "$1" in
	list-json)   cmd_list_json ;;
	get-json)    cmd_get_json "$2" ;;
	explain)     cmd_explain "$2" ;;
	raw-get)     cmd_raw_get ;;
	save)        cmd_save "$2" ;;
	del)         cmd_del "$2" ;;
	toggle)      cmd_toggle "$2" "$3" ;;
	dup)         cmd_dup "$2" ;;
	run-bg)      cmd_run_bg "$2" ;;
	stop)        cmd_stop "$2" ;;
	line-set)    cmd_line_set "$2" "$3" ;;
	line-toggle) cmd_line_toggle "$2" ;;
	adopt)       cmd_adopt "$2" ;;
	raw-save)    cmd_raw_save "$2" ;;
	file-get)    cmd_file_get "$2" ;;
	file-put)    cmd_file_put "$2" "$3" ;;
	apply)       tk_lock; tk_apply; tk_unlock ;;
	boot)        cmd_boot ;;
	run)         cmd_run "$2" "$3" ;;
	run-delayed) case "$3" in ''|*[!0-9]*) ;; *) sleep "$3" ;; esac; cmd_run "$2" boot ;;
	*) echo "usage: tasks.sh list-json|get-json <id>|explain \"<m h dom mon dow>\"|raw-get|save <spec>|del|toggle|dup|run-bg|stop <id>|line-set|line-toggle|adopt|raw-save|file-get|file-put|apply|boot|run <id> <trigger>" >&2
	   exit 2 ;;
esac
