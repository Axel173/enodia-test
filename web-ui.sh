#!/bin/sh
# web-ui.sh — поднимает ОТДЕЛЬНЫЙ веб-сервер (второй экземпляр uhttpd) под нашу
# панель управления VPN. НЕ трогает стоковый nginx (вебморду Xiaomi): слушает свой
# порт на LAN-IP. Отдаёт статику web/ + CGI web/cgi-bin/ под HTTP-Basic.
#
# Почему uhttpd, а не busybox httpd: applet httpd в busybox этого роутера НЕ собран
# ("httpd: applet not found"), а бинарь uhttpd уже лежит в /usr/sbin (стоковый
# образ) — 0 байт флеша. Почему запуск из CLI без UCI-конфига в /etc: /etc
# сбрасывается при ребуте, конфиг там не переживёт перезагрузку — все параметры
# передаём аргументами. Демонизация — через start-stop-daemon -b -m (как у
# transport-плагинов): -f держит uhttpd на переднем плане, ssd уводит в фон и
# пишет pidfile (у uhttpd своего флага pidfile нет).
#
# АВТОРИЗАЦИЯ (HTTP Basic): весь сайт (включая CGI) закрыт строкой "/:admin:<хэш>" в
# $DOCROOT/uhttpd.conf. Хэш генерит сам uhttpd: `uhttpd -m '<пароль>'` (MD5-crypt).
# Пароль задаёт установщик (или вручную: web-ui.sh setpass <пароль>). Забыл пароль —
# задать заново в установщике с ПК. Без uhttpd.conf сервер НЕ стартует (не отдаём
# панель без пароля).
#
# БЕЗОПАСНОСТЬ: слушаем ТОЛЬКО основной LAN-IP (br-lan), не 0.0.0.0 → недоступно
# с WAN и из гостевой сети; -D запрещает листинг каталогов (403), -S не пускает по
# симлинкам за пределы docroot. CGI пока read-only (статус). Управляющие действия
# (Фаза 2) пойдут ТОЛЬКО через существующие безопасные скрипты с санитизацией ввода.
#
# HTTPS (verbs tls-on/tls-off) — ОТДЕЛЬНЫМ процессом `panel-tls`, а не самим uhttpd:
# [клиент] --TLS--> panel-tls:8443 --plain--> этот uhttpd на LAN-IP:8088. Стоковый uhttpd
# HTTPS формально умеет, но грузит крипто плагином `libustream-ssl.so`, которого в прошивке
# нет, а собранный нами не заводится: uhttpd Xiaomi собран с ПАТЧЕНЫМ `struct ustream`
# (пишет notify_* по смещениям 184/192/200 против апстримовых 168/176/184 — проверено
# зондом на железе и перебором всех коммитов libubox), т.е. плагин пришлось бы подгонять
# под вендорский ABI и ломать от каждого обновления прошивки. Разбор — local/tls/NOTES.md.
# Сам по себе tls-on ничего в интернет не открывает — TLS слушает тот же LAN-IP.
#
# ДОСТУП СНАРУЖИ (verbs wan-on/wan-off) — правило в ШТАТНОМ хуке fw3 `input_wan_rule` (у стока
# он пуст и ровно для этого предназначен), своя цепочка PANEL_WAN. Наружу открываем ТОЛЬКО
# TLS-порт и ТОЛЬКО при включённом HTTPS: Basic-пароль поверх голого HTTP в интернете = отдать
# роутер первому, кто слушает канал. Правило смывает `fw3 reload` (вебморда Xiaomi) — переигрывает
# его `start`, который и так бежит из cron каждые 5 минут ради самой панели (той же ценой лечится
# и panel-tls). Отдельной строки в cron и правок в heal/watchdog не нужно. Тем же правилом внешний
# адрес открывается И из дома (hairpin/NAT loopback) — см. wan_rule_apply.
#
# ВТОРОЙ ФАКТОР (TOTP) — в отдельном totp.sh: Basic остаётся первым фактором (иначе не бывает —
# диалог рисует браузер), а код из приложения проверяет наш CGI и выдаёт сессионную куку, которую
# требуют все остальные CGI. Здесь только зеркалим состояние (json/status), чтобы у панели был
# ОДИН источник среза «доступ к панели». Аварийное отключение: sh totp.sh disable --force

ENODIA_DIR=/data/usr/app/enodia
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
DOCROOT="$ENODIA_DIR/web"
AUTHCONF="$DOCROOT/uhttpd.conf"
AUTHUSER=admin
# REALM — то, что браузер пишет в СВОЁМ диалоге входа («Вход на 192.168.28.1:8088 · BE7000 VPN»).
# Модель спрашиваем у владельца ответа (router-lib.sh), а не хардкодим: на AX3600/BE3600 диалог
# называл чужую модель — тот же класс, ради которого в письмах живёт router_relabel. Нет
# библиотеки (старая копия payload) ⇒ прежняя строка байт-в-байт.
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi
REALM="BE7000 VPN"   # model-lit: фолбэк на случай payload БЕЗ router-lib.sh — прежняя строка байт-в-байт
if command -v router_label >/dev/null 2>&1; then
	_rlbl=$(router_label 2>/dev/null)
	[ -n "$_rlbl" ] && REALM="$_rlbl VPN"
