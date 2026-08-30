#!/bin/sh
# lists-update.sh — генерик-драйвер «менеджера источников списков» (см. lists-lib.sh).
#
# Одна точка входа для ВСЕХ списков роутера. Категория = набор источников (url/файл/текст),
# наполняющих одну цель. Реализованные категории:
#   tunnel-cidr — ipset iplist_set   (CIDR через VPN; интегрируется с iplist-update.sh);
#   ipblock     — ipset blocklist_set + iptables DROP (блок вредоносных IP; off по умолчанию);
#   adblock     — dnsmasq address=/домен/0.0.0.0 (блок рекламы/трекеров; off по умолчанию);
#   zapret-cidr — ipset zapret_cidr  (пул десинка ПО IP для zapret.sh; off по умолчанию);
#   zapret-dom  — dnsmasq ipset=/домен/zapret_dom (СВОЙ пул десинка по доменам; off по умолчанию).
# (tunnel-domains / bypass-* — следующая фаза; реестр их уже держит, apply добавится.)
#
# Подкоманды:
#   update <cat>                         — собрать источники → нормализовать → дедуп → применить;
#   add-url <cat> <url> [fmt] [label]    — добавить источник-URL;
#   add-blob <cat> file|text <fmt> <label> <path> — добавить источник-файл/текст (содержимое в path);
#   del <cat> <id> | toggle <cat> <id> <0|1> | set-format <cat> <id> <fmt>;
#   enable <cat> <0|1>                   — мастер-переключатель категории (adblock/ipblock);
#   allow-set <cat> <path>               — задать allowlist (домены-исключения) из файла;
#   list <cat>                           — JSON состояния для панели;
#   presets <cat>                        — JSON каталога готовых источников.
#
# update ДОЛГИЙ (закачки) → CGI запускает его фоном (spawn_bg) и опрашивает .update.state.
# Мутации реестра (add/del/toggle) мгновенные. Всё на /data — переживает ребут.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
# Под `[ -f ]` (инвариант проекта): провалившийся `.` в ash — фатальная ошибка спецбилтина, шелл
# выходит НА МЕСТЕ и молча. Библиотека здесь — весь движок, шима быть не может ⇒ честный отказ.
if [ -f "$ENODIA_DIR/lists-lib.sh" ]; then . "$ENODIA_DIR/lists-lib.sh"; else
	echo "нет $ENODIA_DIR/lists-lib.sh — обнови скрипты (gh-update apply-scripts)" >&2; exit 1
fi

CMD="$1"; CAT="$2"

valid_cat() {
	case "$1" in tunnel-cidr|tunnel-domains|bypass-ip|adblock|ipblock|zapret-cidr|zapret-dom) return 0 ;; *) return 1 ;; esac
}
kind_of() {  # «вид» результата категории
	case "$1" in adblock|tunnel-domains|zapret-dom) echo domains ;; *) echo cidr ;; esac
}
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Миграция старого iplist.conf/iplist.custom в реестр tunnel-cidr (ОДНОКРАТНО). Делает систему
# самосогласованной: и панель (list), и iplist-update (update) видят ОДИН реестр независимо от
# того, кто обратился первым. Реестр уже есть → ничего не делает. custom-mode: only → url-источник
# не заводим (только файл); merge → оба включены; off/пусто → файл заводим ВЫКЛЮЧЕННЫМ (сохраняем,
# но не активен, как было). Источник-URL = как в iplist-update (URL / сайты / дефолт opencck).
migrate_tunnel_cidr() {
	_reg=$(reg_path tunnel-cidr); [ -f "$_reg" ] && return 0
	IPLIST_URL=''; IPLIST_SITES=''; IPLIST_CUSTOM_MODE=''; IPLIST_CUSTOM_FILE="$ENODIA_STATE/iplist.custom"
	[ -f "$ENODIA_STATE/iplist.conf" ] && . "$ENODIA_STATE/iplist.conf"
	_base='https://iplist.opencck.org/?format=text&data=cidr4'
	if   [ -n "$IPLIST_URL" ];   then _u="$IPLIST_URL"; _l="свой URL"
	elif [ -n "$IPLIST_SITES" ]; then _u="$_base"; for _s in $IPLIST_SITES; do _u="$_u&site=$_s"; done; _l="сайты: $IPLIST_SITES"
	else _u="$_base"; _l="весь список opencck"; fi
	[ "$IPLIST_CUSTOM_MODE" = only ] || reg_add tunnel-cidr url 1 cidr "$_l" "$_u" >/dev/null
	if [ -s "$IPLIST_CUSTOM_FILE" ]; then
		_en=0; [ -n "$IPLIST_CUSTOM_MODE" ] && _en=1
		_cid=$(reg_add tunnel-cidr file "$_en" cidr "iplist.custom" "")
		cp "$IPLIST_CUSTOM_FILE" "$(blob_path tunnel-cidr "$_cid")" 2>/dev/null
	fi
}
# tunnel-cidr всегда самомигрируется при первом обращении любой подкомандой.
[ "$CAT" = tunnel-cidr ] && migrate_tunnel_cidr

