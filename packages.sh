#!/bin/sh
# packages.sh — ДВИЖОК КОМПОНЕНТОВ («связок»): что установлено, сколько займёт/освободит,
# можно ли снять и почему нет, и собственно установка/удаление по ПЛАНУ.
#
# ЗАЧЕМ отдельный движок, когда есть proto-install.sh: тот знает только ФИКСИРОВАННЫЕ наборы
# (awg-xray, awg-hy2, …) и потому врёт про реальный роутер — на живом BE7000 автора одновременно
# стоят xray (основная несущая) и byedpi (несёт доп-выход №2), а панель рисует «AmneziaWG + Xray»,
# потому что комбо такого не предусматривает. Модульность = привести UI к тому, что уже есть.
#
# ЕДИНИЦА — НЕ бинарь, а СВЯЗКА на протокол: «Xray» = xray + hev, «AmneziaWG» = amneziawg-go + awg
# (CLI), «ByeDPI» = byedpi + hev. Человек мыслит протоколами, а не файлами; связка «awg без CLI»
# уже ловилась как «готов, но awg0 не встаёт» ([[awg-ready-needs-both-binaries]]).
#
# УСТАНОВЛЕН ≠ АКТИВЕН. Рядом могут лежать несколько альтов (если влезли); трафик несёт один —
# это стережёт transport.sh, а доп-выходы (слоты) имеют свой socks 10830+id. Поэтому движок НИЧЕГО
# не переключает: он только кладёт и снимает файлы. Активация — transport.sh switch из панели.
#
# ПОРЯДОК ОПЕРАЦИИ (грабли флеша): удаления ВСЕГДА первыми → sync (UBIFS пишет лениво, иначе df
# завышает «занято» и гард ложно блокирует) → закачки. Отсюда и форма верба: ОДИН план
# «поставить X, снять Y», а не два независимых действия — замена Xray→Hysteria2 при неснижаемом
# резерве иначе распадается на два прогона, между которыми роутер остаётся без транспорта.
#
# РЕЗЕРВ /data — ЖЁСТКИЙ (2.5 МБ, цифра одна и живёт в store-lib.sh). /data всего 20.6 МБ, и «в
# ноль» его выбирать нельзя: там же логи, снимки
# гео, бэкапы обновлений, а UBIFS без свободных блоков начинает отдавать ENOSPC на ровном месте.
# Не хватило — план возвращает ok=false и СПИСОК того, что можно снять (панель предлагает выбор).
#
# Прогресс — ТОТ ЖЕ протокол и ТЕ ЖЕ файлы, что у proto-install.sh (.proto-install.{state,log} +
# лок /tmp/proto-install.lock): панель уже умеет их опрашивать, а «две установки разом» на 20-МБ
# флеше — ровно тот случай, который лок и придуман не пускать.
#
# rm живёт ЗДЕСЬ (PS-guard на литерал rm). set -e НЕ используем — шаги best-effort.

ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Где лежит бинарь (store-lib.sh). Движку это нужно, чтобы «установлен ли» и «сколько
# освободит» отвечали про ФАКТИЧЕСКИЙ файл, а не про ожидаемое место: связка, уехавшая на
# внешний накопитель, обязана оставаться «установленной». Без накопителя — прежний путь.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path   >/dev/null 2>&1 || bin_path()   { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_dest   >/dev/null 2>&1 || bin_dest()   { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_prune  >/dev/null 2>&1 || bin_prune()  { return 0; }
command -v store_ready >/dev/null 2>&1 || store_ready() { return 1; }
command -v store_root  >/dev/null 2>&1 || store_root()  { printf ''; }
# БЕЗ store-lib.sh переменная пуста, а do_remove сравнивает её с $ENODIA_DIR и делает rm по
# "$BIN_DIR/$b" — то есть по «/имя» в корне. Дефолт закрывает весь этот класс разом.
: "${BIN_DIR:=$ENODIA_DIR}"
# То же и для резерва: цифра живёт в store-lib.sh (её сторожит и usb-offload.sh, возвращая бинари
# с накопителя), а литерал здесь — ровно шим для установки без библиотеки.
: "${DATA_RESERVE_B:=2621440}"
GH="$ENODIA_DIR/gh-update.sh"
STATE="$ENODIA_STATE/.proto-install.state"
LOG="$ENODIA_STATE/.proto-install.log"
LOCK=/tmp/proto-install.lock
RESERVE_B="$DATA_RESERVE_B"   # 2.5 МБ неснижаемого запаса на /data (единственная цифра — в store-lib.sh)

# Реестр связок. Новый компонент = ОДНО слово в PKGS + по строке в трёх case ниже.
PKGS="awg xray hy2 byedpi zapret doh tls"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
set_state() { echo "$1" > "$STATE"; }