fi
# LISTEN — реальный LAN-IP роутера, НЕ хардкод: роутер не всегда на .1 (бывает
# .100/.31), а захардкоженный .1 → uhttpd не забиндится на несуществующий адрес и панель
# не поднимется. Берём адрес основного LAN-бриджа; фолбэк на .1, если детект не удался.
# Имя моста спрашиваем у владельца (router-lib.sh::lan_if): им берётся не только LISTEN — это же
# имя уезжает в hairpin-правило NAT ниже (`-i "$LAN_IF"`), поэтому источник ответа обязан быть один.
LAN_IF=br-lan   # lan-lit: фолбэк на payload БЕЗ router-lib.sh — прежняя строка байт-в-байт
command -v lan_if >/dev/null 2>&1 && LAN_IF=$(lan_if)
LISTEN=$(ip -4 addr show "$LAN_IF" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
[ -n "$LISTEN" ] || LISTEN=192.168.31.1
PORT=8088
PIDFILE=/tmp/uhttpd-web.pid
UHTTPD=/usr/sbin/uhttpd

# --- HTTPS-терминатор -------------------------------------------------------
# Где лежит бинарь (store-lib.sh): без накопителя — прежний путь байт-в-байт. Выносить panel-tls
# на съёмный носитель нельзя (выдернул флешку — потерял вход в панель, в том числе снаружи), и
# держит это не проверка здесь, а БЕЛЫЙ список $STORE_MOVABLE в store-lib.sh, куда panel-tls
# сознательно не входит: движку оффлоада просто нечего с ним делать. Здесь мы читаем факт.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
TLS_BIN=$(bin_path panel-tls)
TLS_FLAG="$ENODIA_STATE/.panel-tls"      # есть файл = HTTPS включён; содержимое = порт (персист на /data)
TLS_CERT="$ENODIA_STATE/panel-cert.pem"
TLS_KEY="$ENODIA_STATE/panel-key.pem"
TLS_PID=/tmp/panel-tls.pid
TLS_LOG=/tmp/panel-tls.log
TLS_PORT_DEF=8443                   # 443 занят стоковым nginx — его не трогаем

# --- Доступ снаружи (WAN) ---------------------------------------------------
WAN_FLAG="$ENODIA_STATE/.panel-wan"      # есть файл = порт открыт наружу (персист на /data)
WAN_CHAIN=PANEL_WAN                 # СВОЯ цепочка (как ENODIA_GEOBLK/VPN_PORTS) — снимается целиком
WAN_DNAT=PANEL_WAN_DNAT             # она же в nat: заводит пакет с WAN на LAN-сокет panel-tls
WAN_HOOK=input_wan_rule             # штатный пустой хук fw3 внутри zone_wan_input
WAN_CONN_MAX=12                     # одновременных соединений с ОДНОГО адреса (у panel-tls всего 32
                                    # слотов ⇒ без этого один клиент занимает все и запирает хозяина)
WAN_RATE=30/min                     # новых соединений с адреса: браузер держит keep-alive, ему хватает
WAN_BURST=60                        # запас на первый заход (панель тянет статику+CGI параллельно)
WAN_IP_FILE="$ENODIA_STATE/.panel-wan-ip"  # последний известный внешний адрес (персист) — см. wan_ip_watch

# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений (ct-lib.sh) — нужен ровно одному месту: «закрыл доступ
# снаружи» обязано оборвать уже открытые снаружи сессии. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush_dport >/dev/null 2>&1 || ct_flush_dport() { [ -n "$1" ] && conntrack -D -p tcp --dport "$1" >/dev/null 2>&1; return 0; }

# Язык событийных писем — общий с остальными скриптами (шим, если файла ещё нет).
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }

