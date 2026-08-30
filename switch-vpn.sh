#!/bin/sh
#
# switch-vpn.sh v3 — переключение страны/конфига AmneziaWG с правильной
# заменой ВСЕХ файлов конфигурации, без гонок с heal.sh и с safety net
# на случай полного фейла.
#
# v3 (май 2026) — лечит «при смене страны интернет на роутере пропадает,
# падает awg, помогает только перезагрузка»:
#
#   1) вендорный awg_setup.sh читает не awg.conf, а amnezia_for_awg.conf.
#      Из него генерирует awg0.conf для amneziawg-go. v2 копировал ТОЛЬКО
#      awg.conf — поэтому на самом деле awg продолжал использовать СТАРЫЕ
#      ключи/endpoint. v3 синхронно обновляет все три файла.
#
#   2) Новый конфиг от приложения AmneziaVPN 4.8.12.9+ часто содержит
#      пустые I1..I5 — старые awg-tools валятся на них. Перед запуском
#      вендорного скрипта v3 их вычищает.
#
#   3) Между bring_down и bring_up могут параллельно сработать heal.sh
#      (cron каждую минуту) и сломать состояние. v3 берёт лок
#      /tmp/enodia-switching.lock — heal.sh с него же читает и выходит,
#      пока идёт переключение.
#
#   4) Если awg0 в итоге не поднялся ни на новом, ни на старом конфиге —
#      v2 ОСТАВЛЯЛ висеть `ip rule fwmark 0x1 → table 1000 → dev awg0`
#      и mangle-правила по iplist_set (~3100 CIDR — Cloudflare/Google/
#      OpenAI/Discord). В результате весь трафик роутера к этим адресам
#      уходил в несуществующий awg0 → «интернет вовсе пропал, помогает
#      только ребут». v3 в этой ситуации флашит правила (safety_off),
#      роутер сохраняет доступ в интернет, а heal.sh при следующем
#      запуске всё восстановит.
#
#   5) Принудительно убиваем зависшие amneziawg-go процессы перед
#      bring_up (иногда init.d stop их не убирает, особенно если запуск
#      был не через init.d).
#
# Использование:
#   switch-vpn.sh                — список конфигов
#   switch-vpn.sh <имя>          — переключиться на configs/<имя>.conf
#   switch-vpn.sh status         — текущий статус
#   switch-vpn.sh rollback       — вручную откатиться на .last.bak
#   switch-vpn.sh failover       — перебрать резервы и встать на первый рабочий
#                                  (зовётся watchdog'ом при смерти активного VPS)

ENODIA_DIR="/data/usr/app/enodia"
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
CONFIGS_DIR="$ENODIA_STATE/configs"
ACTIVE_CONF="$ENODIA_STATE/awg.conf"
SHALIN_CONF="$ENODIA_STATE/amnezia_for_awg.conf"
AWG0_CONF="$ENODIA_STATE/awg0.conf"
ACTIVE_NAME="$ENODIA_STATE/.active"
BACKUP_CONF="$ENODIA_STATE/.last.bak.conf"
BACKUP_NAME="$ENODIA_STATE/.last.bak.name"
SWITCH_LOCK="/tmp/enodia-switching.lock"
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"   # обёртка событийных писем (throttle)
WD_STATE="/tmp/enodia-watchdog.state"   # состояние watchdog (NORMAL/FAILOPEN) — держим синхронным (см. safety_off/apply_routing)
HS_WAIT=25                       # сколько секунд ждать handshake

# Возраст отметки времени (clock-lib.sh). Критично именно здесь: wait_for_handshake судит «пришло
# ли рукопожатие», и при скачке часов (роутер без RTC, реальный случай 10.08.2026) РУЧНАЯ смена
# сервера из панели «не поднялась» и откатилась, хотя туннель встал. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

# Общий примитив «внешний IPv4» (ip-lib.sh): IP-литерал-проба, DNS-free — чинит пустой egress на
# ядре 4.4 (hostname api.ipify.org там молча пустел). Шим на случай частичной установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }

# Язык событийных писем (rollback/failover/failopen) — панельный pref lang (деф. ru).
# Русские ветки сообщений ниже — байт-в-байт прежние; en — параллельный перевод.
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
NF_LANG=$(nf_lang)

# Слой шифрованного DNS (doh-lib.sh) — тот же приём, что в плагинах транспорта: DoH ВЫКЛ
# (дефолт) → doh_apply_dns даёт 1, и аварийная DNS-ветка safety_off работает прежним путём
# байт-в-байт. DoH ВКЛ → слой сам переводит dnsmasq на локальный прокси МИМО туннеля, и
# затирать 00-upstream.conf публичными серверами нельзя: это молча выключило бы шифрованный
# DNS до следующего repair. Шим — на случай установки без lib.
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }

# «awg_setup.sh отработал» ⇒ его последняя строка (`/etc/init.d/firewall reload`) СНЕСЛА ВСЕ
# iptables: цепочки apply-bypass (VPN_EXCLUDE/KEEP/DEV/PORTS/FORCE, режим «целиком в десинк»),
# ENODIA_ZAPRET + NFQUEUE, FORWARD доп-выходов, PANEL_WAN и цепочки «доступа домой». Полный
# переигрыш после этого делает ТОЛЬКО heal.sh (на буте), а смена страны из панели шла мимо
# него — правила оставались снесёнными до ребута, и сторож этого не видел (rule-heal судит по
# `FORWARD -o awg0 ACCEPT`, который тут же возвращает сам awg_setup). Флаг ставит bring_up,
# гасят его replay_* — так переигрыш случается РОВНО после нашего же fw3-reload.
FW3_WIPED=0

