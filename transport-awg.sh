#!/bin/sh
# transport-awg.sh — ПЛАГИН транспорта AmneziaWG (несущая awg0).
#
# Часть плана «транспорт-агностичное ядро + плагины».
# Это ЗЕРКАЛО xray-transport.sh для AmneziaWG: одинаковый контракт up|down|health|
# failover|status, чтобы оркестратор (heal/watchdog/меню) дёргал любой протокол
# единообразно, не зная, awg внутри или xray.
#
# РАЗДЕЛЕНИЕ СЛОЁВ (ключевая идея красивого варианта):
#   * mark-core (ОБЩЕЕ, не зависит от протокола): ipset enodia_list/iplist_set, маркировка
#     mangle -m set -> MARK 0x1, ip rule fwmark 0x1 -> table 1000, цепочки VPN_EXCLUDE/
#     VPN_FORCE, домены. Его строит установщик/heal ОДИН раз и не трогает при смене
#     транспорта. Этот плагин mark-core НЕ касается.
#   * НЕСУЩАЯ (пер-транспорт, забота плагина): что стоит в default table 1000 (тут awg0),
#     FORWARD на неё, MASQUERADE (awg — нужен, у xtun/tun2socks — нет), DNS-схема
#     (awg — внутренний 172.29.x через awg0; xray — публичный, маркированный в туннель).
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark -> table 1000 (mark-core). Если awg0
# умирает или несущую сняли (down) — table 1000 теряет default, fwmark-трафик падает
# в main -> НАПРЯМУЮ (fail-open, не блэкхол). Снять привязку к ДОХЛОМУ awg0 полностью
# (вместе с mark-core) — это switch-vpn.sh safety_off; здесь down лишь РЕЛИНКВИТ
# несущей (mark-core остаётся, повторная активация дешевле). Управление/SSH (br-lan,
# main) от транспорта не зависят.
#
# ВЫЗОВ — как подпроцесс (НЕ source), симметрично xray-transport.sh:
#   transport-awg.sh up        — сделать AmneziaWG активной несущей (весь дом)
#   transport-awg.sh down      — снять awg-несущую (awg0 -> тёплый резерв, трафик прямой)
#   transport-awg.sh status    — показать состояние
#   transport-awg.sh health    — здоровье awg-несущей (для watchdog):
#                                код 0 = здорова / активен не awg; 1 = awg нездоров
#   transport-awg.sh failover  — перебор awg-резервов (делегат в switch-vpn.sh failover,
#                                единый источник правды по перебору; см. ниже)

ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
TABLE=1000
IFACE=awg0
FWMARK=0x1
TRANSPORT_FLAG="$ENODIA_STATE/.transport"
ACTIVE_CONF="$ENODIA_STATE/awg.conf"
SWITCH="$ENODIA_DIR/switch-vpn.sh"
AWG_SETUP="$ENODIA_DIR/awg_setup.sh"
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"
APPLY_BYPASS="$ENODIA_DIR/apply-bypass.sh"
HS_MAX=180            # порог возраста handshake (сек) — как в watchdog.sh
PUB_DNS1=1.1.1.1
PUB_DNS2=8.8.8.8

# Слой шифрованного DNS (doh-lib.sh): при включённом DoH перехватывает установку upstream
# (dnsmasq→127.0.0.1#5053 + :443 резолвера в туннель). ВЫКЛ (дефолт) → doh_apply_dns даёт 1,
# работает прежний путь байт-в-байт. Шим на случай установки без lib (DoH просто недоступен).
# Форма `if [ -f ]; then . ; fi` — инвариант проекта: провалившийся `.` в ash фатален и
# МОЛЧАЛИВ (шелл выходит на месте, rc=2), а `[ -f x ] && . x` под set -e ещё и пробрасывает 1.
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }
# dns-lib: общий резолв Endpoint-домена (is_ipv4/resolve_ipv4) для awg-СЛОТА (Ф2) — тот же
# приём подстановки IP в Endpoint, что у awg_setup.sh для awg0 (setconf не резолвит через
# запертый dnsmasq, [[awg-config-format-footguns]]). Библиотеки нет — НЕ падаем (основная
# несущая awg0 её не требует, конфиг ей генерит awg_setup.sh), но слот об этом честно скажет:
# см. slot_gen_conf, где молчаливый пропуск подстановки означал бы отвергнутый setconf'ом
# конфиг слота и НИ СЛОВА в логе.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi

