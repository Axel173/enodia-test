#!/bin/sh
# warp.sh — «ПОЛУЧИТЬ WARP»: the router registers ITSELF at Cloudflare WARP and gets its own AmneziaWG config, an exit on it and
# (optionally) a road through it for a server whose address the ISP blocked (road.sh).
#
# WHY ITS OWN REGISTRATION. A WARP config from a bot or a friend is a SHARED key: the server keeps one session per key and roams
# between the devices that use it — both flap (the same WARP.conf on BE7000 and AX3600 did exactly that). Online generators also
# create the private key on THEIR side. Here the key is generated on the router (`awg genkey`) and never leaves it; one account
# per router. The API is Cloudflare's unofficial client API (the Android app's): it changes ⇒ every deviation is a refusal in
# words («Cloudflare сменил порядок — нужна новая версия панели»), never a half-written config.
# MASKING (spike BE7000 10.10.2026, dev notes «сервер-через-WARP-дизайн» §9): plain WireGuard to WARP is cut by the ISP after the
# handshake (~3 KB). The config always carries an I1 the ROUTER builds: a QUIC Initial header — the bytes every real QUIC
# Initial has — with the connection id and the body random (`<r N>` is re-drawn by amneziawg-go on EVERY handshake): nothing to
# learn but «this is QUIC», nothing to go stale. S1..S4 stay 0 and H1..H4 = 1..4: the server is vanilla WireGuard.
# PORT BY THE RESULT (hardware test of the registration, BE7000 10.10.2026, dev notes §10): WARP listens on many ports and the ISP
# cuts some of them right after the handshake — 2408, WARP's standard one, gave a handshake and 92 bytes, 891 carried. A handshake
# proves nothing, so the config gets the first port that CARRIES DATA: `transport-awg.sh try` raises a throwaway interface per port
# and asks Cloudflare's trace through it (`warp=on` = pass; the same answer names the colo). None passes ⇒ an error in words and no
# config (the registration is free; an unused one just stays at Cloudflare).
#
# Commands:
#   warp.sh get [<rider config>] — start in the background: register, write configs/WARP.conf, create the exit «WARP», and set the
#                                  rider's road through it; progress and the answer → a JSON file the panel polls (`status`)
#   warp.sh status               — that JSON (state none|running|done|error, msg, exit id, port, colo)
#   warp.sh run [<rider>]        — the work itself, in the foreground
#   warp.sh i1                   — print a generated I1 (what the config gets)
#   warp.sh list                 — the AmneziaWG configs that ARE WARP (server key = Cloudflare's): `name⇥i1` (1 — has a masking
#                                  I1, 0 — none: the ISP may cut it after the handshake) — the ONLY answer «is this config WARP»
#   warp.sh colo <exit id>       — where Cloudflare took exit <id>'s connection: its trace through the exit's live interface →
#                                  {"colo":"HEL","warp":true} | {"colo":"","why":"…"} (DME = Moscow, filtered since spring 2026)
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
API=https://api.cloudflareclient.com/v0a2158
UA="okhttp/3.12.1"; CV="a-6.10-2158"                  # what the Android app sends; the API refuses other clients
WARP_PUB='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo='   # one server key for everyone — a config with it IS WARP (road/panel badge)
NAME=WARP                                              # configs/WARP.conf and the exit's name
PORTS="891 500 1701 4500 854 878 894 908 2408"          # the measured one first, WARP's standard one last (cut here)
TRACE=https://1.1.1.1/cdn-cgi/trace                     # answers `warp=on` + `colo=XXX` only through WARP
TRY_SECS=8                                             # per port: a live WARP answers in ~1 s; worst case ≤ 9 × ~11 s
ST=/tmp/enodia-warp.json; PIDF=/tmp/enodia-warp.pid
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
command -v curl_ca_opt >/dev/null 2>&1 || curl_ca_opt() { return 0; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi   # jtxt: a byte cut that keeps UTF-8 whole
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '"\000-\037\\'; }

# The masking packet: QUIC v1 Initial long header — first byte 0xce (long header, Initial, 4-byte packet number), version
# 00000001, DCID length 8, DCID random, SCID length 0, token length 0, length 0x44d0 (1232), packet number + payload random ⇒
# 1250 bytes, the size of a real client Initial. Measured: works like a captured template, with and without Jc.
gen_i1() { printf '<b 0xce0000000108><r 8><b 0x000044d0><r 1232>'; }

put() { _wpt=$(mktemp "$ST.XXXXXX" 2>/dev/null) || return 1; printf '%s\n' "$1" > "$_wpt" && mv "$_wpt" "$ST"; }   # mktemp: O_EXCL, no planted name
# The config for port $1 from the registration's answer (cmd_run's variables): the probe and the saved file are one text.
wconf() {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32%s\nMTU = 1280\n' "$_wpriv" "$_wv4" "${_wv6:+, $_wv6/128}"
    printf 'S1 = 0\nS2 = 0\nJc = 4\nJmin = 40\nJmax = 70\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = %s\n' "$(gen_i1)"
    printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s:%s\nPersistentKeepalive = 25\n' "$WARP_PUB" "$_wep" "$1"
}
say() { put "{\"state\":\"running\",\"msg\":\"$1\"}"; }
fail() { put "{\"state\":\"error\",\"msg\":\"$1\"}"; exit 1; }