pkg_known()  { case " $PKGS " in *" $1 "*) return 0 ;; esac; return 1; }
pkg_label()  { case "$1" in
        awg) echo "AmneziaWG" ;; xray) echo "Xray" ;; hy2) echo "Hysteria2" ;;
        byedpi) echo "ByeDPI" ;; zapret) echo "Zapret" ;;
        doh) echo "Шифрованный DNS" ;; tls) echo "HTTPS панели" ;;
    esac; }
# Свои бинари связки (их и удаляем).
pkg_own()    { case "$1" in
        awg) echo "amneziawg-go awg" ;; xray) echo "xray" ;; hy2) echo "hysteria" ;;
        byedpi) echo "byedpi" ;; zapret) echo "nfqws" ;;
        doh) echo "https-dns-proxy dot-proxy" ;; tls) echo "panel-tls" ;;
    esac; }
# ОБЩИЕ бинари: нужны связке, но принадлежат не ей (ref-count при удалении).
pkg_shared() { case "$1" in xray|hy2|byedpi) echo "hev" ;; esac; }
# Всё, что должно лежать, чтобы связка РАБОТАЛА (наличие + размер установки).
pkg_files()  { echo "$(pkg_own "$1") $(pkg_shared "$1")"; }

have_bin() { [ -x "$(bin_path "$1")" ]; }
in_list()  { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# absent (ничего нет) | partial (часть файлов) | installed (всё на месте).
# «partial» — не педантизм: половинная установка awg («демон есть, CLI нет») ВРАЛА «готов»,
# и переключение на неё роняло рабочий xray.
# «Есть ли связка вообще» судим по СВОИМ бинарям, а общие (hev) — только на «полноту»:
# иначе hev, лежащий ради byedpi, делал НЕустановленную Hysteria2 «частично установленной»
# (панель предвыбирала её галочкой как стоящую). Поймано на железе 31.07.
pkg_state() {
    _n=0; _h=0
    for b in $(pkg_own "$1");   do _n=$((_n+1)); have_bin "$b" && _h=$((_h+1)); done
    [ "$_h" = 0 ] && { echo absent; return 0; }
    for b in $(pkg_shared "$1"); do _n=$((_n+1)); have_bin "$b" && _h=$((_h+1)); done
    if [ "$_h" = "$_n" ]; then echo installed; else echo partial; fi
}

# Транспорты, несущие доп-выходы — спрашиваем РЕЕСТР слотов (единственный владелец ответа).
# Гард `-f`, а не `-x` (класс Б5-9): снятый бит выполнения ⇒ ответ «выходов нет» ⇒ гард удаления
# молча разрешает снять транспорт, несущий доп-выход, и утащить hev из-под живых слотов. Ref-count
# обязан замолкать только когда реестра НЕТ, а не когда ему забыли поставить +x.
slot_carriers() { [ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" carriers 2>/dev/null; }
slot_uses() { slot_carriers | grep -qx "$1"; }

# --- ГАРДЫ УДАЛЕНИЯ -----------------------------------------------------------------
# Печатает ПРИЧИНУ, по которой связку снимать нельзя (пусто = можно). Причины намеренно
# человеческие: их показывает панель прямо на серой кнопке, а не «ошибка 1».
# Гард по «доступу домой» — НОВЫЙ и закрывает живой баг: awgs0 (роутер как VPN-сервер) — ЭТОТ ЖЕ
# демон amneziawg-go, и снятие awg молча уносило его вместе с правилами. Панель при этом
# продолжала показывать «включено», а телефон домой не заходил до ребута.
pkg_hold() {
    # СНЯТЬ МОЖНО ТОЛЬКО ТО, ЧТО СТОИТ. Гард судил по одному НАМЕРЕНИЮ (`.transport`, реестр слотов,
    # `.doh-on`, `.panel-tls`) и не спрашивал, установлена ли связка вообще, — поэтому на свежей
    # установке с ИМПОРТИРОВАННЫМ бэкапом панель показывала «AmneziaWG · НЕ УСТАНОВЛЕН · снять
    # нельзя: несёт трафик прямо сейчас» и «Шифрованный DNS · НЕ УСТАНОВЛЕН · снять нельзя:
    # включён». Замерено на AX3600 16.08.2026: импорт вернул `.transport=awg` и `.doh-on`, а
    # бинарей нет вовсе — намерение с чужого роутера приехало, файлы остались там.
    # Для плана это безопасно: снятие отсутствующего и так пустая операция.
    if [ "$(pkg_state "$1")" = absent ]; then return 0; fi
    _t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    case "$1" in
        awg|xray|hy2|byedpi|zapret)
            [ "$_t" = "$1" ] && { echo "несёт трафик прямо сейчас — сперва переключи транспорт"; return 0; }
            slot_uses "$1" && { echo "несёт дополнительный выход — сперва убери выход в «Серверах»"; return 0; }
            ;;
    esac
    case "$1" in
        awg) [ -f "$ENODIA_STATE/server/.on" ] && { echo "нужен для «доступа домой» (сервер awgs0 — тот же демон)"; return 0; } ;;
        # Третий потребитель nfqws — устройства «целиком в десинк» (правила по источнику). Их не
        # видно ни в .transport, ни в списке выходов, поэтому без этой строки удаление проходило
        # бы «успешно», а у телевизора десинк тихо исчезал.
        zapret) [ -s "$ENODIA_STATE/.desync-ips" ] && { echo "его держат устройства «целиком в десинк» ($(grep -c . "$ENODIA_STATE/.desync-ips" 2>/dev/null)) — сперва верни им обычный режим"; return 0; } ;;
        doh) [ "$(cat "$ENODIA_STATE/.doh-on" 2>/dev/null)" = on ] && { echo "включён шифрованный DNS — сперва выключи"; return 0; } ;;
        tls) [ -f "$ENODIA_STATE/.panel-tls" ] && { echo "включён HTTPS панели — снимешь и потеряешь вход"; return 0; } ;;
    esac
    return 0
}