# Событийное письмо: $1 key, $2 throttle_sec, $3 тема, $4 текст.
# Тихо ничего не делает, если обёртки нет или почта не настроена
# (notify-event.sh сам уважает .notify-off и тихо выходит без notify.conf).
notify_event() {
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$CONFIGS_DIR"

# Бинарь для проверки handshake. Порядок ОБРАТНЫЙ прежнему и совпадает с wg_bin() в
# transport-awg.sh (инвариант «handshake читает awg, НЕ wg»): сперва НАШ awg из $ENODIA_DIR
# (amneziawg-tools известной версии), потом awg из PATH, и только в самом конце wg. На стоке
# wg нет вовсе, но если он появится от чужой установки — читать AWG-интерфейс им не наш выбор.
WG=""
[ -x "$ENODIA_BIN/awg" ] && WG="$ENODIA_BIN/awg"
[ -z "$WG" ] && command -v awg >/dev/null 2>&1 && WG=awg
[ -z "$WG" ] && command -v wg  >/dev/null 2>&1 && WG=wg

# ============================================================
# Локи против гонок с heal.sh
# ============================================================
SWITCH_LOCK_MINE=0
acquire_lock() {
    # ЧУЖОЙ лок не перебиваем и не снимаем — его снимет владелец (идиома take_switch_lock из
    # transport.sh, она же в proto-install.sh и в CGI панели). Прежняя форма (безусловный `: >` +
    # безусловный `rm` в trap) освобождала лок, который держал КТО-ТО ДРУГОЙ: смена сервера из
    # панели посреди установки компонентов открывала сторожу дорогу в середину чужой операции.
    [ -e "$SWITCH_LOCK" ] || { : > "$SWITCH_LOCK" 2>/dev/null && SWITCH_LOCK_MINE=1; }
    trap 'release_lock' EXIT INT TERM HUP
}
release_lock() {
    # Сохраняем код возврата: failover отдаёт его watchdog'у (0=встал на резерв /
    # 1=прямой режим), а этот хендлер висит на EXIT-trap и не должен его затереть.
    _rc=$?
    [ "$SWITCH_LOCK_MINE" = 1 ] && rm -f "$SWITCH_LOCK" 2>/dev/null
    return $_rc
}

# ============================================================
# Утилиты
# ============================================================
list_configs() {
    printf "${BLUE}Доступные конфиги в $CONFIGS_DIR:${NC}\n"
    found=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        endpoint=$(grep -E "^Endpoint" "$f" | head -1 | awk -F'= *' '{print $2}')
        active=""
        if [ -f "$ACTIVE_NAME" ] && [ "$(cat "$ACTIVE_NAME")" = "$name" ]; then
            active="${GREEN} ← АКТИВНЫЙ${NC}"
        fi
        printf "  ${YELLOW}%-20s${NC} (Endpoint: %s)%s\n" "$name" "$endpoint" "$active"
        found=$((found+1))
    done
    [ $found -eq 0 ] && printf "  ${RED}Конфигов нет.${NC} Положи .conf в %s\n" "$CONFIGS_DIR"
}

show_status() {
    printf "${BLUE}Статус AmneziaWG:${NC}\n"
    if [ -f "$ACTIVE_NAME" ]; then
        printf "  Активный конфиг: ${GREEN}%s${NC}\n" "$(cat "$ACTIVE_NAME")"
    fi
    if ip link show awg0 >/dev/null 2>&1; then
        printf "  Интерфейс awg0: ${GREEN}поднят${NC}\n"
        if [ -n "$WG" ]; then
            hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$hs" in
                ''|*[!0-9]*) hs=0 ;;
            esac
            if [ "$hs" -gt 0 ]; then
                ago=$(age_since "$hs")
                printf "  Handshake: ${GREEN}%d сек назад${NC}\n" "$ago"
            else
                printf "  Handshake: ${RED}нет${NC}\n"
            fi
        fi
        ip_vpn=$(probe_ext_ip "--interface awg0" 5)
        [ -n "$ip_vpn" ] && printf "  Внешний IP через VPN: ${GREEN}%s${NC}\n" "$ip_vpn"
    else
        printf "  Интерфейс awg0: ${RED}не поднят${NC}\n"
    fi
}

# Ждать handshake до HS_WAIT секунд
wait_for_handshake() {
    [ -z "$WG" ] && return 1
    i=0
    while [ $i -lt $HS_WAIT ]; do
        hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        case "$hs" in
            ''|*[!0-9]*) hs=0 ;;
        esac
        if [ "$hs" -gt 0 ]; then
            ago=$(age_since "$hs")
            [ "$ago" -lt 300 ] && return 0
        fi
        sleep 1
        i=$((i+1))
        printf "."
    done
    return 1
}

# Установить ВСЕ файлы конфигурации из source-файла.
# Это главное изменение v3: amnezia_for_awg.conf — то, что реально
# читает вендорный awg_setup.sh, поэтому он тоже должен обновиться.
install_config() {
    src="$1"
    name="$2"

    # 1. Главный awg.conf
    cp "$src" "$ACTIVE_CONF"

    # 2. Чистим пустые I1..I5 (AmneziaVPN 4.8.12.9+ их добавляет)
    if grep -qE '^I[1-5][[:space:]]*=[[:space:]]*$' "$ACTIVE_CONF"; then
        sed -i '/^I[1-5][[:space:]]*=[[:space:]]*$/d' "$ACTIVE_CONF"
    fi

    # 3. Синхронизируем amnezia_for_awg.conf — вендорный awg_setup.sh
    #    читает именно его. БЕЗ этого awg продолжит использовать СТАРЫЕ
    #    ключи и endpoint после "переключения".
    cp "$ACTIVE_CONF" "$SHALIN_CONF"

    # 4. Удаляем awg0.conf чтобы вендорный скрипт сгенерировал свежий.
    #    Иначе amneziawg-go читает старые ключи из awg0.conf.
    rm -f "$AWG0_CONF"

    # 5. Запоминаем имя активного
    echo "$name" > "$ACTIVE_NAME"
}