# --- Правила iptables/ipset для целей блокировки/маршрутизации (идемпотентно) ---
ensure_mark_rule() {  # tunnel-cidr: mangle MARK по iplist_set (как в iplist-update.sh)
	# ...кроме установки «только панель»: транспорта нет, `ip rule` никто не ставил, и метка
	# ложится в пустоту — зато В MANGLE ПОЯВЛЯЕТСЯ НАШЕ ПРАВИЛО на роутере, который обещан
	# человеку «как сток». Поймано на железе (AX3600, 15.08.2026): гард стоял в iplist-update.sh,
	# а наполнение делегировано СЮДА — и правило приходило этим путём. Владелец ответа один
	# (transport.sh configured); код 2 = старая копия скрипта ⇒ ведём себя как раньше.
	if [ -f "$ENODIA_DIR/transport.sh" ]; then
		sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
		[ "$?" = 1 ] && return 0
	fi
	iptables -t mangle -C PREROUTING -m set --match-set iplist_set dst -j MARK --set-mark 0x1 2>/dev/null || \
		iptables -t mangle -A PREROUTING -m set --match-set iplist_set dst -j MARK --set-mark 0x1 2>/dev/null
}
# ipblock: DROP трафика к/от вредоносных IP через ЕДИНУЮ цепочку ENODIA_BLK (джамп из INPUT+FORWARD).
# Порядок ВНУТРИ цепочки = 3 слоя защиты связи (см. lists-lib.sh collect_critical/ensure_allow_set):
#   1) blocklist_allow (VPS/WAN/DNS/LAN) → RETURN — критичные IP НИКОГДА не дропаем, даже если в списке;
#   2) DROP по SOURCE только с WAN-интерфейса (-i $wan) — LAN-источник структурно не отвалится;
#   3) DROP по DST (LAN/роутер → вредоносный адрес) — это и есть цель блокировки.
# Отдельная цепочка → teardown чистый (флаш+удаление), порядок правил гарантирован при любом апдейте.
ensure_block_rules() {
	ipset list -n 2>/dev/null | grep -qx blocklist_set || \
		ipset create blocklist_set hash:net hashsize 4096 maxelem 1000000 2>/dev/null
	ensure_allow_set                                   # слой 1: критичные IP в blocklist_allow
	_wif=$(wan_iface)
	del_legacy_block_rules                             # снять прямые правила старых версий (до ENODIA_BLK)
	if iptables -nL ENODIA_BLK >/dev/null 2>&1; then iptables -F ENODIA_BLK 2>/dev/null
	else iptables -N ENODIA_BLK 2>/dev/null; fi
	iptables -A ENODIA_BLK -m set --match-set blocklist_allow src -j RETURN 2>/dev/null
	iptables -A ENODIA_BLK -m set --match-set blocklist_allow dst -j RETURN 2>/dev/null
	[ -n "$_wif" ] && iptables -A ENODIA_BLK -i "$_wif" -m set --match-set blocklist_set src -j DROP 2>/dev/null
	iptables -A ENODIA_BLK -m set --match-set blocklist_set dst -j DROP 2>/dev/null
	iptables -C INPUT   -j ENODIA_BLK 2>/dev/null || iptables -I INPUT   -j ENODIA_BLK 2>/dev/null
	iptables -C FORWARD -j ENODIA_BLK 2>/dev/null || iptables -I FORWARD -j ENODIA_BLK 2>/dev/null
}
del_legacy_block_rules() {  # прямые INPUT/FORWARD-правила версий ДО цепочки ENODIA_BLK
	for spec in "FORWARD dst" "FORWARD src" "INPUT src"; do
		ch=${spec% *}; dir=${spec#* }
		while iptables -C "$ch" -m set --match-set blocklist_set "$dir" -j DROP 2>/dev/null; do
			iptables -D "$ch" -m set --match-set blocklist_set "$dir" -j DROP 2>/dev/null || break
		done
	done
}
del_block_rules() {
	iptables -D INPUT   -j ENODIA_BLK 2>/dev/null
	iptables -D FORWARD -j ENODIA_BLK 2>/dev/null
	iptables -F ENODIA_BLK 2>/dev/null
	iptables -X ENODIA_BLK 2>/dev/null
	del_legacy_block_rules
}
# ВАЖНО: пишем в ЖИВОЙ conf-dir dnsmasq (/tmp/dnsmasq.d), НЕ в /etc/dnsmasq.d. Стоковый
# init на рестарте делает `cp -a /etc/dnsmasq.d/* /tmp/dnsmasq.d/` (АДДИТИВНО, без чистки) —
# файл из /etc копируется в /tmp, но при ВЫКЛючении rm из /etc НЕ убирает стухшую копию в /tmp,
# и dnsmasq продолжал блокировать домены с adblock=off (поймано на железе 2026-07-11). Живём
# в /tmp: apply/teardown/count работают с ОДНИМ файлом, что реально читает dnsmasq. /tmp=RAM,
# на ребуте чистится → adblock переигрывает heal.sh (снимок тоже в RAM). SIGHUP address= не
# перечитывает → dnsmasq_reload делает полный рестарт (он и так конф-дир перечитывает).
adblock_conf() { echo /tmp/dnsmasq.d/06-adblock.conf; }

# zapret-cidr: пул десинка ПО IP. Сам ipset и правила (ACCEPT мимо туннеля + scoped NFQUEUE) ведёт
# zapret.sh — здесь ТОЛЬКО наполнение, чтобы не разъезжались два владельца одних правил. После
# заливки зовём идемпотентный `zapret.sh rewire`: он создаст сет, если его ещё нет, и довесит на
# него правила, когда zapret — активный транспорт. zapret не установлен → no-op: пул спокойно
# лежит на флеше и заработает при первом включении десинка.
ZAPRET_CIDR_SET=zapret_cidr
# Гард `-f`, а НЕ `-x`: зовём через `sh`, бит выполнения тут ничего не решает, а снятый (заливка
# по scp/base64, обновление скриптов) тихо выключал бы довеску правил на пул — класс Б5-9/Б6-7.
zapret_rewire() { [ -f "$ENODIA_DIR/zapret.sh" ] && sh "$ENODIA_DIR/zapret.sh" rewire >/dev/null 2>&1; return 0; }

# zapret-dom: СВОЙ пул десинка ПО ДОМЕНАМ (файл/URL/текст) рядом с курированной четвёркой категорий
# zapret.sh. Своя цель — свой сниппет dnsmasq и свой набор: «выключил свой пул» не должно задевать
# категории (и наоборот — teardown транспорта флашит только их набор). Сниппет живёт в ЖИВОМ
# /tmp/dnsmasq.d по той же грабле, что adblock (init копирует /etc→/tmp АДДИТИВНО, и rm из /etc не
# убирает стухшую копию ⇒ выключение не доезжало); на ребуте его переигрывает heal.sh 5.8 из
# ФЛЕШ-снимка (офлайн, без закачки — ровно как у zapret-cidr: десинк обязан работать без сервера).
ZAPRET_DOM_SET=zapret_dom
zapret_dom_conf() { echo /tmp/dnsmasq.d/07-zapret-dom.conf; }
# Набор ОБЯЗАН существовать до записи ipset=-строк: dnsmasq сам его НЕ создаёт (кладёт записи лишь в
# существующий). Параметры совпадают с ensure_set в zapret.sh — кто первый, тот и создал.
ensure_dom_set() {
	ipset list -n 2>/dev/null | grep -qx "$ZAPRET_DOM_SET" || \
		ipset create "$ZAPRET_DOM_SET" hash:net family inet hashsize 1024 maxelem 1000000 2>/dev/null
	return 0
}

applied_count() {  # текущий размер результата в цели (для UI)
	case "$1" in
		tunnel-cidr) ipset_count iplist_set ;;
		ipblock)     ipset_count blocklist_set ;;
		zapret-cidr) ipset_count "$ZAPRET_CIDR_SET" ;;
		zapret-dom)  grep -c '^ipset=/' "$(zapret_dom_conf)" 2>/dev/null ;;    # доменов в пуле = ipset=-строк
		adblock)     grep -c '/0\.0\.0\.0$' "$(adblock_conf)" 2>/dev/null ;;   # доменов = A-строк (не всех, их 2×)
		*) echo 0 ;;
	esac
}