# ПОЧЕМУ СТОЯЩАЯ СВЯЗКА ЗДЕСЬ НЕ ЗАРАБОТАЕТ. Отдельный вопрос от pkg_hold («почему нельзя снять»)
# и от state («стоит ли»): бинарь бывает на месте, а сделать им нечего — zapret на ядре 4.4
# (AX3600/BE3600) без libxt_NFQUEUE. Экран «Компоненты» показывал такую связку просто «установлен»,
# и человек видел занятые 122 КБ без единого слова о том, что включить их тут невозможно; причину
# называла только карточка Zapret. Спрашиваем ВЛАДЕЛЬЦА ответа (verb nfq-ok, проба кэширована) —
# второй копии пробы в проекте нет; rc=2 (старая копия плагина) = НЕ судим, как в transport_ready.
# Печатает строку-причину или ничего.
pkg_warn() {
    [ "$(pkg_state "$1")" = absent ] && return 0
    case "$1" in
        zapret) [ -f "$ENODIA_DIR/zapret.sh" ] || return 0
                sh "$ENODIA_DIR/zapret.sh" nfq-ok >/dev/null 2>&1 || [ "$?" = 2 ] || \
                    echo "на этом роутере не заработает: ядро без NFQUEUE (десинк без VPS здесь даёт ByeDPI)" ;;
    esac
    return 0
}