# «Текст роутера → строка внутри JSON» (cmd_json ниже) — одна копия на проект, в json-lib.sh.
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jesc >/dev/null 2>&1 || {
	jesc() { tr -d '\033\r' | tr '\n\t' '  ' | cut -c1-"$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
}

is_running() {
	[ -f "$PIDFILE" ] || return 1
	pid=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$pid" ] && [ -d "/proc/$pid" ]
}

tls_enabled() { [ -f "$TLS_FLAG" ]; }
tls_port()    { p=$(cat "$TLS_FLAG" 2>/dev/null); echo "${p:-$TLS_PORT_DEF}"; }

tls_running() {
	[ -f "$TLS_PID" ] || return 1
	pid=$(cat "$TLS_PID" 2>/dev/null)
	[ -n "$pid" ] && [ -d "/proc/$pid" ]
}

# Самоподписанный сертификат живёт на /data (переживает ребут; /etc = ramfs).
# ГЕЙТ ПО ЧАСАМ ОБЯЗАТЕЛЕН: RTC на роутере нет, до ntpsetclock время = 1970, и выписанный
# тогда сертификат протух бы (notAfter = 1970+10 лет) ровно в момент, когда часы догонят
# реальность. Не выписываем — cron панели (*/5) вернётся сюда, когда время встанет.
tls_ensure_cert() {
	[ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] && return 0
	now=$(date +%s 2>/dev/null)
	[ -n "$now" ] && [ "$now" -ge 1700000000 ] 2>/dev/null || {
		echo "часы не синхронизированы — сертификат не выписан (повтор после ntp)"; return 1; }
	command -v openssl >/dev/null 2>&1 || { echo "нет openssl — сертификат не выписать"; return 1; }
	cn=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	[ -n "$cn" ] || cn="$LISTEN"
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout "$TLS_KEY.tmp" -out "$TLS_CERT.tmp" -subj "/CN=$cn" >/dev/null 2>&1 || {
		rm -f "$TLS_KEY.tmp" "$TLS_CERT.tmp"; echo "не удалось выписать сертификат"; return 1; }
	mv "$TLS_KEY.tmp" "$TLS_KEY"; mv "$TLS_CERT.tmp" "$TLS_CERT"
	chmod 600 "$TLS_KEY"; chmod 644 "$TLS_CERT"
	echo "сертификат выписан (CN=$cn, самоподписанный)"
}

tls_start() {
	tls_enabled || return 0
	tls_running && return 0
	[ -x "$TLS_BIN" ] || { echo "нет $TLS_BIN — HTTPS пропущен"; return 1; }
	is_running || { echo "панель не поднята — HTTPS пропущен"; return 1; }
	tls_ensure_cert || return 1
	[ -f "$TLS_PID" ] && : > "$TLS_PID"
	# pidfile ведёт start-stop-daemon (как у uhttpd), поэтому своего -p демону не даём.
	start-stop-daemon -S -b -m -p "$TLS_PID" -x "$TLS_BIN" -- \
		-l "$LISTEN:$(tls_port)" -b "$LISTEN:$PORT" \
		-c "$TLS_CERT" -k "$TLS_KEY" -L "$TLS_LOG" >/dev/null 2>&1
	sleep 1
	if tls_running; then echo "HTTPS: https://$LISTEN:$(tls_port)  (pid $(cat "$TLS_PID"))"
	else echo "не удалось поднять panel-tls (см. $TLS_LOG)"; return 1; fi
}

tls_stop() {
	tls_running || return 0
	# busybox ssd -K пишет результат в STDOUT — глушим, иначе строка протечёт в вывод CGI
	start-stop-daemon -K -p "$TLS_PID" -x "$TLS_BIN" >/dev/null 2>&1
	: > "$TLS_PID"
	echo "HTTPS остановлен"
}

wan_enabled() { [ -f "$WAN_FLAG" ]; }

# WAN-интерфейс: сперва uci (истина конфига), фолбэк — маршрут по умолчанию. `ip route get`
# берём БЕЗ метки, поэтому смотрит в main table и возвращает именно WAN, а не наш туннель
# (правило fwmark→table 1000 срабатывает только на помеченных пакетах).
wan_iface() {
	i=$(uci -q get network.wan.ifname 2>/dev/null)
	[ -n "$i" ] || i=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([a-z0-9._-]*\).*/\1/p' | head -1)
	echo "$i"
}
wan_addr() {
	i=$(wan_iface); [ -n "$i" ] || return 1
	ip -4 addr show dev "$i" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1
}

# Вердикт «достучатся ли снаружи» — БЕЗ сетевой пробы, по самому WAN-адресу.
# Почему не `probe_ext_ip`: на роутере с живым туннелем она меряет выход ЧЕРЕЗ VPS и возвращает
# IP сервера (проверено: WAN 5.3.74.114, а проба отдаёт 77.105.143.198) ⇒ гард на ней ВСЕГДА
# врал бы «ты за NAT». Публичный адрес на WAN-интерфейсе = роутер и есть граница, проба избыточна
# (ровно замысел is_private_ip в ip-lib.sh); приватный = CGNAT или двойной NAT, и там внешний IP
# всё равно не наш — честно говорим, что автоматически не дотянемся.
#   public <ip> | private <ip> | none
wan_verdict() {
	a=$(wan_addr)
	[ -n "$a" ] || { echo none; return 0; }
	if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then
		. "$ENODIA_DIR/ip-lib.sh"
		is_private_ip "$a" && { echo "private $a"; return 0; }
	fi
	echo "public $a"
}

# Внешний адрес ДИНАМИЧЕСКИЙ: после переподключения провайдер даёт другой, ссылка «снаружи»
# протухает МОЛЧА, и узнать об этом можно только вернувшись домой — ровно наоборот тому, ради
# чего доступ снаружи включали. Следим лишь пока он включён (иначе внешний адрес пользователю
# не нужен) и на ТОМ ЖЕ тике cron, что чинит правило: своей строки в crontab не заводим.
wan_ip_watch() {
	new="$1"
	[ -n "$new" ] || return 0
	old=$(cat "$WAN_IP_FILE" 2>/dev/null)
	[ "$old" = "$new" ] && return 0
	echo "$new" > "$WAN_IP_FILE"
	# Первый прогон (файла не было) — НЕ событие: сравнивать было не с чем, а письмо
	# «адрес сменился» сразу после включения только путает.
	[ -n "$old" ] || return 0
	[ -f "$ENODIA_DIR/notify-event.sh" ] || return 0
	# Приватный адрес (CGNAT) в письме = ссылка, которая никуда не ведёт: смену отмечаем в
	# файле, но молчим — панель об этом честно предупреждает своей плашкой.
	v=$(wan_verdict); set -- $v
	[ "$1" = public ] || return 0
	p=$(tls_port)
	if [ "$(nf_lang)" = en ]; then
		sh "$ENODIA_DIR/notify-event.sh" panel-wan-ip 3600 "BE7000: router external address changed" \
"The ISP gave the router a new external address, so the old panel link no longer works.

Was:  $old
Now:  $new

Panel from outside: https://$new:$p
Access from outside is still on, the login is still the panel password." >/dev/null 2>&1
	else
		sh "$ENODIA_DIR/notify-event.sh" panel-wan-ip 3600 "BE7000: внешний адрес роутера сменился" \
"Провайдер выдал роутеру новый внешний адрес — старая ссылка на панель больше не работает.

Было:  $old
Стало: $new

Панель снаружи: https://$new:$p
Доступ снаружи по-прежнему открыт, вход — под тем же паролем панели." >/dev/null 2>&1
	fi
	return 0
}

# Правило ставим ИДЕМПОТЕНТНО и пересобираем цепочку с нуля: TLS-порт мог смениться, а старое
# правило осталось бы открытым портом в интернет — ровно тот случай, где «досборка» опаснее пересборки.
wan_rule_apply() {
	wan_enabled || return 0
	tls_enabled || return 0     # без HTTPS наружу не открываем НИКОГДА (см. шапку)
	iptables -L "$WAN_HOOK" -n >/dev/null 2>&1 || { echo "нет цепочки $WAN_HOOK (fw3 не поднят?)"; return 1; }
	p=$(tls_port)
	iptables -N "$WAN_CHAIN" 2>/dev/null
	iptables -F "$WAN_CHAIN" 2>/dev/null
	# Порядок внутри цепочки = порядок отказов: сперва потолок одновременных, затем темп новых,
	# и только потом ACCEPT. Не попавшее в ACCEPT проваливается обратно в zone_wan_input → REJECT.
	# Код возврата лимитов ПРОВЕРЯЕМ: `-m hashlimit --help` доказывает лишь наличие библиотеки
	# расширения, а вставка может упасть на отсутствующем модуле ядра — молча открыть порт БЕЗ
	# ограничителя нельзя, это ровно та защита, ради которой порт вообще решились открыть.
	lim=1
	iptables -A "$WAN_CHAIN" -p tcp --dport "$p" -m connlimit \
		--connlimit-above "$WAN_CONN_MAX" --connlimit-mask 32 -j DROP 2>/dev/null || lim=0
	iptables -A "$WAN_CHAIN" -p tcp --dport "$p" -m conntrack --ctstate NEW -m hashlimit \
		--hashlimit-above "$WAN_RATE" --hashlimit-burst "$WAN_BURST" \
		--hashlimit-mode srcip --hashlimit-name paneltls -j DROP 2>/dev/null || lim=0
	iptables -A "$WAN_CHAIN" -p tcp --dport "$p" -j ACCEPT || { wan_rule_clear; echo "не удалось поставить правило"; return 1; }
	iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || iptables -I "$WAN_HOOK" 1 -j "$WAN_CHAIN"
	[ "$lim" = 1 ] || echo "ВНИМАНИЕ: ограничитель частоты подключений не встал — порт открыт без защиты от перебора"
	# panel-tls слушает ЛОКАЛЬНЫЙ LAN-адрес, и пакет, пришедший на WAN-адрес, до этого сокета сам
	# не доедет: разрешающего правила мало, слушателя на внешнем адресе просто нет («порт закрыт»
	# снаружи при идеальном на вид файрволе). Bind до 0.0.0.0 НЕ расширяем — тот же сокет стал бы
	# виден гостевой сети и любому будущему интерфейсу, а инвариант панели ровно обратный. Вместо
	# этого заводим трафик DNAT'ом на LAN-адрес: слушатель прежний, путь снаружи один и явный.
	wi=$(wan_iface)
	if [ -n "$wi" ]; then
		iptables -t nat -N "$WAN_DNAT" 2>/dev/null
		iptables -t nat -F "$WAN_DNAT" 2>/dev/null
		iptables -t nat -A "$WAN_DNAT" -i "$wi" -p tcp --dport "$p" -j DNAT --to-destination "$LISTEN:$p" 2>/dev/null \
			|| echo "ВНИМАНИЕ: не удалось завернуть WAN-трафик на панель (DNAT) — снаружи не откроется"
		# HAIRPIN (NAT loopback): ИЗ ДОМА внешний адрес не открывался — пакет к WAN-IP приходит на
		# br-lan, правило выше его не ловит (`-i <wan>`), слушателя на внешнем адресе нет ⇒ RST.
		# Одна и та же ссылка обязана работать в любой сети, иначе «снаружи открывается, а дома нет»
		# читается как поломка панели. SNAT здесь НЕ нужен: сервер — сам роутер, ответ разворачивает
		# та же запись conntrack (маскарад понадобился бы, стой за DNAT другой хост LAN). Гостевую
		# сеть НЕ пускаем — вход в панель только из основной, инвариант тот же, что у bind'а.
		ha=$(wan_addr)
		wan_ip_watch "$ha"
		if [ -n "$ha" ]; then
			iptables -t nat -A "$WAN_DNAT" -i "$LAN_IF" -d "$ha" -p tcp --dport "$p" \
				-j DNAT --to-destination "$LISTEN:$p" 2>/dev/null \
				|| echo "ВНИМАНИЕ: не удалось завернуть домашний трафик на внешний адрес (hairpin)"
		fi
		iptables -t nat -C PREROUTING -j "$WAN_DNAT" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$WAN_DNAT"
	else
		echo "ВНИМАНИЕ: WAN-интерфейс не определён — снаружи не откроется"
	fi
	return 0
}

# Лимиты стоят? Считаем DROP'ы в цепочке (их ровно два, когда оба модуля зашли). Панель по этому
# полю честно предупреждает: «открыто, но без ограничителя» — а не делает вид, что всё в порядке.
wan_limits_ok() {
	n=$(iptables -S "$WAN_CHAIN" 2>/dev/null | grep -c 'j DROP')
	[ "${n:-0}" -ge 2 ] 2>/dev/null
}

wan_rule_clear() {
	# Ссылок может быть несколько (переигрыш поверх недоснятой) — снимаем, пока снимается.
	while iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null; do
		iptables -D "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || break
	done
	iptables -F "$WAN_CHAIN" 2>/dev/null
	iptables -X "$WAN_CHAIN" 2>/dev/null
	while iptables -t nat -C PREROUTING -j "$WAN_DNAT" 2>/dev/null; do
		iptables -t nat -D PREROUTING -j "$WAN_DNAT" 2>/dev/null || break
	done
	iptables -t nat -F "$WAN_DNAT" 2>/dev/null
	iptables -t nat -X "$WAN_DNAT" 2>/dev/null
	# Старые соединения переживают снятие правил (NSS/conntrack держит трансляцию) — гасим их,
	# иначе уже открытая снаружи сессия продолжает работать после «закрыл доступ». Владелец
	# сброса один — ct-lib.sh: на ядре 4.4 утилиты conntrack нет, и проверка `command -v` честно
	# отказывалась, оставляя чужую сессию живой; там сброс делает ручка ускорителя.
	ct_flush_dport "$(tls_port)"
	return 0
}

# «Правило стоит» = ОБА звена: разрешение в filter И заворот в nat. Без второго снаружи будет
# «закрыто» при зелёном статусе — ровно та ложь, которую панель обязана не показывать.
wan_rule_active() {
	iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || return 1
	iptables -t nat -C PREROUTING -j "$WAN_DNAT" 2>/dev/null
}

# «Второй фактор включён?» — спрашиваем ВЛАДЕЛЬЦА (totp.sh), своей копии состояния тут нет
# (та же причина, что у tls_*/wan_*: две копии разъезжаются). Нет движка — ответ «нет».
totp_on() {
	[ -f "$ENODIA_DIR/totp.sh" ] || return 1
	case "$(sh "$ENODIA_DIR/totp.sh" status 2>/dev/null | grep '^{' | tail -1)" in
		*'"on":true'*) return 0 ;;
	esac
	return 1
}

