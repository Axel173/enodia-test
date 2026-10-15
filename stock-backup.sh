#!/bin/sh
# stock-backup.sh — THE STOCK SETTINGS BACKUP («копия настроек прошивки»): see it, turn it off (freeing the flash), turn it back
# on. The ONLY owner of this stock feature in the project: the panel (cgi-bin/data `stockbak`, cgi-bin/action `stock_backup`),
# the install wizard (enodia.py runs THIS file from the package over SSH, before anything is installed — hence the shims below),
# heal.sh (boot) and uninstall.sh call it; nobody else reads or writes the flag.
#
# WHAT IT IS. Xiaomi keeps its settings (/etc/config, crontabs, passwd/shadow) in a LUKS+ext4 container /data/sec_cfg/data.vol.
# With `misc.features.sec_cfg_bak=1` the stock's /usr/sbin/sec_cfg_bak.sh (cron every 6 h; on BE6500 a boot hook too) keeps a
# full COPY of it in /data/usr/sec_cfg/ whenever `uci show` changed. On BE6500 (19.5-MB /data) the copy held 3.8 MB of real flash
# and Xray did not fit (measured 13.10.2026); BE7000 ships the same script with the flag unset.
# THE PRICE, said wherever the offer is made (/lib/preinit/89_mount_sec_cfg): at boot a container that fails luksOpen/e2fsck is
# restored FROM THE COPY; with no copy the stock makes an EMPTY container — every router setting reset (Wi-Fi, the root password,
# our cron lines: Enodia stops starting until the wizard attaches it again).
#
# THE FLAG AND THE REMOVAL GO TOGETHER: the copy removed alone comes back on the stock's next pass, the flag alone leaves the
# megabytes where they are. UNDER THE STOCK'S OWN LOCK: sec_cfg_bak.sh copies under flock(/var/run/sec_cfg_bak.lock) — holding it,
# we never remove a copy being written nor flip the flag mid-copy.
# THE MARKER `$ENODIA_STATE/.stock-backup-off` is the person's INTENT and what the flag was before us: heal turns the copy off again
# when a firmware update brings the flag back, uninstall puts back the value we changed (user's decisions 15.10.2026). No marker —
# we never touched it, and neither verb does anything.
# NO OWN «LIGHT» COPY of the settings: they carry Wi-Fi passwords and the root hash — out of the encrypted container they would lie
# on the flash in the clear (user's decision 15.10.2026).
# The offer is judged by FACT, not by model: the stock script and the live container exist, and the flag is 1 or a copy lies there.
#
#   stock-backup.sh status     — one JSON line: present flag copy copy_b est_b live busy mine at freed_b free_b need_b offer can_on
#   stock-backup.sh off        — flag 0 + the copy removed: {"ok":true,"freed_b":N} or {"ok":false,"why":"<code>"}
#   stock-backup.sh on         — the flag back to 1 and a fresh copy made at once; refused without room for it
#   stock-backup.sh heal       — boot: the person chose «off» and the flag (or a copy) came back ⇒ off again + an event
#   stock-backup.sh uninstall  — the flag back to what it was before us; the marker removed
# Refusal codes (`why`) — the panel and the wizard word them: absent · nolive · busy · nothing · space · uci · rm · notmine.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
SB_VOL=${ENODIA_SB_VOL:-/data/sec_cfg/data.vol}             # the live container
SB_DIR=${ENODIA_SB_DIR:-/data/usr/sec_cfg}                  # the stock's copy of it
SB_SCRIPT=${ENODIA_SB_SCRIPT:-/usr/sbin/sec_cfg_bak.sh}     # the stock's copier (CGI's PATH may lack /usr/sbin — by path)
SB_LOCK=${ENODIA_SB_LOCK:-/var/run/sec_cfg_bak.lock}        # the copier's own flock
SB_MOUNTS=${ENODIA_SB_MOUNTS:-/proc/mounts}
SB_FREE_WAIT=${ENODIA_SB_FREE_WAIT:-10}                     # seconds UBIFS may take to give freed blocks back
SB_MARK="$ENODIA_STATE/.stock-backup-off"
SB_EST=${ENODIA_SB_EST:-/tmp/enodia-stock-backup.est}      # RAM: the copy's estimated weight per (file, size, mtime)
SB_RESERVE_B=1048576                                        # free space left over after a fresh copy