# --- РАЗМЕРЫ -------------------------------------------------------------------------
# ДВЕ СТОРОНЫ ОДНОГО ПЛАНА. С внешним накопителем «сколько займёт» перестаёт быть одним числом:
# xray уедет на флешку, hev останется на /data — и резерв стережёт ТОЛЬКО /data. Поэтому у
# обеих размерных функций есть scope: пусто = «весь вес связки» (человеку — сколько она весит),
# data = «сколько из этого ляжет/лежит на /data» (арифметика резерва). Без накопителя оба ответа
# совпадают байт-в-байт, то есть на стоковом роутере ничего не изменилось.
# Куда ЛЯЖЕТ новый файл, знает bin_dest; где ЛЕЖИТ существующий — bin_path. Спрашивать надо
# разное: снимаем мы то, что лежит, а ставим — туда, где место.
#
# «Сколько ЗАЙМЁТ» — из bin-manifest.txt (gh-update.sh bin-size), только недостающие файлы:
# доустановка hev к уже стоящему byedpi стоит 0.15 МБ, а не размер всей связки.
pkg_add_b() {       # $1 = связка, $2 = scope (пусто | data)
    _s=0
    for b in $(pkg_files "$1"); do
        have_bin "$b" && continue
        if [ "$2" = data ] && [ "$(bin_dest "$b")" != "$ENODIA_BIN/$b" ]; then continue; fi
        _n=$(sh "$GH" bin-size "$b" 2>/dev/null | tr -d ' \r'); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        _s=$((_s+_n))
    done
    echo "$_s"
}
# «Не знаю размер» ≠ «ноль». bin-manifest.txt может не доехать (старый публичный снимок, нет
# сети) — тогда pkg_add_b молча считает недостающий файл БЕСПЛАТНЫМ и вердикт «влезет» врёт на
# целые мегабайты. Панели отдаём это флагом, машинным вызывающим (plan-ok) — как ОТКАЗ.
pkg_add_unknown() {   # 0 = хотя бы один нужный размер неизвестен
    for b in $(pkg_files "$1"); do
        have_bin "$b" && continue
        _n=$(sh "$GH" bin-size "$b" 2>/dev/null | tr -d ' \r')
        case "$_n" in ''|*[!0-9]*|0) return 0 ;; esac
    done
    return 1
}
# «Сколько ОСВОБОДИТ» — ФАКТИЧЕСКИЕ байты файлов на диске (манифест мог отстать от того, что
# реально лежит). hev считаем только если после ЭТОГО плана он никому не нужен.
pkg_del_b() {       # $1 = связка, $2 = ВЕСЬ список снимаемых (ref-count для hev), $3 = scope,
                    # $4 = 1, если hev в ЭТОМ плане уже засчитан кем-то другим (см. plan_calc)
    _s=0
    for b in $(pkg_own "$1"); do
        _p=$(bin_path "$b"); [ -f "$_p" ] || continue
        if [ "$3" = data ] && [ "$_p" != "$ENODIA_BIN/$b" ]; then continue; fi
        _n=$(stat -c%s "$_p" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        _s=$((_s+_n))
    done
    _hp=$(bin_path hev)
    if [ "$4" != 1 ] && [ -n "$(pkg_shared "$1")" ] && [ -f "$_hp" ] && ! hev_needed_after "$2"; then
        if [ "$3" != data ] || [ "$_hp" = "$ENODIA_BIN/hev" ]; then
            _n=$(stat -c%s "$_hp" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
            _s=$((_s+_n))
        fi
    fi
    echo "$_s"
}
# hev общий: его держат ЛЮБОЙ оставшийся socks-карриер и ЛЮБОЙ слот на нём (slot-tun-lib.sh).
hev_needed_after() {   # $1 = список снимаемых; 0 = hev ещё нужен
    for p in xray hy2 byedpi; do
        in_list "$p" "$1" && continue
        for b in $(pkg_own "$p"); do have_bin "$b" && return 0; done
    done
    for c in $(slot_carriers); do
        case "$c" in xray|hy2|byedpi) return 0 ;; esac
    done
    return 1
}

disk_free_b()  { df /data 2>/dev/null | tail -1 | awk 'NF>=5{printf "%.0f", $(NF-2)*1024}'; }
disk_total_b() { df /data 2>/dev/null | tail -1 | awk 'NF>=5{printf "%.0f", $(NF-4)*1024}'; }
# Свободно на внешнем накопителе (0, когда его нет). Флешка на порядки больше флеша, но
# «на порядки» ≠ «бесконечно»: там же файлы пользователя, поэтому свой скромный запас есть и тут.
store_free_b() {
    if store_ready; then df -k "$(store_root)" 2>/dev/null | tail -1 | awk 'NF>=5{printf "%.0f", $(NF-2)*1024}'
    else echo 0; fi
}
STORE_RESERVE_B=16777216
# «xray,hy2» → «xray hy2»; «-» и пусто → пусто (панель шлёт «-» для пустой стороны плана).
norm_list()    { printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//; s/^-$//'; }
# Байты → «X.Y МБ» для ЛОГА (человек читает мегабайты, а busybox не умеет float). Знак вручную:
# остаток от деления отрицательного даёт «-1.-2», а «останется» бывает и отрицательным.
mb() { _v=${1:-0}; _sg=""; [ "$_v" -lt 0 ] && { _sg="-"; _v=$((0-_v)); }; echo "$_sg$((_v/1048576)).$(( (_v%1048576)*10/1048576 ))"; }

# --- СОСТОЯНИЕ ДЛЯ ПАНЕЛИ ------------------------------------------------------------
# Один срез: диск + все связки. Второй копии «что установлено» в CGI быть не должно —
# ровно так разъезжались прежние curCombo()/cur_alt().
cmd_list_json() {
    printf '{"engine":true,"reserve_b":%s,"free_b":%s,"total_b":%s,"pkgs":[' "$RESERVE_B" "$(disk_free_b)" "$(disk_total_b)"
    _first=1
    for p in $PKGS; do
        _st=$(pkg_state "$p"); _hold=$(pkg_hold "$p"); _warn=$(pkg_warn "$p")
        _ver=$(sh "$GH" bin-ver "$(pkg_own "$p" | cut -d' ' -f1)" 2>/dev/null | tr -d ' \r')
        [ "$_first" = 1 ] || printf ','
        _first=0
        # Вес связки — ДВА числа, ровно как в плане: полный и та его часть, что лежит (ляжет) на
        # /data. Без накопителя они совпадают байт-в-байт. С накопителем разница — единственное,
        # из чего панель может узнать место жительства связки: иначе карточка «Xray» обещала бы
        # освободить 7.9 МБ ФЛЕША, а освободила бы флешку, и полоса не шевельнулась бы.
        printf '{"id":"%s","label":"%s","state":"%s","ver":"%s","add_b":%s,"add_data_b":%s,"del_b":%s,"del_data_b":%s,"hold":"%s","warn":"%s"}' \
            "$p" "$(pkg_label "$p")" "$_st" "$_ver" \
            "$(pkg_add_b "$p")" "$(pkg_add_b "$p" data)" \
            "$(pkg_del_b "$p" "$p")" "$(pkg_del_b "$p" "$p" data)" "$_hold" "$_warn"
    done
    printf ']}\n'
}

# --- ПЛАН ------------------------------------------------------------------------------
# Считает вердикт БЕЗ побочных эффектов: «останется = свободно + Σснимаемое − Σставимое».
# Заполняет P_* для cmd_apply, чтобы арифметика жила в ОДНОМ месте (иначе кнопка и сама
# операция начнут расходиться в оценке — классика «в панели влезало, а на роутере нет»).
plan_calc() {       # $1 = ставим, $2 = снимаем
    P_INS=$(norm_list "$1"); P_DEL=$(norm_list "$2")
    P_ERR=""; P_BLOCK=""; P_NEED=0; P_FREED=0; P_UNK=0; P_NEED_ST=0; P_FREED_ST=0
    for p in $P_INS; do
        pkg_known "$p" || { P_ERR="$P_ERR неизвестный компонент: $p"; continue; }
        in_list "$p" "$P_DEL" && { P_ERR="$P_ERR $p указан и на установку, и на удаление"; continue; }
        # Вес связки делим по месту жительства: в резерв /data идёт только то, что там осядет.
        _a=$(pkg_add_b "$p"); _d=$(pkg_add_b "$p" data)
        P_NEED=$((P_NEED + _d)); P_NEED_ST=$((P_NEED_ST + _a - _d))
        pkg_add_unknown "$p" && P_UNK=1
    done
    # hev — ОДИН файл на всех: снимая в одном плане ДВУХ его потребителей (Xray + ByeDPI),
    # прежний код засчитывал его освобождение КАЖДОМУ (hev_needed_after судит про весь список
    # сразу, а зовётся на каждую связку) — «освободится» завышалось, а у самой границы резерва
    # это переворачивает вердикт «влезет». Считаем его РОВНО ОДИН раз за план.
    _hevdone=0
    for p in $P_DEL; do
        pkg_known "$p" || { P_ERR="$P_ERR неизвестный компонент: $p"; continue; }
        _h=$(pkg_hold "$p")
        [ -n "$_h" ] && { P_BLOCK="$P_BLOCK|$p: $_h"; continue; }
        _a=$(pkg_del_b "$p" "$P_DEL" "" "$_hevdone"); _d=$(pkg_del_b "$p" "$P_DEL" data "$_hevdone")
        P_FREED=$((P_FREED + _d)); P_FREED_ST=$((P_FREED_ST + _a - _d))
        if [ "$_hevdone" = 0 ] && [ -n "$(pkg_shared "$p")" ] && [ -f "$(bin_path hev)" ] \
           && ! hev_needed_after "$P_DEL"; then _hevdone=1; fi
    done
    P_FREE=$(disk_free_b); case "$P_FREE" in ''|*[!0-9]*) P_FREE=0 ;; esac
    P_LEFT=$((P_FREE + P_FREED - P_NEED))
    P_OK=1
    [ -n "$P_ERR" ] && P_OK=0
    [ -n "$P_BLOCK" ] && P_OK=0
    [ "$P_LEFT" -lt "$RESERVE_B" ] && P_OK=0
    # Вторая сторона: место на накопителе. Спрашиваем ТОЛЬКО когда туда что-то поедет — иначе
    # это лишний df на роутере без флешки (а таких большинство).
    P_SFREE=0; P_SLEFT=0
    if [ "$P_NEED_ST" -gt 0 ] || [ "$P_FREED_ST" -gt 0 ]; then
        P_SFREE=$(store_free_b); case "$P_SFREE" in ''|*[!0-9]*) P_SFREE=0 ;; esac
        P_SLEFT=$((P_SFREE + P_FREED_ST - P_NEED_ST))
        if [ "$P_NEED_ST" -gt 0 ] && [ "$P_SLEFT" -lt "$STORE_RESERVE_B" ]; then
            P_ERR="$P_ERR на внешнем накопителе не хватает места"
            P_OK=0
        fi
    fi
}