# ОТКРЫТИЕ ПОРТА НАРУЖУ ТРЕБУЕТ ВТОРОГО ФАКТОРА. За HTTP-Basic здесь стоит не «страница
# настроек», а действие `console` в cgi-bin/action — root-shell по замыслу; в интернете один
# лишь пароль его не удержит. Перебор Basic наши же лимиты НЕ ловят: `--connlimit`/`--hashlimit`
# считают СОЕДИНЕНИЯ, а Basic перебирается тысячами запросов внутри одного keep-alive TCP — на
# уровень CGI неудачная попытка вообще не доезжает (uhttpd отвечает 401 сам, не запуская нас),
# то есть счётчик там завести физически негде. Единственный настоящий рубеж — TOTP: его пауза
# после неудач (totp_lock_bump) считается уже НАШИМ кодом, на каждый запрос.
# `--force` оставлен сознательно: это CLI, и хозяин вправе открыть порт зная цену (например,
# чтобы починить панель, когда телефон с приложением потерян). Панель `--force` не передаёт
# НИКОГДА — там путь один: сперва включи 2FA.
# УЖЕ ОТКРЫТЫЙ доступ этот гард не закрывает: `wan_rule_apply` (его зовёт cron каждые 5 минут)
# сюда не заходит. Иначе обновление панели молча отбирало бы вход снаружи у того, кто настроил
# его раньше этой проверки, — и выяснилось бы это в отъезде. Для таких установок панель показывает
# предупреждение рядом с тумблером.
wan_on() {
	tls_enabled || { echo "сперва включи HTTPS ($0 tls-on) — наружу открываем только его"; return 1; }
	tls_running || { echo "HTTPS включён, но panel-tls не работает — сперва почини его"; return 1; }
	_2fa=0; totp_on && _2fa=1
	if [ "$1" != "--force" ] && [ "$_2fa" = 0 ]; then
		echo "сперва включи второй фактор (2FA) — наружу открываем только под ним:"
		echo "панель → Настройки → Доступ к панели → Второй фактор."
		echo "осознанно открыть без него: $0 wan-on --force"
		return 1
	fi
	: > "$WAN_FLAG"
	wan_rule_apply || { rm -f "$WAN_FLAG"; return 1; }
	v=$(wan_verdict); set -- $v
	case "$1" in
		public)  echo "открыт доступ снаружи: https://$2:$(tls_port)" ;;
		private) echo "правило поставлено, но WAN-адрес $2 приватный (CGNAT/двойной NAT) —"
		         echo "снаружи панель не откроется, пока провайдер не даст белый IP" ;;
		*)       echo "правило поставлено, но WAN-адрес определить не вышло" ;;
	esac
	# Итоговая строка обязана называть ФАКТ, а не намерение: под `--force` порт открыт БЕЗ второго
	# фактора, и «вход по-прежнему под паролем панели» звучало бы как «всё в порядке».
	if [ "$_2fa" = 1 ]; then
		echo "вход — пароль панели плюс код из приложения"
	else
		echo "ВТОРОГО ФАКТОРА НЕТ: вход держит один только пароль — он должен быть длинным"
	fi
}