# --- teardown при выключении категории --------------------------------------
teardown() {
	case "$1" in
		adblock) rm -f "$(adblock_conf)" 2>/dev/null; dnsmasq_reload ;;
		ipblock) del_block_rules; ipset flush blocklist_set 2>/dev/null; ipset destroy blocklist_allow 2>/dev/null; ct_flush ;;
		# zapret-cidr: сет ОПУСТОШАЕМ, но НЕ уничтожаем и правила НЕ трогаем — их владелец zapret.sh,
		# и он же держит на сете ссылку (destroy при живом правиле вернул бы «set is in use»).
		# Пустой сет = ноль совпадений = десинка по IP нет, ровно семантика «категория выключена».
		zapret-cidr) ipset flush "$ZAPRET_CIDR_SET" 2>/dev/null; ct_flush ;;
		# zapret-dom: снять сниппет (иначе dnsmasq продолжит наполнять пул) И опустошить СВОЙ набор —
		# он наш целиком, в отличие от zapret_set категорий. Правила на нём не трогаем: их владелец
		# zapret.sh, а пустой набор = ноль совпадений = ровно семантика «пул выключен».
		zapret-dom)  rm -f "$(zapret_dom_conf)" 2>/dev/null; dnsmasq_reload
		             ipset flush "$ZAPRET_DOM_SET" 2>/dev/null; ct_flush ;;
	esac
}

# --- update: собрать → нормализовать → применить ----------------------------
ustate() { echo "$1" > "$(ram_dir "$CAT")/.update.state"; }  # прогресс/лог — в ОЗУ (панель читает через list)
ulog()   { echo "$*" >> "$(ram_dir "$CAT")/.update.log"; }