# Что МОЖНО снять, чтобы освободить место (панель показывает это списком «сними лишнее»).
# Только установленное, без гарда и не участвующее в текущем плане.
# need_b/freed_b/left_b — ПРО /data: панель считает по ним «останется свободно» и рисует полосу
# флеша, поэтому смешивать сюда накопитель нельзя (арифметика перестала бы сходиться). Что
# уедет на флешку, отдаём отдельными полями — они появились вместе с накопителем и на роутере
# без него всегда нули.
cmd_plan() {
    plan_calc "$1" "$2"
    printf '{"ok":%s,"free_b":%s,"need_b":%s,"freed_b":%s,"left_b":%s,"reserve_b":%s,"unknown":%s' \
        "$([ "$P_OK" = 1 ] && echo true || echo false)" "$P_FREE" "$P_NEED" "$P_FREED" "$P_LEFT" "$RESERVE_B" \
        "$([ "$P_UNK" = 1 ] && echo true || echo false)"
    printf ',"store":%s,"need_store_b":%s,"freed_store_b":%s,"store_free_b":%s' \
        "$(store_ready && echo true || echo false)" "$P_NEED_ST" "$P_FREED_ST" "$P_SFREE"
    printf ',"errors":['
    [ -n "$P_ERR" ] && printf '"%s"' "$(printf '%s' "$P_ERR" | sed 's/^ *//')"
    printf '],"blocked":['
    _f=1
    if [ -n "$P_BLOCK" ]; then
        # `printf '%s\n'` ОБЯЗАТЕЛЕН: без завершающего перевода строки `while read` возвращает
        # ненулевой код на последней записи и молча её теряет — а записей тут обычно ровно одна,
        # так что «нельзя снять, потому что…» не печаталось вовсе (ok=false без единой причины).
        printf '%s\n' "$P_BLOCK" | tr '|' '\n' | while IFS= read -r b; do
            [ -n "$b" ] || continue
            [ "$_f" = 1 ] || printf ','
            _f=0
            printf '{"id":"%s","why":"%s"}' "${b%%:*}" "$(printf '%s' "${b#*: }")"
        done
    fi
    printf '],"free_candidates":['
    _f=1
    for p in $PKGS; do
        [ "$(pkg_state "$p")" = absent ] && continue
        [ -n "$(pkg_hold "$p")" ] && continue
        in_list "$p" "$P_DEL" && continue
        in_list "$p" "$P_INS" && continue
        # Кандидат, освобождающий 0 байт (частичная связка, чьи файлы держит кто-то ещё), в списке
        # «сними, чтобы влезло» — обман: человек снимет и не получит ни мегабайта. Считаем строго
        # по /data: список нужен ровно тогда, когда упёрлись в резерв ФЛЕША, и связка, целиком
        # уехавшая на накопитель, там не помогает ничем.
        _d=$(pkg_del_b "$p" "$p" data); [ "$_d" -gt 0 ] || continue
        [ "$_f" = 1 ] || printf ','
        _f=0
        printf '{"id":"%s","label":"%s","del_b":%s}' "$p" "$(pkg_label "$p")" "$_d"
    done
    printf ']}\n'
}

# --- ВЫПОЛНЕНИЕ ------------------------------------------------------------------------
# Пидфайл(ы) демона связки. Нужны, чтобы снятие не оставляло ЖИВОЙ процесс без бинаря:
# гарды выше берегут лишь то, что числится активным (.transport, слоты), а осиротевшийся демон
# (упавший switch, прерванный failover) в них не виден — и продолжает держать общий socks 10808
# или xtun. Ровно за этим `_kill_alt_daemon` стоит в purge-alt установщика; панельный путь
# остался без него, хотя теперь именно он — единственный экран установки.
pkg_pids() { case "$1" in
        xray) echo /tmp/xray.pid ;; hy2) echo /tmp/hysteria.pid ;; byedpi) echo /tmp/byedpi.pid ;;
        doh) echo /tmp/doh.pid ;; tls) echo /tmp/panel-tls.pid ;;
    esac; }