# Глушим amneziawg-go процессы (на случай если init.d не убил)
# Гасим демон ИМЕННО awg0. ГРАБЛЯ (поймано на железе 30.07.2026): раньше тут стоял killall по
# ИМЕНИ БИНАРЯ, а инстансов amneziawg-go у нас теперь несколько — awg0 (эта несущая), awgN
# (awg-выходы слотов) и awgs0 (VPN-сервер «доступ домой»). Каждый failover звал bring_up →
# killall уносил сервер и слоты вместе с awg0, поднять их было НЕКОМУ до следующего ребута.
# Снаружи это выглядело как «телефон вчера подключался, а сегодня нет»: правила фаервола на
# месте, панель показывает «включено», а несущей нет. Матчим по /proc/*/cmdline — зеркало
# slot_kill_daemon (transport-awg.sh) и srv_kill_daemon (vpn-server.sh).
awg0_daemon_pids() {
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        case "$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) " in
            *"amneziawg-go awg0 "*|*"amnezia-wg awg0 "*|*"wireguard-go awg0 "*) echo "${_p#/proc/}" ;;
        esac
    done
}
kill_awg_processes() {
    for _pid in $(awg0_daemon_pids); do kill -TERM "$_pid" 2>/dev/null; done
    _i=0
    while [ -n "$(awg0_daemon_pids)" ] && [ "$_i" -lt 8 ]; do
        if [ "$_i" = 3 ]; then
            for _pid in $(awg0_daemon_pids); do kill -KILL "$_pid" 2>/dev/null; done
        fi
        sleep 1; _i=$((_i + 1))
    done
}

# AmneziaWG реально установлен? Нужны ОБА бинаря: amneziawg-go (демон несущей awg0) И
# awg (CLI amneziawg-tools — bring_up/awg_setup.sh делают им `awg setconf awg0`). На
# hy2/xray-only установке их НЕТ (awg = опциональная база транспорт-агностичного ядра),
# либо awg стоит наполовину (демон докачался, CLI — нет). Тогда switch_to/do_failover НЕ
# должны рвать рабочую несущую и звать safety_off ради awg-конфига, который некому поднять
# (orphaned awg.conf + bring_down + bring_up-fail + safety_off). Симметрично transport_ready awg.
awg_installed() { [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -x "$ENODIA_BIN/awg" ]; }

# --- переигрыш ВСЕХ наших цепочек после fw3-reload внутри awg_setup.sh (см. FW3_WIPED) -----
# Канонический переигрыш один — `vpn-toggle.sh repair`: он заведён ровно под fw3-reload и уже
# знает про apply-bypass, zapret, доп-выходы и «доступ домой». Своей копии этого списка тут
# быть не должно (она отстанет с первой же новой подсистемой). Рекурсии нет: repair при
# transport=awg ставит несущую ИНЛАЙНОМ (awg0 к этому моменту уже поднят), awg_setup.sh не зовёт.
replay_after_fw3() {
    [ "$FW3_WIPED" = 1 ] || return 0
    FW3_WIPED=0
    [ -f "$ENODIA_DIR/vpn-toggle.sh" ] || return 0
    printf "${BLUE}[правила]${NC} переигрываю цепочки после firewall reload...\n"
    sh "$ENODIA_DIR/vpn-toggle.sh" repair >/dev/null 2>&1 || true
}
# АВАРИЙНЫЙ вариант того же: туннель мёртв и мы уже в прямом режиме (safety_off). Полный repair
# звать НЕЛЬЗЯ — он вернёт маркировку и default в дохлый awg0, т.е. ровно тот кирпич, от которого
# safety_off и спасает. Поднимаем только то, что от туннеля НЕ зависит: «доступ домой» (свой
# awgs0 и свои цепочки; телефон снаружи иначе молча отваливался бы до ребута). Панельные
# PANEL_WAN/DNAT переигрывает свой cron (`web-ui.sh start` раз в 5 мин), их тут не трогаем.
replay_home_only() {
    [ "$FW3_WIPED" = 1 ] || return 0
    FW3_WIPED=0
    # -f + `sh` (класс Б5-9): при снятом бите аварийная ветка молча не поднимала бы «доступ домой»
    # — а зовут её как раз после safety_off, когда телефон снаружи и есть единственный путь домой.
    [ -f "$ENODIA_DIR/vpn-server.sh" ] && [ -f "$ENODIA_STATE/server/.on" ] && \
        sh "$ENODIA_DIR/vpn-server.sh" up >/dev/null 2>&1
    return 0
}