cmd_get() {
    _wgp=$(cat "$PIDF" 2>/dev/null | tr -cd '0-9')
    [ -n "$_wgp" ] && [ -d "/proc/$_wgp" ] && { echo "[warp] получение уже идёт"; return 0; }
    if [ -n "$1" ]; then printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+$' && [ -f "$ENODIA_STATE/configs/$1.conf" ] \
        || { echo "[warp] нет конфига «$1»"; return 1; }; fi
    [ -f "$ENODIA_STATE/configs/$NAME.conf" ] && { echo "[warp] WARP этого роутера уже есть (конфиг «$NAME») — сперва удалите его"; return 1; }
    [ -x "$ENODIA_BIN/awg" ] || { echo "[warp] нет AmneziaWG — поставьте его в «Компонентах»"; return 1; }
    say "начинаю"
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -m -p "$PIDF" -x /bin/sh -- "$ENODIA_DIR/warp.sh" run "$1" >/dev/null 2>&1
    else ( sh "$ENODIA_DIR/warp.sh" run "$1" >/dev/null 2>&1 & ); fi
    echo "[warp] получаю WARP — обычно до 30 секунд"
}

cmd_run() {   # $1 = rider (optional)
    W=/tmp/enodia-warp.work.$$; rm -rf "$W"; ( umask 077; mkdir "$W" ) || fail "нет места для работы"
    trap 'rm -rf "$W" "$PIDF"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
    say "создаю ключ на роутере"
    _wpriv=$("$ENODIA_BIN/awg" genkey 2>/dev/null); _wpub=$(printf '%s' "$_wpriv" | "$ENODIA_BIN/awg" pubkey 2>/dev/null)
    [ -n "$_wpriv" ] && [ -n "$_wpub" ] || fail "не удалось создать ключ (awg genkey)"
    say "регистрируюсь у Cloudflare"
    _wtos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","model":"PC","serial_number":"","locale":"en_US"}' "$_wpub" "$_wtos" > "$W/req"
    _wca=$(curl_ca_opt "$API/reg")
    # shellcheck disable=SC2086
    _wc=$(curl -s $_wca -o "$W/reg" -w '%{http_code}' --connect-timeout 10 --max-time 20 -X POST \
        -H "User-Agent: $UA" -H "CF-Client-Version: $CV" -H 'Content-Type: application/json' --data-binary @"$W/req" "$API/reg" 2>/dev/null)
    case "$_wc" in
        200) ;;
        000|'') fail "Cloudflare не ответил — попробуйте позже" ;;
        *) fail "Cloudflare отклонил регистрацию (HTTP $_wc): он сменил порядок — нужна новая версия панели" ;;
    esac
    _wsk=$(jsonfilter -i "$W/reg" -e '@.config.peers[0].public_key' 2>/dev/null)
    _wv4=$(jsonfilter -i "$W/reg" -e '@.config.interface.addresses.v4' 2>/dev/null)
    _wv6=$(jsonfilter -i "$W/reg" -e '@.config.interface.addresses.v6' 2>/dev/null)
    _wep=$(jsonfilter -i "$W/reg" -e '@.config.peers[0].endpoint.v4' 2>/dev/null | sed 's/:[0-9]*$//')
    [ "$_wsk" = "$WARP_PUB" ] || fail "Cloudflare прислал незнакомый ключ сервера — нужна новая версия панели"
    printf '%s' "$_wv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || fail "Cloudflare не прислал адрес — нужна новая версия панели"
    printf '%s' "$_wep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || fail "Cloudflare не прислал адрес сервера — нужна новая версия панели"
    _wn=0; _wall=0; _wport=""; _wcolo=""
    for _wp in $PORTS; do _wall=$((_wall+1)); done
    for _wp in $PORTS; do
        _wn=$((_wn+1)); say "ищу порт, который провайдер не режет: $_wp ($_wn из $_wall)"
        wconf "$_wp" > "$W/conf" || fail "не удалось записать конфиг"
        _wtr=$(sh "$ENODIA_DIR/transport-awg.sh" try "$W/conf" "$TRACE" "$TRY_SECS" 2>/dev/null); _wrc=$?
        case "$_wrc" in
            0) printf '%s\n' "$_wtr" | grep -qx 'warp=on' || continue
               _wport=$_wp; _wcolo=$(printf '%s\n' "$_wtr" | sed -n 's/^colo=\([A-Z][A-Z][A-Z]\)$/\1/p' | head -n 1); break ;;
            4) fail "не поднялся пробный интерфейс AmneziaWG — проверьте его в «Компонентах»" ;;
            5) fail "сейчас идёт другая проба конфига — повторите через минуту" ;;
        esac
    done
    [ -n "$_wport" ] || fail "Cloudflare выдал WARP, но провайдер режет его на всех портах ($(echo $PORTS | sed 's/ /, /g')) — конфиг не сохранён"
    say "сохраняю конфиг (порт $_wport)"
    mkdir -p "$ENODIA_STATE/configs" || fail "нет каталога конфигов"
    ( umask 077; cp "$W/conf" "$ENODIA_STATE/configs/$NAME.conf.$$" ) && mv "$ENODIA_STATE/configs/$NAME.conf.$$" "$ENODIA_STATE/configs/$NAME.conf" \
        || fail "не удалось записать конфиг (место на разделе?)"
    say "создаю выход"
    _wso=$(sh "$ENODIA_DIR/slots.sh" add "$NAME" awg "$NAME" main 2>&1)
    _wid=$(printf '%s\n' "$_wso" | sed -n 's/.*выход №\([2-7]\) .*создан.*/\1/p' | tail -n 1)
    [ -n "$_wid" ] || fail "конфиг «$NAME» сохранён, а выход не создался: $(printf '%s' "$_wso" | tail -n 1 | sed 's/^\[slots\] //' | tr -d '"\\' | jtxt 160)"
    if [ -n "$1" ]; then
        say "прокладываю дорогу для $1"
        _wro=$(sh "$ENODIA_DIR/road.sh" set awg "$1" "$_wid" 2>&1) \
            || fail "WARP получен (выход №$_wid), а дорога не встала: $(printf '%s' "$_wro" | tail -n 1 | sed 's/^\[road\] //' | tr -d '"\\' | jtxt 160)"
    fi
    put "{\"state\":\"done\",\"exit\":\"$_wid\",\"rider\":\"$1\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"WARP получен: выход №$_wid${1:+, $1 едет через него}\"}"
    exit 0
}