kill_by_pidfile() { [ -f "$1" ] || return 0; start-stop-daemon -K -p "$1" >/dev/null 2>&1; rm -f "$1"; return 0; }

do_remove() {       # $1 = связка, $2 = весь список снимаемых
    log "Снимаю $(pkg_label "$1")…"
    # Zapret снимает СЕБЯ САМ: у него не только бинарь, но и правила NFQUEUE, dnsmasq и флаг
    # десинка — вторая копия этого teardown разъехалась бы с zapret.sh на первой же правке.
    # Гард `-f` + `sh` (класс Б5-9): при `-x` снятый бит выполнения давал ТИХИЙ пропуск teardown
    # и бодрое «Снимаю Zapret…» в логе при живых правилах и живом nfqws.
    if [ "$1" = zapret ]; then
        [ -f "$ENODIA_DIR/zapret.sh" ] && sh "$ENODIA_DIR/zapret.sh" remove >> "$LOG" 2>&1
        return 0
    fi
    for _pf in $(pkg_pids "$1"); do kill_by_pidfile "$_pf"; done
    # Сносим ОБЕ возможные копии — резидентную и на внешнем накопителе. Инвариант store-lib
    # «копия ровно одна» держится именно здесь: оставь мы файл на накопителе, bin_path (он
    # предпочитает накопитель) продолжил бы отдавать снятый бинарь как живой.
    for b in $(pkg_own "$1"); do
        rm -f "$ENODIA_BIN/$b"
        [ "$BIN_DIR" != "$ENODIA_BIN" ] && rm -f "$BIN_DIR/$b"
    done
    if [ -n "$(pkg_shared "$1")" ] && ! hev_needed_after "$2"; then
        log "hev больше никому не нужен — снимаю"
        kill_by_pidfile /tmp/hev.pid
        rm -f "$ENODIA_BIN/hev"
        [ "$BIN_DIR" != "$ENODIA_BIN" ] && rm -f "$BIN_DIR/hev"
    fi
    return 0
}
do_install() {      # $1 = связка
    log "Ставлю $(pkg_label "$1")…"
    if [ "$1" = zapret ]; then
        # У zapret своя установка: бинарь + фейки TLS/QUIC + переигрыш правил, если десинк был включён.
        [ -f "$ENODIA_DIR/zapret.sh" ] || { log "нет zapret.sh — обнови скрипты"; return 1; }
        sh "$ENODIA_DIR/zapret.sh" install >> "$LOG" 2>&1 || { log "zapret не установился"; return 1; }
        return 0
    fi
    for b in $(pkg_files "$1"); do
        have_bin "$b" && continue
        log "Скачиваю $b…"
        # КУДА качать решает bin_dest (store-lib.sh), а не этот цикл: с включённым накопителем
        # тяжёлое едет сразу туда, минуя 20-МБ флеш (иначе «поставить три транспорта» упиралось бы
        # в место ровно так же, как до накопителя). bin_prune следом убирает копию с другой
        # стороны — bin_path предпочитает накопитель, и забытый там старый файл выдавал бы себя
        # за свежескачанный. Порог обрыва и арку выбирает сам gh-update (bin-manifest.txt).
        _dst=$(bin_dest "$b")
        mkdir -p "${_dst%/*}" 2>/dev/null
        sh "$GH" fetch-bin "$b" "$_dst" >> "$LOG" 2>&1 || { log "не скачал $b"; return 1; }
        bin_prune "$b"
        [ "$_dst" = "$ENODIA_BIN/$b" ] || log "  $b лёг на внешний накопитель"
    done
    # «Установлен ≠ активен» — про это надо СКАЗАТЬ, иначе «поставил и ничего не изменилось».
    case "$1" in
        awg|xray|hy2|byedpi) log "$(pkg_label "$1") установлен. Включить — в «Транспорт VPN» (нужен активный конфиг)." ;;
        doh) log "Компоненты шифрованного DNS установлены. Включить — в «Настройках» → DNS." ;;
        tls) log "Компонент HTTPS установлен. Включить — в «Настройках» → «Доступ к панели»." ;;
    esac
    return 0
}