# Поднять туннель из текущего awg.conf
bring_up() {
    ip link del awg0 2>/dev/null
    kill_awg_processes
    sleep 1

    started=0
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        if [ -x "$s" ]; then
            "$s" start >/dev/null 2>&1
            started=1
            break
        fi
    done

    # Если init.d не справился или его нет — зовём вендорный awg_setup.sh.
    # /etc/init.d/awg в проекте никто не создаёт ⇒ ветка init.d выше промахивается ВСЕГДА, и
    # эта строка бежит на КАЖДОЙ смене страны. Внутри — `/etc/init.d/firewall reload`, который
    # сносит все iptables: помечаем это флагом, переигрыш сделают replay_* (см. FW3_WIPED).
    if ! ip link show awg0 >/dev/null 2>&1 && [ -f "$ENODIA_DIR/awg_setup.sh" ]; then
        FW3_WIPED=1
        ( cd "$ENODIA_DIR" && sh ./awg_setup.sh >/tmp/switch-vpn-setup.log 2>&1 )
    fi

    # Ждём появления интерфейса
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        ip link show awg0 >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

bring_down() {
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        [ -x "$s" ] && "$s" stop >/dev/null 2>&1 && break
    done
    ip link set awg0 down 2>/dev/null
    ip link del awg0 2>/dev/null
    kill_awg_processes
}

# Восстановить нормальную маршрутизацию через awg0: ЯДРО (mark-core: маркировка
# ipset->MARK + ip rule fwmark->table 1000) + awg-НЕСУЩАЯ (transport-awg.sh up:
# default dev awg0 + FORWARD + MASQUERADE + туннельный DNS + .transport=awg).
# Единый источник правды вместо ретайрнутого split-route.sh. awg0 здесь уже поднят
# (bring_up до вызова), поэтому ensure_carrier в плагине — мгновенный no-op
# (awg_setup/fw3-reload НЕ трогаются). split-route.sh оставлен лишь фолбэком для
# старых роутеров без плагинов.
apply_routing() {
    [ -f "$ENODIA_DIR/mark-core.sh" ] && sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1
    if [ -f "$ENODIA_DIR/transport-awg.sh" ]; then
        sh "$ENODIA_DIR/transport-awg.sh" up >/dev/null 2>&1
    elif [ -f "$ENODIA_DIR/split-route.sh" ]; then
        sh "$ENODIA_DIR/split-route.sh" >/dev/null 2>&1
    fi
    # enodia_list НЕ флашим. Прежний код это делал с мотивировкой «там осели старые IP, привязанные
    # к старому endpoint» — она НЕВЕРНА: в enodia_list лежат адреса САЙТОВ (их кладёт dnsmasq по
    # `ipset=/домен/enodia_list`), от endpoint'а VPS они не зависят вовсе. Цена флаша — ровно та же
    # авария, что чинил set-lib.sh [[groups-set-rebuild-wipes-dnsmasq-ips]]: после смены страны
    # доменные правила МЕРТВЫ, пока каждый домен не перерезолвят заново, а `killall -HUP dnsmasq`
    # чистит лишь кэш dnsmasq и заставить клиента переспросить не может (у него свой кэш и живые
    # соединения). HUP оставляем: после смены выхода кэш прежнего сервера стоит сбросить.
    killall -HUP dnsmasq 2>/dev/null
    # Несущая через туннель восстановлена — синхронизируем watchdog в NORMAL (safety_off ставил
    # FAILOPEN). Иначе после успешного ручного failover/rollback STATE залипал бы в FAILOPEN и
    # сторож на следующем тике зря дёргал бы restore_awg_carrier.
    echo NORMAL > "$WD_STATE" 2>/dev/null || true
    # Несущая жива и правила ядра на месте — самое время вернуть всё, что смёл наш же
    # firewall reload (bypass/порты/устройства/zapret/доп-выходы/«доступ домой»).
    replay_after_fw3
}

# SAFETY NET: туннель окончательно мёртв (новый конфиг не поднялся и
# откат тоже не поднялся). Без этого роутер «уходит в кирпич»:
#   1) fwmark+mangle гонят трафик в дохлый awg0 — даже исходящий с
#      самого роутера к Cloudflare/Google/OpenAI (~3100 CIDR в iplist_set)
#   2) КЛЮЧЕВОЕ: dnsmasq настроен на upstream-DNS внутри туннеля
#      (172.29.172.254 от Amnezia). Когда awg0 умирает, dnsmasq шлёт
#      запросы в дохлый интерфейс → НИ ОДИН сайт не резолвится, даже
#      yandex.ru. SSH работает только потому, что заходишь по IP.
# safety_off восстанавливает оба пути: трафик идёт напрямую через
# провайдера, DNS — на 1.1.1.1/8.8.8.8. Это временное состояние;
# heal.sh при следующем срабатывании (раз в минуту) всё восстановит,
# если awg.conf к тому моменту валиден (после rollback он уже OLD).
safety_off() {
    printf "${YELLOW}[safety]${NC} убираю маршрут/марку/DNS-привязку к дохлому awg0\n"

    # 1. КЛЮЧЕВОЕ: убрать сам МАРШРУТ в дохлый туннель. `default dev awg0` в table 1000 —
    #    единственная причина блэкхола, и снять его надо ДО/ВМЕСТО возни с марками:
    #      * awg0 мы СОЗНАТЕЛЬНО не опускаем (сторож продолжает мониторить handshake) ⇒ маршрут
    #        оставался живым, и любой, кто вернёт марку, вернёт и кирпич. А возвращает её сторож
    #        САМ: mipctld-guard (cron */2) видит «нет MARK по iplist_set» и переигрывает
    #        mark-core — вместе с `ip rule fwmark 0x1 -> table 1000`;
    #      * ДОП-ВЫХОДЫ с fallback=main смотрят в ту же table 1000 (mark-core, FALLBACK-AWARE), и
    #        снятие ОДНОЙ марки 0x1 их не спасало: привязанные группы/гео/устройства продолжали
    #        уезжать в мёртвый awg0 — блэкхол вместо fail-open (находка ревью, батч 4).
    #    Пустая table 1000 = lookup проваливается в main = НАПРЯМУЮ, что и обещает fail-open.
    #    Живые доп-выходы со СВОЕЙ несущей (table 100N) при этом продолжают работать — правильно.
    ip route del default dev awg0 table 1000 2>/dev/null
    ip rule del fwmark 0x1 table 1000 2>/dev/null
    # Марки в mangle снимать не нужно и вредно копировать сюда список сетов: их у mark-core
    # ПЯТЬ (+слот-сеты), а здешняя копия отстала на двух и молча не снимала grp_vpn/enodia_ip_vpn/
    # geo_vpn. Без ip rule и без default марка ни на что не влияет, а вернёт её (и правильно)
    # первый же mark-core. Снимаем лишь NAT нашей несущей.
    iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null

    # 2. DNS — выключаем upstream через дохлый туннель, ставим публичный.
    #    Это файл в overlay (/etc), он сбросится при ребуте — нам и надо.
    #    При включённом «Шифрованном DNS» решает doh-lib: он переводит dnsmasq на локальный
    #    прокси, ходящий НАПРЯМУЮ через WAN. Затирать конфиг публичными серверами в этом случае
    #    значило бы молча выключить шифрованный DNS до следующего repair.
    if doh_apply_dns direct; then
        # Шапка не врёт: при включённом DoH публичных серверов в конфиге НЕТ, и сообщение
        # в конце функции обязано говорить то, что произошло на самом деле.
        _dnsmsg="DNS остаётся на шифрованном резолвере (он ходит мимо туннеля, напрямую)"
    elif [ -f /etc/dnsmasq.d/00-upstream.conf ]; then
        _dnsmsg="DNS временно на 1.1.1.1/8.8.8.8"
        cat > /etc/dnsmasq.d/00-upstream.conf <<'DNS_FALLBACK'
# Временный fallback, поставлен switch-vpn.sh safety_off.
# Будет заменён обратно на VPN-DNS при следующем срабатывании heal.sh
# (как только awg0 поднимется). При ребуте overlay /etc сбрасывается.
no-resolv
server=1.1.1.1
server=8.8.8.8
DNS_FALLBACK
    else
        _dnsmsg="DNS не трогали (нет 00-upstream.conf)"
    fi
    # Снимаем маршрут к VPN-DNS через дохлый awg0 (если был)
    VPN_DNS=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -n "$VPN_DNS" ] && ip route del "$VPN_DNS/32" dev awg0 2>/dev/null

    # Перезапускаем dnsmasq, чтобы подхватил новый upstream
    /etc/init.d/dnsmasq restart 2>/dev/null || killall -HUP dnsmasq 2>/dev/null

    # NSS/ECM offload: для УЖЕ установленных потоков старый маршрут (в дохлый awg0) залипает
    # до conntrack-таймаута — клиенты висят, хотя fail-open уже включён. Инвариант проекта:
    # после iptables-изменения обязателен conntrack -F (см. transport-*/zapret/apply-bypass).
    ct_flush

    # Пометить watchdog FAILOPEN: мы в прямом режиме. Без этого ALIVE-ветка сторожа (она
    # восстанавливает маркировку ТОЛЬКО из состояния FAILOPEN) не вернёт VPN, если VPS оживёт
    # с живым handshake раньше HS_DEAD — типичный кейс: ручной switch → rollback → safety_off
    # оставлял STATE=NORMAL → VPN молча выключен «навсегда» (heal под boot-локом). apply_routing
    # вернёт NORMAL при успешном подъёме несущей.
    echo FAILOPEN > "$WD_STATE" 2>/dev/null || true

    # Если сюда пришли ПОСЛЕ нашего же awg_setup.sh — его firewall reload снёс и цепочки
    # «доступа домой». Полный repair тут запрещён (вернул бы маршрут в дохлый awg0), поднимаем
    # только независимое от туннеля.
    replay_home_only

    printf "${YELLOW}[safety]${NC} %s, трафик весь напрямую\n" "${_dnsmsg:-DNS не менялся}"
}