wan_off() {
	rm -f "$WAN_FLAG"
	wan_rule_clear
	echo "доступ снаружи закрыт"
}

# --- Состояние для панели ОДНИМ JSON. Копию этой логики в cgi-bin/data не заводим: два места,
# считающие «включено/работает» по одним и тем же файлам, разъезжаются (проверено на подписках).
# Прогресс доустановки бинаря по воздуху отдаём отсюда же — panel-tls принадлежит этому скрипту.
cmd_json() {
	ti=false; [ -x "$TLS_BIN" ] && ti=true
	to=false; tls_enabled && to=true
	tr_=false; tls_running && tr_=true
	wo=false; wan_enabled && wo=true
	wr=false; wan_rule_active && wr=true
	wl=true; wan_rule_active && { wan_limits_ok || wl=false; }
	up=false; is_running && up=true
	cert=false; [ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] && cert=true
	v=$(wan_verdict); set -- $v; wkind="$1"; waddr="$2"
	# Прогресс доустановки panel-tls по воздуху. Источник — ОБЩИЕ файлы движка компонентов
	# (.proto-install.{state,log}): кнопка «Установить» зовёт packages.sh, своего лога у неё нет.
	ing=false; imsg=""
	[ -f /tmp/proto-install.pid ] && [ -d "/proc/$(cat /tmp/proto-install.pid 2>/dev/null)" ] && ing=true
	# jesc вместо прежнего «вырезать кавычки + cut -c»: тот резал БАЙТАМИ (лог по-русски ⇒ обрыв
	# посреди буквы) и не снимал сырой TAB. Одна копия на проект — json-lib.sh; шим ниже у либы.
	[ -f "$ENODIA_STATE/.proto-install.log" ] && imsg=$(tail -n1 "$ENODIA_STATE/.proto-install.log" 2>/dev/null | jesc 160)
	# Второй фактор входа живёт в totp.sh — он и отдаёт свой срез. Своей копии «включено/сколько
	# кодов осталось» тут нет по той же причине, что и у TLS: две копии состояния разъезжаются.
	tf=""
	[ -f "$ENODIA_DIR/totp.sh" ] && tf=$(sh "$ENODIA_DIR/totp.sh" status 2>/dev/null | grep '^{' | tail -1)
	[ -n "$tf" ] || tf='{"on":false,"pending":false,"clock":true,"recovery":0,"sessions":0,"lock":0,"engine":false}'
	printf '{"up":%s,"lan":"%s","port":%s,"installed":%s,"cert":%s,"tls_on":%s,"tls_running":%s,"tls_port":%s,"wan_on":%s,"wan_rule":%s,"wan_limits":%s,"wan_kind":"%s","wan_addr":"%s","installing":%s,"install_msg":"%s","totp":%s}\n' \
		"$up" "$LISTEN" "$PORT" "$ti" "$cert" "$to" "$tr_" "$(tls_port)" "$wo" "$wr" "$wl" "$wkind" "$waddr" "$ing" "$imsg" "$tf"
}