cmd_apply() {
    : > "$LOG"; set_state RUNNING
    plan_calc "$1" "$2"
    log "План: ставим [${P_INS:-—}], снимаем [${P_DEL:-—}]"
    if [ -n "$P_ERR" ]; then set_state FAIL; log "Отказ:$P_ERR"; return 1; fi
    if [ -n "$P_BLOCK" ]; then
        set_state FAIL
        printf '%s\n' "$P_BLOCK" | tr '|' '\n' | while IFS= read -r b; do [ -n "$b" ] && log "Нельзя снять $b"; done
        return 1
    fi
    log "Свободно $(mb "$P_FREE") МБ; освободим $(mb "$P_FREED"), займём $(mb "$P_NEED"), останется $(mb "$P_LEFT") МБ"
    [ "$P_NEED_ST" -gt 0 ] && log "На внешний накопитель уедет $(mb "$P_NEED_ST") МБ (свободно там $(mb "$P_SFREE") МБ) — флеш это не тронет"
    [ "$P_UNK" = 1 ] && log "ВНИМАНИЕ: размеры части файлов неизвестны (нет bin-manifest.txt) — оценка занятого НЕПОЛНАЯ."
    if [ "$P_LEFT" -lt "$RESERVE_B" ]; then
        set_state FAIL
        log "Не хватает места: после операции осталось бы $(mb "$P_LEFT") МБ при неснижаемом резерве $(mb "$RESERVE_B") МБ. Сними что-нибудь ещё."
        return 1
    fi
    # Пре-чек сети ДО удалений: иначе снимем рабочий компонент и не скачаем новый (тот же довод,
    # что в proto-install — там на этом уже обжигались). reachable = проба СЕТИ, не наличия файла.
    # Гард `-f`, а не `-x`: при снятом бите пре-чек молча ПРОПУСКАЛСЯ (условие ложно) — то есть
    # ровно в том случае, когда качать всё равно будем через `sh "$GH"`, мы сперва сносили
    # рабочий компонент и только потом узнавали, что сети нет.
    # ПРИЧИНУ берём у пре-чека, а не выдумываем: «GitHub недоступен» на отказе по частоте (429)
    # отправляло человека чинить интернет, которого не ломали. Пусто = старая копия gh-update,
    # которая причин ещё не печатает ⇒ прежний текст.
    if [ -n "$P_INS" ] && [ -f "$GH" ]; then
        _why=$(sh "$GH" reachable 2>/dev/null)
        if [ "$?" = 0 ]; then
            sh "$GH" bin-manifest refresh >/dev/null 2>&1
        else
            [ -n "$_why" ] || _why="GitHub недоступен — проверь интернет"
            set_state FAIL; log "$_why. НИЧЕГО не тронул."; return 1
        fi
    fi
    for p in $P_DEL; do do_remove "$p" "$P_DEL"; done
    [ -n "$P_DEL" ] && sync 2>/dev/null
    _rc=0
    for p in $P_INS; do do_install "$p" || _rc=1; done
    if [ "$_rc" = 0 ]; then
        set_state OK; log "Готово. Свободно $(mb "$(disk_free_b)") МБ."
    else
        set_state FAIL; log "Часть компонентов не установилась — см. лог выше."
    fi
    return $_rc
}