# _update_pass: ОДИН проход — собрать источники реестра → нормализовать → применить в цель.
# Пишет в рабочие файлы ОЗУ $W (задан вызывающим do_update). Всегда под локом do_update; если
# реестр менялся во время прохода — do_update переиграет его ещё раз (dirty-повтор).
_update_pass() {
	echo "===== $(date) update $CAT ====="

	# Категория выключена (adblock/ipblock без .enabled) → снести цель, выйти.
	if ! cat_enabled "$CAT"; then
		echo "category disabled → teardown"
		teardown "$CAT"; return 0
	fi

	kind=$(kind_of "$CAT")
	reg=$(reg_path "$CAT")
	work=$W/.work; : > "$work"
	nsrc=0    # источников, реально давших данные в этом проходе
	# ВКЛЮЧЁННЫХ источников в реестре — независимо от того, скачались ли они. Разводит два разных
	# случая, которые по пустому результату не отличить: «источник умер/не скачался» (nen>0 — цель
	# НЕ обнуляем, поднимаем из снимка) и «пользователь удалил/выключил все источники» (nen=0 — цель
	# обязана опустеть, иначе снимок вернёт список, который человек только что убрал = «удалил, а всё
	# на месте»). Считается для ВСЕХ целей: доменный пул десинка, tunnel-cidr и zapret-cidr.
	# Про CIDR-цели раньше стояло «снимок всегда» с доводом «от опустошения зависит МАРШРУТИЗАЦИЯ,
	# цена ошибочного обнуления выше цены лишнего списка». Довод верен для СБОЯ и там сохранён
	# (nen>0 → снимок), но на выключение руками он не распространяется: там ошибки нет, есть
	# явное решение человека, а пустой пул — fail-open, а не блэкхол. Поймано пользователем
	# 14.08.2026: снял галку с opencck, панель сказала «применяю», iplist_set остался 3530 —
	# ровно снимок, и пережил бы ребут.
	nen=0

	if [ -f "$reg" ]; then
		while IFS="$TAB" read -r id type en fmt cnt ts label value; do
			[ -n "$id" ] || continue
			[ "$en" = 1 ] || { echo "skip $id (disabled)"; continue; }
			nen=$((nen + 1))
			raw=$W/.raw.$id; : > "$raw"
			case "$type" in
				url)
					if fetch_url "$value" "$raw"; then
						cp "$raw" "$(cache_path "$CAT" "$id")" 2>/dev/null
						echo "src $id url ok: $value"
					elif [ -s "$(cache_path "$CAT" "$id")" ]; then
						cp "$(cache_path "$CAT" "$id")" "$raw"
						echo "src $id url FAILED → cache: $value"
					else
						echo "src $id url FAILED, no cache: $value"; reg_set_meta "$CAT" "$id" 0 "$(date +%s)"; rm -f "$raw"; continue
					fi ;;
				file|text)
					if [ -s "$(blob_path "$CAT" "$id")" ]; then cp "$(blob_path "$CAT" "$id")" "$raw"
					else echo "src $id blob missing"; rm -f "$raw"; continue; fi ;;
				*) rm -f "$raw"; continue ;;
			esac
			# auto-формат: распознать для показа в UI (нормализация всё равно kind-driven).
			[ "$fmt" = auto ] || [ -z "$fmt" ] && { det=$(detect_format < "$raw"); reg_set_format "$CAT" "$id" "$det"; }
			norm=$W/.norm.$id
			normalize "$kind" "$fmt" < "$raw" | sort -u > "$norm"
			scnt=$(grep -c '' "$norm" 2>/dev/null); case "$scnt" in ''|*[!0-9]*) scnt=0 ;; esac
			cat "$norm" >> "$work"
			reg_set_meta "$CAT" "$id" "$scnt" "$(date +%s)"
			echo "src $id: $scnt записей ($kind)"
			nsrc=$((nsrc + 1)); rm -f "$raw" "$norm"
		done < "$reg"
	fi

	# Дедуп общего результата.
	all=$W/.all; sort -u "$work" > "$all" 2>/dev/null; rm -f "$work"
	total=$(grep -c '' "$all" 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac
	echo "источников: $nsrc, суммарно уникальных: $total"

	# Применить в цель.
	case "$CAT" in
		tunnel-cidr)
			# ЗАЩИТА ЛОКАЛКИ — третья причина для того же фильтра (у ipblock это DROP, у zapret-cidr
			# ACCEPT мимо туннеля, здесь — МАРКИРОВКА dst в туннель). Приватка/CGNAT/мультикаст в этом
			# пуле уводит в awg0 ровно то, что обязано жить в локалке: ответы роутера клиентам
			# (mangle OUTPUT метится по тому же сету), mDNS/SSDP-мультикаст, а у абонента за CGNAT —
			# его собственный WAN-шлюз 100.64/10. Хуже прочих тем, что снимок лежит на ФЛЕШЕ ⇒
			# переживает ребут. Не гипотеза: замерено 04.08.2026 на живом BE7000 — в текущем
			# opencck-листе 6 адресов 100.64/10, и тот же фильтр на zapret-cidr режет 884→880.
			# Свою приватку «в VPN» человек задаёт правилом адреса или группой (enodia_ip_vpn/grp_vpn) —
			# эти пути идут мимо фильтра, так что сценарий «корпоративная сеть 10.x через VPN» цел.
			_b=$(grep -c '' "$all" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
			strip_bogon 4 < "$all" > "$all.safe" && mv "$all.safe" "$all"   # порог 4, а не 8 — см. strip_bogon
			_a=$(grep -c '' "$all" 2>/dev/null); case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
			echo "tunnel-cidr bogon-фильтр: $_b → $_a CIDR (приватка/CGNAT вырезаны — защита LAN)"
			if n=$(apply_ipset iplist_set "$all"); then
				ensure_mark_rule; snap_write "$CAT" "$all"
				echo "iplist_set: $n записей"
			elif [ "$nen" = 0 ]; then
				# ВЫКЛЮЧИЛИ/УДАЛИЛИ ВСЕ ИСТОЧНИКИ РУКАМИ — это решение человека, а не авария.
				# Раньше сюда падал общий снимок-фолбэк и возвращал РОВНО ТОТ список, который
				# только что убрали: панель отвечала «Источник выключен — применяю», а пул
				# оставался прежним и переживал ребут (heal → iplist-update → сюда же). Снимок
				# обнуляем ВМЕСТЕ с сетом — иначе он воскресит список на следующем же прогоне.
				# Пустой пул безопасен: это fail-open (ничего не метится в туннель), не блэкхол.
				ipset flush iplist_set 2>/dev/null; ensure_mark_rule; snap_write "$CAT" "$all"
				echo "включённых источников нет → iplist_set очищен"
			else
				# пусто/сбой ПРИ ЖИВЫХ источниках — поднять из снимка (фолбэк, как в iplist-update.sh)
				if [ -s "$(snap_path "$CAT")" ]; then apply_ipset iplist_set "$(snap_path "$CAT")" >/dev/null && ensure_mark_rule; echo "источники пусты → снимок"
				else echo "источники пусты, снимка нет — set не тронут"; fi
			fi ;;
		ipblock)
			# ЗАЩИТА LAN: вырезать приватку/богоны/широкие маски ДО заливки в set и снимка — иначе
			# DROP по blocklist_set (INPUT/FORWARD) убьёт локалку (см. strip_bogon в lists-lib.sh).
			_b=$(grep -c '' "$all" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
			strip_bogon < "$all" > "$all.safe" && mv "$all.safe" "$all"
			_a=$(grep -c '' "$all" 2>/dev/null); case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
			echo "ipblock bogon-фильтр: $_b → $_a CIDR (приватка/широкие вырезаны — защита LAN)"
			ensure_block_rules
			if n=$(apply_ipset blocklist_set "$all"); then echo "blocklist_set: $n записей"
			else ipset flush blocklist_set 2>/dev/null; echo "blocklist пуст"; fi
			ct_flush
			snap_write "$CAT" "$all" ;;
		zapret-cidr)
			# ЗАЩИТА LAN — обязательна, причина ДРУГАЯ, чем у ipblock: на этот сет zapret вешает
			# `PREROUTING -m set --match-set … dst -j ACCEPT` ВЫШЕ маркировки mark-core. Приватка
			# или широкая маска в пуле вывела бы весь LAN-трафик мимо VPN (тихая утечка, а не
			# обрыв — заметить труднее, чем FireHOL-инцидент). strip_bogon режет то же самое.
			_b=$(grep -c '' "$all" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
			strip_bogon < "$all" > "$all.safe" && mv "$all.safe" "$all"
			_a=$(grep -c '' "$all" 2>/dev/null); case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
			echo "zapret-cidr bogon-фильтр: $_b → $_a CIDR (приватка/широкие вырезаны — защита LAN)"
			if n=$(apply_ipset "$ZAPRET_CIDR_SET" "$all"); then
				zapret_rewire; snap_write "$CAT" "$all"
				echo "$ZAPRET_CIDR_SET: $n записей"
			elif [ "$nen" = 0 ]; then
				# Симметрично tunnel-cidr: «выключил» обязано значить выключил (разбор — там же).
				ipset flush "$ZAPRET_CIDR_SET" 2>/dev/null; zapret_rewire; snap_write "$CAT" "$all"
				echo "включённых источников нет → $ZAPRET_CIDR_SET очищен"
			else
				# Источники пусты/сбой ПРИ ЖИВЫХ источниках — поднять из флеш-снимка (как
				# tunnel-cidr): мёртвый источник не должен молча обнулять пул десинка.
				if [ -s "$(snap_path "$CAT")" ]; then apply_ipset "$ZAPRET_CIDR_SET" "$(snap_path "$CAT")" >/dev/null && zapret_rewire; echo "источники пусты → снимок"
				else echo "источники пусты, снимка нет — set не тронут"; fi
			fi
			ct_flush ;;
		adblock)
			n=$(apply_dnsmasq_block "$(adblock_conf)" "$all" "$(allow_path "$CAT")")
			echo "adblock: $n доменов заблокировано"
			snap_write "$CAT" "$all" ;;
		zapret-dom)
			# Набор — ДО сниппета (dnsmasq иначе будет ругаться на несуществующий), правила — ПОСЛЕ
			# (rewire идемпотентен и молчит, когда десинк выключен: наполнение пула не «включает» zapret).
			ensure_dom_set
			if [ -s "$all" ]; then
				n=$(apply_dnsmasq_ipset "$(zapret_dom_conf)" "$all" "$ZAPRET_DOM_SET" "$(allow_path "$CAT")")
				zapret_rewire; snap_write "$CAT" "$all"
				echo "$ZAPRET_DOM_SET: $n доменов в пуле десинка"
			elif [ "$nen" = 0 ]; then
				# Включённых источников нет ВООБЩЕ (пользователь удалил/выключил все) → пул обязан
				# опустеть: снимаем сниппет и флашим свой набор. Снимок на флеше НЕ трогаем — вернуть
				# источник и не потерять офлайн-состав дороже, чем лишний файл.
				rm -f "$(zapret_dom_conf)" 2>/dev/null; dnsmasq_reload
				ipset flush "$ZAPRET_DOM_SET" 2>/dev/null
				echo "включённых источников нет → пул очищен"
			else
				# Источники пусты/сбой — поднять из флеш-снимка (как zapret-cidr): мёртвый источник не
				# должен молча обнулять пул десинка (для доменов «обнулить» = снять правила dnsmasq).
				if [ -s "$(snap_path "$CAT")" ]; then
					n=$(apply_dnsmasq_ipset "$(zapret_dom_conf)" "$(snap_path "$CAT")" "$ZAPRET_DOM_SET" "$(allow_path "$CAT")")
					zapret_rewire; echo "источники пусты → снимок ($n доменов)"
				else echo "источники пусты, снимка нет — пул не тронут"; fi
			fi ;;
	esac
	rm -f "$all"
	return 0
}