setpass() {
	pass="$1"
	[ -n "$pass" ] || { echo "usage: $0 setpass <пароль>"; return 1; }
	[ -x "$UHTTPD" ] || { echo "нет $UHTTPD"; return 1; }
	# ХЭШ ОБЯЗАН БЫТЬ СОЛЁНЫМ. `uhttpd -m` солит ПУСТОЙ солью (замерено на живом роутере:
	# `/:admin:$1$$ft…`), то есть один и тот же пароль даёт ОДИН И ТОТ ЖЕ хэш на всех установках
	# проекта: утёкший `uhttpd.conf` вскрывается предвычисленной таблицей без единого перебора, а
	# панель бывает открыта наружу по HTTPS. Соль — из /dev/urandom, шестнадцатеричная (в соли
	# crypt запрещён только «$»), хэш считает openssl: он на роутере есть, им уже ходят notify.sh
	# и gh-update.sh. Пароль отдаём СТДИНОМ, а не в argv: argv видна в /proc/<pid>/cmdline любому,
	# кто в этот миг читает список процессов.
	# ФОЛБЭК ОБЯЗАТЕЛЕН И ПРОВЕРЯЕТ РЕЗУЛЬТАТ, а не наличие бинаря: сборка без `openssl passwd`
	# (или без `-stdin`) должна вернуть прежнее поведение байт-в-байт. Пустой или кривой хэш здесь =
	# панель, которая не пускает НИКОГО, а чинится это только по SSH. Старые бессолевые хэши
	# остаются валидными: crypt читает соль из самой строки, переписывать их не нужно.
	#
	# СХЕМА ОБЯЗАНА ОСТАТЬСЯ `$1$` (MD5-crypt). «Усилить до SHA-512» — первое, что просится (и это
	# просил внешний аудит), но ЗАМЕРЕНО на живом BE7000 23.08.2026: `openssl passwd -6` и `-5`
	# считают хэш прекрасно, uhttpd с таким хэшем СТАРТУЕТ и слушает порт — и УМИРАЕТ на первом же
	# запросе с авторизацией (good=000 bad=000, процесса больше нет; с `$1$` — good=200 bad=401).
	# Причина в libc: панель линкована на musl (`/lib/ld-musl-aarch64.so.1`), а в этой сборке от
	# crypt остались только `crypt_r` и DES/MD5 — строки `rounds=` (константа crypt_sha256/512) в
	# libc.so НЕТ ВООБЩЕ. То есть `$6$` тут не «слабее защищён», а панель, которая падает на каждом
	# входе. Стенд: local/uhttpd-crypt-test.sh.
	# Отсюда единственный доступный рычаг — ЭНТРОПИЯ СОЛИ. Хекс от md5sum давал 4 бита на символ,
	# то есть 32 бита вместо штатных для crypt 48: алфавит соли — `./0-9A-Za-z` (64 символа), и
	# base64 от шести случайных байт ложится в него ровно (8 символов, `+` меняем на `.`, `/` в
	# соли законен). Проверка теперь ПО АЛФАВИТУ, а не по длине: восемь любых символов пропустили бы
	# и `$`, который crypt считает концом соли.
	h=""
	_salt=$(dd if=/dev/urandom bs=6 count=1 2>/dev/null | openssl base64 2>/dev/null | tr -d '\n' | tr '+' '.' | cut -c1-8)
	case "$_salt" in
		????????) case "$_salt" in *[!A-Za-z0-9./]*) _salt="" ;; esac ;;
		*) _salt="" ;;
	esac
	if [ -n "$_salt" ]; then h=$(printf '%s' "$pass" | openssl passwd -1 -salt "$_salt" -stdin 2>/dev/null); fi
	case "$h" in
		'$1$'?*'$'?*) : ;;
		*) h=$("$UHTTPD" -m "$pass" 2>/dev/null) ;;
	esac
	[ -n "$h" ] || { echo "не удалось сгенерить хэш"; return 1; }
	mkdir -p "$DOCROOT"
	printf '/:%s:%s\n' "$AUTHUSER" "$h" > "$AUTHCONF"
	chmod 600 "$AUTHCONF"
	echo "пароль панели задан (пользователь: $AUTHUSER)"
	# ПРИМЕНЯЕТ ПАРОЛЬ ТОТ, КТО ЕГО МЕНЯЕТ. uhttpd читает файл авторизации РОВНО ОДИН РАЗ — при
	# старте (ключ -c), поэтому свежий хэш на диске сам по себе не значит ничего: живая панель
	# пускает по СТАРОМУ до перезапуска. Хуже, что вызыватели этого не видели: идиома «setpass &&
	# web-ui.sh start» на работающей панели получает от start бодрое «уже работает (pid …)» и
	# рапортует успех. Поймано на железе 16.08.2026 (AX3600): пароль сменили с ПК, файл переписан,
	# процесс запущен 22 часами раньше — панель по-прежнему пускала по старому паролю.
	# Исключение ровно одно — вызов из CGI: мы потомок этого же uhttpd, и, убив его сейчас, потеряем
	# ответ, которого ждёт браузер (панель поэтому рестартит отложенно, сама). Флаг явный, а
	# $GATEWAY_INTERFACE — страховка для копий CGI постарше этой строки.
	if [ "$2" = "--no-restart" ] || [ -n "$GATEWAY_INTERFACE" ]; then
		echo "(перезапуск за вызывателем — до него панель пускает по старому паролю)"
		return 0
	fi
	if is_running; then stop >/dev/null 2>&1; start; fi
}