# ВОЗВРАТ ТУННЕЛЬНОГО DNS живёт в ПЛАГИНЕ (transport-awg.sh restore_vpn_dns), сюда его копию
# больше не заводим. Здешняя копия была написана до плагинов и не проходила через doh_apply_dns:
# в do_failover она бежала ПОСЛЕ apply_routing (который уже поставил DNS правильно, через плагин
# и слой DoH) и перетирала 00-upstream.conf туннельным сервером ⇒ при включённом «Шифрованном
# DNS» DoH молча отваливался после КАЖДОГО failover'а. Кому нужно переиграть DNS активного
# транспорта — верб `transport.sh dns`.

# ============================================================
# Главная процедура переключения с автооткатом
# ============================================================
switch_to() {
    target="$1"
    # Гард: без awg-демона активировать awg-конфиг нечем. Выходим ДО bring_down/safety_off,
    # чтобы НЕ уронить уже несущий транспорт (hy2/xray). Это та самая ловушка из логов:
    # «Залить конфиг + активировать» при hy2-only установке.
    if ! awg_installed; then
        printf "${RED}[FAIL]${NC} AmneziaWG не установлен (нет %s/amneziawg-go).\n" "$ENODIA_DIR"
        printf "Активировать awg-конфиг нечем — текущий транспорт НЕ тронут.\n"
        printf "Чтобы получить AmneziaWG: переустановите с ПК (enodia-setup.bat -> Установка),\n"
        printf "выбрав вариант с AmneziaWG (например «AmneziaWG + Hysteria2»).\n"
        exit 1
    fi
    src="$CONFIGS_DIR/${target}.conf"
    if [ ! -f "$src" ]; then
        printf "${RED}[FAIL]${NC} Не найден файл %s\n" "$src"
        printf "Доступные конфиги:\n"
        list_configs
        exit 1
    fi

    acquire_lock

    # Активна ЧУЖАЯ несущая (xray/hy2/byedpi/zapret)? Отпустить её через ОРКЕСТРАТОР, иначе
    # смена awg-сервера уводит транспорт на awg МИМО него: apply_routing ниже поднимет awg0 и
    # плагин запишет `.transport=awg`, а `down` прежнего плагина не позовёт НИКТО. Итог —
    # осиротевшие ciadpi/xray/hysteria + hev держат socks 10808 и xtun, их FORWARD-правила
    # остаются, RAM течёт (на BE3600 со 176 МБ это заметно). Соседний set_xray_server в панели
    # делает ровно наоборот и специально об этом пишет («НЕ роняет чужую несущую») — здесь же
    # пользователь ЯВНО выбрал awg-сервер, значит смена несущей и есть его намерение.
    cur_t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    case "$cur_t" in
        ''|awg) ;;
        *) if [ -f "$ENODIA_DIR/transport.sh" ]; then
               printf "${BLUE}[транспорт]${NC} отпускаю текущую несущую (%s) — переходим на AmneziaWG\n" "$cur_t"
               sh "$ENODIA_DIR/transport.sh" down "$cur_t" >/dev/null 2>&1 || true
           fi ;;
    esac

    # Сохраняем текущее (на случай отката)
    if [ -f "$ACTIVE_CONF" ]; then
        cp "$ACTIVE_CONF" "$BACKUP_CONF"
        if [ -f "$ACTIVE_NAME" ]; then
            cp "$ACTIVE_NAME" "$BACKUP_NAME"
        else
            : > "$BACKUP_NAME"
        fi
        printf "${BLUE}[бэкап]${NC} текущий конфиг сохранён в %s\n" "$BACKUP_CONF"
    fi

    printf "${BLUE}[1/5]${NC} Останавливаю awg0...\n"
    bring_down

    printf "${BLUE}[2/5]${NC} Применяю конфиг ${YELLOW}%s${NC} (awg.conf + amnezia_for_awg.conf + awg0.conf)...\n" "$target"
    install_config "$src" "$target"

    printf "${BLUE}[3/5]${NC} Поднимаю awg0...\n"
    if ! bring_up; then
        printf "${RED}[FAIL]${NC} awg0 не поднялся → автооткат\n"
        rollback
        return $?
    fi

    printf "${BLUE}[4/5]${NC} Жду handshake (до %d сек)" "$HS_WAIT"
    if wait_for_handshake; then
        printf " ${GREEN}есть${NC}\n"
        printf "${BLUE}[5/5]${NC} Применяю правила маршрутизации...\n"
        apply_routing
        printf "\n${GREEN}[OK]${NC} Переключение на ${YELLOW}%s${NC} успешно.\n\n" "$target"
        show_status
        # Осознанный (ручной) выбор страны = новый «основной» (home) для режима
        # failover home: именно сюда watchdog будет возвращаться, когда home оживёт.
        echo "$target" > "$ENODIA_STATE/.failover-home"
        return 0
    else
        printf " ${RED}нет ответа${NC}\n"
        printf "${RED}[FAIL]${NC} %s не подключается (handshake не пришёл за %d сек)\n" "$target" "$HS_WAIT"
        printf "${YELLOW}=> автооткат на предыдущий конфиг${NC}\n\n"
        rollback
        return $?
    fi
}