# do_update: сериализованная обёртка над _update_pass. Два прохода в один момент писали в ОДНИ
# рабочие файлы ОЗУ и реестр → врали счётчики в UI (spawn_bg в CGI сам rm-ил pidfile → дедуп
# start-stop-daemon не срабатывал; reconcile-триггеры src_add/del/toggle участили перекрытие).
# Первый берёт атомарный mkdir-лок; конкуренты помечают .update.dirty и выходят — держатель после
# прохода переиграет под свежий реестр, схлопнув N кликов в ОДИН доп. проход (тяжёлые закачки блок-
# листов второй раз не тянем). Лок в ОЗУ (/tmp) — на ребуте чистится сам; убитый PID детектим по /proc.
# Механика лока — общая `ls_lock_take`/`ls_lock_drop` в lists-lib.sh (её же использует geo.sh do_build).
do_update() {
	valid_cat "$CAT" || { echo "unknown category: $CAT" >&2; return 2; }
	W=$(ram_dir "$CAT")                       # ОЗУ: сюда ВСЕ закачки/рабочие файлы (не на флеш!)
	lock="$W/.update.lock"
	ls_lock_take "$lock" "$W/.update.dirty" || return 0   # держатель жив → он переиграет под свежий реестр
	trap 'ls_lock_drop "$lock"' EXIT INT TERM

	: > "$W/.update.log"; ustate RUNNING
	exec >>"$W/.update.log" 2>&1
	while :; do
		rm -f "$W/.update.dirty"   # сброс ДО чтения реестра: пойманный dirty ⇒ реестр прочитан ПОСЛЕ мутации
		_update_pass
		[ -f "$W/.update.dirty" ] || break
		echo "--- реестр менялся во время обновления → переигрываю проход ---"
	done
	ustate DONE
	trap - EXIT INT TERM
	ls_lock_drop "$lock"
	return 0
}

# reapply: БЫСТРОЕ восстановление цели из снимка БЕЗ скачивания (для boot-хука heal.sh:
# dnsmasq-conf adblock и ipset/DROP ipblock живут в RAM и стираются на ребуте, а .enabled+.snapshot
# на /data переживают). Офлайн-безопасно (не ходит в сеть). Категория выключена → teardown.
do_reapply() {
	valid_cat "$CAT" || return 2
	if ! cat_enabled "$CAT"; then teardown "$CAT"; return 0; fi
	_snap=$(snap_path "$CAT"); [ -s "$_snap" ] || return 0
	case "$CAT" in
		# Снимок на флеше мог быть записан ДО появления фильтра (или руками) ⇒ чистим и на reapply,
		# как это делают ipblock/zapret-cidr ниже: боевой набор не должен зависеть от возраста снимка.
		tunnel-cidr) _ts=$(ram_dir "$CAT")/.reapply.safe; strip_bogon 4 < "$_snap" > "$_ts"
		             apply_ipset iplist_set "$_ts" >/dev/null 2>&1 && ensure_mark_rule
		             rm -f "$_ts" ;;
		ipblock)     ensure_block_rules
		             _ss=$(ram_dir "$CAT")/.reapply.safe; strip_bogon < "$_snap" > "$_ss"   # защита LAN и на reapply
		             apply_ipset blocklist_set "$_ss" >/dev/null 2>&1; rm -f "$_ss"
		             ct_flush ;;
		zapret-cidr) _zs=$(ram_dir "$CAT")/.reapply.safe; strip_bogon < "$_snap" > "$_zs"   # защита LAN и на reapply
		             apply_ipset "$ZAPRET_CIDR_SET" "$_zs" >/dev/null 2>&1; rm -f "$_zs"
		             zapret_rewire ;;
		adblock)     apply_dnsmasq_block "$(adblock_conf)" "$_snap" "$(allow_path "$CAT")" >/dev/null 2>&1 ;;
		zapret-dom)  ensure_dom_set
		             apply_dnsmasq_ipset "$(zapret_dom_conf)" "$_snap" "$ZAPRET_DOM_SET" "$(allow_path "$CAT")" >/dev/null 2>&1
		             zapret_rewire ;;
	esac
	return 0
}