# ПОЧЕМУ панель не поднялась. `start-stop-daemon -b` заворачивает stdio демона в /dev/null
# (грабля проекта: «в логе пусто» ≠ «ошибок нет»), поэтому настоящая причина до сих пор
# терялась, а наверх уезжало голое «не удалось поднять uhttpd» — с ним нечего делать ни
# тестеру, ни ПК-скрипту, ни установщику, который зовёт нас последним шагом. Судим по ФАКТАМ,
# а последним шагом спрашиваем сам uhttpd: гоняем его пару секунд В ПЕРЕДНЕМ ПЛАНЕ (порт
# заведомо свободен — фоновая попытка только что провалилась) и ловим stderr.
# Аргументы приходят ТЕ ЖЕ, что уехали в start-stop-daemon ("$@" от start): вторая копия
# строки запуска разъехалась бы с первой, и диагностика начала бы врать.
start_why() {
	# №1 по частоте: адреса ещё нет. LISTEN берётся из br-lan, а на буте бридж поднимается
	# позже нас — uhttpd молча падает на bind. Тот же случай — смена LAN-подсети роутера.
	if ! ip -4 addr show 2>/dev/null | grep -q "inet ${LISTEN}[/ ]"; then
		echo "адреса $LISTEN нет ни на одном интерфейсе — сеть ещё не поднялась или LAN-IP роутера сменился"
		return 0
	fi
	_wb=$(netstat -ltn 2>/dev/null | grep "[.:]$PORT " | head -1)
	if [ -n "$_wb" ]; then
		echo "порт $PORT уже занят другим процессом ($_wb)"
		return 0
	fi
	_we=$(timeout -t 2 "$UHTTPD" "$@" 2>&1 | grep -v '^[[:space:]]*$' | head -2 | tr '\n' ' ')
	[ -n "$_we" ] && { echo "uhttpd отказался стартовать: $_we"; return 0; }
	echo "вручную uhttpd стартует, а фоновый запуск не удержался — проверь $PIDFILE и место в /tmp"
}

start() {
	[ -x "$UHTTPD" ] || { echo "нет $UHTTPD"; return 1; }
	[ -f "$DOCROOT/index.html" ] || { echo "нет $DOCROOT/index.html"; return 1; }
	[ -f "$AUTHCONF" ] || { echo "сначала задай пароль: $0 setpass <пароль>"; return 1; }
	# ВАЖНО: при живом uhttpd не выходим, а идём дальше к tls_start — этот же start зовёт
	# cron каждые 5 минут, и он обязан лечить ОБА процесса, а не только первый. Сюда же прицеплен
	# переигрыш WAN-правила: его смывает fw3 reload, и другого сторожа у него нет.
	if is_running; then echo "уже работает (pid $(cat "$PIDFILE"))"; tls_start; wan_rule_apply; return 0; fi
	[ -f "$PIDFILE" ] && : > "$PIDFILE"
	# -i .html=htmlwrap — отдавать ДОКУМЕНТ панели с `Cache-Control: no-cache` (заголовков у uhttpd
	# нет, но есть интерпретатор по расширению). Без этого браузер кэширует index.html эвристически
	# и после обновления держит СТАРЫЙ документ со СТАРОЙ ссылкой `?v=` ⇒ «фича не приехала»,
	# невоспроизводимо (поймано на железе 2026-07-21). Подробности — в шапке web/htmlwrap.
	# Нет файла (установка старее фичи) → стартуем как раньше, панель важнее заголовка.
	[ -x "$DOCROOT/htmlwrap" ] && set -- -i ".html=$DOCROOT/htmlwrap" || set --
	# -t/-T подняты над дефолтами uhttpd (60 с скрипт, 30 с сеть) РАДИ ОДНОГО потребителя —
	# `cgi-bin/diag?full=1`: он собирает архив с логами синхронно, и это единственная страница
	# панели, которая заведомо думает десятки секунд (замер на BE7000 — 19 с, на armv7 дольше).
	# Сетевой таймаут важен не меньше скриптового: до первого байта tar клиент ждёт молча, а
	# 30-секундный дефолт рвал бы соединение ровно на слабом роутере, где архив и нужен.
	# ПОТОЛОК задаёт именно -T, а не -t: молчащий CGI умрёт на 120 с, до 180 не дойдёт никогда
	# (по HTTPS та же цифра — IDLE_TO в panel-tls.c). Понадобится больше — поднимать ВСЕ ТРИ.
	# Полный список аргументов собираем В "$@" ОДИН раз — его же дословно повторяет диагностика
	# отказа (start_why гоняет uhttpd в переднем плане теми же ключами).
	set -- -f -h "$DOCROOT" -c "$AUTHCONF" -r "$REALM" -x /cgi-bin \
		-t 180 -T 120 \
		-p "$LISTEN:$PORT" -I index.html -D -S "$@"
	start-stop-daemon -S -b -m -p "$PIDFILE" -x "$UHTTPD" -- "$@"
	sleep 1
	if is_running; then echo "поднят: http://$LISTEN:$PORT  (pid $(cat "$PIDFILE"))"
	else echo "не удалось поднять uhttpd: $(start_why "$@")"; return 1; fi
	tls_start
	wan_rule_apply
}