if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# The wizard runs this file before the install: no libraries yet. The shims repeat the library forms one to one.
command -v fs_anchor >/dev/null 2>&1 || fs_anchor() { _fan="${1:-$ENODIA_DIR}"; while [ -n "$_fan" ] && [ ! -e "$_fan" ]; do _fan="${_fan%/*}"; done; printf '%s' "${_fan:-/}"; }
command -v fs_line   >/dev/null 2>&1 || fs_line()   { df -k "$(fs_anchor "$1")" 2>/dev/null | tail -1 | awk '{for(i=NF;i>1;i--) if($i ~ /%$/) break; if(i>=4 && $(i-3) ~ /^[0-9]+$/ && $(i-1) ~ /^[0-9]+$/ && $(i-3)+0>0){m=""; for(j=i+1;j<=NF;j++){ if(j>i+1) m=m " "; m=m $j }; print $(i-3), $(i-1), m}}'; }
command -v fs_free_b >/dev/null 2>&1 || fs_free_b() { _fsb=$(fs_line "$1" | awk '{printf "%.0f", $2*1024}'); case "$_fsb" in ''|*[!0-9]*) _fsb=0 ;; esac; printf '%s' "$_fsb"; }
command -v lbl_commit >/dev/null 2>&1 || lbl_commit() { if [ -z "$2" ]; then rm -f "$1"; return $?; fi; _lblt="$1.$$"; if printf '%s\n' "$2" > "$_lblt" 2>/dev/null && [ "$(cat "$_lblt" 2>/dev/null)" = "$2" ]; then mv "$_lblt" "$1" && return 0; fi; rm -f "$_lblt"; return 1; }

num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
tf()  { if "$@"; then echo true; else echo false; fi; }
# A refusal: its code for the wizard (it words it in two languages) and the words for the panel (its dictionary translates).
no()  {
	case "$1" in
		absent)  _nom="у этой прошивки нет копии настроек" ;;
		nolive)  _nom="хранилище настроек роутера не открылось при загрузке — копию не трогаю: она может быть единственной целой" ;;
		busy)    _nom="прошивка как раз делает копию — повторите через минуту" ;;
		nothing) _nom="копия настроек прошивки уже выключена" ;;
		space)   _nom="на флеше не хватит места на новую копию — сперва освободите место" ;;
		uci)     _nom="прошивка не приняла смену настройки" ;;
		rm)      _nom="копию выключил, но удалить её не вышло — место не освободилось" ;;
		*)       _nom="копию выключали не через панель — включить её отсюда нельзя" ;;
	esac
	printf '{"ok":false,"why":"%s","msg":"%s"}\n' "$1" "$_nom"; return 1
}
hum() { awk -v b="${1:-0}" 'BEGIN { k = b / 1024; if (k < 1024) printf "%d КБ", k; else printf "%.1f МБ", k / 1024 }'; }

# The flag as uci holds it: 1 · 0 · empty (unset — BE7000's way of «off»); anything else reads as empty.
sb_flag() { _sbf=$(uci -q get misc.features.sec_cfg_bak 2>/dev/null); case "$_sbf" in 0|1) echo "$_sbf" ;; *) echo "" ;; esac; }
sb_set()  { uci set "misc.features.sec_cfg_bak=$1" 2>/dev/null && uci commit misc 2>/dev/null && [ "$(sb_flag)" = "$1" ]; }
sb_present() { [ -f "$SB_SCRIPT" ] && [ -f "$SB_VOL" ]; }
sb_copy()    { [ -e "$SB_DIR" ]; }
# The live container mounted where the settings are read from. Not mounted = it failed at boot, and the copy may be the ONLY
# good one left — never removed then.
sb_live() { awk '$1 == "/dev/mapper/sec_cfg" && $2 == "/etc/config" { f = 1 } END { exit !f }' "$SB_MOUNTS" 2>/dev/null; }
# The copier at work right now: its lock is held. Opening the lock file creates it — as the copier itself does.
sb_busy() { [ -d "${SB_LOCK%/*}" ] || return 1; ! sb_try 9<>"$SB_LOCK"; }
sb_try()  { flock -n 9; }
sb_mark() { sed -n "s/^$1=//p" "$SB_MARK" 2>/dev/null | head -n 1; }
sb_size_b() { _sbs=0; for _sbz in "$@"; do [ -f "$_sbz" ] && _sbs=$((_sbs + $(num "$(stat -c %s "$_sbz" 2>/dev/null)"))); done; echo "$_sbs"; }