# One awk pass over every config: a [Peer] key equal to Cloudflare's makes it WARP; a non-empty I1 is the masking. Names as the
# panel knows them (the file name without .conf).
cmd_list() {
    set -- "$ENODIA_STATE"/configs/*.conf
    [ -f "$1" ] || return 0
    awk -v k="$WARP_PUB" '
        FNR == 1 { if (nm != "" && w) print nm "\t" i; nm = FILENAME; sub(/^.*\//, "", nm); sub(/\.conf$/, "", nm); w = 0; i = 0 }
        { sub(/\r$/, "") }
        /^[ \t]*PublicKey[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); if (v == k) w = 1 }
        /^[ \t]*I1[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); if (v ~ /[^ \t]/) i = 1 }
        END { if (nm != "" && w) print nm "\t" i }' "$@" 2>/dev/null | grep -E "^[A-Za-z0-9._-]+$(printf '\t')[01]\$"
}
# Cloudflare's point for an exit: the trace through ITS interface (the name — from the orchestrator, the only owner of «id → iface»).
# The answer is Cloudflare's text; anything else — «нет данных» with a reason, never a guessed point.
cmd_colo() {
    case "$1" in [2-7]) ;; *) echo '{"colo":"","why":"битый номер выхода"}'; return 0 ;; esac
    _wif=$(sh "$ENODIA_DIR/transport.sh" slot-iface "$1" 2>/dev/null | tr -cd 'a-z0-9')
    [ -n "$_wif" ] && [ -d "/sys/class/net/$_wif" ] || { echo '{"colo":"","why":"выход не поднят"}'; return 0; }
    _wca=$(curl_ca_opt "$TRACE" --interface "$_wif")
    # shellcheck disable=SC2086
    _wtr=$(curl -s $_wca --interface "$_wif" --connect-timeout 5 --max-time "$TRY_SECS" "$TRACE" 2>/dev/null)
    _wcl=$(printf '%s\n' "$_wtr" | sed -n 's/^colo=\([A-Z][A-Z][A-Z]\)$/\1/p' | head -n 1)
    [ -n "$_wcl" ] || { echo '{"colo":"","why":"Cloudflare не ответил через выход"}'; return 0; }
    printf '{"colo":"%s","warp":%s}\n' "$_wcl" "$(printf '%s\n' "$_wtr" | grep -qx 'warp=on' && echo true || echo false)"
}

case "$1" in
    get)    cmd_get "$2" ;;
    status) cat "$ST" 2>/dev/null || printf '{"state":"none"}\n' ;;
    run)    cmd_run "$2" ;;
    i1)     gen_i1; echo ;;
    list)   cmd_list ;;
    colo)   cmd_colo "$2" ;;
    *)      echo "usage: $0 get [<конфиг>] | status | run [<конфиг>] | i1 | list | colo <id>"; exit 2 ;;
esac