stop() {
	wan_rule_clear     # порт наружу без живой панели не держим (флаг остаётся — start вернёт)
	tls_stop           # сперва терминатор: без бэкенда он всё равно бесполезен
	if is_running; then
		start-stop-daemon -K -p "$PIDFILE" -x "$UHTTPD" 2>/dev/null
		: > "$PIDFILE"
		echo "остановлен"
	else
		echo "не запущен"
	fi
}

tls_on() {
	port="$1"
	case "$port" in
		"" ) port=$(tls_port) ;;
		*[!0-9]* ) echo "порт должен быть числом"; return 1 ;;
	esac
	[ "$port" -gt 0 ] 2>/dev/null && [ "$port" -lt 65536 ] || { echo "порт вне диапазона"; return 1; }
	[ "$port" = "$PORT" ] && { echo "порт $port занят самой панелью"; return 1; }
	[ -x "$TLS_BIN" ] || { echo "нет $TLS_BIN (обнови установку)"; return 1; }
	echo "$port" > "$TLS_FLAG"
	tls_stop >/dev/null 2>&1     # порт мог смениться — поднимаем заново
	tls_start
	wan_rule_apply               # порт открыт наружу — правило пересобрать под НОВЫЙ порт
}

# Выключение HTTPS снимает и доступ снаружи, причём ВМЕСТЕ с флагом: иначе следующий tls-on
# молча вернул бы панель в интернет — неожиданное самораскрытие хуже лишнего клика.
tls_off() {
	wan_enabled && { wan_off; echo "(доступ снаружи снят вместе с HTTPS)"; }
	tls_stop
	rm -f "$TLS_FLAG"
	echo "HTTPS выключен"
}

case "$1" in
	start)     start ;;
	stop)      stop ;;
	restart)   stop; start ;;
	setpass)   setpass "$2" "$3" ;;
	tls-on)    tls_on "$2" ;;
	tls-off)   tls_off ;;
	tls-cert)  rm -f "$TLS_CERT" "$TLS_KEY"; tls_ensure_cert && { tls_stop >/dev/null 2>&1; tls_start; } ;;
	wan-on)    wan_on "$2" ;;      # "$2" = --force: открыть порт БЕЗ второго фактора (только из CLI)
	wan-off)   wan_off ;;
	wan-rule)  wan_rule_apply ;;   # ручной переигрыш (после fw3 reload), тот же путь, что из start
	json)      cmd_json ;;         # состояние для панели (cgi-bin/data?section=panel_access)
	status|"") if is_running; then echo "работает (pid $(cat "$PIDFILE")) на http://$LISTEN:$PORT"; else echo "не запущен"; fi
	           if tls_enabled; then
	                   if tls_running; then echo "HTTPS: работает (pid $(cat "$TLS_PID")) на https://$LISTEN:$(tls_port)"
	                   else echo "HTTPS: включён, но НЕ работает (порт $(tls_port); см. $TLS_LOG)"; fi
	           else echo "HTTPS: выключен"; fi
	           if wan_enabled; then
	                   v=$(wan_verdict); set -- $v
	                   if wan_rule_active; then st="правило стоит"; else st="ВКЛЮЧЁН, но правила НЕТ (fw3 смыл?)"; fi
	                   case "$1" in
	                           public)  echo "Снаружи: $st — https://$2:$(tls_port)" ;;
	                           private) echo "Снаружи: $st, но WAN-адрес $2 приватный — извне не достучаться" ;;
	                           *)       echo "Снаружи: $st, WAN-адрес не определён" ;;
	                   esac
	           else echo "Снаружи: закрыт"; fi
	           # Второй фактор (totp.sh) — печатаем и здесь: это первое, что смотрят по SSH, когда
	           # «панель просит какой-то код». Аварийное отключение: sh totp.sh disable --force
	           if [ -f "$ENODIA_DIR/totp.sh" ]; then
	                   case "$(sh "$ENODIA_DIR/totp.sh" status 2>/dev/null)" in
	                           *'"on":true'*) echo "Второй фактор (TOTP): включён" ;;
	                           *)             echo "Второй фактор (TOTP): выключен" ;;
	                   esac
	           fi ;;
	*) echo "usage: $0 {start|stop|restart|status|setpass <пароль> [--no-restart]|tls-on [порт]|tls-off|tls-cert|wan-on [--force]|wan-off|wan-rule|json}"; exit 1 ;;
esac