# Возраст отметки времени с защитой от скачка часов (clock-lib.sh). Шим = прежнее поведение:
# частичная установка без lib не должна падать, но и защиты там не будет.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

log() { echo "[transport-awg] $*"; }
notify_event() { [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# CLI handshake читает awg (amneziawg-tools), НЕ amneziawg-go (тот ДЕМОН и на show
# печатает Usage). Предпочитаем локальный бинарь, иначе из PATH.
wg_bin() {
    if [ -x "$ENODIA_BIN/awg" ]; then echo "$ENODIA_BIN/awg"
    elif command -v awg >/dev/null 2>&1; then echo awg
    else echo ""; fi
}

# Возраст последнего handshake в секундах (999999 = handshake'а не было / нет бинаря).
# Считает age_since (clock-lib.sh): голая разность «now - hs» врёт ровно на величину скачка часов,
# а часы тут без RTC и прыгают вперёд через ~13 мин после загрузки — cmd_health на этом объявлял
# живую несущую мёртвой. [[watchdog-clock-step-false-death]]
hs_age() {
    wg=$(wg_bin); [ -n "$wg" ] || { echo 999999; return; }
    hs=$("$wg" show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    age_since "$hs"
}

carrier_up() { ip link show "$IFACE" 2>/dev/null | grep -q 'state UP\|UNKNOWN\|LOWER_UP'; }

# ---- анти-петля: endpoint своего VPS мимо маркировки ----------------------
# IP endpoint'а awg-сервера. Сначала у демона (awg show — уже резолвленный пир),
# фолбэк — Endpoint из awg.conf (обычно сразу IP). Только IPv4 (iplist_set = cidr4).
awg_endpoint_ip() {
    wg=$(wg_bin)
    if [ -n "$wg" ]; then
        ep=$("$wg" show "$IFACE" endpoints 2>/dev/null | awk 'NR==1{print $2}' | sed 's/:[0-9]*$//')
        echo "$ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo "$ep"; return 0; }
    fi
    ep=$(grep -E '^Endpoint' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//; s/[[:space:]]//g')
    echo "$ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && echo "$ep"
}
# Исключить endpoint awg-сервера из маркировки (иначе свои же UDP-пакеты к VPS,
# если его IP в iplist_set, заворачиваются обратно в awg0 = петля). Идемпотентно,
# переживает ребут (.endpoint-bypass на /data). Зовём ДО постановки default->awg0.
exclude_endpoint() {
    ep=$(awg_endpoint_ip)
    [ -n "$ep" ] || { log "endpoint awg не определён — пропуск анти-петли"; return 0; }
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-set "$ep" >/dev/null 2>&1
    log "endpoint $ep исключён из маркировки (анти-петля)"
}

# ---- DNS ------------------------------------------------------------------
# awg-режим: dnsmasq форвардит во ВНУТРЕННИЙ Amnezia-DNS (172.29.172.254 dev awg0).
# ЕДИНСТВЕННАЯ копия возврата туннельного DNS для awg (в switch-vpn.sh жил дубль мимо
# doh_apply_dns — он перетирал 00-upstream.conf после failover'а и молча выключал DoH;
# снят при ревью батча 4). VPN_DNS берём из активного awg.conf.
restore_vpn_dns() {
    doh_apply_dns tunnel && return 0    # DoH ВКЛ → резолв через локальный прокси в туннель; ВЫКЛ → ниже как было
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -z "$vpn_dns" ] && vpn_dns=172.29.172.254
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\n' "$vpn_dns" > /etc/dnsmasq.d/00-upstream.conf
    ip route replace "$vpn_dns/32" dev "$IFACE" 2>/dev/null
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}
# Релинквит несущей -> DNS на публичный НАПРЯМУЮ (не маркируем: при снятой несущей
# трафик к 1.1.1.1/8.8.8.8 должен идти мимо туннеля). Зеркало DNS-части safety_off.
set_public_dns() {
    doh_apply_dns direct && return 0    # DoH ВКЛ (или авто-режим прямых) → резолв через локальный прокси; иначе → ниже как было
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -n "$vpn_dns" ] && ip route del "$vpn_dns/32" dev "$IFACE" 2>/dev/null
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\nserver=%s\n' "$PUB_DNS1" "$PUB_DNS2" > /etc/dnsmasq.d/00-upstream.conf
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ---- несущая (carrier) ----------------------------------------------------
# Поднять awg0, если его нет. Зеркало bring_up из switch-vpn.sh (init.d -> вендорный
# awg_setup.sh -> ждём интерфейс). Возврат 0 — awg0 есть.
# «awg_setup.sh отработал» ⇒ его последняя строка (`/etc/init.d/firewall reload`) СНЕСЛА ВСЕ
# iptables: цепочки apply-bypass, ENODIA_ZAPRET+NFQUEUE, FORWARD доп-выходов, PANEL_WAN, «доступ
# домой». Мы вернём только СВОЮ несущую, поэтому просим канонический переигрыш — см. replay_fw3.
FW3_WIPED=0
ensure_carrier() {
    if ip link show "$IFACE" >/dev/null 2>&1; then return 0; fi
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        [ -x "$s" ] && { "$s" start >/dev/null 2>&1; break; }
    done
    if ! ip link show "$IFACE" >/dev/null 2>&1 && [ -f "$AWG_SETUP" ]; then
        FW3_WIPED=1
        ( cd "$ENODIA_DIR" && sh ./awg_setup.sh >/tmp/transport-awg-setup.log 2>&1 )
    fi
    i=0; while [ $i -lt 15 ]; do
        ip link show "$IFACE" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# Переиграть ВСЕ цепочки после нашего же fw3-reload. Канонический переигрыш один —
# `vpn-toggle.sh repair` (он знает про apply-bypass, zapret, доп-выходы и «доступ домой»),
# своей копии списка тут быть не должно. Зовём ТОЛЬКО после записи .transport=awg: repair
# читает этот флаг и иначе поднял бы несущую ПРЕЖНЕГО транспорта. Рекурсии нет — на
# transport=awg repair ставит несущую инлайном, awg_setup.sh не трогает (awg0 уже поднят).
replay_fw3() {
    [ "$FW3_WIPED" = 1 ] || return 0
    FW3_WIPED=0
    [ -f "$ENODIA_DIR/vpn-toggle.sh" ] || return 0
    log "awg_setup сделал firewall reload — переигрываю цепочки (vpn-toggle repair)"
    sh "$ENODIA_DIR/vpn-toggle.sh" repair >/dev/null 2>&1 || true
}

# Наложить awg-несущую поверх mark-core: default dev awg0 + FORWARD awg0 + MASQUERADE
# awg0 + маршрут к VPN_DNS. Это КАРРИЕР-часть split-route.sh (mark-core/ip rule —
# отдельно, тут не трогаем). Идемпотентно.
apply_awg_routing() {
    ip link set "$IFACE" up 2>/dev/null
    # FORWARD ACCEPT (fw3 policy FORWARD=DROP -> без этого LAN-трафик в awg0 дропается)
    iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$IFACE" -j ACCEPT
    iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$IFACE" -j ACCEPT
    # NAT для исходящего через awg0 (у tun2socks/xtun этого НЕ нужно — он терминирует)
    iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    # СВАП дефолта в боевой таблице на awg0 (маркировку/ip rule mark-core НЕ трогаем)
    ip route replace default dev "$IFACE" table "$TABLE"
}

# Снять awg-несущую (релинквит): убрать default/FORWARD/MASQUERADE awg0. mark-core
# (ip rule + ipset MARK) ОСТАЁТСЯ -> table 1000 без default -> fail-open в main (прямой).
# awg0 НЕ удаляем — тёплый резерв для быстрого кросс-возврата.
remove_awg_routing() {
    ip route del default dev "$IFACE" table "$TABLE" 2>/dev/null
    iptables -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null
}

# ---- awg-СЛОТ (доп-выход, мульти-транспорт Ф2) ----------------------------------
# Дизайн: local/CLAUDE-мультитранспорт-дизайн.md. «Выход» слота = (awg, configs/<cfg>.conf):
# СВОЯ несущая awg<id> (id 2..4; awg0 = основной), свой UAPI-сокет, свой IP из конфига, default в
# table 100<id>. Марку 0x<id> и `ip rule fwmark -> table 100<id>` ставит mark-core (transport.sh
# после slot-up его переигрывает) — тут ТОЛЬКО карриер: подъём awgN + FORWARD/MASQUERADE + вывод
# endpoint'а из-под маркировки (анти-петля). БЕЗ DNS (один dnsmasq через основной слот, дизайн §DNS),
# БЕЗ guest/firewall-зоны (это awg0-специфика awg_setup.sh). КЛЮЧЕВОЕ ОТЛИЧИЕ от awg_setup.sh:
# НИКАКОГО `killall amneziawg-go` (убил бы awg0 и другие слоты!) — гасим ТОЛЬКО демон СВОЕГО awgN.
slot_iface()   { echo "awg$1"; }               # id 2..4 -> awg2/awg3/awg4
slot_table()   { echo "100$1"; }               # id 2 -> 1002 ...
slot_srcconf() { echo "$ENODIA_STATE/configs/$1.conf"; }   # исходный конфиг страны/сервера
slot_ifconf()  { echo "$ENODIA_BIN/awg$1.conf"; }        # сгенерированный stripped conf для setconf

# pid'ы демона amneziawg-go ИМЕННО этого iface (по /proc/*/cmdline: busybox ps ненадёжен с флагами,
# а демон зовётся с полным путём + iface-аргументом — матчим по нему, awg0/другие слоты не заденем).
slot_daemon_pids() {   # $1 = iface (awgN)
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        case "$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) " in
            *"amneziawg-go $1 "*) echo "${_p#/proc/}" ;;
        esac
    done
}
# Погасить демон awgN (TERM -> добить KILL) + снять его stale UAPI-сокет. НЕ трогает awg0.
slot_kill_daemon() {   # $1 = iface
    _if="$1"
    for _pid in $(slot_daemon_pids "$_if"); do kill "$_pid" 2>/dev/null; done
    _i=0
    while [ -n "$(slot_daemon_pids "$_if")" ] && [ "$_i" -lt 8 ]; do
        [ "$_i" = 3 ] && for _pid in $(slot_daemon_pids "$_if"); do kill -9 "$_pid" 2>/dev/null; done
        sleep 1; _i=$((_i+1))
    done
    rm -f "/var/run/amneziawg/$_if.sock" "/var/run/wireguard/$_if.sock" 2>/dev/null
}

# Дефолтный MTU доп-выхода, когда строки MTU= в конфиге нет (у нативных .conf Amnezia её нет
# НИКОГДА). Зеркало AWG_MTU_DEFAULT из awg_setup.sh — полный разбор «почему 1376, а не 1420»
# и замеры с железа там же; правишь одно — правь и второе.
AWG_MTU_DEFAULT=1376

# Сгенерировать stripped iface-conf из configs/<cfg>.conf. Зеркало awg_setup.sh (парс Address/MTU,
# вырезание wg-quick-директив, чистка пустых I1..I5 AWG 2.0, подстановка IP в Endpoint-домен). DNS
# слоту не нужен (свой dnsmasq не поднимаем). Печатает "ADDRESS<TAB>MTU".
slot_gen_conf() {   # $1 = src_conf, $2 = dst iface-conf
    _src="$1"; _dst="$2"
    _addr=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' \t\r')
    _mtu=$(grep -E '^[[:space:]]*MTU[[:space:]]*=' "$_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    awk '!/^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=/' "$_src" > "$_dst"
    sed -i '/^[[:space:]]*I[1-5][[:space:]]*=[[:space:]]*$/d' "$_dst" 2>/dev/null   # пустые I1..I5 валят setconf
    _epsrc=$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    _ephost=$(echo "$_epsrc" | sed 's/:[0-9]*$//')
    _epport=$(echo "$_epsrc" | sed -n 's/.*:\([0-9]*\)$/\1/p')
    case "$_ephost" in
        ''|\[*) : ;;                                   # нет Endpoint / IPv6-литерал — не подставляем
        # ВНИМАНИЕ: stdout функции — это её РЕЗУЛЬТАТ ("ADDRESS<TAB>MTU", его читает
        # slot_carrier_up через cut), поэтому все сообщения тут строго в stderr.
        *) if ! command -v is_ipv4 >/dev/null 2>&1; then
               # Без dns-lib.sh подставить IP нечем. Молчать тут НЕЛЬЗЯ: `awg setconf` резолвит
               # домен сам через запертый в туннель dnsmasq и, промахнувшись, отвергает конфиг
               # ЦЕЛИКОМ — awgN встанет пустым, а в логе не будет ни строчки о причине.
               log "слот: нет $ENODIA_DIR/dns-lib.sh — Endpoint '$_ephost' останется ИМЕНЕМ; awg setconf может отвергнуть конфиг слота целиком (обнови скрипты)" >&2
           elif ! is_ipv4 "$_ephost"; then
               _epip=$(resolve_ipv4 "$_ephost" 2>/dev/null)
               if [ -n "$_epip" ] && [ -n "$_epport" ]; then
                   sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $_epip:$_epport|" "$_dst"
               else
                   log "слот: не зарезолвил Endpoint '$_ephost' (ни dnsmasq, ни DoH) — setconf может отвергнуть конфиг слота целиком" >&2
               fi
           fi ;;
    esac
    printf '%s\t%s\n' "$_addr" "$_mtu"
}

# Поднять несущую awgN (id, cfg-name). Возврат 0 = awgN есть. Идемпотентно: живой iface = тёплый,
# конфиг не пересобираем; отсутствует = генерим conf + стартуем демон + IP/MTU/up.
slot_carrier_up() {   # $1 = id ; $2 = cfg
    _id="$1"; _cfg="$2"; _if=$(slot_iface "$_id"); _src=$(slot_srcconf "$_cfg"); _dst=$(slot_ifconf "$_id")
    if ip link show "$_if" >/dev/null 2>&1; then ip link set "$_if" up 2>/dev/null; return 0; fi
    [ -f "$_src" ] || { log "слот №$_id: нет конфига $_src"; return 1; }
    [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -x "$ENODIA_BIN/awg" ] || { log "слот №$_id: нет бинарей amneziawg-go/awg"; return 1; }
    _am=$(slot_gen_conf "$_src" "$_dst")
    _addr=$(printf '%s' "$_am" | cut -f1); _mtu=$(printf '%s' "$_am" | cut -f2)
    [ -n "$_addr" ] || { log "слот №$_id: в $_src нет Address — awgN был бы без IPv4, не поднимаю"; return 1; }
    slot_kill_daemon "$_if"                     # добить возможный stale-демон/сокет ИМЕННО awgN
    # GOMEMLIMIT — см. разбор в шапке net-tune.sh (он единственный владелец значения). Слот такой
    # же демон, как awg0: без потолка его куча растёт по трафику, а на тесной модели их несколько.
    # grep по ФОРМЕ — гард на рассинхрон версий: старый net-tune.sh печатает на этот верб `usage: …`
    # в stdout, и оно стало бы первым аргументом env (демон не стартует). См. шапку net-tune.sh.
    env $(sh "$ENODIA_DIR/net-tune.sh" memlimit-env 2>/dev/null | grep -E '^GOMEMLIMIT=[0-9]+MiB$') "$ENODIA_BIN/amneziawg-go" "$_if" || { log "слот №$_id: amneziawg-go $_if не стартовал"; return 1; }
    _i=0; while ! ip link show "$_if" >/dev/null 2>&1 && [ "$_i" -lt 10 ]; do sleep 1; _i=$((_i+1)); done
    ip link show "$_if" >/dev/null 2>&1 || { log "слот №$_id: $_if не появился"; slot_kill_daemon "$_if"; return 1; }
    "$ENODIA_BIN/awg" setconf "$_if" "$_dst"
    ip a add "$_addr" dev "$_if" 2>/dev/null
    ip link set dev "$_if" mtu "${_mtu:-$AWG_MTU_DEFAULT}" 2>/dev/null
    ip link set up "$_if"
    return 0
}

# Вывести endpoint слота из-под маркировки (анти-петля). Берём IP из СГЕНЕРИРОВАННОГО ifconf (там
# Endpoint уже подставлен как IP). Аддитивно, не затирая основной endpoint-bypass (apply-bypass).
slot_exclude_endpoint() {   # $1 = id
    _id="$1"; _dst=$(slot_ifconf "$_id")
    _ep=$(grep -E '^[[:space:]]*Endpoint' "$_dst" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//; s/[[:space:]]//g')
    if echo "$_ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "$_ep" >/dev/null 2>&1
        log "слот №$_id: endpoint $_ep исключён из маркировки (анти-петля)"
    else
        log "слот №$_id: endpoint не IPv4/не определён — пропуск анти-петли"
    fi
}

# Наложить карриер-часть слота: default dev awgN в table 100N + FORWARD ACCEPT + MASQUERADE.
# ip rule (fwmark 0xN -> table 100N) ставит mark-core (transport.sh переигрывает после slot-up).
slot_apply_routing() {   # $1 = id
    _id="$1"; _if=$(slot_iface "$_id"); _tab=$(slot_table "$_id")
    ip link set "$_if" up 2>/dev/null
    iptables -C FORWARD -o "$_if" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$_if" -j ACCEPT
    iptables -C FORWARD -i "$_if" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$_if" -j ACCEPT
    iptables -t nat -C POSTROUTING -o "$_if" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$_if" -j MASQUERADE
    ip route replace default dev "$_if" table "$_tab"
}
slot_remove_routing() {   # $1 = id
    _id="$1"; _if=$(slot_iface "$_id"); _tab=$(slot_table "$_id")
    ip route del default dev "$_if" table "$_tab" 2>/dev/null
    iptables -D FORWARD -o "$_if" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$_if" -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$_if" -j MASQUERADE 2>/dev/null
}

# Контракт слота (transport.sh _slot_dispatch): slot-up <id> <cfg> / slot-down <id>.
cmd_slot_up() {   # $1 = id, $2 = cfg
    _id="$1"; _cfg="$2"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    [ -n "$_cfg" ] && [ "$_cfg" != '-' ] || { log "слот №$_id: awg-выходу нужен конфиг (configs/<имя>.conf)"; return 1; }
    if ! slot_carrier_up "$_id" "$_cfg"; then
        log "слот №$_id: несущая awg не поднялась → выход живёт по fallback-политике (mark-core)"
        return 1
    fi
    slot_exclude_endpoint "$_id"                # ifconf сгенерирован → endpoint известен
    slot_apply_routing "$_id"
    ct_flush
    log "слот №$_id: awg-несущая $(slot_iface "$_id") в table $(slot_table "$_id") (конфиг $_cfg)"
    return 0
}
cmd_slot_down() {   # $1 = id
    _id="$1"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    _if=$(slot_iface "$_id")
    slot_remove_routing "$_id"
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "" >/dev/null 2>&1   # снять анти-петлю слота
    slot_kill_daemon "$_if"                     # гасим демон (владелец TUN) — TUN уходит следом
    ip link del "$_if" 2>/dev/null              # cleanup, если TUN пережил демон
    ct_flush
    log "слот №$_id: awg-несущая $_if снята"
    return 0
}

# ---- команды контракта ----------------------------------------------------
cmd_up() {
    if ! ensure_carrier; then
        log "awg0 не поднялся — несущую не активирую"
        return 1
    fi
    exclude_endpoint        # анти-петля: endpoint мимо маркировки ДО постановки default->awg0
    apply_awg_routing
    restore_vpn_dns
    echo awg > "$TRANSPORT_FLAG"
    replay_fw3              # только ПОСЛЕ записи флага: repair поднимает несущую по .transport
    # Ручная/оркестраторная смена транспорта = новый «эпизод» для авто-failover.
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "транспорт = AmneziaWG (default table $TABLE -> $IFACE). mark-core сохранён."
    cmd_status
}

cmd_down() {
    remove_awg_routing
    set_public_dns
    # .transport НЕ переписываем: «кто активен» решает оркестратор (он поднимет
    # следующий транспорт). Снятая несущая = прямой режим до следующего up.
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "AmneziaWG-несущая снята ($IFACE — тёплый резерв, трафик напрямую)."
}

cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    [ "$t" = awg ] || return 0          # активен не awg — судить не нам
    carrier_up || { log "health: $IFACE не поднят"; return 1; }
    age=$(hs_age)
    if [ "$age" -ge "$HS_MAX" ]; then
        log "health: handshake устарел (${age}с >= ${HS_MAX}с)"
        return 1
    fi
    return 0
}

# Перебор awg-резервов делегируем в switch-vpn.sh failover — ЕДИНЫЙ источник правды
# (там safety_off -> перебор configs/*.conf -> apply_routing -> письма; DNS возвращаем мы,
# apply_routing зовёт `transport-awg.sh up`).
# Дублировать do_failover здесь нельзя (два источника правды по перебору, дрейф).
cmd_failover() {
    [ -f "$SWITCH" ] || { log "нет $SWITCH"; return 1; }
    sh "$SWITCH" failover
}

cmd_status() {
    # ФАКТ ФЛАГА, а не догадка. Прежнее `${t:-awg}` печатало «awg» на установке «только панель»,
    # где транспорт не выбирали НИ РАЗУ, — и печатало это в ДАМП, вчетвером с остальными плагинами.
    # Читатель разбора получал четыре независимых подтверждения того, чего нет. Что означает пустой
    # флаг (старый роутер или «только панель»), знает ОДИН верб — `transport.sh configured`; его и
    # спрашивает дамп в своей секции. Плагину положено сообщать факт: флаг пуст. Формулировка —
    # ОБЩАЯ с тремя остальными плагинами и БЕЗ ссылки на секцию дампа: срез читают и из SSH, где
    # никакой «секции выше» нет, а четыре разных текста про одно состояние читаются как четыре
    # разных состояния.
    t=; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    echo "--- transport-awg status ---"
    echo "активный транспорт (.transport): ${t:-(флаг пуст — транспорт не выбран)}"
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default || echo "(нет default — прямой режим)"
    echo "--- $IFACE ---"; ip link show "$IFACE" >/dev/null 2>&1 && echo "поднят (handshake $(hs_age)с назад)" || echo "нет"
    echo "--- FORWARD $IFACE ---"; iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null && echo "ACCEPT есть" || echo "нет"
}

case "$1" in
    up)       cmd_up ;;
    down)     cmd_down ;;
    status)   cmd_status ;;
    health)   cmd_health ;;
    failover) cmd_failover ;;
    dns)      restore_vpn_dns ;;   # переиграть DNS активной несущей (DoH toggle/смена резолвера) — через doh_apply_dns
    slot-up)   cmd_slot_up "$2" "$3" ;;   # доп-выход (Ф2): поднять awgN в table 100N
    slot-down) cmd_slot_down "$2" ;;      # доп-выход: снять awgN (-> fallback-политика mark-core)
    *) echo "usage: $0 up|down|status|health|failover|dns|slot-up <id> <cfg>|slot-down <id>"; exit 2 ;;
esac