# The copy's weight ON THE FLASH, estimated: UBIFS compresses, and the container's never-written part is zeros, so the bytes say
# little (BE6500: an 8-MB container, 3.8 MB freed). gzip of each file is the honest guess; it costs a second per copy, so it is
# kept in RAM per (file, size, mtime) — the copier rewrites the file only when the settings changed.
sb_est_b() {
	_seT=0; _seC=""
	for _sef in "$SB_DIR"/*; do
		[ -f "$_sef" ] || continue
		_sek="$_sef $(stat -c '%s %Y' "$_sef" 2>/dev/null)"
		_sev=$(awk -v k="$_sek" '($1 " " $2 " " $3) == k { print $4; exit }' "$SB_EST" 2>/dev/null)
		[ -n "$_sev" ] || _sev=$(gzip -c "$_sef" 2>/dev/null | wc -c)
		_sev=$(num "$(echo $_sev)")
		_seT=$((_seT + _sev)); _seC="${_seC:+$_seC
}$_sek $_sev"
	done
	lbl_commit "$SB_EST" "$_seC" 2>/dev/null
	echo "$_seT"
}

sb_status() {
	_ssP=false; sb_present && _ssP=true
	_ssF=$(sb_flag)
	_ssC=false; _ssCb=0; _ssEb=0
	if sb_copy; then _ssC=true; _ssCb=$(sb_size_b "$SB_DIR"/*); _ssEb=$(sb_est_b); fi
	_ssL=$(tf sb_live)
	_ssB=false; [ "$_ssP" = true ] && sb_busy && _ssB=true
	_ssM=false; [ -f "$SB_MARK" ] && _ssM=true
	_ssFree=$(fs_free_b "$SB_DIR")
	_ssNeed=$(( $(sb_size_b "$SB_VOL") + SB_RESERVE_B ))
	# The router decides, the screens only show: an offer while the copier works or a copy lies there; «back on» only for one
	# turned off through us, and only with room for a fresh copy (a copy cut short by a full flash still gets its md5 written —
	# the stock would then «restore» a stump at boot).
	_ssO=false; [ "$_ssP" = true ] && [ "$_ssL" = true ] && { [ "$_ssF" = 1 ] || [ "$_ssC" = true ]; } && _ssO=true
	_ssOn=false; [ "$_ssP" = true ] && [ "$_ssL" = true ] && [ "$_ssM" = true ] && [ "$_ssF" != 1 ] && [ "$_ssFree" -ge "$_ssNeed" ] && _ssOn=true
	printf '{"present":%s,"flag":"%s","copy":%s,"copy_b":%s,"est_b":%s,"live":%s,"busy":%s,"mine":%s,"at":%s,"freed_b":%s,"free_b":%s,"need_b":%s,"offer":%s,"can_on":%s}\n' \
		"$_ssP" "$_ssF" "$_ssC" "$_ssCb" "$_ssEb" "$_ssL" "$_ssB" "$_ssM" "$(num "$(sb_mark at)")" "$(num "$(sb_mark freed)")" \
		"$_ssFree" "$_ssNeed" "$_ssO" "$_ssOn"
}

# Freed space by FACT: the df delta of the copy's volume. UBIFS hands blocks back lazily — asked again each second until something
# came back and then two asks in a row add nothing (≤ SB_FREE_WAIT s).
sb_freed() {
	_sfm=0; _sfi=0; _sfs=0
	while [ "$_sfi" -lt "$SB_FREE_WAIT" ]; do
		_sfd=$(( $(fs_free_b "$SB_DIR") - $1 ))
		if [ "$_sfd" -gt "$_sfm" ]; then _sfm=$_sfd; _sfs=0
		else _sfs=$((_sfs + 1)); [ "$_sfs" -ge 2 ] && [ "$_sfm" -gt 0 ] && break; fi
		_sfi=$((_sfi + 1)); sleep 1
	done
	echo "$_sfm"
}

sb_now() {   # the moment for the marker; 0 while the clock is not trusted (the panel then shows no date)
	if command -v clock_sane >/dev/null 2>&1 && ! clock_sane; then echo 0; else num "$(date +%s 2>/dev/null)"; fi
}

# off — run with the copier's lock on fd 9 (sb_off opens it). $1: user | heal.
sb_off_locked() {
	sb_try || { no busy; return 1; }
	_soW=$(sb_flag)
	[ "$_soW" = 1 ] || sb_copy || { no nothing; return 1; }
	# What the flag was BEFORE us survives a second «off» (heal after a firmware update): the first marker keeps it.
	_soNew=1; [ -f "$SB_MARK" ] && _soNew=0
	_soWas=$(sb_mark was); [ "$_soNew" = 1 ] && _soWas=$_soW
	_soAt=$(sb_now)
	_soF0=$(fs_free_b "$SB_DIR")
	# THE INTENT FIRST: a pass cut halfway (power, a killed caller) leaves the marker, and heal finishes it at the next boot — the
	# other order could leave the flag at 0 with nothing saying it was 1, and uninstall would never put it back. On a flash full to
	# the last block the marker may not land: the removal goes on (it is what frees the room), and the marker is written after it.
	mkdir -p "$ENODIA_STATE" 2>/dev/null   # the wizard turns it off BEFORE the install: no state dir yet
	lbl_commit "$SB_MARK" "$(printf 'was=%s\nat=%s\nfreed=0' "$_soWas" "$_soAt")" 2>/dev/null
	if [ "$_soW" = 1 ] && ! sb_set 0; then
		[ "$_soNew" = 1 ] && lbl_commit "$SB_MARK" "" 2>/dev/null   # refused: no intent left behind
		no uci; return 1
	fi
	rm -rf "$SB_DIR" 2>/dev/null; sync
	# The flag is already 0: what stays will not grow, but the megabytes were not given back — said, not hidden.
	sb_copy && { no rm; return 1; }
	_soFr=$(sb_freed "$_soF0")
	lbl_commit "$SB_MARK" "$(printf 'was=%s\nat=%s\nfreed=%s' "$_soWas" "$_soAt" "$_soFr")" 2>/dev/null
	if [ "$1" = heal ] && [ -f "$ENODIA_DIR/events.sh" ]; then
		sh "$ENODIA_DIR/events.sh" add stockbak-reoff 0 "Прошивка снова включила копию своих настроек" \
			"Вы её выключали — выключил снова: освобождено $((_soFr / 1024)) КБ. Обычно так бывает после обновления прошивки." >/dev/null 2>&1
	fi
	if [ "$_soFr" -gt 0 ]; then _som="копия настроек прошивки выключена: освобождено $(hum "$_soFr") на флеше"
	else _som="копия настроек прошивки выключена; место флеш отдаст чуть позже"; fi
	printf '{"ok":true,"freed_b":%s,"marked":%s,"msg":"%s"}\n' "$_soFr" "$(tf test -f "$SB_MARK")" "$_som"
}
sb_off() {
	sb_present || { no absent; return 1; }
	sb_live || { no nolive; return 1; }
	mkdir -p "${SB_LOCK%/*}" 2>/dev/null
	_sbo=$(sb_off_locked "$1" 9<>"$SB_LOCK" 2>/dev/null)
	[ -n "$_sbo" ] || _sbo='{"ok":false,"why":"busy"}'
	printf '%s\n' "$_sbo"
	case "$_sbo" in *'"ok":true'*) return 0 ;; esac; return 1
}

sb_on() {
	sb_present || { no absent; return 1; }
	sb_live || { no nolive; return 1; }
	[ -f "$SB_MARK" ] || { no notmine; return 1; }
	if [ "$(sb_flag)" != 1 ]; then
		[ "$(fs_free_b "$SB_DIR")" -ge $(( $(sb_size_b "$SB_VOL") + SB_RESERVE_B )) ] || { no space; return 1; }
		sb_set 1 || { no uci; return 1; }
	fi
	lbl_commit "$SB_MARK" "" 2>/dev/null
	# The copy NOW, under our eyes and with the room just checked — the stock's own pass may come at any of the next six hours,
	# when the flash may be fuller. The copier takes its own lock; busy means it is copying already.
	sh "$SB_SCRIPT" >/dev/null 2>&1
	if sb_copy; then _som="копия настроек прошивки включена и сделана"
	else _som="копия настроек прошивки включена — прошивка сделает её при следующем проходе"; fi
	printf '{"ok":true,"copy":%s,"msg":"%s"}\n' "$(tf sb_copy)" "$_som"
}

sb_heal() {
	[ -f "$SB_MARK" ] || return 0
	sb_present || return 0
	[ "$(sb_flag)" = 1 ] || sb_copy || return 0
	# A boot hook may be copying right now (BE6500): wait for it — up to a minute.
	_shi=0
	while :; do
		_sho=$(sb_off heal)
		case "$_sho" in *'"why":"busy"'*) ;; *) break ;; esac
		_shi=$((_shi + 1)); [ "$_shi" -lt 30 ] || break
		sleep 2
	done
	printf '%s\n' "$_sho"
}

sb_uninstall() {
	[ -f "$SB_MARK" ] || return 0
	if [ "$(sb_mark was)" = 1 ] && sb_present && [ "$(sb_flag)" != 1 ]; then sb_set 1 || return 1; fi
	lbl_commit "$SB_MARK" ""
}

case "${1:-}" in
	status)    sb_status ;;
	off)       sb_off user ;;
	on)        sb_on ;;
	heal)      sb_heal ;;
	uninstall) sb_uninstall ;;
	*)         echo "usage: stock-backup.sh status|off|on|heal|uninstall" >&2; exit 2 ;;
esac