# guarded_enable: включить категорию С АВТО-ОТКАТОМ при обрыве связи (слой 3 защиты). Для ipblock
# «глухой» DROP теоретически может оборвать роутер/резолв — после apply делаем self-test и, если
# связь/резолв упали ИЛИ приватка просочилась в блок-сет, откатываем (тот же отсоединённый guard-
# рецепт, что раньше гоняли вручную start-stop-daemon -b). Пишем вердикт в .guard.state для панели.
guarded_enable() {
	_c="$1"
	: > "$(enable_path "$_c")"
	echo APPLYING > "$(ram_dir "$_c")/.guard.state"
	CAT="$_c" do_update
	[ "$_c" = ipblock ] || { echo OK > "$(ram_dir "$_c")/.guard.state"; return 0; }
	sleep 3
	_ok=1
	# (а) приватка/LAN в блок-сете = катастрофа (ровно инцидент FireHOL) → откат безусловно.
	for _p in 192.168.31.1 192.168.31.0 10.0.0.1 100.64.0.1; do
		ipset test blocklist_set "$_p" >/dev/null 2>&1 && _ok=0
	done
	# (б) роутер потерял WAN-шлюз → откат (DROP по INPUT src мог задеть роутер).
	# ICMP до шлюза идёт НАПРЯМУЮ (шлюз не в iplist_set) → пинг тут валиден.
	_gw=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
	[ -n "$_gw" ] && { ping -c 1 -W 3 "$_gw" >/dev/null 2>&1 || _ok=0; }
	# (в) роутер→интернет проверяем ПО TCP (curl), а НЕ ICMP: 1.1.1.1/8.8.8.8 лежат в
	# iplist_set и маркируются в туннель, а на socks-транспортах (xray/hy2/byedpi)
	# несущая = tun2socks, который ICMP НЕ проксирует → ping ВСЕГДА FAIL → ipblock
	# откатывался сразу при каждом включении (guard.state=REVERTED). TCP через
	# tun2socks проходит штатно; на awg тоже работает. Проверено на железе 2026-07-14.
	_net=0
	for _h in 1.1.1.1 8.8.8.8; do
		curl -sk -o /dev/null -m 6 --connect-timeout 5 "https://$_h" 2>/dev/null && { _net=1; break; }
	done
	[ "$_net" = 1 ] || _ok=0
	if [ "$_ok" != 1 ]; then
		ulog "SELF-TEST FAILED → авто-откат ipblock (связь/резолв или приватка в сете)"
		rm -f "$(enable_path "$_c")"; teardown "$_c"; ct_flush
		echo REVERTED > "$(ram_dir "$_c")/.guard.state"
		return 1
	fi
	echo OK > "$(ram_dir "$_c")/.guard.state"
	return 0
}

# --- Каталог готовых источников (пресеты) -----------------------------------
# URL берём через CDN-зеркала (jsdelivr — на роутере надёжнее github-raw anycast; в iplist_set).
# Поля (через |): label|url|format|group|approx|site|desc
#   group  — rec (рекомендуемые, лёгкие/безопасные) | aggr (агрессивнее, тяжелее/больше ложных);
#   approx — примерный размер для UI-бюджета (человекочитаемо, «~48k»);
#   site   — страница проекта (кнопка-ссылка у пресета, чтобы юзер посмотрел, что за сервис);
#   desc   — короткое описание (последнее поле, может содержать пробелы).
presets_lines() {
	case "$1" in
		adblock)
			cat <<'EOF'
Hagezi Light|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/light.txt|dnsmasq|rec|~44k|https://github.com/hagezi/dns-blocklists|мягкий, почти без ложных срабатываний
OISD Small|https://small.oisd.nl/dnsmasq|dnsmasq|rec|~56k|https://oisd.nl|реклама, трекеры, фишинг — сбалансированно
Peter Lowe|https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext|hosts|rec|~3.5k|https://pgl.yoyo.org|только рекламные серверы, очень лёгкий
AdGuard DNS filter|https://cdn.jsdelivr.net/gh/AdguardTeam/AdGuardSDNSFilter@gh-pages/Filters/filter.txt|adblock|rec|~155k|https://github.com/AdguardTeam/AdGuardSDNSFilter|базовый фильтр AdGuard DNS
Hagezi Normal|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/multi.txt|dnsmasq|aggr|~160k|https://github.com/hagezi/dns-blocklists|сбалансированный, шире охват
Hagezi Pro|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/pro.txt|dnsmasq|aggr|~230k|https://github.com/hagezi/dns-blocklists|жёсткий, максимум охвата
OISD Big|https://big.oisd.nl/dnsmasq|dnsmasq|aggr|~500k|https://oisd.nl|расширенный список OISD
StevenBlack hosts|https://cdn.jsdelivr.net/gh/StevenBlack/hosts@master/hosts|hosts|aggr|~78k|https://github.com/StevenBlack/hosts|классический hosts-список
EOF
			;;
		ipblock)
			cat <<'EOF'
FireHOL level1|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/firehol_level1.netset|cidr|rec|~4.6k|https://iplists.firehol.org|минимум ложных срабатываний, базовые угрозы
Spamhaus DROP|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/spamhaus_drop.netset|cidr|rec|~1.6k|https://www.spamhaus.org/blocklists/do-not-route-or-peer/|заведомо враждебные сети (спам, малварь)
Spamhaus EDROP|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/spamhaus_edrop.netset|cidr|rec|~0.3k|https://www.spamhaus.org/blocklists/do-not-route-or-peer/|дополнение к DROP
FireHOL level2|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/firehol_level2.netset|cidr|aggr|~29k|https://iplists.firehol.org|+ атакующие сети и ботнеты за сутки
FireHOL level3|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/firehol_level3.netset|cidr|aggr|~13k|https://iplists.firehol.org|более широкий охват угроз
EOF
			;;
		# zapret-cidr: пул десинка ПО IP. Категории зеркалят ДОМЕННЫЕ категории zapret.sh
		# (youtube/google/discord/meta), чтобы «включил YouTube» значило одно и то же в обоих пулах.
		# Каждый URL ПРОВЕРЕН на железе 2026-07-25 (отдаёт непустой CIDR); мёртвые варианты не
		# положены сознательно: `site=google.com`/`googlevideo.com` у opencck отдают ПУСТО, а
		# runetfreedom не имеет youtube/discord/instagram — источник, который молча приезжает
		# нулевым, выглядит в UI как «включил, а не работает».
		# ПОЧЕМУ Google-пресет главный: список YouTube у opencck НЕ накрывает часть googlevideo
		# (живой поток телевизора шёл с 173.194.153.35, его там нет), а официальный goog.json
		# несёт 173.194.0.0/16 — и всего в 99 префиксах. Именно он закрывает исходную жалобу.
		# Cloudflare НЕ предлагаем: по граблям проекта десинк её всё равно не берёт, а вывод
		# 607 её подсетей мимо туннеля утащил бы пол-интернета из VPN ради нулевого эффекта.
		zapret-cidr)
			cat <<'EOF'
