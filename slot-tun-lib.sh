#!/bin/sh
# slot-tun-lib.sh — ОБЩИЙ per-slot слой tun2socks для доп-выходов (слотов мульти-транспорта).
#
# ЗАЧЕМ. Три транспорта несут слот ОДИНАКОВО: локальный socks-провайдер (ciadpi / xray /
# hysteria) + свой hev-socks5-tunnel → свой TUN → своя table 100N. Отличается ТОЛЬКО кто
# слушает socks. Первым это получил byedpi (Ф1c), и копировать те же 10 функций ещё в
# xray-transport.sh и transport-hy2.sh (Ф3) означало бы три расходящиеся копии — ровно та
# грабля, из-за которой resolve_ipv4 вынесли в dns-lib.sh, а probe_ext_ip — в ip-lib.sh.
# Здесь живёт ВСЁ, что не зависит от протокола: имена/порты/пути слота, per-slot hev.yaml,
# подъём и снятие hev, ожидание socks, карриер-маршрутизация.
#
# КОНТРАКТ ВЫЗЫВАЮЩЕГО (плагин транспорта определяет ДО `. slot-tun-lib.sh`):
#   ENODIA_DIR     — корень установки;
#   HEV         — путь к бинарю hev-socks5-tunnel;
#   SOCKS_ADDR  — адрес локального socks (127.0.0.1);
#   log()       — вывод в лог плагина;
#   proc_alive() — «жив ли pid из пидфайла» (пустой пидфайл = НЕ жив, см. грабли плагинов).
# Библиотека НЕ имеет собственных дефолтов для них СОЗНАТЕЛЬНО: молчаливый дефолт замаскировал
# бы неполный source (плагин без ENODIA_DIR не должен «почти работать» на чужих путях).
#
# ЧЕГО ЗДЕСЬ НЕТ (и почему):
#   * DNS — один dnsmasq на роутер, upstream ведёт ОСНОВНОЙ транспорт (дизайн §DNS);
#   * MASQUERADE — tun2socks ТЕРМИНИРУЕТ соединение на роутере (наружу идёт от него же);
#   * ip rule (fwmark 0xN → table 100N) — владелец ОДИН: mark-core.sh (fallback-aware);
#     плагин после slot-up/slot-down лишь просит transport.sh переиграть маркировку;
#   * анти-петля — протокол-специфична (endpoint-bypass у awg/xray/hy2, owner-RETURN у byedpi).
#
# ПОРТЫ. socks слота = SLOT_SOCKS_BASE+id (10832..10834). Один id = РОВНО один транспорт
# (реестр slots.sh), поэтому общая база для всех плагинов не создаёт коллизий, а совпадение
# с чужим (осиротевшим после смены транспорта слота) демоном лечит slot_free_socks.
# Диапазон 10812..10819 намеренно НЕ трогаем — там throwaway-инстансы xray-test.sh.

# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w` (ENODIA_DIR даёт
# вызывающий — см. контракт выше). Плагины сорсят её и сами, повторный source безвреден; здесь он
# ради того, чтобы карриер-маршруты слота не зависели от полноты чужого пролога. Нет файла —
# прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi

: "${ENODIA_STATE:=/data/usr/app/enodia-state}"

SLOT_SOCKS_BASE=10830

slot_socks_port() { echo $(( SLOT_SOCKS_BASE + $1 )); }   # id 2 -> 10832 ...
slot_tun()        { echo "xtun$1"; }
slot_table()      { echo "100$1"; }
slot_hev_pid()    { echo "/tmp/hev-s$1.pid"; }
slot_hev_log()    { echo "/tmp/hev-s$1.log"; }
slot_hev_yaml()   { echo "$ENODIA_STATE/hev-s$1.yaml"; }

# per-slot hev.yaml: свой tun/порт/ipv4. 198.18.<id>.1 — бенчмарк-диапазон (RFC 2544), не
# пересекается ни с LAN, ни с реальными сетями ⇒ адрес TUN слота ничего не затеняет.
slot_write_hev_yaml() {   # $1 = id
    _id="$1"
    cat > "$(slot_hev_yaml "$_id")" <<YAML
tunnel:
  name: xtun$_id
  mtu: 8500
  ipv4: 198.18.$_id.1
socks5:
  port: $(slot_socks_port "$_id")
  address: 127.0.0.1
  udp: 'udp'
misc:
  log-file: $(slot_hev_log "$_id")
  log-level: warn
YAML
}

# Дождаться, пока socks-порт слота начнёт слушать. $2 = число попыток (деф. 8).
# Пробел в grep-шаблоне обязателен: без него "10832" матчил бы и "108320" (чужой порт).
slot_wait_socks() {   # $1 = port ; $2 = tries
    _p="$1"; _t="${2:-8}"; _i=0
    while [ "$_i" -lt "$_t" ]; do
        netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$_p " && return 0
        sleep 1; _i=$((_i+1))
    done
    netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$_p "
}