# Откат на сохранённый бэкап
rollback() {
    if [ ! -f "$BACKUP_CONF" ]; then
        printf "${RED}[FAIL]${NC} бэкап %s не найден, откатываться не на что\n" "$BACKUP_CONF"
        safety_off
        if [ "$NF_LANG" = en ]; then
            notify_event "switch-failopen" 3600 "BE7000: CRIT — VPN did not come up, direct mode" \
"The new config did not come up, and there is nothing to roll back to (no backup $BACKUP_CONF).
Direct mode is on (safety_off): internet and DNS work bypassing the VPN,
listed sites are unavailable. awg0 is not active.
Log in via SSH: cat /tmp/switch-vpn-setup.log; then $ENODIA_DIR/heal.sh."
        else
            notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Новый конфиг не поднялся, а откатиться не на что (нет бэкапа $BACKUP_CONF).
Включён прямой режим (safety_off): интернет и DNS работают мимо VPN,
сайты из списка недоступны. awg0 не активен.
Зайди по SSH: cat /tmp/switch-vpn-setup.log; затем $ENODIA_DIR/heal.sh."
        fi
        return 1
    fi
    prev_name="(неизвестно)"
    [ -s "$BACKUP_NAME" ] && prev_name=$(cat "$BACKUP_NAME")

    bring_down
    # Восстанавливаем ВСЕ три файла, как в install_config
    install_config "$BACKUP_CONF" "$prev_name"

    if bring_up && wait_for_handshake; then
        apply_routing
        printf "\n${GREEN}[ОТКАТ OK]${NC} вернулся на ${YELLOW}%s${NC}\n\n" "$prev_name"
        show_status
        if [ "$NF_LANG" = en ]; then
            notify_event "switch-rollback" 3600 "BE7000: VPN auto-rollback → $prev_name" \
"Switching to the new config failed (the tunnel did not come up or no
handshake arrived). The router automatically rolled back to the previous config: $prev_name —
VPN works on it again. Check the new config and try again."
        else
            notify_event "switch-rollback" 3600 "BE7000: автооткат VPN → $prev_name" \