Google + googlevideo (официальный)|https://www.gstatic.com/ipranges/goog.json|cidr|rec|~99|https://www.gstatic.com/ipranges/goog.json|официальные диапазоны Google — накрывают googlevideo целиком
YouTube (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=youtube.com|cidr|rec|~0.8k|https://iplist.opencck.org|подсети YouTube — точечнее, но без части googlevideo
Discord (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=discord.com|cidr|rec|~0.1k|https://iplist.opencck.org|подсети Discord (сайт и медиа)
Google (runetfreedom geoip)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geoip@release/text/google.txt|cidr|aggr|~2.9k|https://github.com/runetfreedom/russia-blocked-geoip|шире официального: весь Google по данным РКН-списков
Instagram (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=instagram.com|cidr|aggr|~0.1k|https://iplist.opencck.org|подсети Instagram/Meta CDN
Facebook (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=facebook.com|cidr|aggr|~0.2k|https://iplist.opencck.org|подсети Facebook/Meta CDN
X / Twitter (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=x.com|cidr|aggr|~16|https://iplist.opencck.org|подсети X (бывший Twitter)
EOF
			;;
		# zapret-dom: СВОИ домены в тот же десинк. Источники — те же каталоги, что уже питают
		# «Гео-списки» (runetfreedom geosite = РКН-домены, v2fly domain-list-community): пиновка и
		# формат ровно как в geo.sh, поэтому доверенность источников уже подтверждена железом.
		# Плоские `domain:`/`full:`-префиксы понимает norm_domains (lists-lib.sh).
		# КАЖДЫЙ URL проверен с роутера 2026-07-26 (HTTP 200 + непустое тело; instagram.txt/
		# telegram.txt у runetfreedom НЕ существуют — 404, поэтому эти сервисы взяты из v2fly).
		# ru-blocked.txt (~79.5k доменов) — в aggr и с предупреждением: столько ipset=-строк dnsmasq
		# держит, но снимок на флеш не поместится (кап MAX_FLASH_CIDR) ⇒ после ребута нужен re-fetch.
		zapret-dom)
			cat <<'EOF'
YouTube (RU-блокировки)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/youtube.txt|domain|rec|~178|https://github.com/runetfreedom/russia-blocked-geosite|домены YouTube из РКН-списков
Google (RU-блокировки)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/google.txt|domain|rec|~1.1k|https://github.com/runetfreedom/russia-blocked-geosite|домены Google (поиск, сервисы, Gemini)
Discord (RU-блокировки)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/discord.txt|domain|rec|~28|https://github.com/runetfreedom/russia-blocked-geosite|домены Discord (сайт, медиа, вложения)
Telegram (v2fly)|https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@master/data/telegram|domain|rec|~21|https://github.com/v2fly/domain-list-community|домены Telegram (веб, API, CDN)
Instagram (v2fly)|https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@master/data/instagram|domain|rec|~76|https://github.com/v2fly/domain-list-community|домены Instagram/Meta CDN
OpenAI / ChatGPT (v2fly)|https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@master/data/openai|domain|rec|~30|https://github.com/v2fly/domain-list-community|домены OpenAI (ChatGPT, API)
Все домены, заблокированные в РФ|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/ru-blocked.txt|domain|aggr|~79.5k|https://github.com/runetfreedom/russia-blocked-geosite|весь РКН-реестр доменов — тяжёлый, снимок на флеш не поместится
EOF
			;;
	esac
}
emit_presets() {
	printf '['
	first=1
	while IFS='|' read -r lbl url fmt grp approx site desc; do
		[ -n "$lbl" ] || continue
		[ "$first" = 1 ] || printf ','
		first=0
		[ -n "$grp" ] || grp=rec
		printf '{"label":"%s","url":"%s","format":"%s","group":"%s","approx":"%s","site":"%s","desc":"%s"}' \
			"$(jesc "$lbl")" "$(jesc "$url")" "$(jesc "$fmt")" "$(jesc "$grp")" "$(jesc "$approx")" "$(jesc "$site")" "$(jesc "$desc")"
	done <<EOF
$(presets_lines "$1")
EOF
	printf ']'
}

# --- list: JSON состояния категории для панели ------------------------------
emit_list() {
	en=true; cat_enabled "$CAT" || en=false
	ac=$(applied_count "$CAT"); case "$ac" in ''|*[!0-9]*) ac=0 ;; esac
	al=0; [ -s "$(allow_path "$CAT")" ] && { al=$(grep -c '' "$(allow_path "$CAT")" 2>/dev/null); case "$al" in ''|*[!0-9]*) al=0 ;; esac; }
	st=$(cat "$(ram_dir "$CAT")/.update.state" 2>/dev/null | tr -d ' \r\n'); [ -n "$st" ] || st=IDLE
	gs=$(cat "$(ram_dir "$CAT")/.guard.state" 2>/dev/null | tr -d ' \r\n'); [ -n "$gs" ] || gs=NONE
	# blocklist_allow — число критичных IP под защитой (для UI «Защита сети»); 0 если сет не создан.
	# ГАРД обязателен: если ipset_count вернёт пусто (напр. рассинхрон deploy — старый lists-lib.sh
	# без функции), пустое поле %s ломает JSON целиком («critical_count»:,) → панель «не удалось
	# получить источники» + мастер-тумблер блокировки не рисуется. Ни одно числовое поле не должно
	# уезжать пустым — как ac/al выше (поймано на железе 2026-07-18, BE7000: lists-lib.sh был stale).
	ca=$(ipset_count blocklist_allow 2>/dev/null); case "$ca" in ''|*[!0-9]*) ca=0 ;; esac
	# СОДЕРЖИМОЕ allowlist'а, а не только счётчик: верб `allow-set` ЗАМЕНЯЕТ файл целиком, а панель
	# показывала лишь «исключений: N» и однострочное поле — то есть человек, дописав туда один
	# домен, стирал все прежние и узнавал об этом только по вернувшейся рекламе. Отдаём то, что
	# он на самом деле правит. base64 — потому что домены идут построчно, а JSON-эскейпа на
	# busybox нет (та же причина, что у name_b64 слотов и полей events.sh).
	# Потолок 32 КБ: список рукописный (десятки строк), но панель обязана ЗНАТЬ, что он не влез,
	# и не дать сохранить обрезок поверх целого — иначе лечение стало бы той же болезнью.
	ab=''; acut=false
	if [ -s "$(allow_path "$CAT")" ]; then
		if [ "$(wc -c < "$(allow_path "$CAT")" 2>/dev/null || echo 0)" -gt 32768 ]; then acut=true
		else ab=$(base64 < "$(allow_path "$CAT")" 2>/dev/null | tr -d '\n\r'); fi
	fi
	printf '{"cat":"%s","kind":"%s","enabled":%s,"count":%s,"allow_count":%s,"allow_b64":"%s","allow_cut":%s,"update_state":"%s","guard_state":"%s","critical_count":%s,"sources":[' \
		"$CAT" "$(kind_of "$CAT")" "$en" "$ac" "$al" "$ab" "$acut" "$st" "$gs" "$ca"
	first=1; reg=$(reg_path "$CAT")
	if [ -f "$reg" ]; then
		while IFS="$TAB" read -r id type enb fmt cnt ts label value; do
			[ -n "$id" ] || continue
			eb=false; [ "$enb" = 1 ] && eb=true
			case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
			case "$ts"  in ''|*[!0-9]*) ts=0 ;; esac
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"id":"%s","type":"%s","enabled":%s,"format":"%s","count":%s,"ts":%s,"label":"%s","value":"%s"}' \
				"$(jesc "$id")" "$(jesc "$type")" "$eb" "$(jesc "$fmt")" "$cnt" "$ts" "$(jesc "$label")" "$(jesc "$value")"
		done < "$reg"
	fi
	printf '],"presets":'; emit_presets "$CAT"; printf '}\n'
}