# Освободить socks-порт слота, если его держит ЧУЖОЙ pid. Причина та же, что у основного
# free_foreign_socks: осиротевший демон (смена транспорта слота, оборванный рестарт) держит
# порт → наш socks-провайдер не забиндит и молча умрёт, а netstat увидит ЧУЖОГО слушателя →
# «поднялся» вернулось бы ЛОЖНО, и трафик выхода пошёл бы через чужой протокол/сервер.
slot_free_socks() {   # $1 = id ; $2 = пидфайл СВОЕГО socks-провайдера
    _port=$(slot_socks_port "$1"); _own=$(cat "$2" 2>/dev/null | tr -d ' \r\n')
    _holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$_port " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$_holder" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_holder" = "$_own" ] && return 0
    log "слот №$1: socks $_port держит чужой pid $_holder — освобождаю"
    kill "$_holder" 2>/dev/null
    _i=0; while [ $_i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$_port " || break; sleep 1; _i=$((_i+1)); done
}

# Держит ли socks-порт слота ИМЕННО наш демон? «Порт слушает» ≠ «слушает тот, кого мы запустили»:
# при перезапуске демона слота (смена стратегии/конфига) уходящий предшественник ещё держит бинд
# несколько секунд, новый в этот момент не стартует — и проверка по одному netstat отрапортовала бы
# успех, хотя через миг socks исчезнет вместе с ним. Нет netstat -p или держатель не определился →
# считаем «наш»: диагностики нет, ронять из-за этого рабочий путь нельзя.
slot_socks_is_ours() {   # $1 = port ; $2 = свой пидфайл
    _own=$(cat "$2" 2>/dev/null | tr -d ' \r\n')
    [ -n "$_own" ] || return 1
    _holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$1 " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$_holder" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_holder" = "$_own" ]
}

# Поднять hev слота (tun2socks → socks слота) и дождаться появления TUN. Идемпотентно
# (жив — не трогаем): watchdog зовёт slot-up повторно для reup. 0 = TUN есть.
slot_hev_up() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id")
    [ -x "$HEV" ] || { log "слот №$_id: НЕТ бинаря hev ($HEV)"; return 1; }
    slot_write_hev_yaml "$_id"
    if ! proc_alive "$(slot_hev_pid "$_id")"; then
        log "слот №$_id: запускаю hev (tun2socks -> $_tun)…"
        start-stop-daemon -S -b -m -p "$(slot_hev_pid "$_id")" -x "$HEV" -- "$(slot_hev_yaml "$_id")"
    fi
    _i=0; while [ $_i -lt 6 ]; do ip link show "$_tun" >/dev/null 2>&1 && break; sleep 1; _i=$((_i+1)); done
    ip link show "$_tun" >/dev/null 2>&1 || {
        log "слот №$_id: tun $_tun не создан. Лог hev:"; tail -n 15 "$(slot_hev_log "$_id")" 2>/dev/null; return 1; }
    return 0
}

# Снять hev слота. hev держит xtunN как НЕ-persistent tun ⇒ устройство уходит вместе с ним,
# но -K НЕ блокирует, поэтому ждём исчезновения (и добиваем явным del, если tun пережил hev).
# Пидфайл убираем, чтобы не копить stale (риск попасть в переиспользованный pid).
slot_hev_down() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id")
    start-stop-daemon -K -p "$(slot_hev_pid "$_id")" 2>/dev/null
    _i=0
    while ip link show "$_tun" >/dev/null 2>&1 && [ "$_i" -lt 6 ]; do
        ip link del "$_tun" 2>/dev/null
        ip link show "$_tun" >/dev/null 2>&1 || break
        sleep 1; _i=$((_i+1))
    done
    rm -f "$(slot_hev_pid "$_id")" 2>/dev/null
}

# Карриер-часть слота: default dev xtunN в table 100N + FORWARD ACCEPT (у fw3 policy FORWARD=DROP).
# БЕЗ MASQUERADE (см. шапку). ip rule ставит mark-core — тут только своя таблица и своё устройство.
slot_apply_routing() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id"); _tab=$(slot_table "$_id")
    ip link set "$_tun" up 2>/dev/null
    iptables -C FORWARD -o "$_tun" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$_tun" -j ACCEPT
    iptables -C FORWARD -i "$_tun" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$_tun" -j ACCEPT
    ip route replace default dev "$_tun" table "$_tab"
}
slot_remove_routing() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id"); _tab=$(slot_table "$_id")
    ip route flush table "$_tab" 2>/dev/null || true
    iptables -D FORWARD -o "$_tun" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$_tun" -j ACCEPT 2>/dev/null
}