case "$1" in
    list-json) cmd_list_json ;;
    plan)      cmd_plan "$2" "$3" ;;
    # МАШИННЫЙ вердикт для sh-вызывающих (proto-install.sh, установщик с ПК): код 0 = «влезет,
    # сносить ради места ничего не надо». JSON на busybox не парсят, а вторая копия арифметики
    # ровно там и разъезжается («в панели влезало, а на роутере нет»). Неизвестные размеры =
    # ОТКАЗ: лучше отработать по-старому (снести лишнее), чем соврать «места хватит».
    plan-ok)   plan_calc "$2" "$3"; [ "$P_OK" = 1 ] && [ "$P_UNK" = 0 ] && exit 0; exit 1 ;;
    # Лок — mkdir (атомарно, без TOCTOU): два клика в панели на 20-МБ флеше = «No space».
    # Тот же лок, что у proto-install.sh: смена набора и правка компонентов — одна очередь.
    # ВТОРОЙ лок — switching: между `do_remove` (гасим демоны снимаемой связки) и концом закачек
    # лежат МИНУТЫ, и тик сторожа в это окно волен уводить транспорт/переподнимать несущую поверх
    # идущей установки. proto-install.sh это уже держит (батч 10), а панельный путь — единственный
    # экран установки — ходит СЮДА. Идиома общая: чужой лок не трогаем, свой снимаем trap'ом.
    apply|install|remove)
               if ! mkdir "$LOCK" 2>/dev/null; then echo "уже выполняется"; exit 1; fi
               SWLOCK=/tmp/enodia-switching.lock; SWMINE=0
               [ -e "$SWLOCK" ] || { : > "$SWLOCK" 2>/dev/null && SWMINE=1; }
               trap 'rmdir "$LOCK" 2>/dev/null; [ "$SWMINE" = 1 ] && rm -f "$SWLOCK" 2>/dev/null' EXIT INT TERM HUP PIPE
               case "$1" in
                   apply)   cmd_apply "$2" "$3" ;;
                   install) cmd_apply "$2" "" ;;
                   remove)  cmd_apply "" "$2" ;;
               esac ;;
    state)     cat "$STATE" 2>/dev/null || echo IDLE ;;
    # ТОЧЕЧНЫЙ и ДЕШЁВЫЙ ответ «стоит ли связка» (absent|partial|installed) — для тех, кому нужен
    # один пакет, а не весь срез. `list-json` для этого не годится: он на КАЖДУЮ связку зовёт
    # `gh-update.sh bin-ver`, а тот при пустом кэше уходит качать bin-manifest с GitHub. Здесь —
    # только файловая система. Владелец состояния остаётся один (pkg_state), копий не заводим.
    pkg-state) pkg_known "$2" || { echo "неизвестный компонент: $2" >&2; exit 2; }
               pkg_state "$2" ;;
    *) echo "usage: $0 list-json | plan <ставим> <снимаем> | plan-ok <ставим> <снимаем> | apply <ставим> <снимаем> | install <список> | remove <список> | state | pkg-state <компонент>"; echo "       списки через запятую, «-» = пусто; компоненты: $PKGS"; exit 2 ;;
esac