# --- Диспетчер подкоманд -----------------------------------------------------
case "$CMD" in
	update)   do_update ;;
	reapply)  do_reapply ;;
	list)     valid_cat "$CAT" || { echo '{"error":"unknown category"}'; exit 1; }; emit_list ;;
	presets)  valid_cat "$CAT" || { printf '[]\n'; exit 1; }; emit_presets "$CAT"; echo ;;
	add-url)
		valid_cat "$CAT" || { echo "unknown category" >&2; exit 1; }
		url="$3"; fmt="${4:-auto}"; label="$5"
		case "$url" in http://*|https://*) ;; *) echo "bad url" >&2; exit 1 ;; esac
		[ -n "$label" ] || label="$url"
		reg_add "$CAT" url 1 "$fmt" "$label" "$url" ;;
	add-blob)
		valid_cat "$CAT" || { echo "unknown category" >&2; exit 1; }
		btype="$3"; fmt="${4:-auto}"; label="$5"; path="$6"
		case "$btype" in file|text) ;; *) echo "bad type" >&2; exit 1 ;; esac
		[ -s "$path" ] || { echo "empty blob" >&2; exit 1; }
		id=$(reg_add "$CAT" "$btype" 1 "$fmt" "$label" "")
		cp "$path" "$(blob_path "$CAT" "$id")" && printf '%s' "$id" ;;
	get-blob)   # вывести содержимое blob file/text-источника (для просмотра/правки в панели)
		valid_cat "$CAT" || exit 1
		f=$(blob_path "$CAT" "$3"); [ -f "$f" ] || { echo "no blob" >&2; exit 1; }
		cat "$f" ;;
	set-blob)   # перезаписать содержимое СУЩЕСТВУЮЩЕГО blob (правка вставленного текста/файла)
		valid_cat "$CAT" || exit 1
		id="$3"; path="$4"
		[ -s "$path" ] || { echo "empty blob" >&2; exit 1; }
		[ -f "$(blob_path "$CAT" "$id")" ] || { echo "no such blob" >&2; exit 1; }
		cp "$path" "$(blob_path "$CAT" "$id")" ;;
	del)      valid_cat "$CAT" || exit 1; reg_del "$CAT" "$3" ;;
	toggle)   valid_cat "$CAT" || exit 1; case "$4" in 0|1) reg_toggle "$CAT" "$3" "$4" ;; *) exit 1 ;; esac ;;
	set-format) valid_cat "$CAT" || exit 1; reg_set_format "$CAT" "$3" "$4" ;;
	enable)
		valid_cat "$CAT" || exit 1
		case "$3" in
			1) : > "$(enable_path "$CAT")" ;;
			0) rm -f "$(enable_path "$CAT")"; teardown "$CAT" ;;
			*) exit 1 ;;
		esac ;;
	safe-enable)   # включить + собрать/применить + self-test с авто-откатом (слой 3); зовётся CGI фоном
		valid_cat "$CAT" || exit 1
		guarded_enable "$CAT" ;;
	allow-set)
		valid_cat "$CAT" || exit 1
		[ -f "$3" ] || { echo "no file" >&2; exit 1; }
		norm_domains < "$3" | sort -u > "$(allow_path "$CAT").new" && mv "$(allow_path "$CAT").new" "$(allow_path "$CAT")" ;;
	*) echo "usage: lists-update.sh update|list|presets|add-url|add-blob|get-blob|set-blob|del|toggle|set-format|enable|allow-set <cat> …" >&2; exit 2 ;;
esac