"Переключение на новый конфиг не удалось (туннель не поднялся или не пришёл
handshake). Роутер автоматически откатился на предыдущий конфиг: $prev_name —
VPN снова работает на нём. Проверь новый конфиг и попробуй ещё раз."
        fi
        return 0
    else
        printf "\n${RED}[ОТКАТ FAIL]${NC} даже старый конфиг не поднялся.\n"
        printf "${RED}Включаю safety_off — чтобы роутер не упёрся в дохлый awg0.${NC}\n"
        safety_off
        if [ "$NF_LANG" = en ]; then
            notify_event "switch-failopen" 3600 "BE7000: CRIT — VPN did not come up, direct mode" \
"The config change failed, and the ROLLBACK to the old config ($prev_name) also did not
bring the tunnel up. Direct mode is on (safety_off): internet and DNS work
bypassing the VPN, listed sites are unavailable. awg0 is not active.
Investigate via SSH: cat /tmp/switch-vpn-setup.log; cat /tmp/enodia-startup.log."
        else
            notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Смена конфига провалилась, и ОТКАТ на старый конфиг ($prev_name) тоже не
поднял туннель. Включён прямой режим (safety_off): интернет и DNS работают
мимо VPN, сайты из списка недоступны. awg0 не активен.
Разбор по SSH: cat /tmp/switch-vpn-setup.log; cat /tmp/enodia-startup.log."
        fi
        printf "${YELLOW}Что делать:${NC}\n"
        printf "  1) Проверь awg.conf: cat %s\n" "$ACTIVE_CONF"
        printf "  2) Проверь интернет на роутере: ping 1.1.1.1\n"
        printf "  3) Запусти heal.sh вручную: %s/heal.sh\n" "$ENODIA_DIR"
        printf "  4) Если не помогло — reboot и SSH-вход, разбор по логам:\n"
        printf "     cat /tmp/enodia-startup.log; cat /tmp/switch-vpn-setup.log\n"
        return 1
    fi
}

# ============================================================
# FAILOVER: автоматический перебор резервных конфигов
# ============================================================
# Зовётся watchdog.sh (или вручную: switch-vpn.sh failover), когда активный
# VPS умер. В отличие от switch_to (переключение на КОНКРЕТНУЮ страну) —
# перебирает ВСЕ configs/*.conf по алфавиту (glob в sh сортирован), кроме
# текущего, и встаёт на первый, давший handshake.
#
# Почему safety_off ПЕРВЫМ: перебор несколько раз опускает/поднимает awg0. Если
# оставить fwmark/mangle и туннельный DNS — на время перебора клиенты снова без
# интернета и DNS (ровно та авария, что чиним: трафик к iplist_set/enodia_list
# уходит в дохлый awg0, dnsmasq не резолвит). safety_off сразу пускает трафик/DNS
# напрямую, а VPN-роутинг возвращаем ТОЛЬКО когда резерв реально ответил (apply_routing —
# он же вернёт туннельный DNS через плагин и слой DoH).
#
# Возврат: 0 — встали на резерв (.active обновлён install_config'ом); 1 — ни один
# не встал, остались в прямом режиме (safety_off), awg0 поднят на ИСХОДНОМ конфиге
# для дальнейшего мониторинга watchdog'ом (вернётся, когда исходный оживёт).
do_failover() {
    # Гард: нет awg-демона — awg-перебор невозможен. Возвращаем 1 (watchdog трактует как
    # «прямой режим»), НЕ дёргая safety_off/bring_down. До этой ветки штатно не доходим
    # (cross на awg отсечён transport_ready), но защищаемся от любого вызова.
    if ! awg_installed; then
        printf "${YELLOW}[failover]${NC} AmneziaWG не установлен — awg-перебор невозможен, пропускаю.\n"
        return 1
    fi
    acquire_lock

    cur_name=""
    [ -f "$ACTIVE_NAME" ] && cur_name=$(cat "$ACTIVE_NAME")

    # Сохраняем текущий (исходный) конфиг — если ни один резерв не встанет,
    # вернём его, чтобы awg0 мониторил именно исходный сервер.
    if [ -f "$ACTIVE_CONF" ]; then
        cp "$ACTIVE_CONF" "$BACKUP_CONF"
        if [ -f "$ACTIVE_NAME" ]; then cp "$ACTIVE_NAME" "$BACKUP_NAME"; else : > "$BACKUP_NAME"; fi
    fi

    printf "${BLUE}[failover]${NC} активный сервер ${YELLOW}%s${NC} не отвечает — перебираю резервы\n" "${cur_name:-?}"

    # 1) Немедленно вернуть интернет/публичный DNS (см. шапку функции).
    safety_off

    # 2) Перебор резервов по алфавиту; первый с handshake — наш.
    tried=""
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        [ "$name" = "$cur_name" ] && continue   # текущий (дохлый) пропускаем

        printf "${BLUE}[failover]${NC} пробую ${YELLOW}%s${NC}...\n" "$name"
        bring_down
        install_config "$f" "$name"
        if bring_up && wait_for_handshake; then
            apply_routing            # он же вернёт туннельный DNS: плагин + слой DoH
            ip=$(probe_ext_ip "--interface awg0" 5)
            printf "\n${GREEN}[failover OK]${NC} встал на ${YELLOW}%s${NC} (внешний IP: %s)\n" "$name" "${ip:-?}"
            if [ "$NF_LANG" = en ]; then
                notify_event "failover-ok" 1800 "BE7000: VPN failover -> $name" \
"Server ${cur_name:-?} stopped responding. The router automatically switched
to a backup config: $name — VPN works again (handshake received).
External IP now: ${ip:-unknown}.

To return to ${cur_name:-the previous one} manually: panel :8088 -> the VPN card."
            else
                notify_event "failover-ok" 1800 "BE7000: VPN-failover -> $name" \
"Сервер ${cur_name:-?} перестал отвечать. Роутер автоматически переключился
на резервный конфиг: $name — VPN снова работает (handshake получен).
Внешний IP сейчас: ${ip:-неизвестен}.

Вернуться на ${cur_name:-прежний} вручную: панель :8088 -> карточка VPN."
            fi
            return 0
        fi
        tried="$tried $name"
    done

    # 3) Ни один резерв не встал — возвращаем ИСХОДНЫЙ конфиг (чтобы awg0 мониторил
    #    именно его) и остаёмся в прямом режиме: safety_off уже сделан в п.1,
    #    apply_routing НЕ зовём.
    printf "\n${RED}[failover FAIL]${NC} ни один резерв не поднялся (пробовал:%s)\n" "${tried:- нет}"
    bring_down
    if [ -f "$BACKUP_CONF" ]; then
        install_config "$BACKUP_CONF" "$cur_name"
        bring_up   # без ожидания handshake: VPS мёртв, нам нужен лишь awg0 для мониторинга
    fi
    # Остаёмся в прямом режиме ⇒ полный repair запрещён (вернул бы маршрут в дохлый awg0),
    # но «доступ домой» после наших firewall reload'ов поднять надо — см. replay_home_only.
    replay_home_only
    if [ "$NF_LANG" = en ]; then
        notify_event "failover-fail" 3600 "BE7000: VPN down, backups unavailable — direct mode" \
"Server ${cur_name:-?} is not responding, and no backup config came up
(tried:${tried:- none}). The router is in DIRECT mode (safety_off): traffic and DNS
go around the VPN — if the ISP link is alive, the internet works; listed sites are
unavailable.
awg0 is up on ${cur_name:-the original} — monitoring continues: when any
server comes back, VPN returns automatically (the watchdog will retry the backups)."
    else
        notify_event "failover-fail" 3600 "BE7000: VPN упал, резервы недоступны — прямой режим" \
"Сервер ${cur_name:-?} не отвечает, и ни один резервный конфиг не поднялся
(пробовал:${tried:- нет}). Роутер в ПРЯМОМ режиме (safety_off): трафик и DNS идут
мимо VPN — если связь с провайдером есть, интернет работает; сайты из списка
недоступны.
awg0 поднят на ${cur_name:-исходном} — мониторинг продолжается: когда любой
сервер оживёт, VPN вернётся автоматически (watchdog повторит перебор резервов)."
    fi
    return 1
}

# ============================================================
# MAIN
# ============================================================
case "$1" in
    ""|list|ls)
        list_configs
        echo ""
        printf "Использование: %s <имя_конфига>\n" "$0"
        printf "Пример:        %s germany\n" "$0"
        printf "Откат:         %s rollback\n" "$0"
        printf "Текущий:       %s status\n" "$0"
        ;;
    status)
        show_status
        ;;
    rollback)
        acquire_lock
        rollback
        ;;
    safety-off|safety_off)
        # Точка входа для watchdog.sh: аварийный fail-open БЕЗ перебора
        # серверов — снять привязку к дохлому awg0 и пустить трафик/DNS
        # напрямую. Туннель НЕ опускаем: handshake продолжит мониториться,
        # и watchdog вернёт VPN, когда VPS оживёт.
        safety_off
        ;;
    failover)
        # Точка входа для watchdog.sh (режимы sticky/home) и ручного запуска:
        # перебрать резервы и встать на первый рабочий. Код возврата (0=встали на
        # резерв / 1=прямой режим) watchdog читает, чтобы выставить своё состояние.
        do_failover
        ;;
    stage)
        # РАЗЛОЖИТЬ конфиг БЕЗ переключения — зеркало того, что панель делает для xray/hy2
        # (`set_xray_server`: «просто стейджим конфиг — применится при switch»). Зачем отдельный
        # верб: у AmneziaWG раскладка не сводится к `cp` — это ТРИ файла (awg.conf +
        # amnezia_for_awg.conf, который читает вендорный awg_setup.sh, + удаление awg0.conf,
        # иначе демон возьмёт СТАРЫЕ ключи) плюс вычистка пустых I1..I5. Копия этой логики в CGI
        # разъехалась бы с install_config первой же правкой.
        # ЗАЧЕМ ВООБЩЕ (разбор с тестером 14.08.2026): без awg.conf `transport_ready awg` = false,
        # и панель честно пишет «нужен конфиг» — при том, что конфиг ДОБАВЛЕН и виден в списке.
        # Единственным способом положить awg.conf было полное переключение, а оно СНАЧАЛА роняет
        # текущую несущую: не поднялся awg — откатываться не на что (прежнего awg.conf нет) ⇒
        # safety_off, и человек остаётся вообще без VPN. Ровно это он и получил: «после попытки
        # установить авг теперь даже хистерия не запускается».
        [ -n "$2" ] || { printf "${RED}[FAIL]${NC} укажи имя конфига\n"; exit 1; }
        _st_src="$CONFIGS_DIR/${2}.conf"
        [ -f "$_st_src" ] || { printf "${RED}[FAIL]${NC} Не найден файл %s\n" "$_st_src"; exit 1; }
        install_config "$_st_src" "$2"
        printf "${GREEN}[OK]${NC} конфиг %s разложен (awg.conf + amnezia_for_awg.conf). Несущая НЕ тронута.\n" "$2"
        ;;
    *)
        switch_to "$1"
        ;;
esac
