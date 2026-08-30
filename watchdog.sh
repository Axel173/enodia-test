#!/bin/sh
# watchdog.sh — сторож VPN-туннеля на Xiaomi BE7000.
#
# Запускается из cron каждые 2 минуты. Следит за живостью awg0 по возрасту
# последнего handshake (при PersistentKeepalive=25 «старше 180 сек» = VPS
# реально не отвечает, без ложных срабатываний) и переключает режимы:
#
#   NORMAL  → FAILOPEN  (VPS умер): зовёт switch-vpn.sh safety-off —
#             снимает fwmark/mangle/MASQUERADE и переводит DNS на публичный,
#             трафик идёт напрямую через провайдера. Интернет НЕ пропадает
#             (в т.ч. DNS-резолвинг, который у нас завязан на туннель —
#             см. историю инцидента). Сайты из списка на это время
#             недоступны. Шлёт письмо через notify.sh.
#
#   FAILOPEN → NORMAL   (VPS ожил): возвращает VPN-роутинг (mark-core + transport-awg)
#             и DNS-upstream обратно в туннель. Шлёт письмо.
#
# АВТО-FAILOVER (июнь 2026). Детекцию падения НЕ меняем (те же HS_DEAD/HS_ALIVE);
# меняется лишь ДЕЙСТВИЕ при смерти VPS — по режиму из $ENODIA_STATE/.failover-mode:
#   off    — как раньше: safety-off + письмо «VPN упал».
#   sticky — (дефолт, нет файла → sticky) зовёт `switch-vpn.sh failover`: перебор
#            configs/*.conf по алфавиту, встаём на первый рабочий и остаёмся.
#   home   — то же, плюс когда «основной» (`.failover-home`) снова доступен —
#            возвращаемся на него (ALIVE-ветка, троттл FAILBACK_INTERVAL).
# Если резервов нет (один конфиг) — любой режим вырождается в классический
# safety-off, поэтому дефолт-ВКЛ безопасен. Перебор в FAILOPEN повторяется не
# чаще fo_retry (БЭКОФФ: 10→20→40→80→120 мин, сброс при возврате здоровья).
# Письма failover-ok/failover-fail шлёт сам switch-vpn; watchdog по коду
# возврата лишь выставляет STATE.
#
# ГЕЙТ «ЕСТЬ ЛИ ИНТЕРНЕТ ВООБЩЕ» (август 2026). Перед КАЖДЫМ перебором сторож
# отличает «лёг VPS» от «лёг провайдер»: линк и дефолт-маршрут при аварии выше
# по сети остаются на месте, поэтому одного wan_up() мало — нужна egress-проба
# ЧЕРЕЗ WAN (inet_reachable). Подтверждённое отсутствие интернета подавляет
# перебор (все серверы физически недостижимы) и даёт СВОЁ событие wan-down,
# а не «VPN упал, резервы недоступны» — VPN там ни при чём.
#
# Почему это решает инцидент «VPS отвалился → на ПК лёг даже рунет»:
#   DNS на роутере один на все сети и форвардится в туннель. Пока туннель
#   мёртв, не резолвится ничего. safety_off временно ставит публичный DNS —
#   рунет и весь остальной трафик продолжают работать.
#
# Состояние — в /tmp/enodia-watchdog.state (NORMAL/FAILOPEN). Письмо уходит
# ТОЛЬКО на смену режима, а не каждый тик. /tmp сбрасывается при ребуте —
# после загрузки считаем NORMAL, и watchdog переоценит ситуацию заново.
# После ребута выжидаем BOOT_GRACE сек (первичный подъём несущей — забота heal.sh,
# а не watchdog), иначе получаем самонаведённый failopen на буте (см. boot-grace ниже).
#
# Уведомления можно выключить, создав файл .notify-off (см. notify()).
# Туннель watchdog НЕ поднимает сам — если awg0 вообще нет, это территория
# heal.sh, мы просто выходим.

ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
STATE=/tmp/enodia-watchdog.state
LOCK=/tmp/enodia-watchdog.lock
SWITCH_LOCK=/tmp/enodia-switching.lock
HEAL_LOCK=/tmp/enodia-heal.lock    # лок heal.sh (1×/boot) — снимаем при мид-дэй смерти awg0, чтобы heal пересоздал
# ПРИЧИНА внепланового прогона heal. Снимая heal-лок, сторож запускает у heal ПОЛНЫЙ бутовый
# сценарий — вместе с письмом «загрузка OK, VPN поднят», которое человек читает как «роутер сам
# перезагрузился» (жалоба 30.07.2026; ровно поэтому `vpn-toggle repair` лок НЕ снимает). Здесь
# снятие ЗАКОННО — awg0 физически исчез, а пересоздавать интерфейс умеет только heal, — но письмо
# про загрузку было бы ложью: сторож уже прислал «awg0 упал» и пришлёт «VPN восстановлен».
# Маркер в /tmp: heal глушит по нему ИМЕННО бутовое письмо, всё остальное делает как всегда.
HEAL_REASON=/tmp/enodia-heal.reason
heal_reason() { echo "$1" > "$HEAL_REASON" 2>/dev/null; }
LOG=/tmp/enodia-watchdog.log
NOTIFY="$ENODIA_DIR/notify.sh"
NOTIFY_OFF="$ENODIA_STATE/.notify-off"

# Общий примитив «внешний IPv4» (ip-lib.sh): IP-литерал-проба, DNS-free — чинит пустой egress на
# ядре 4.4 (hostname api.ipify.org там молча пустел). Шим на случай частичной установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }

# Возраст отметки времени (clock-lib.sh): БЕЗ него весь этот файл судит по `now - ts`, а часы на
# роутере без RTC прыгают вперёд через ~13 мин после загрузки ⇒ живой туннель выглядит мёртвым, а
# все троттлы разом «протухают». Шим повторяет ПРЕЖНЕЕ поведение (частичная установка без lib —
# не хуже, чем было), но полноценная защита живёт в самой lib. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

# Слой шифрованного DNS (doh-lib.sh): keepalive демона https_dns_proxy (ниже, после лока). Шим —
# без lib doh_want=false ⇒ keepalive no-op. [[doh-direct-modes-backlog]]
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_enabled >/dev/null 2>&1 || doh_enabled() { return 1; }
command -v doh_want >/dev/null 2>&1 || doh_want() { return 1; }   # старая lib без авто-режима

# Язык писем и событий сторожа — тот же панельный pref, что у heal/switch-vpn (nf-i18n.sh).
# Сторож был ПОСЛЕДНИМ отправителем, оставшимся только на русском: у человека с англоязычной
# панелью половина «центра уведомлений» приходила на чужом языке — и именно та половина, где
# написано, почему пропал VPN. Шим = ru, то есть прежнее поведение байт-в-байт.
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
NF_LANG=$(nf_lang)

# Пороги можно переопределить через окружение (для тюнинга и тестов):
#   HS_DEAD=10 sh watchdog.sh   — заставит счесть VPS мёртвым
HS_DEAD=${HS_DEAD:-180}     # handshake старше этого (сек) => VPS не отвечает
HS_ALIVE=${HS_ALIVE:-120}   # handshake свежее этого (сек) => VPS жив (возврат)
                            # зазор 120..180 — гистерезис против «дребезга»

# Грейс после подъёма несущей: столько секунд НЕ судим tunnel-транспорт по egress-пробе.
# ЗАЧЕМ (железо 14.08.2026): enodia-switching.lock отпускается, когда стартовали ДЕМОНЫ, а не когда
# заработал выход, и тик в этом зазоре пишет SUSPECT живому каналу (панель — «проверяю…»), а
# ВТОРАЯ такая осечка уходит в лестницу failover, отменяя ручной выбор сервера. Отметку кладёт
# каждый плагин в своём up (carrier_up_mark, clock-lib.sh). Цена грейса — максимум один
# пропущенный тик: реальная авария подтвердится на следующем, через 2 минуты.
# ЗАМЕР (BE7000, 14.08.2026, xray по имени на здоровой сети): полный подъём несущей до
# проходящего health — 7 с (6 с сам подъём + проба сразу). Наблюдённая осечка была на 19-й
# секунде после старта демона. 60 — это запас к замеру, а не круглое число с потолка: восьмикратно
# перекрывает норму и вдвое — худший наблюдённый случай, оставаясь много меньше тика (120 с).
CARRIER_GRACE=${CARRIER_GRACE:-60}
CARRIER_UP_STAMP="${CARRIER_UP_STAMP:-/tmp/.carrier-up.stamp}"   # нет свежей clock-lib → stamp_age даст 999999 ⇒ грейса нет, прежнее поведение

# Boot-grace: первые N сек после загрузки несущую поднимает heal.sh (cron */1), а НЕ
# watchdog. Пока идёт первичный подъём, health транспорта закономерно ещё не проходит —
# не даём watchdog'у объявить его мёртвым и свалиться в failover/safety_off (self-inflicted
# failopen на буте, пойман на железе 07.07.2026: xray health «сбой» в 21:13-21:14 ещё до
# того, как heal поднял xray в 21:14:21). Тюнится через окружение (тест/медленный бут).
BOOT_GRACE=${BOOT_GRACE:-180}

# --- Авто-failover на резервный конфиг (см. switch-vpn.sh failover) ---
ACTIVE_NAME="$ENODIA_STATE/.active"
CONFIGS_DIR="$ENODIA_STATE/configs"
SWITCH_VPN="$ENODIA_DIR/switch-vpn.sh"
VPN_TOGGLE="$ENODIA_DIR/vpn-toggle.sh"            # repair: полный переигрыш правил сплита (mark-core + несущая + FORWARD/MASQUERADE + DNS)
FAILOVER_MODE_FILE="$ENODIA_STATE/.failover-mode"   # off|sticky|home; нет файла → sticky
FAILOVER_HOME_FILE="$ENODIA_STATE/.failover-home"   # имя «основного» конфига для home
FAILOVER_ESCALATE_FILE="$ENODIA_STATE/.failover-escalate"  # cross|direct; нет файла → cross
FAILOVER_STAMP=/tmp/enodia-failover.stamp         # троттл повторного перебора в FAILOPEN
FAILBACK_STAMP=/tmp/enodia-failback.stamp         # троттл попыток возврата на home
FAILOVER_RETRY=${FAILOVER_RETRY:-600}          # БАЗОВАЯ пауза (сек) между переборами в FAILOPEN; дальше — бэкофф (fo_retry)
FAILOVER_BACKOFF=/tmp/enodia-failover.backoff     # текущая пауза бэкоффа (удваивается на каждом безуспешном свипе пула)
FAILOVER_MAX=${FAILOVER_MAX:-7200}             # кап бэкоффа (сек): 10→20→40→80→120 мин
# Кап бэкоффа для TUNNEL-транспортов — НИЖЕ awg-шного, и вот почему. В fail-open несущая awg
# СОЗНАТЕЛЬНО остаётся поднятой (safety_off снимает лишь маршрут), поэтому оживление VPS видно
# по свежему handshake на КАЖДОМ тике, а длинная пауза стоит дёшево. У xray/hy2/byedpi несущая
# в прямом режиме СНЯТА (иначе её default в table 1000 = блэкхол, см. ensure_direct_mode) ⇒
# единственный детектор оживления — сама повторная попытка, и 120 мин означали бы «VPS вернулся,
# а VPN два часа не возвращается». Свип тут дешевле awg-шного (старт двух демонов + одна
# egress-проба, без wait_for_handshake по каждому конфигу), так что лестница 10→20→30 мин честнее.
TUNNEL_RETRY_MAX=${TUNNEL_RETRY_MAX:-1800}
FAILBACK_INTERVAL=${FAILBACK_INTERVAL:-900}    # как часто (сек) пробовать возврат на home
WANOUT_COUNT=/tmp/enodia-wanout.count             # подряд провалов egress-пробы через WAN (гистерезис)
WANOUT_EVENT=/tmp/enodia-wanout.event             # эпизод «интернета нет вообще» уже объявлен (гейт события/письма)
WANOUT_SWEEP=/tmp/enodia-wanout.sweep             # когда в последний раз пускали КОНТРОЛЬНЫЙ свип вопреки пробе
WAN_PROBE_FAILS=${WAN_PROBE_FAILS:-2}          # со скольких подряд провалов пробы считаем «интернета нет вообще»
WANOUT_MAX=${WANOUT_MAX:-3600}                 # не реже раза в N сек всё же пробуем перебор вслепую (предохранитель)
REUP_STAMP=/tmp/enodia-reup.stamp                 # троттл переподъёма awg-несущей ПЕРЕД перебором резервов (см. ниже)
REUP_RETRY=${REUP_RETRY:-1800}                 # не чаще раза в N сек: reup рвёт awg0, крутить его каждый тик нельзя
RULEHEAL_STAMP=/tmp/enodia-ruleheal.stamp         # троттл письма о rule-heal (fw3-reload снёс правила сплита)
RULEHEAL_NOTIFY=${RULEHEAL_NOTIFY:-1800}       # не чаще раза в N сек слать письмо о восстановлении правил (анти-спам, если repair не помог)
WIPE_SEEN=/tmp/enodia-splitwipe.seen              # первый (ещё не подтверждённый) детект «правила сплита снесены»
ROUTELOST_SEEN=/tmp/enodia-routelost.seen         # то же для «пропал default несущей из table 1000» — счёт СВОЙ: болезни разные, путать их подтверждения нельзя
AWG0_SEEN=/tmp/awg0.seen                       # «в ЭТУ загрузку awg0 хоть раз был живым» — отличает ПАДЕНИЕ несущей от «её ещё не поднимали» (см. ветку «awg0 ИСЧЕЗ»); в /tmp ⇒ умирает вместе с загрузкой, как и положено вопросу «в эту загрузку»
WIPE_CONFIRM=${WIPE_CONFIRM:-420}              # окно (сек) подтверждения вторым тиком; больше периода cron (120) с запасом
DOMWARM_STAMP=/tmp/enodia-domwarm.stamp           # троттл периодического прогрева доменных правил
DOMWARM_INTERVAL=${DOMWARM_INTERVAL:-3600}     # не чаще раза в N сек: прогрев форкает nslookup на каждый домен
# Защита от «хождения по кругу» awg<->xray: какие протоколы уже перебраны в ТЕКУЩЕМ
# эпизоде аварии. cross-эскалация не прыгает в протокол, который уже пробовали →
# терминал всегда safety_off, без флаппинга. Чистится, когда транспорт снова здоров.
FAILOVER_EPISODE=/tmp/enodia-failover-episode
TRANSPORT_HOME_FILE="$ENODIA_STATE/.transport-home"  # awg|xray|hy2 — предпочитаемый транспорт (ручной выбор в меню); пусто → авто-возврат транспорта выключен
XT_AWG="$ENODIA_DIR/transport-awg.sh"              # плагин awg-несущей (возврат awg-роутинга вместо split-route)
MARK_CORE="$ENODIA_DIR/mark-core.sh"               # ядро маркировки (транспорт-агностично; было в split-route)
TRANSPORT_SH="$ENODIA_DIR/transport.sh"            # ОРКЕСТРАТОР: switch/up/down/health/failover/next — ВСЯ работа с tunnel-транспортами идёт через него (имя файла плагина знает только он)
XSTATE=/tmp/enodia-watchdog.xstate                 # состояние мониторинга tunnel-транспорта (xray/hy2/…): HEALTHY/SUSPECT/FAILED
SUPPORT_SH="$ENODIA_DIR/support.sh"                 # «режим поддержки»: reap гасит истёкший туннель (DRY — не плодим отдельный cron-демон)
SLOTS_SH="$ENODIA_DIR/slots.sh"                      # реестр доп-выходов (мульти-транспорт Ф2): health слотов ниже
VPNSRV_SH="$ENODIA_DIR/vpn-server.sh"                # «доступ домой» (роутер как VPN-сервер): keepalive несущей awgs0 ниже
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"           # событийные письма (throttle по ключу) — для отказа доп-выхода
TAB=$(printf '\t')

# Вернуть ТОЛЬКО маркировку (mark-core), без несущей. Используется restore_awg_carrier
# (возврат awg при оживании VPS). Cross/home-переключения транспортов идут через
# transport.sh switch (тот сам кладёт mark-core). Зеркало бывшего split-route.sh, очищенного
# от awg0-несущей. Фолбэк на split-route — для старых роутеров без mark-core.
restore_marking() {
    if [ -f "$MARK_CORE" ]; then sh "$MARK_CORE" >>"$LOG" 2>&1
    elif [ -f "$ENODIA_DIR/split-route.sh" ]; then sh "$ENODIA_DIR/split-route.sh" >>"$LOG" 2>&1; fi
}
# Вернуть awg-несущую целиком (mark-core + transport-awg.sh up): default dev awg0 + FORWARD +
# MASQUERADE + туннельный DNS + .transport=awg. Замена split-route.sh для «awg снова активен».
restore_awg_carrier() {
    restore_marking
    if [ -f "$XT_AWG" ]; then sh "$XT_AWG" up >>"$LOG" 2>&1; fi
}

# --- Rule-heal: несущая жива, но правила сплита снесены (fw3/firewall reload) ---
# ГРАБЛЯ [[boot-race-fw3-reload-wipes-rules]]: fw3 reload (изменение в веб-морде Xiaomi,
# /etc/init.d/firewall restart, пересборка на буте ПОСЛЕ heal.sh) флашит ВСЕ iptables. Туннель
# router→VPS цел (handshake/health «ок»), но mangle-MARK + FORWARD ACCEPT + MASQUERADE снесены →
# форвард клиента дропается (fw3 policy FORWARD=DROP) → сплит молча мёртв. Watchdog проверял
# ТОЛЬКО живость несущей, оттого был слеп к этому (heal.sh тоже не спасал — лок 1×/boot).
# Отпечаток (проверен на железе): fw3-reload флашит iptables, но `ip rule`/`ip route table 1000`
# ПЕРЕЖИВАЮТ → default table 1000 всё ещё указывает на несущую (awg0/xtun), а FORWARD ACCEPT для
# неё исчез. Сигнал = FORWARD -o <несущая> ACCEPT отсутствует. mipctld-guard (restore_marking) его
# НЕ маскирует — тот ставит лишь маркировку, FORWARD/MASQUERADE — забота несущей.
# ВЛАДЕЛЕЦ СПИСКА — ОРКЕСТРАТОР (`transport.sh marking`): «везёт ли по марке» спрашивает не
# только сторож, но и тумблер панели, а два списка в двух файлах разъедутся на шестом
# транспорте. Код 2 (старая копия без верба) или нет файла ⇒ прежний вшитый ответ, байт-в-байт.
# zapret — прямой DPI без маркировки, его rule-heal сторожит ОТДЕЛЬНОЙ веткой (jump ENODIA_ZAPRET).
uses_marking() {
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" marking "$1" >/dev/null 2>&1
        case "$?" in 0) return 0 ;; 1) return 1 ;; esac
    fi
    case "$1" in awg|xray|hy2|byedpi) return 0 ;; *) return 1 ;; esac
}
# Устройство несущей = dev у `default` в боевой table 1000. Ставит его ТОЛЬКО плагин несущей,
# поэтому это единственный честный признак «несущая держит маршрут»: пусто = lookup проваливается
# в main = трафик идёт ПРЯМО (ровно это и обещает fail-open, см. switch-vpn.sh safety_off).
# Доп-выходы живут в СВОИХ table 100N и сюда не попадают.
carrier_route_dev() {
    ip route show table 1000 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
# `iptables -C`. ГРАБЛЯ (июль 2026): на стоке iptables 1.6.2 берёт /run/xtables.lock, а стоковые
# демоны Xiaomi (sp_check.sh */5, mobile_accel.sh */3, startscene_crontab.lua ежеминутно, mipctld,
# upnp) дёргают iptables постоянно. Без ожидания вызов при занятом локе не ждёт, а СРАЗУ падает
# кодом 4 — и прежний код («любой ненулевой = правила снесены») по этому коллизионному коду
# запускал полный repair. Само ожидание (`-w 5` там, где сборка его умеет) и ретрай на код 2
# теперь ставит ipt-lib.sh — ЕДИНСТВЕННЫЙ владелец на все 255 мест проекта, эта функция стала его
# частным случаем. Здесь остаётся ровно то, ради чего она заводилась: возвращаем код КАК ЕСТЬ,
# чтобы вызывающий отличил «правила нет» (1) от «проверить не смог» (4/2/…).
ipt_check_t() {   # $1 = таблица, дальше — правило. `-t` ОБЯЗАН стоять ДО `-C`: у `-C` чейн идёт
                  # аргументом опции, и форма `-C -t mangle PREROUTING` разобралась бы как чейн «-t».
    _ipt="$1"; shift
    iptables -t "$_ipt" -C "$@" 2>/dev/null; _iprc=$?
    return "$_iprc"
}
ipt_check() { ipt_check_t filter "$@"; }
split_rules_wiped() {
    # $1 — активный транспорт. true(0) ⇔ ожидаемое правило транспорта пропало И это подтвердил
    # ВТОРОЙ тик подряд. «Не смог проверить»/«нечего проверять» → 1 (иначе ложный repair =
    # conntrack -F каждый тик = дребезг связи). Точность важнее полноты.
    _cif=""
    case "$1" in
        zapret)
            # У zapret НЕТ несущей (десинк идёт прямым путём) ⇒ признака «FORWARD -o dev» не
            # существует, и до 08.2026 этот транспорт был для rule-heal НЕВИДИМ: fw3-reload сносит
            # всю проводку десинка (jump ENODIA_ZAPRET, NFQUEUE в POSTROUTING, анти-петлю), а nfqws
            # остаётся жив ⇒ health «ок», панель показывает «Zapret активен», десинка нет до
            # ребута. Признак: jump на ENODIA_ZAPRET — `rules_add` ставит его БЕЗУСЛОВНО, пока
            # есть .zapret-on (гейт ниже отсекает «zapret ещё/уже не несёт»).
            [ -f "$ENODIA_STATE/.zapret-on" ] || return 1
            _what="mangle PREROUTING -j ENODIA_ZAPRET"
            ipt_check_t mangle PREROUTING -j ENODIA_ZAPRET; _rc=$?
            ;;
        *)
            # Маркирующий транспорт: несущая есть в table 1000, но FORWARD ACCEPT для неё снесён.
            # Пусто/нет default table 1000 → НЕ оцениваем.
            uses_marking "$1" || return 1
            _cif=$(carrier_route_dev)
            [ -n "$_cif" ] || return 1
            _what="FORWARD -o $_cif -j ACCEPT"
            ipt_check FORWARD -o "$_cif" -j ACCEPT; _rc=$?
            ;;
    esac
    if [ "$_rc" = 0 ]; then rm -f "$WIPE_SEEN" 2>/dev/null; return 1; fi          # правило есть → всё цело
    if [ "$_rc" != 1 ]; then                                                      # 4=лок занят, прочее=сбой вызова
        log "split-check: iptables -C дал код $_rc (лок занят/сбой) — НЕ сужу, жду следующего тика"
        return 1
    fi
    # ВТОРОЙ ТИК ПОДРЯД. Полный repair теперь стоит дорого (conntrack -F = дребезг связи), а
    # одиночный «нет правила» бывает и не от fw3-reload. Первый детект только запоминаем;
    # чиним, если через ~2 мин (WIPE_CONFIRM) правила всё ещё нет. Штамп протух → счёт заново.
    if [ "$(stamp_age "$WIPE_SEEN")" -le "$WIPE_CONFIRM" ]; then
        return 0                                                                  # подтверждено двумя тиками → wiped
    fi
    date +%s > "$WIPE_SEEN"
    # Отпечаток для разбора постфактум: реальный fw3-reload сносит ВСЁ (FORWARD схлопывается до
    # пары строк, MASQUERADE несущей тоже нет), а «пропало одно правило» — совсем другая болезнь.
    if [ -n "$_cif" ]; then
        log "split-check: $_what не найден (строк в FORWARD: $(iptables -S FORWARD 2>/dev/null | wc -l), MASQ несущей: $(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-o $_cif -j MASQUERADE")) — жду подтверждения на следующем тике"
    else
        log "split-check: $_what не найден (правил в mangle PREROUTING: $(iptables -t mangle -S PREROUTING 2>/dev/null | wc -l), NFQUEUE в POSTROUTING: $(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c -- '--queue-num')) — жду подтверждения на следующем тике"
    fi
    return 1
}
# --- Пропал САМ МАРШРУТ несущей: table 1000 пуста при живой несущей -------------------
# ГРАБЛЯ (замерено на AX3600 14.08.2026): ядро сносит `default dev awg0` ВМЕСТЕ с интерфейсом
# (`ip link set awg0 down` — так делает любой сбой/пересоздание несущей), а `up` маршрут НЕ
# возвращает. Итог: демон жив, handshake свежий, FORWARD -o awg0 ACCEPT на месте — и ВЕСЬ
# маркированный трафик уходит НАПРЯМУЮ (lookup 1000 проваливается в main), а следом умирает DNS
# роутера (upstream доступен только через туннель) ⇒ панель зелёная, «VPN включён», имена не
# резолвятся. split_rules_wiped этот случай не ловит СТРУКТУРНО: устройство несущей он берёт ИЗ
# table 1000 и на пустой таблице честно отвечает «не оцениваю» — там пустота означает намеренный
# fail-open. То есть в NORMAL никто не проверял, что несущая ДЕРЖИТ маршрут.
# ЧЕМ ОТЛИЧАЕМ ДЕФЕКТ ОТ НАМЕРЕННОГО ПРЯМОГО РЕЖИМА — ПО СЕТИ, а не по строке в файле (тот же
# принцип, что у ensure_direct_mode): и глобальное выключение (vpn-toggle off), и safety_off
# снимают САМО правило `ip rule fwmark 0x1 table 1000` — маркированному трафику некуда
# проваливаться, блэкхола нет, судить не о чем. Правило на месте + таблица пуста = дефект.
carrier_rule_present() {
    ip rule show 2>/dev/null | grep -qE 'fwmark 0x1(/\S+)? lookup 1000'
}
carrier_route_lost() {
    uses_marking "$1" || return 1                  # zapret несущей не держит — сторожить нечего
    # ПОВОД ИСЧЕЗ — СЧЁТ ПОДТВЕРЖДЕНИЙ СБРАСЫВАЕМ (симметрично split_rules_wiped, где это делает
    # ветка «правило есть»). Иначе отметка живёт WIPE_CONFIRM секунд после САМОСТОЯТЕЛЬНОГО
    # выздоровления (маршрут вернул heal/плагин/ручной repair), и СЛЕДУЮЩИЙ штатный однотиковый
    # провал — то самое окно «ip rule уже есть, маршрут ещё нет» — сработает СРАЗУ, без второго
    # тика: глобальный `conntrack -F` всему дому ровно там, где подтверждение и заводилось.
    if [ -n "$(carrier_route_dev)" ]; then rm -f "$ROUTELOST_SEEN" 2>/dev/null; return 1; fi
    carrier_rule_present || { rm -f "$ROUTELOST_SEEN" 2>/dev/null; return 1; }   # VPN выключен/safety_off — прямой режим НАСТОЯЩИЙ
    # ВТОРОЙ ТИК ПОДРЯД — как у split_rules_wiped: repair стоит conntrack -F (дребезг связи), а
    # окно «правило уже есть, маршрут ещё нет» бывает штатно (mark-core кладёт ip rule ДО того,
    # как плагин поставит default). Смену транспорта тик и так пропускает по SWITCH_LOCK.
    if [ "$(stamp_age "$ROUTELOST_SEEN")" -le "$WIPE_CONFIRM" ]; then return 0; fi
    date +%s > "$ROUTELOST_SEEN"
    log "route-check: table 1000 ПУСТА при живой несущей ($1) и целом ip rule — жду подтверждения на следующем тике"
    return 1
}
# Полный repair (vpn-toggle): mark-core + несущая + FORWARD/MASQUERADE + DNS + apply-bypass +
# conntrack -F. Идемпотентен и транспорт-aware (vpn-toggle сам читает .transport). Письмо —
# throttl'ом (RULEHEAL_NOTIFY сек), чтобы патологический цикл «repair не помог» не спамил.
# Поводов ДВА (снесены правила / пропал маршрут несущей), действие и троттл — ОДНИ: второй
# копии `repair` + письма не заводим, иначе они разъедутся по условиям отправки.
do_rule_repair() {   # $1=строка в лог  $2=тема письма  $3=тело письма
    log "$1"
    rm -f "$WIPE_SEEN" "$ROUTELOST_SEEN" 2>/dev/null   # счёт подтверждений — заново: следующий детект снова начнётся с первого тика
    [ -f "$VPN_TOGGLE" ] && sh "$VPN_TOGGLE" repair >>"$LOG" 2>&1
    if [ "$(stamp_age "$RULEHEAL_STAMP")" -ge "$RULEHEAL_NOTIFY" ]; then
        date +%s > "$RULEHEAL_STAMP"
        # Троттл тут СВОЙ (RULEHEAL_STAMP выше), поэтому окно обёртки 0: второго троттла не надо,
        # а журнал панели нужен — «роутер сам восстановил правила» человек должен увидеть в истории.
        notify_ev "rule-heal" 0 "$2" "$3"
    fi
}
heal_split_rules() {
    if [ "$NF_LANG" = en ]; then
        do_rule_repair "rule-heal: несущая ($1) жива, но FORWARD/сплит снесён (fw3-reload?) → vpn-toggle.sh repair" \
            "BE7000: VPN rules restored (firewall reset)" \
"Looks like the router firewall reloaded (a change in the Xiaomi web UI or a firewall
restart) and wiped the VPN routing rules, while the tunnel itself stayed up.
The watchdog noticed the carrier FORWARD rule was gone and replayed the rules (vpn-toggle repair):
marking, FORWARD/MASQUERADE and DNS-through-tunnel are back — split tunneling works again."
        return
    fi
    do_rule_repair "rule-heal: несущая ($1) жива, но FORWARD/сплит снесён (fw3-reload?) → vpn-toggle.sh repair" \
        "BE7000: восстановил правила VPN (сброс firewall)" \
"Похоже, firewall роутера перезагрузился (изменение в веб-панели Xiaomi или перезапуск
фаервола) и снёс правила маршрутизации VPN, хотя сам туннель остался жив.
Watchdog заметил пропажу FORWARD-правила несущей и переиграл правила (vpn-toggle repair):
маркировка, FORWARD/MASQUERADE и DNS-через-туннель восстановлены — сплит-туннель снова работает."
}
heal_carrier_route() {
    if [ "$NF_LANG" = en ]; then
        do_rule_repair "route-heal: несущая ($1) жива, но default из table 1000 пропал → vpn-toggle.sh repair" \
            "BE7000: VPN route restored" \
"The tunnel stayed up (the server answers), but the route into it disappeared from the VPN
routing table — all traffic that should go through the VPN went direct, and site names stopped
resolving. The watchdog noticed and replayed the rules (vpn-toggle repair): the route through the
tunnel and DNS are restored."
        return
    fi
    do_rule_repair "route-heal: несущая ($1) жива, но default из table 1000 пропал → vpn-toggle.sh repair" \
        "BE7000: восстановил маршрут VPN" \
"Туннель остался жив (сервер отвечает), но из таблицы маршрутизации VPN пропал сам маршрут в
него — весь трафик, который должен идти через VPN, уходил напрямую, а имена сайтов переставали
резолвиться. Watchdog заметил это и переиграл правила (vpn-toggle repair): маршрут через туннель
и DNS восстановлены."
}

# --- health ДОП-ВЫХОДОВ (слотов мульти-транспорта, Ф2) --------------------------------
# Основной транспорт сторожит весь цикл ниже (failover-лестница). Доп-выходы (slots.sh) — своя
# ЛЁГКАЯ проба БЕЗ авто-перебора серверов слота (v1, дизайн §«Отказ слота»): дохлую несущую слота
# гасим → table 100N пустеет → mark-core уводит трафик слота по его fallback-политике (main|direct),
# а не блэкхолит в мёртвый туннель. Сторожим awg-слоты (дохлую несущую гасим → fallback) и
# byedpi-слоты (Ф1c: ciadpi/hev самовыключаются → ПЕРЕПОДНИМАЕМ на месте idem-slot-up, иначе гасим)
# и xray/hy2-слоты (Ф3: здоровье спрашиваем у плагина вербом slot-health — там egress-проба).
# zapret-слоту сторож не нужен (несущей нет, десинк на прямом пути).
# Событие на слот — throttl'ом (не спамим).
slot_hs_age() {   # $1 = iface (awgN) -> возраст handshake в сек (999999 = нет)
    [ -n "$WG" ] || { echo 999999; return; }
    _hs=$($WG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    age_since "$_hs"          # не «now - hs»: скачок часов иначе хоронит живой выход (clock-lib.sh)
}
slot_fail_event() {   # $1=id $2=cfg $3=fallback $4=причина
    [ -f "$NOTIFY_EVENT" ] || return 0
    _fbl=$([ "$3" = direct ] && echo "напрямую" || echo "через основной туннель")
    sh "$NOTIFY_EVENT" "slot-fail-$1" 3600 \
        "BE7000: доп-выход №$1 недоступен" \
"Дополнительный выход №$1 (сервер $2) не отвечает ($4).
Его трафик переключён на запасной путь: $_fbl.
Выход вернётся автоматически после перезагрузки роутера или при включении вручную в панели." >/dev/null 2>&1
}
# Свежий лок браузер-свипа byedpi = панель СЕЙЧАС применяет стратегии вживую (ciadpi перезапускается
# на каждой). Сторож обязан молчать: иначе принял бы штатный рестарт за падение и «переподнял» выход
# посреди пробы, испортив замер. Лок общий на основную несущую и выходы (см. transport-byedpi.sh).
bp_sweep_fresh() {
    [ -f /tmp/byedpi-sweep.lock ] || return 1
    _bts=$(cat /tmp/byedpi-sweep.lock 2>/dev/null | tr -d ' \r\n')
    case "$_bts" in ''|*[!0-9]*) return 1 ;; esac
    # Через age_since: голая разность после скачка часов делает СВЕЖИЙ лок «старым», сторож
    # перестаёт молчать и переподнимает выход посреди пробы — ровно то, от чего лок и заведён.
    [ "$(age_since "$_bts")" -lt 180 ]
}
slot_health_sweep() {
    # `-f`, а НЕ `-x`: зовём через `sh`, и снятый бит выполнения (дрейф деплоя) тихо выключал бы
    # сторож доп-выходов ЦЕЛИКОМ — ровно грабля Б5-9 (`bd_any_byedpi_slot`).
    [ -f "$SLOTS_SH" ] || return 0
    # Идёт смена транспорта (панель/CLI/cross сторожа держат enodia-switching.lock): несущие сейчас
    # снимаются и поднимаются штатно, и любая проба здоровья слота в этом окне читается как отказ.
    # Тот же гард стоит в health/failover byedpi (батч 5).
    [ -e "$SWITCH_LOCK" ] && return 0
    sh "$SLOTS_SH" list-enabled 2>/dev/null | while IFS="$TAB" read -r sid st scfg sfb; do
        if [ "$st" = byedpi ]; then
            bp_sweep_fresh && continue          # идёт браузер-свип — рестарты ciadpi штатны
            # Лок протух, а бэкап выхода остался = браузер закрыли, не завершив свип: на выходе
            # висит СЛУЧАЙНАЯ стратегия последнего раунда. Возвращаем исходную (у основной несущей
            # то же делает transport-byedpi.sh cmd_health, но он бежит, лишь когда byedpi — активный
            # транспорт, а выход живёт и при awg).
            if [ -f "$ENODIA_STATE/.byedpi-args-s$sid.sweepbak" ]; then
                log "slot-health: браузер-свип выхода №$sid брошен — восстанавливаю исходную стратегию"
                sh "$ENODIA_DIR/transport-byedpi.sh" sweep-end "$sid" >>"$LOG" 2>&1
            fi
            # byedpi-выход (Ф1c): несущая = ciadpi(pid)+hev+xtunN. Здоровье спрашиваем у ПЛАГИНА
            # (verb slot-health): он делает egress-пробу через socks выхода, а не только смотрит
            # pid+tun. Разница существенна: ciadpi умеет БЫТЬ ЖИВЫМ процессом и не форвардить
            # (accept-EINVAL рубит приём соединений, процесс и xtunN остаются) — по pid+tun выход
            # выглядел здоровым, а трафик группы уходил в никуда. rc=2 = плагин старой версии
            # (дрейф деплоя) -> судим по прежним лёгким признакам, чтобы не гасить выход вслепую.
            # Просел -> ПЕРЕПОДНИМАЮ на месте идемпотентным slot-up (он же переиграет mark-core).
            # Не вышло -> гашу -> fallback. Переподнять, а не бросить выход — как reup_carrier у
            # основного byedpi (ciadpi известно самовыключается).
            _rc=2
            [ -f "$TRANSPORT_SH" ] && { sh "$TRANSPORT_SH" slot-health "$sid" >/dev/null 2>&1; _rc=$?; }
            if [ "$_rc" = 0 ]; then
                continue                             # плагин: выход жив (демоны + egress) -> не трогаем
            elif [ "$_rc" = 2 ]; then
                _bp=$(cat "/tmp/byedpi-s$sid.pid" 2>/dev/null | tr -d ' \r\n')
                if [ -n "$_bp" ] && kill -0 "$_bp" 2>/dev/null && ip link show "xtun$sid" >/dev/null 2>&1; then
                    continue                         # старый плагин: ciadpi жив + tun есть -> считаем живым
                fi
            fi
            log "slot-health: byedpi-выход №$sid просел (ciadpi/tun/egress) -> переподнимаю на месте"
            if [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-up "$sid" >>"$LOG" 2>&1; then
                log "slot-health: byedpi-выход №$sid переподнят"
            else
                [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
                slot_fail_event "$sid" "$scfg" "$sfb" "десинк не поднялся"
            fi
            continue
        fi
        if [ "$st" = xray ] || [ "$st" = hy2 ]; then
            # xray/hy2-выход (Ф3): несущая = демон+hev+xtunN, но смерть VPS видна ТОЛЬКО
            # egress-пробой (процесс и tun при мёртвом сервере живы) ⇒ здоровье спрашиваем у
            # САМОГО плагина вербом slot-health (он знает свои pid/порт) — в отличие от
            # awg/byedpi-веток, где сторож смотрит признаки сам. Живой -> не трогаем.
            # Просел -> ОДНА попытка переподнять на месте идемпотентным slot-up (типовой
            # случай: демон упал/socks умолк), не вышло -> гасим -> fallback-политика.
            # Перебора РЕЗЕРВОВ у слота нет by design (v1, дизайн §«Отказ слота»).
            [ -f "$TRANSPORT_SH" ] || continue
            sh "$TRANSPORT_SH" slot-health "$sid" >/dev/null 2>&1; _rc=$?
            [ "$_rc" = 0 ] && continue                  # выход жив
            [ "$_rc" = 2 ] && continue                  # плагин старой версии (дрейф деплоя) — судить не по чем, не трогаем
            log "slot-health: $st-выход №$sid ($scfg) не отвечает -> переподнимаю на месте"
            if sh "$TRANSPORT_SH" slot-up "$sid" >>"$LOG" 2>&1 && sh "$TRANSPORT_SH" slot-health "$sid" >/dev/null 2>&1; then
                log "slot-health: $st-выход №$sid переподнят"
            else
                sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
                slot_fail_event "$sid" "$scfg" "$sfb" "сервер выхода не отвечает"
            fi
            continue
        fi
        [ "$st" = awg ] || continue                 # у zapret-слота несущей нет — сторожить нечего
        # Без бинаря awg возраст handshake не прочитать: slot_hs_age отдаёт 999999, и выход был бы
        # ПОГАШЕН по ложному «мёртв». Нечем судить — не трогаем (как rc=2 у плагинов выше).
        [ -n "$WG" ] || continue
        sif="awg$sid"
        if ! ip link show "$sif" >/dev/null 2>&1; then
            # несущая исчезла (демон упал). fallback=main требует ip rule -> table 1000, но mark-core
            # ставил её на 100N при живой несущей; пустая 100N проваливает трафик в main=НАПРЯМУЮ,
            # игнорируя main-политику. Переигрываем — ТОЛЬКО когда правило реально устарело (0xN->100N),
            # иначе churn каждый тик. fallback=direct пустую 100N уже трактует как «напрямую» — цель.
            if [ "$sfb" = main ] && ip rule show 2>/dev/null | grep -qE "fwmark 0x$sid(/\S+)? lookup 100$sid"; then
                log "slot-health: awg-выход №$sid — несущая исчезла, fallback=main → переигрываю (table 1000)"
                restore_marking
                slot_fail_event "$sid" "$scfg" "$sfb" "несущая исчезла"
            fi
            continue
        fi
        _age=$(slot_hs_age "$sif")
        [ "$_age" -lt "$HS_DEAD" ] && continue       # выход жив — не трогаем
        # несущая поднята, но handshake мёртв (сервер слота лёг) → трафик группы блэкхолит в дохлый
        # туннель. Гасим несущую (transport.sh slot-down: down awgN + mark-core -> fallback).
        log "slot-health: awg-выход №$sid ($scfg) мёртв (handshake ${_age}с) → гашу несущую → fallback=$sfb"
        [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
        slot_fail_event "$sid" "$scfg" "$sfb" "handshake ${_age}с"
    done
}

# ВЫХОД ИЗ ТИКА, который НЕ теряет свип доп-выходов. ГРАБЛЯ (ревью 04.08.2026): сам свип стоял
# ОДИН РАЗ в самом низу файла, а ветка tunnel-транспорта (.transport != awg — то есть ВСЕ альты,
# ради которых выходы и заводят) кончается `exit 0` в КАЖДОМ из семи путей ⇒ при активном
# xray/hy2/byedpi/zapret доп-выходы не сторожились ВООБЩЕ: дохлая несущая слота держала трафик
# группы/устройства в блэкхоле до ребута или ручного клика в панели, хотя код сторожа для этого
# написан и работает. Здесь свип идёт ПОСЛЕДНИМ (как и раньше — после всех решений по основному
# транспорту), поэтому порядок действий не меняется. Ветки «интернета нет вообще» и boot-grace
# выходят обычным `exit 0` НАМЕРЕННО: без аплинка egress-пробы слотов провалятся все разом, и
# свип погасил бы живые выходы + прислал по письму на каждый.
# ПЕРИОДИЧЕСКИЙ ПРОГРЕВ ДОМЕННЫХ ПРАВИЛ. Наборы enodia_list/enodia_bypass наполняет dnsmasq в момент,
# когда САМ резолвит домен. Там, где клиенты спрашивают наш dnsmasq, набор пополняется даром — и
# эта функция ничего не меняет. А там, где клиенты ходят мимо (свой AdGuard Home или Pi-hole на
# NAS, DoH в браузере, DNS вписан руками), наполнителей ровно два: прогрев при добавлении правила
# и прогрев на буте. Между ними адреса протухают по TTL и переезжают у CDN, а обновить их некому,
# и правило тихо перестаёт действовать — на ВСЕХ устройствах разом.
# Своей cron-строки не заводим (как у usb-offload): тик сторожа и так ходит каждые 2 минуты,
# троттл дешевле отдельного расписания. WARM_TRIES=1 — без повторов и пауз: свипу надо освежить
# адреса, а не дождаться демона, и задерживать тик на секунды за домен нельзя (следующий встанет
# на локе). Живёт в finish() СОЗНАТЕЛЬНО: сюда не попадают ветки «интернета нет» и boot-grace, а
# без аплинка резолв всё равно провалится и только сожжёт время тика.
domain_warm_sweep() {
    [ -f "$ENODIA_DIR/domain.sh" ] || return 0
    [ "$(stamp_age "$DOMWARM_STAMP")" -ge "$DOMWARM_INTERVAL" ] || return 0
    date +%s > "$DOMWARM_STAMP"
    _dw=$(WARM_TRIES=1 sh "$ENODIA_DIR/domain.sh" warm 2>&1)
    # В лог — только когда есть что сказать: в норме верб печатает одну строку «выполнен».
    case "$_dw" in
        *"не попал"*|*ПЕРЕПОЛНЕН*|*"не ответил"*)
            log "domain-warm: $(printf '%s' "$_dw" | tr '\n' ' ')" ;;
    esac
}

# ПЕРИОДИЧЕСКАЯ ЖИВОСТЬ АВТО-DoH. Политика, троттл и сам откат — в doh-lib.sh (второй копии тут
# нет), мы только зовём и рассказываем человеку. Живёт в finish() по той же причине, что и прогрев
# доменов: сюда не попадают ветки «интернета нет вообще» и boot-grace, а без аплинка проба
# провалилась бы вслепую и выключила бы исправный резолвер на час. Keepalive выше (doh_want +
# doh_start) отвечает на «демон упал», эта строка — на «демон жив, а ответов нет»: разные вопросы,
# и второй до 09.08.2026 не задавал никто. Старая установка без doh-lib → команды нет → no-op.
# РЕЗОЛВЕР МИМО НЕСУЩЕЙ, ПОКА ТА ПОД ПОДОЗРЕНИЕМ. Политика и сами правила — в doh-lib.sh (второй
# копии тут нет), мы только зовём в двух точках вердикта (несущая усомнилась / снова везёт) и
# рассказываем человеку. ЗАЧЕМ: при «Шифрованном DNS» upstream у dnsmasq ровно один и он сам
# заперт маркой в несущую ⇒ мёртвая несущая = дом без DNS, а конфиг по имени без DNS не поднять
# (замерено 14.08.2026: 10+ минут без DNS при живом WAN). Старая установка без doh-lib → no-op.
doh_follow_carrier() {   # $1 = suspect|ok
    command -v doh_untunnel >/dev/null 2>&1 || return 0
    if [ "$1" = suspect ]; then
        doh_untunnel && log "DoH: несущая под подозрением — резолвер уведён МИМО неё (шифрование сохранено, DNS дома жив)"
    else
        doh_retunnel && log "DoH: несущая снова везёт — резолвер вернулся в туннель"
    fi
    return 0
}

doh_health_sweep() {
    command -v doh_health_tick >/dev/null 2>&1 || return 0
    # Идёт смена транспорта: DNS сейчас переставляют штатно, и проба в этом окне читается как
    # отказ резолвера (тот же гард и по той же причине стоит в slot_health_sweep).
    [ -e "$SWITCH_LOCK" ] && return 0
    # ГЕЙТ АПЛИНКА передаём ФУНКЦИЕЙ, а не флагом: политика живёт в doh-lib, а «жив ли аплинк»
    # умеет считать только сторож. Нужен потому, что обещание «в finish() не попадают ветки
    # „интернета нет“» держится не везде: у zapret health чисто локальный (nfqws жив), и при
    # аварии У ПРОВАЙДЕРА тик доходит сюда с ПРОЙДЕННЫМ health — проба валится, и через два
    # тика мы выключили бы исправный резолвер на час. wan_probe_ok платный (curl 4 с), поэтому
    # doh-lib зовёт его ТОЛЬКО когда проба уже провалилась. inet_reachable брать нельзя: он
    # ведёт счётчики эпизода wan-down и слал бы письма про провайдера из DNS-ветки.
    doh_health_tick wan_probe_ok; _dhr=$?
    [ "$_dhr" = 0 ] && return 0
    if [ "$_dhr" = 2 ]; then
        log "DoH (авто): карантин истёк — пробую включить шифрованный DNS снова"
        return 0
    fi
    log "DoH (авто): резолвер перестал отвечать — вернул обычный DNS, авто-режим не трогаю час"
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "doh-auto-off" 3600 \
        "BE7000: шифрованный DNS не отвечает — вернул обычный" \
"Роутер сам включал шифрованный DNS (DoH), пока туннель не используется. Резолвер перестал
отвечать: имена не резолвились, и из-за этого не открывались даже те сайты, что работают напрямую.
DNS возвращён на обычный ($DOH_PLAIN_DNS1 / $DOH_PLAIN_DNS2), интернет должен заработать сразу.
Через час роутер попробует включить шифрованный DNS снова. Если это повторяется — смените
резолвера в панели (Настройки → Шифрованный DNS) или выключите там авто-режим." >/dev/null 2>&1
    return 0
}

# Порядок НЕ произволен: живость DNS проверяем ДО прогрева доменов. Прогрев БЕЗУСЛОВНО
# переставляет свой часовой штамп, и на тике отката он сжёг бы слот, резолвя через резолвер,
# который следующей же строкой признаётся мёртвым, — правила по доменам остались бы на протухших
# адресах ещё на час. Обратной зависимости нет: проба резолвера от прогрева не зависит.
finish() { slot_health_sweep; doh_health_sweep; domain_warm_sweep; exit "${1:-0}"; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

notify() {
    # $1 — тема, $2 — текст. Молчим, если уведомления выключены флагом
    # или notify.sh недоступен. notify.sh сам тихо выйдет, если почта ещё
    # не настроена (пустой notify.conf), так что watchdog от этого не падает.
    if [ -f "$NOTIFY_OFF" ]; then
        log "notify выключен флагом .notify-off — письмо не отправлено: '$1'"
        return
    fi
    [ -f "$NOTIFY" ] && sh "$NOTIFY" "$1" "$2" >>"$LOG" 2>&1
}

# То же письмо, но ЧЕРЕЗ обёртку событий: throttle по ключу + запись в «центр уведомлений» панели.
# notify() выше — прямой SMTP, без того и без другого, и для ПОВТОРЯЮЩЕГОСЯ повода это разом спам
# и слепая панель (письмо ушло, а в истории пусто). Нет обёртки (установка старше неё) — шлём как
# раньше: важное письмо не должно молча пропасть из-за порядка обновления файлов.
#
# ПОЧЕМУ ЧЕРЕЗ НЕЁ ИДУТ И РАЗОВЫЕ ПЕРЕХОДЫ (throttle 0). Падение VPN, уход на резерв и возврат —
# самые важные записи журнала, и панель прямо обещает их человеку («здесь появятся: падение VPN и
# уход на резерв, автооткат сервера»). Они звали notify() напрямую, то есть письмо уходило, а в
# истории роутера не оставалось НИЧЕГО — замерено на BE7000 18.08.2026: после импорта пришло письмо
# «VPN восстановлен», а файла `.events` на роутере не существовало вовсе. Троттл этим поводам не
# нужен и вреден (второе падение подряд — это НОВОСТЬ, а не спам): они и так edge-triggered по
# $STATE/$XSTATE, поэтому ключ есть, а окно 0 — почта ведёт себя ровно как раньше, журнал появился.
notify_ev() {   # $1 ключ, $2 throttle_sec, $3 тема, $4 текст
    if [ -f "$NOTIFY_EVENT" ]; then
        sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
    else
        notify "$3" "$4"
    fi
}

# ВЫБРАН ТРАНСПОРТ, КОТОРОГО НА РОУТЕРЕ НЕТ. Повод общий у обеих веток ниже (tunnel и awg), потому
# и текст ОДИН: для человека разница между «Xray» и «AmneziaWG» здесь только в имени, а вопрос тот
# же — бэкап настроек переносит выбор сервера и правила, но не программы. Ключ тоже общий: два
# письма об одном и том же за сутки не нужны.
transport_missing_event() {   # $1 — человекочитаемое имя транспорта
    if [ "$NF_LANG" = en ]; then
        notify_ev "transport-missing" 86400 \
            "BE7000: a VPN is selected, but its component is not installed" \
"The router settings select transport $1, but the program itself is not on the router — this is
what a move looks like: a settings backup carries the server choice and the rules, but not the
programs (they are two orders of magnitude heavier).
Right now the router works DIRECTLY: the internet is there, listed sites bypass the VPN.
What to do: open the panel at :8088 → «Components» and install $1 — everything comes up by
itself after that, the settings are already in place."
        return
    fi
    notify_ev "transport-missing" 86400 \
        "BE7000: VPN выбран, но компонент не установлен" \
"В настройках роутера выбран транспорт $1, но самой программы на роутере нет — так бывает после
переезда: бэкап настроек переносит выбор сервера и правила, а программы (они на два порядка
тяжелее) не переносит.
Роутер сейчас работает НАПРЯМУЮ: интернет есть, сайты из списка идут мимо VPN.
Что сделать: откройте панель :8088 → «Компоненты» и поставьте $1 — дальше всё поднимется само,
настройки уже на месте."
}

ext_ip() { probe_ext_ip "" 5; }

# Режим failover: off|sticky|home. Нет файла/мусор → sticky (ВКЛ по умолчанию).
fo_mode() {
    m=$(cat "$FAILOVER_MODE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$m" in off|sticky|home) printf '%s' "$m" ;; *) printf 'sticky' ;; esac
}

# Эскалация при исчерпании серверов активного протокола: cross|direct. Нет файла →
# cross (макс. устойчивость). cross — перебрать другой протокол; direct — прямой режим.
fo_escalate() {
    e=$(cat "$FAILOVER_ESCALATE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$e" in cross|direct) printf '%s' "$e" ;; *) printf 'cross' ;; esac
}

# Эпизод-гард (анти-петля): помечаем перебранные протоколы; cross не лезет в уже
# пробованный. busybox-safe (grep -w есть).
episode_has() { [ -f "$FAILOVER_EPISODE" ] && grep -qw "$1" "$FAILOVER_EPISODE" 2>/dev/null; }
episode_add() { episode_has "$1" || echo "$1" >> "$FAILOVER_EPISODE"; }
episode_reset() { : > "$FAILOVER_EPISODE"; }

# Предпочитаемый («домашний») транспорт: awg|xray|hy2. ПУСТО (нет файла) → авто-возврат
# транспорта выключен (пишется только ручным выбором человека в панели — авто-cross
# его НЕ трогает, иначе «дом» уехал бы за аварийным переключением).
transport_home() { cat "$TRANSPORT_HOME_FILE" 2>/dev/null | tr -d ' \t\r\n'; }

# Человекочитаемое имя транспорта для писем (под hy2 добавится строка). Generic-замена
# хардкоду «Xray» — теперь ветка обслуживает любой tunnel-транспорт.
transport_label() {
    case "$1" in
        awg)  echo "AmneziaWG" ;;
        xray) echo "Xray" ;;
        hy2)  echo "Hysteria2" ;;
        byedpi) echo "ByeDPI" ;;
        zapret) echo "Zapret" ;;
        *)    echo "$1" ;;
    esac
}
# Готов ли транспорт <name> к подъёму — спрашиваем ОРКЕСТРАТОР (его реестр + проверка
# плагина/секрет-конфига). Watchdog не знает имён файлов плагинов, только имена транспортов.
transport_ready() { sh "$TRANSPORT_SH" list 2>/dev/null | grep -qw "$1"; }
# Следующий готовый НЕ-awg транспорт для cross с awg (xray/hy2/… по реестру). Пусто → некуда.
cross_target_from_awg() { sh "$TRANSPORT_SH" next awg 2>/dev/null; }

# Установлен ли AmneziaWG (есть секрет-конфиг). В xray-only awg НЕТ — cross на него
# невозможен (нет awg0/awg.conf), эскалация вырождается в прямой режим. Зеркало
# HAVE_AWG установщика и have_awg из xray-transport.sh.
have_awg() { [ -f "$ENODIA_STATE/awg.conf" ]; }

# ЛЕЖИТ ЛИ НА РОУТЕРЕ САМА ПРОГРАММА транспорта — вопрос ОТДЕЛЬНЫЙ от have_awg выше: тот про
# КОНФИГ, то есть про намерение, а намерение приезжает и ИЗ БЭКАПА ЧУЖОГО роутера (`awg.conf` в
# архиве). Спрашиваем владельца ответа — оркестратор (верб `installed <t>`).
# Именно про БИНАРИ, а не про `ready`: «не готов» бывает от трёх причин (нет бинаря · нет конфига ·
# ядро не умеет), и совет «поставьте компонент» верен ровно для первой — на ядре 4.4 zapret не
# встанет НИКОГДА, и звать туда установку значило бы гонять человека по кругу.
# Код 2 = старая копия скрипта не знает верба ⇒ считаем, что программа есть, и ведём себя как
# раньше: обновление в любом порядке не должно выключать починку на рабочем роутере.
# Отдельно от transport_ready() выше СОЗНАТЕЛЬНО: та судит по СОДЕРЖИМОМУ `list`, и пустой вывод
# (старый скрипт) читает как «не готов» — для выбора цели cross это безопасно, а для «чинить или
# нет» дало бы ровно обратное, опасное умолчание.
# ПРОБА ВЕРСИИ — ОТДЕЛЬНЫМ вербом, и это не перестраховка: спросить сразу `installed <имя>` НЕЛЬЗЯ.
# Верб `installed` существовал и РАНЬШЕ, но БЕЗ аргумента: старая копия аргумент проглотит, напечатает
# СПИСОК и вернёт код ПОСЛЕДНЕЙ итерации своего цикла (SELECTABLE кончается zapret) — то есть 1 на
# любом роутере без nfqws. Вышло бы «программы нет» там, где стоит всё, и обновление ОДНОГО файла
# (точечный --push, частичный apply-scripts) выключало бы авто-починку awg0 до ребута. Верб `ready`
# приехал ВМЕСТЕ с `installed <имя>`, поэтому его код 2 = честный признак старой копии.
carrier_installed() {
    [ -f "$TRANSPORT_SH" ] || return 0
    sh "$TRANSPORT_SH" ready "$1" >/dev/null 2>&1
    [ "$?" = 2 ] && return 0
    sh "$TRANSPORT_SH" installed "$1" >/dev/null 2>&1; _circ=$?
    [ "$_circ" != 1 ]
}

# Жив ли WAN-аплинк — локально, без интернета. Отличает «лёг провайдер/кабель» от
# «лёг VPS»: при мёртвом WAN перебор серверов/транспортов БЕССМЫСЛЕН (ни один сервер
# физически недостижим) → watchdog просто ждёт, не гоняя failover вхолостую (раньше при
# пропаже WAN он перебирал ВСЕ конфиги + cross на альт каждые FAILOVER_RETRY впустую).
# КОНСЕРВАТИВНО: считаем WAN мёртвым ТОЛЬКО при явном сигнале (нет дефолт-маршрута в
# main-таблице ИЛИ carrier=0 на WAN-iface) — чтобы НЕ подавить ЗАКОННЫЙ failover, если
# шлюз провайдера просто режет ICMP. Дефолт туннеля живёт в table 1000, поэтому дефолт
# из main = реальный WAN-iface (та же логика, что в cgi-bin/ip).
wan_iface() { ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
wan_up() {
    _wi=$(wan_iface)
    [ -n "$_wi" ] || return 1   # нет дефолта вообще → WAN не настроен/отвалился
    if [ -r "/sys/class/net/$_wi/carrier" ]; then
        [ "$(cat "/sys/class/net/$_wi/carrier" 2>/dev/null)" = "1" ] || return 1   # физлинк опущен (кабель/порт)
    fi
    return 0
}

# --- Гейт «есть ли интернет ВООБЩЕ», а не «жив ли VPS» ---------------------------------
# ГРАБЛЯ (железо 03.08.2026): при аварии У ПРОВАЙДЕРА линк и дефолт-маршрут на месте, а
# интернета нет. wan_up() такой случай ПРОПУСКАЕТ (он сознательно смотрит только на жёсткие
# локальные признаки) ⇒ сторож каждые FAILOVER_RETRY перебирал ВЕСЬ пул конфигов с
# wait_for_handshake на каждом: за ночь 63 повтора события «резервы недоступны», свип крутился
# впустую до утра. Перебор серверов без аплинка бессмыслен ФИЗИЧЕСКИ — ни один недостижим.
#
# Второй сигнал = РЕАЛЬНАЯ egress-проба, привязанная к WAN-интерфейсу. `--interface` ОБЯЗАТЕЛЕН:
# роутер сам заворачивает 1.1.1.1/8.8.8.8 в несущую (mangle OUTPUT MARK от set_*_dns + ip route
# dns/32 dev awg0 + оба ∈ iplist_set) ⇒ проба без бинда померяла бы ТУННЕЛЬ, а не аплинк — ровно
# та грабля, из-за которой не срабатывал DoH-фолбэк резолва. Платим за пробу ТОЛЬКО в момент
# аварии (перед перебором); в здоровом состоянии сторож её не делает вовсе.
wan_probe_ok() {
    _wi=$(wan_iface)
    [ -n "$_wi" ] || return 1
    [ -n "$(probe_ext_ip "--interface $_wi" 4)" ] && return 0
    # Второй адрес другого оператора: у части провайдеров Cloudflare заворачивается/режется, и
    # одна цель дала бы вечное «интернета нет». Тут важен ФАКТ соединения, а не тело — любой
    # ответ (даже 404) = сеть жива, как в `gh-update.sh reachable`.
    curl -s -k -o /dev/null --interface "$_wi" --max-time 4 https://8.8.8.8/ 2>/dev/null
}

# Событие «нет связи с провайдером» — РОВНО ОДНО на эпизод (throttle notify-event тут вторичен:
# гейтит сам штамп). Прежде этот случай молча оседал строкой в логе, а пользователь видел лишь
# ×63 «VPN упал, резервы недоступны» — письмо про VPN там, где VPN ни при чём.
wan_out_event() {
    date +%s > "$WANOUT_SWEEP"
    [ -f "$WANOUT_EVENT" ] && return 0
    date +%s > "$WANOUT_EVENT"
    log "интернета нет ВООБЩЕ ($1) — перебор серверов подавлен, жду возвращения аплинка"
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "wan-down" 1800 \
        "BE7000: нет связи с провайдером" \
"Роутер не видит интернета от провайдера ($1) — недоступен НЕ только VPN, а сеть целиком.
Перебор VPN-серверов на это время приостановлен: без аплинка ни один сервер недостижим,
и перебор лишь греет флеш и засоряет журнал.
Роутер сам заметит возвращение связи и восстановит VPN — делать ничего не нужно." >/dev/null 2>&1
    return 0
}
wan_out_clear() {
    rm -f "$WANOUT_COUNT" "$WANOUT_SWEEP" 2>/dev/null
    [ -f "$WANOUT_EVENT" ] || return 0
    rm -f "$WANOUT_EVENT" 2>/dev/null
    log "аплинк вернулся — перебор серверов снова разрешён"
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "wan-up" 1800 \
        "BE7000: связь с провайдером вернулась" \
"Интернет от провайдера снова доступен. Роутер возобновил обычную работу:
если VPN всё ещё не поднят, сторож переберёт серверы на ближайшем тике." >/dev/null 2>&1
    return 0
}

# 0 = связь есть ЛИБО судить не берёмся (действуем как раньше); 1 = подтверждённое «интернета нет».
# Гистерезис: единичный промах пробы НЕ подавляет перебор — ровно та причина, по которой в wan_up
# отвергнут ICMP-пинг шлюза: пропустить ЗАКОННЫЙ failover при реально мёртвом VPS дороже, чем
# один лишний свип. Жёсткий локальный сигнал (нет дефолта/carrier=0) подтверждения не требует.
inet_reachable() {
    if ! wan_up; then
        echo "$WAN_PROBE_FAILS" > "$WANOUT_COUNT"
        wan_out_event "нет дефолт-маршрута или линк опущен"
        return 1
    fi
    if wan_probe_ok; then wan_out_clear; return 0; fi
    _n=$(cat "$WANOUT_COUNT" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    _n=$((_n + 1)); echo "$_n" > "$WANOUT_COUNT"
    if [ "$_n" -lt "$WAN_PROBE_FAILS" ]; then
        log "egress-проба через WAN не прошла ($_n/$WAN_PROBE_FAILS) — единичный промах, перебор НЕ подавляю"
        return 0
    fi
    # Предохранитель: проба тоже может врать (провайдер заворачивает/режет ОБА anycast-адреса) —
    # тогда подавление стало бы ВЕЧНЫМ и живой резерв не подняли бы никогда. Раз в WANOUT_MAX
    # пускаем ОДИН контрольный свип вслепую: цена — дорогой перебор раз в час, зато отказ временный.
    # Гейт `-f`: штамп появляется в wan_out_event, т.е. с ПЕРВОГО подтверждённого отказа. Без него
    # «нет файла = возраст 999999» открывал бы клапан сразу на подтверждении — то есть первое же
    # подавление пропускало бы свип и не объявляло эпизод.
    if [ -f "$WANOUT_SWEEP" ] && [ "$(stamp_age "$WANOUT_SWEEP")" -ge "$WANOUT_MAX" ]; then
        date +%s > "$WANOUT_SWEEP"
        log "интернета нет по пробе, но подавление идёт ≥$((WANOUT_MAX / 60)) мин — пускаю ОДИН контрольный свип"
        return 0
    fi
    wan_out_event "egress-проба через WAN не отвечает"
    return 1
}

# --- Бэкофф перебора пула --------------------------------------------------------------
# Свип пула стоит дорого (по конфигу × wait_for_handshake) и рвёт awg0 на каждом кандидате.
# Пока авария длится, повторять его в одном и том же ритме незачем: удваиваем паузу до кап-а,
# а любое возвращение здоровья (или аплинка) сбрасывает лестницу в исходные FAILOVER_RETRY.
fo_retry() {
    _b=$(cat "$FAILOVER_BACKOFF" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
    [ "$_b" -lt "$FAILOVER_RETRY" ] && _b=$FAILOVER_RETRY
    [ "$_b" -gt "$FAILOVER_MAX" ] && _b=$FAILOVER_MAX
    printf '%d' "$_b"
}
fo_backoff_bump() {   # $1 — кап (сек) для ЭТОГО вызова; без него общий FAILOVER_MAX. Кап передаёт
                      # tunnel-ветка (TUNNEL_RETRY_MAX), иначе её лог обещал бы паузу, которой нет.
    _cap=${1:-$FAILOVER_MAX}
    _b=$(( $(fo_retry) * 2 ))
    [ "$_b" -gt "$_cap" ] && _b=$_cap
    echo "$_b" > "$FAILOVER_BACKOFF"
    log "перебор не помог → следующая попытка не раньше чем через $((_b / 60)) мин"
    return 0
}
fo_backoff_reset() {
    [ -f "$FAILOVER_BACKOFF" ] || return 0
    rm -f "$FAILOVER_BACKOFF" 2>/dev/null
    log "бэкофф перебора сброшен (здоровье вернулось)"
    return 0
}
# Здоровье вернулось: снять бэкофф и закрыть эпизод «интернета нет» (иначе письмо «связь
# вернулась» не ушло бы никогда — inet_reachable зовётся только в аварии).
health_back() { fo_backoff_reset; wan_out_clear; }

# FAILOPEN — это СОСТОЯНИЕ СЕТИ, а не строка в файле: пока в table 1000 висит default в дохлую
# несущую, «прямой режим» — блэкхол, а не fail-open. ГРАБЛЯ (диаг тестера 08.08.2026, VPS мёртв,
# провайдер жив): ФАЗА 0 плагина (`transport.sh failover` чинит несущую НА МЕСТЕ) поднимает
# демонов и ВОЗВРАЩАЕТ `default dev xtun` ещё до того, как выяснится, что сервер не отвечает, —
# а ветка «уже FAILOPEN — без изменений» несущую не трогала. Итог: весь маркированный трафик
# уезжал в никуда, и вместе с ним DNS (set_xray_dns метит 1.1.1.1/8.8.8.8 В туннель) ⇒ dnsmasq
# переставал резолвить ВООБЩЕ ВСЁ при живом WAN. Тем же путём откатывался и ручной
# `transport.sh down`: следующий тик поднимал несущую обратно.
# safety_off здесь не помощник — он снимает `default dev awg0` и про альт-несущую не знает;
# владелец релинквиша = ПЛАГИН (он же вернёт прямой DNS и снимет свои OUTPUT-марки).
# ПОЧЕМУ ЭТО НЕ ДЕРЁТСЯ С РУЧНЫМ ПОДЪЁМОМ: зовём только из состояния FAILED, а КАЖДЫЙ плагин на
# up/down чистит xstate (grep `enodia-watchdog.xstate` — все пять) ⇒ после ручного switch/heal мы
# видим HEALTHY и даём несущей нормально пройти лестницу. Новый плагин обязан делать так же.
ensure_direct_mode() {
    _edev=$(carrier_route_dev)
    [ -n "$_edev" ] || return 0    # table 1000 пуста → прямой режим НАСТОЯЩИЙ, тишина
    log "FAILOPEN, но несущая ($_edev) снова держит default в table 1000 → снимаю (fail-open, не блэкхол)"
    sh "$TRANSPORT_SH" down "$1" >>"$LOG" 2>&1
    echo "FAILOPEN" > "$STATE"
    # ВЕРДИКТ ВОЗВРАЩАЕМ СВОИМ ИМЕНЕМ. `down` у КАЖДОГО плагина делает `rm -f` по xstate (штатно:
    # так ручной switch не дерётся со сторожем — см. коммент выше), но здесь down зовём МЫ, и
    # вместе с ним теряется ровно то состояние, на котором держится троттл лестницы. Без этой
    # строки следующий тик читал пустой файл как HEALTHY ⇒ провал шёл «первой осечкой» → SUSPECT,
    # ещё через тик ветка `xcur != FAILED` заново крутила ВЕСЬ пул и ПОВТОРНО слала письмо
    # «резервы недоступны» (здешний notify() без throttle): пауза вместо 10→20→30 мин выходила
    # ~4 мин. Файл эпизода тем же rm тоже уходит, но он ПОАТТЕМПТНЫЙ (лестница начинается с
    # episode_reset), поэтому его не восстанавливаем — только вердикт.
    echo FAILED > "$XSTATE"
}

# Эскалация awg→другой транспорт (вариант A). Зовётся, когда awg-пул исчерпан и система
# уже в safety_off (прямой = SAFE-пол). Цель выбирает ОРКЕСТРАТОР (transport.sh next awg —
# первый готовый не-awg по реестру, обычно xray/hy2). Возвращает маркировку (safety_off её
# снял), поднимает цель, при нужде перебирает её пул. 0 — встали; 1 — цель тоже мёртва
# (прямой). Анти-петля: не лезет в транспорт, уже пробованный в этом эпизоде.
cross_awg_to_other() {
    [ "$(fo_escalate)" = "cross" ] || return 1
    other=$(cross_target_from_awg)
    [ -n "$other" ] || return 1
    episode_has "$other" && return 1
    episode_add "$other"
    olbl=$(transport_label "$other")
    log "awg-пул исчерпан → cross: пробую $other"
    sh "$TRANSPORT_SH" switch "$other" >>"$LOG" 2>&1   # оркестратор: релинквиш awg + mark-core + подъём $other
    if sh "$TRANSPORT_SH" health "$other" >/dev/null 2>&1 || sh "$TRANSPORT_SH" failover "$other" >>"$LOG" 2>&1; then
        echo NORMAL > "$STATE"; echo HEALTHY > "$XSTATE"
        ip=$(ext_ip)
        # «be7000 меню -> Протокол» тут стояло с тех пор, когда протокол переключал ПК-скрипт.
        # Он этого давно не умеет (весь выбор — в панели), и письмо отправляло человека в
        # несуществующий пункт меню ровно в тот момент, когда он растерян. Адрес один: :8088.
        if [ "$NF_LANG" = en ]; then
            notify_ev "cross-switch" 0 "BE7000: AmneziaWG went down -> switched to $olbl" \
"All awg servers are unreachable. The router switched over to $olbl automatically.
External IP: ${ip:-unknown}.
To go back to AmneziaWG: panel :8088 -> the VPN card."
        else
            notify_ev "cross-switch" 0 "BE7000: AmneziaWG упал -> перешли на $olbl" \
"Все awg-серверы недоступны. Роутер автоматически переключился на $olbl.
Внешний IP: ${ip:-неизвестен}.
Вернуться на AmneziaWG: панель :8088 -> карточка VPN."
        fi
        return 0
    fi
    sh "$TRANSPORT_SH" down "$other" >>"$LOG" 2>&1
    [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
    echo FAILOPEN > "$STATE"; echo FAILED > "$XSTATE"
    log "cross: $other тоже недоступен → прямой режим"
    return 1
}

# Сколько резервных конфигов в configs/ (кроме активного). busybox-safe.
count_backups() {
    a=$(cat "$ACTIVE_NAME" 2>/dev/null)
    c=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f" .conf)" = "$a" ] && continue
        c=$((c+1))
    done
    printf '%d' "$c"
}

# Возраст (сек) с момента записи stamp-файла; нет файла → большое число.
# Возраст отметки-троттла. Штампы лежат в /tmp ⇒ рождаются ПОСЛЕ загрузки: «старше аптайма» —
# это скачок часов, а не давность, и age_since вернёт 0 (троттл НЕ истёк). Иначе один шаг часов
# разом открывал все окна: лестница failover, бэкофф, возврат домой — всё в одном тике.
stamp_age() {
    if [ -f "$1" ]; then
        t=$(cat "$1" 2>/dev/null); case "$t" in ''|*[!0-9]*) t=0 ;; esac
        age_since "$t"
    else
        echo 999999
    fi
}

# Секунд с момента загрузки роутера — для boot-grace. /proc/uptime = «<секунды> <idle>»,
# берём целую часть первого числа. Нет файла/мусор → большое число (грейс не срабатывает,
# ведём себя как раньше). busybox-safe (cut есть). RTC на BE7000 нет, но uptime от него
# не зависит — это монотоника ядра, надёжнее date для «сколько прошло с ребута».
uptime_secs() {
    u=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    case "$u" in ''|*[!0-9]*) u=999999 ;; esac
    printf '%d' "$u"
}

# Запустить перебор резервов через switch-vpn.sh и выставить STATE по коду:
# 0 — встали на резерв (NORMAL); 1 — прямой режим (FAILOPEN). Письма шлёт switch-vpn.
run_failover() {
    date +%s > "$FAILOVER_STAMP"
    if sh "$SWITCH_VPN" failover >>"$LOG" 2>&1; then
        echo "NORMAL" > "$STATE"
        log "failover: встали на резерв ($(cat "$ACTIVE_NAME" 2>/dev/null))"
        return 0
    else
        echo "FAILOPEN" > "$STATE"
        log "failover: резервы недоступны → прямой режим"
        return 1
    fi
}

# Бинарь для чтения handshake. ПОРЯДОК: сперва НАШ awg, потом системный wg — инвариант проекта
# «handshake читает awg, НЕ wg» (`wg_bin()` в transport-awg.sh). На стоке wg нет, но там, где он
# есть (дев-роутер/чужая сборка), обычный wg не понимает A-параметры AmneziaWG.
WG=""
[ -x "$ENODIA_BIN/awg" ] && WG="$ENODIA_BIN/awg"
[ -z "$WG" ] && command -v wg >/dev/null 2>&1 && WG=wg

# Тест-хук/ручной вызов: только проход health доп-выходов (для железо-проверки Ф2 без ожидания
# 180с+тика; cron зовёт watchdog БЕЗ аргумента и идёт полным циклом ниже).
[ "$1" = slot-sweep ] && { slot_health_sweep; exit 0; }

# Не лезем во время ручного переключения страны (switch-vpn.sh держит лок)
[ -e "$SWITCH_LOCK" ] && exit 0

# Один экземпляр за раз. Лок с ОТМЕТКОЙ ВРЕМЕНИ, а не пустой: тик сторожа делает сетевые пробы и
# зовёт плагины (curl, awg setconf, перебор пула) — зависший или убитый -9 экземпляр оставлял бы
# файл НАВСЕГДА, и сторож молча умирал до ребута. Это худший из отказов «живучести»: подсистема,
# которая должна замечать чужие отказы, отказывает сама и никому об этом не говорит. Протухший
# (старше LOCK_STALE) лок перехватываем и пишем об этом в журнал.
LOCK_STALE=${LOCK_STALE:-1800}
if [ -e "$LOCK" ]; then
    if [ "$(stamp_age "$LOCK")" -lt "$LOCK_STALE" ]; then exit 0; fi
    log "лок сторожа протух (возраст $(stamp_age "$LOCK")с ≥ ${LOCK_STALE}с) — прошлый тик завис/убит, перехватываю"
fi
date +%s > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM HUP

# --- Режим поддержки: погасить истёкший туннель (до boot-grace — экспайр важнее) ---
# DRY: watchdog уже бежит cron */2, поэтому reap живёт здесь, а не отдельным демоном. Дёшево
# и идемпотентно (no-op, когда доступ не открыт — гейт [ -s .support-active ] внутри). Ставим
# ДО boot-grace-выхода, но после ребута /tmp сброшен → .support-active нет → сразу no-op.
[ -f "$SUPPORT_SH" ] && sh "$SUPPORT_SH" reap >/dev/null 2>&1

# --- DoH keepalive: демон https_dns_proxy мог упасть, а dnsmasq форвардит на 127.0.0.1:5053 ---
# Мёртвый прокси при включённом DoH = DNS всего дома лёг (dnsmasq стучит в пустой loopback-порт).
# Несущая при этом жива, DNS-сеттер транспорта не перевызывается ⇒ поднять некому, кроме нас.
# Ставим ДО boot-grace/WAN-гейта: dead-proxy рвёт DNS в ЛЮБОМ состоянии, а старт демона безвреден
# даже при мёртвом WAN (он просто не резолвит, пока WAN не вернётся). Идемпотентно; без .doh-on/
# бинаря doh_enabled=false ⇒ no-op. Независимо от transport-failover ниже. [[doh-direct-modes-backlog]]
if doh_want 2>/dev/null && ! doh_running 2>/dev/null; then
    log "DoH: https_dns_proxy не запущен, а DoH нужен (тумблер/авто-режим) → поднимаю"
    doh_start >>"$LOG" 2>&1
fi
# Ротация лога прокси — ОТДЕЛЬНОЙ строкой, а не внутри doh_start: тот зовётся только когда демон
# УПАЛ, а лог растит как раз ЖИВОЙ (замерено ~3 МБ/сутки в ОЗУ, ротации не было вовсе). Цена тика —
# один `stat`; порог и глубина хвоста заданы в doh-lib.sh, второй копии политики тут нет.
command -v doh_log_rotate >/dev/null 2>&1 && doh_log_rotate
# Якоря СВОЕГО резолвера: адрес чужого сервера может уехать под нами, а на нём висят марка/RETURN
# :443/853 в mangle. Тут — единственное место, где мы это заметим БЕЗ перезапуска демона (doh_start
# зовётся только когда тот упал). Троттл, гейт «резолвер вообще свой?» и сама перестановка правил —
# внутри функции, второй копии политики здесь нет. Каталожные резолверы = мгновенный no-op.
command -v doh_custom_refresh >/dev/null 2>&1 && doh_custom_refresh

# --- Внешний накопитель: вернуть хранилище, если оно пропало из-под ног ---
# Второй (и последний) хук монтирования: первый — heal.sh, но он отрабатывает 1×/boot, а
# флешку могли воткнуть ПОСЛЕ его тика, выдернуть и вставить обратно, или стоковый automount
# отвалился. Без хранилища bin_path отдаёт резидентный путь, транспорт становится «не
# установлен» и ветки ниже честно уводят в fail-open — вот только чинить это по-настоящему
# умеет ровно одно действие: смонтировать обратно. Ставим ДО boot-grace: на буте heal и
# watchdog идут вперемешку, а монтаж безвреден в любом состоянии. Нет маркера .bin-store
# (роутер без накопителя) ⇒ usb-offload выходит первой строкой, no-op.
[ -f "$ENODIA_DIR/usb-offload.sh" ] && sh "$ENODIA_DIR/usb-offload.sh" mount-ensure >>"$LOG" 2>&1

# --- Boot-grace: не мешаем heal.sh поднять несущую на буте ---
# Пойман 07.07.2026: сразу после ребута watchdog (ещё ДО того, как heal поднял xray)
# объявлял транспорт «подтверждённый сбой» → failover → пул исчерпан → safety_off, а
# спустя ~20с heal штатно поднимал xray. Итог — самонаведённый failopen-churn на каждом
# ребуте + залипший FAILOPEN (см. баг сброса STATE ниже). Первые $BOOT_GRACE сек просто
# пропускаем тик: на буте /tmp сброшен → STATE=NORMAL, терять нечего, а здоровый транспорт
# пройдёт health на первом же тике после грейса. Гейт общий — прикрывает и tunnel-, и awg-ветку.
up=$(uptime_secs)
if [ "$up" -lt "$BOOT_GRACE" ]; then
    log "boot-grace: uptime ${up}с < ${BOOT_GRACE}с — пропускаю тик (первичный подъём несущей за heal.sh)"
    exit 0
fi

# --- НАБЛЮДЕНИЕ (не решение): видели ли мы awg0 живым в эту загрузку ---
# «Интерфейса нет» — ДВА разных события с одинаковой сигнатурой: несущая УПАЛА (демон умер/OOM —
# про это шлём письмо) и несущую ЕЩЁ НЕ ПОДНИМАЛИ (намерение `.transport=awg` приехало импортом
# бэкапа, а компонент доставили из «Компонентов» — тот ставит, но не активирует). Второе — не
# авария: письмо «awg0 упал — прямой режим» описывает падение того, что не поднималось (замерено
# на AX3600 17.08.2026). Отличить их можно ТОЛЬКО по своей же памяти, поэтому отметку кладём тут,
# ДО всех веток: это наблюдение сторожа, оно не зависит ни от активного транспорта (при xray awg0
# — тёплый резерв, и он тоже считается «был живым»), ни от версии плагинов. Ветка awg0 читает её
# ниже. Мимо boot-grace: там тик выходит раньше, а на буте несущую поднимает heal.
if ip link show awg0 >/dev/null 2>&1; then date +%s > "$AWG0_SEEN" 2>/dev/null || true; fi

# --- Настроен ли транспорт ВООБЩЕ (установка «только панель») ---
# Спрашиваем ОРКЕСТРАТОР (единственный владелец ответа; признак — пустой `.transport` И отсутствие
# awg.conf, см. transport.sh cmd_configured). Код 2 = старая копия скрипта, верб не знаком ⇒ ведём
# себя как раньше: обновление в любом порядке не должно выключать сторожа на рабочем роутере.
# Цена — один fork в два минуты; ответ нужен ДО mipctld-гарда, который иначе создаст маркировку
# с нуля там, где её сознательно не заводили.
TRANSPORT_OK=1
if [ -f "$TRANSPORT_SH" ]; then
    sh "$TRANSPORT_SH" configured >/dev/null 2>&1; _tc=$?
    [ "$_tc" = 1 ] && TRANSPORT_OK=0
fi

# --- mipctld-guard: наши MARK+ACCEPT должны стоять ВЫШЕ miwifi/NFQUEUE ---
# ГРАБЛЯ (Сергей, 12.07.2026 — [[mipctld-nfqueue-fwmark-split]]): стоковый mipctld инспектирует
# ФОРВАРД через ipt_compiler/NFQUEUE в mangle PREROUTING и реинъектит пакет с mark=0. mark-core
# ставит MARK+ACCEPT ВЫШЕ этих цепочек, но durable-фикс может «сползти»:
#   (1) на буте heal.sh (1×/boot) мог отработать РАНЬШЕ, чем firewall построил ipt_compiler →
#       mark-core сфолбэчил аппендом НИЖЕ miwifi → метка стирается → клиент мимо туннеля;
#   (2) fw3/mipctld пересобирают цепочки и задвигают наши правила вниз.
# Тут (cron */2) дёшево сверяем позиции и, если наш iplist_set-MARK ОТСУТСТВУЕТ ИЛИ стоит НИЖЕ
# первой miwifi-цепочки — переигрываем mark-core (идемпотентно ставит выше). conntrack НЕ трогаем
# (флаш всех соединений раз в 2 мин = дребезг связи; правильный путь берут НОВЫЕ потоки, а гард
# в норме молчит). Где фичи Xiaomi нет (дев-роутер) — miwifi не найден → no-op.
mark_above_miwifi_ok() {
    mi=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/miwifi|ipt_compiler|NFQUEUE/{print $1; exit}')
    [ -z "$mi" ] && return 0   # фичи Xiaomi нет — сторожить нечего
    mk=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/match-set iplist_set dst/ && /MARK set/{print $1; exit}')
    # Маркировки нет ВООБЩЕ и транспорт не настроен («только панель») — сторожить тоже нечего:
    # правил в ядре не заводили, а «починка» их СОЗДАЛА БЫ, вернув маркировку в пустую table 1000
    # на роутере, где человек ещё ничего не выбрал. Различать «нет вовсе» и «сползло вниз»
    # обязательно: второе — настоящий баг, ради которого гард и написан, и он остаётся живым и
    # для слот-режима (доп-выход без основной несущей — правила есть, транспорта нет).
    [ -z "$mk" ] && [ "$TRANSPORT_OK" = 0 ] && return 0
    [ -n "$mk" ] && [ "$mk" -lt "$mi" ]   # MARK есть И выше первой miwifi-цепочки
}
if ! mark_above_miwifi_ok; then
    log "mipctld-guard: маркировка iplist_set ниже/мимо miwifi — переигрываю mark-core"
    restore_marking
fi

# --- Keepalive «доступа домой»: сервер включён, а несущей awgs0 нет ---
# Несущая сервера — такой же демон в userspace, как awg0: умер (OOM, чужой killall, ручной
# kill) — TUN уходит вместе с ним, и поднять его до следующего ребута НЕКОМУ (heal.sh заперт
# boot-локом 1×/boot, а `vpn-toggle repair` зовётся только по rule-heal). Снаружи это выглядит
# как «телефон вчера подключался, а сегодня нет», причём правила фаервола на месте и панель
# показывает «включено». Поймано на железе 30.07: failover звал switch-vpn → awg_setup.sh с
# `killall amneziawg-go` (сам killall вычищен, но страховка нужна и на прочие смерти демона).
# Дёшево (одна `ip link show` в тик) и идемпотентно; флаг server/.on = НАМЕРЕНИЕ человека,
# поэтому решение «поднимать» принимаем по нему, а не по наличию интерфейса.
if [ -f "$VPNSRV_SH" ] && [ -f "$ENODIA_STATE/server/.on" ] && ! ip link show awgs0 >/dev/null 2>&1; then
    log "доступ домой: сервер включён, но несущей awgs0 нет (демон умер?) → поднимаю"
    sh "$VPNSRV_SH" up >>"$LOG" 2>&1
fi

# Транспорт-aware. При активном TUNNEL-транспорте (.transport != awg: xray/hy2/…) awg-логику
# НЕ применяем (иначе watchdog зря гонял бы awg-failover, видя «старый» handshake awg0-резерва).
# ВСЯ работа с tunnel-транспортом идёт через ОРКЕСТРАТОР (transport.sh health/failover/switch/
# down/next) — имя файла плагина знает только он, поэтому ветка generic и hysteria2 станет
# drop-in (без правок watchdog). Лестница на сбой (НЕ цикл — каждый протокол ≤1 раза за эпизод,
# терминал = safety_off):
#   off            → вернуться на AmneziaWG (если установлен), иначе прямой режим.
#   sticky/home    → перебор резервов транспорта (transport.sh failover); исчерпан →
#                    по .failover-escalate: cross → следующий готовый транспорт (transport.sh
#                    next, обычно awg) + его перебор (анти-петля через episode-гард),
#                    direct → прямой режим.
# Анти-дребезг: первая осечка health = SUSPECT (без действий), реакция со 2-го тика.
# После фолбэка на awg .transport=awg → следующий тик идёт обычной awg-веткой.
# Транспорта нет вовсе (установка «только панель»): несущей никто не заводил, чинить нечего.
# Молча — а не строкой в лог каждые две минуты: тик здорового роутера обязан быть тихим, иначе
# лог в ОЗУ растёт ровно там, где ничего не происходит. Выходим ЧЕРЕЗ finish(), а не своим
# `exit 0`: доп-выход (слот) и «Шифрованный DNS» живут БЕЗ основной несущей, и их свипы —
# единственное, что в этом состоянии вообще осмысленно.
[ "$TRANSPORT_OK" = 0 ] && finish

TRANSPORT=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
if [ -n "$TRANSPORT" ] && [ "$TRANSPORT" != "awg" ] && [ -f "$TRANSPORT_SH" ]; then
    TLABEL=$(transport_label "$TRANSPORT")
    xcur=HEALTHY; [ -f "$XSTATE" ] && xcur=$(cat "$XSTATE")

    if sh "$TRANSPORT_SH" health "$TRANSPORT" >>"$LOG" 2>&1; then
        if [ "$xcur" != "HEALTHY" ]; then echo HEALTHY > "$XSTATE"; episode_reset; log "$TRANSPORT health: ок"; fi
        doh_follow_carrier ok       # несущая везёт ⇒ резолвер можно вернуть в туннель
        health_back   # бэкофф перебора и эпизод «интернета нет» закрыты: туннель жив ⇒ аплинк тоже
        # STATE обратно в NORMAL, если несущую подняли МИМО watchdog (типичный boot-race:
        # failopen поставил сам watchdog, а поднял транспорт heal.sh). В NORMAL его писали
        # ТОЛЬКО cross/failover-ветки → без этого STATE залипал в FAILOPEN на здоровом
        # туннеле, и статус/панель/меню врали «прямой режим». health прошёл → трафик идёт
        # через VPN = NORMAL. Идемпотентно: пишем, только если там не NORMAL.
        [ "$(cat "$STATE" 2>/dev/null)" = "NORMAL" ] || echo NORMAL > "$STATE"
        # Rule-heal: health прошёл (несущая xtun жива), но fw3-reload мог снести FORWARD/сплит —
        # переиграть правила, иначе клиент молча идёт мимо туннеля. [[boot-race-fw3-reload-wipes-rules]]
        split_rules_wiped "$TRANSPORT" && heal_split_rules "$TRANSPORT"
        # …и вторая половина того же вопроса: правила на месте, а САМ МАРШРУТ несущей пропал
        # (table 1000 пуста) ⇒ маркированный трафик молча идёт напрямую. См. carrier_route_lost.
        carrier_route_lost "$TRANSPORT" && heal_carrier_route "$TRANSPORT"
        # A: домашний транспорт = awg, а мы на tunnel (после cross) → вернуться на awg,
        # когда awg0 снова жив (он держит handshake тёплым резервом). Только mode=home,
        # троттл FAILBACK_INTERVAL. transport_home пуст → не трогаем (юзер не задавал).
        if [ "$(fo_mode)" = "home" ] && [ "$(transport_home)" = "awg" ] \
           && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
            ahs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$ahs" in ''|*[!0-9]*) ahs=0 ;; esac
            if [ "$ahs" -gt 0 ] && [ "$(age_since "$ahs")" -le "$HS_ALIVE" ]; then
                date +%s > "$FAILBACK_STAMP"
                log "home-transport: awg жив → возврат на AmneziaWG"
                sh "$TRANSPORT_SH" switch awg >>"$LOG" 2>&1   # релинквиш tunnel + подъём awg-несущей
            fi
        fi
        finish
    fi

    # …health НЕ прошёл. ПЕРЕД лестницей спрашиваем, есть ли на роутере сама программа: переезд
    # (импорт бэкапа принёс `.transport`, а бинарей тут не было ни разу) кончался письмом
    # «$TLABEL упал, резервы недоступны» — о падении того, что никогда не поднималось, — и
    # бесконечным перебором серверов, который делу не помогает. Состояние ставим честное (мы вне
    # туннеля) и говорим ОДИН раз: лечится не перебором, а установкой компонента.
    # МЕСТО ВАЖНО — строго ПОСЛЕ пробы health, а не до неё: у альтов бинарь ищется через bin_path,
    # то есть «программы нет» и «накопитель отвалился» — ОДИН ответ, а демон в этот момент жив в
    # памяти и туннель может везти. Спроси мы раньше — тик снимал бы с маршрута РАБОЧУЮ несущую.
    if ! carrier_installed "$TRANSPORT"; then
        if [ "$xcur" != FAILED ]; then
            log "transport=$TRANSPORT, но компонент не установлен — лестницу не кручу (ставить в панели: «Компоненты»)"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
            transport_missing_event "$TLABEL"
        fi
        finish
    fi

    # НЕСУЩУЮ ТОЛЬКО ЧТО ПОДНЯЛИ — не судим её вовсе (ни SUSPECT, ни лестница). Лок смены
    # транспорта к этому моменту уже снят (он держится до старта демонов, а не до рабочего
    # egress), поэтому гард выше сюда не достаёт. Ровно этот зазор красил живой канал в
    # «проверяю…» и мог отменить ручной выбор сервера авто-резервом.
    _cg=$(stamp_age "$CARRIER_UP_STAMP")
    if [ "$_cg" -lt "$CARRIER_GRACE" ]; then
        log "$TRANSPORT health: осечка, но несущую подняли ${_cg}с назад (грейс ${CARRIER_GRACE}с) — жду прогрева"
        finish
    fi

    # Первая осечка → SUSPECT, без действий: ждём подтверждения на след. тике (≈2 мин;
    # зеркало гистерезиса awg-handshake, чтобы не флапать на разовой пробе). Это и
    # начало нового эпизода аварии — сбрасываем episode-гард.
    if [ "$xcur" = "HEALTHY" ]; then
        echo SUSPECT > "$XSTATE"; episode_reset
        log "$TRANSPORT health: осечка (жду подтверждения на следующем тике)"
        # Резолвер уводим УЖЕ на первой осечке, не дожидаясь подтверждения: ждать нечего — если
        # несущая жива, вернём его следующим же тиком, а если мертва, то ровно в эти две минуты
        # человек и лезет менять сервер, и без DNS у него ничего не поднимется.
        doh_follow_carrier suspect
        finish
    fi

    # Интернета нет ВООБЩЕ (линк/дефолт лёг ИЛИ egress-проба через WAN не отвечает дважды
    # подряд) → ни один сервер/транспорт недостижим: перебор бессмыслен. Ждём восстановления
    # аплинка, не трогая транспорт (вернётся health сам).
    if ! inet_reachable; then
        log "$TRANSPORT health: провал, но интернета нет вообще — не перебираю, жду аплинка"
        exit 0
    fi

    mode=$(fo_mode)

    # --- МЫ УЖЕ В ПРЯМОМ РЕЖИМЕ (xcur=FAILED): лестницу крутим ПО ТРОТТЛУ, а не каждый тик ---
    # Симметрия с awg-веткой («уже FAILOPEN → повторная попытка по fo_retry»), но кап паузы свой —
    # TUNNEL_RETRY_MAX (там несущая остаётся тёплой, у нас снята; см. коммент к константе).
    # Без троттла тик раз в 2 мин звал failover, тот ФАЗОЙ 0 поднимал несущую под мёртвым VPS,
    # health проваливался — и так по кругу, оставляя блэкхол (см. ensure_direct_mode). Порядок
    # важен: СНАЧАЛА гарантируем прямой режим, и только потом решаем, пора ли пробовать снова —
    # иначе ожидание проходило бы с живым маршрутом в никуда. mode=off сюда не входит: там своя
    # терминальная ветка ниже (она несущую уже сняла и лестницу не крутит).
    if [ "$xcur" = FAILED ] && [ "$mode" != off ]; then
        ensure_direct_mode "$TRANSPORT"
        _ret=$(fo_retry); [ "$_ret" -gt "$TUNNEL_RETRY_MAX" ] && _ret=$TUNNEL_RETRY_MAX
        _left=$(( _ret - $(stamp_age "$FAILOVER_STAMP") ))
        if [ "$_left" -gt 0 ]; then
            log "$TRANSPORT мёртв, уже FAILOPEN — прямой режим (следующая попытка через $((_left / 60)) мин)"
            finish
        fi
        episode_reset   # свежая попытка ВСЕЙ лестницы: вдруг ожил другой транспорт
        log "$TRANSPORT всё ещё мёртв, FAILOPEN → повторная попытка восстановления"
    fi

    episode_add "$TRANSPORT"
    log "$TRANSPORT health: подтверждённый сбой (режим=$mode)"

    if [ "$mode" = "off" ]; then
        if have_awg; then
            log "$TRANSPORT режим=off → фолбэк на AmneziaWG"
            sh "$TRANSPORT_SH" switch awg >>"$LOG" 2>&1   # релинквиш tunnel + подъём awg-несущей + .transport=awg
            echo FAILED > "$XSTATE"
            ip=$(ext_ip)
            if [ "$NF_LANG" = en ]; then
                notify_ev "cross-switch" 0 "BE7000: $TLABEL went down -> back to AmneziaWG" \
"$TLABEL failed the health check (daemon/tunnel/egress probe).
Auto-failover is off (mode off) — the router returned to AmneziaWG (awg0).
External IP now: ${ip:-unknown}.
To turn $TLABEL back on: panel :8088 -> the VPN card."
            else
            notify_ev "cross-switch" 0 "BE7000: $TLABEL упал -> вернулись на AmneziaWG" \
"$TLABEL не прошёл проверку здоровья (демон/туннель/проба egress).
Авто-failover выключен (режим off) — роутер вернулся на AmneziaWG (awg0).
Внешний IP сейчас: ${ip:-неизвестен}.
Снова включить $TLABEL: панель :8088 -> карточка VPN."
            fi
        else
            # tunnel-only: возвращаться на awg НЕКУДА → прямой режим. Уведомляем ОДИН раз
            # (на переходе xcur!=FAILED): .transport остаётся прежним, иначе ветка крутила
            # бы down+письмо каждый тик. down в tunnel-only сам уводит в прямой (set_direct_dns).
            if [ "$xcur" != FAILED ]; then
                log "$TRANSPORT режим=off, awg не установлен → прямой режим (fail-open)"
                sh "$TRANSPORT_SH" down "$TRANSPORT" >>"$LOG" 2>&1
                echo FAILED > "$XSTATE"
                ip=$(ext_ip)
                if [ "$NF_LANG" = en ]; then
                    notify_ev "vpn-failopen" 0 "BE7000: $TLABEL went down -> direct mode" \
"$TLABEL failed the health check (daemon/tunnel/egress probe).
Auto-failover is off (mode off) and AmneziaWG is not installed — the router is in DIRECT
mode: traffic and DNS bypass the VPN (if the ISP link is up, the internet works),
listed sites are unavailable.
External IP now: ${ip:-unknown}.
To bring $TLABEL back up: panel :8088 -> the VPN card."
                else
                notify_ev "vpn-failopen" 0 "BE7000: $TLABEL упал -> прямой режим" \
"$TLABEL не прошёл проверку здоровья (демон/туннель/проба egress).
Авто-failover выключен (режим off), AmneziaWG не установлен — роутер в ПРЯМОМ
режиме: трафик и DNS идут мимо VPN (если связь с провайдером есть, интернет
работает), сайты из списка недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.
Снова поднять $TLABEL: панель :8088 -> карточка VPN."
                fi
            else
                # Повторные тики: письмо и переход не дублируем, но следим, что прямой режим не
                # разъехался — несущую мог поднять heal/установщик/ручной up, а VPS всё ещё мёртв.
                ensure_direct_mode "$TRANSPORT"
            fi
        fi
        finish
    fi

    # sticky/home → перебор резервов транспорта (внутри плагина: xray-configs/*.json и т.п.)
    log "→ перебор резервов $TRANSPORT"
    # Отметка ПОПЫТКИ (не результата) — от неё считает троттл повторов выше. Ставим до вызова:
    # свип может идти минуты, и «с момента прошлой попытки» честнее мерить от её начала.
    date +%s > "$FAILOVER_STAMP"
    if sh "$TRANSPORT_SH" failover "$TRANSPORT" >>"$LOG" 2>&1; then
        echo HEALTHY > "$XSTATE"
        log "$TRANSPORT-failover: встали на резервный сервер"
        finish
    fi

    # Пул транспорта исчерпан → эскалация. cross → следующий готовый транспорт по реестру
    # (transport.sh next, обычно awg — он первый; в tunnel-only его нет → cross_target пуст
    # → прямой режим, без попыток поднять отсутствующий awg0).
    esc=$(fo_escalate)
    other=$(sh "$TRANSPORT_SH" next "$TRANSPORT")
    if [ "$esc" = "cross" ] && [ -n "$other" ] && ! episode_has "$other"; then
        episode_add "$other"
        log "$TRANSPORT-пул исчерпан → cross: переключаюсь на $other"
        sh "$TRANSPORT_SH" switch "$other" >>"$LOG" 2>&1   # релинквиш tunnel + подъём несущей $other (switch уже записал .transport)
        # Несущая $other поднята; здоровье — через контракт плагина. Жив → остаёмся.
        if sh "$TRANSPORT_SH" health "$other" >/dev/null 2>&1; then
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: $other жив — остаёмся на нём"
        elif [ "$other" = "awg" ] && [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" failover >>"$LOG" 2>&1; then
            # awg: текущий default-конфиг мёртв → перебор awg-резервов (единый бэкенд switch-vpn;
            # do_failover здесь НЕзачем — он пропустил бы рабочий default по имени).
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: текущий awg мёртв → встали на awg-резерв"
        elif [ "$other" != "awg" ] && sh "$TRANSPORT_SH" failover "$other" >>"$LOG" 2>&1; then
            # tunnel-цель (hy2/…): перебор её собственных резервов
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: перебор резервов $other — встали"
        else
            echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
            log "cross: $other тоже недоступен → прямой режим"
            # …и прямой режим обязан быть НАСТОЯЩИМ: switch уже поднял несущую $other, а health
            # она не прошла — без снятия её default в table 1000 остался бы блэкхол на весь тик.
            # awg — исключение: его владелец safety_off (снимает маршрут, но awg0 СОЗНАТЕЛЬНО
            # держит тёплым резервом ради детекта оживления по handshake), и .transport=awg ⇒
            # следующий тик идёт awg-веткой, а не сюда.
            # Бэкофф растим и ЗДЕСЬ. Ветка «пул исчерпан» ниже до нас не доходит (cross кончается
            # своим finish), поэтому без этой строки конфигурация «два tunnel-транспорта без awg»
            # (xray+hy2) крутила бы полный свип ОБОИХ пулов каждые FAILOVER_RETRY=10 мин всю
            # аварию — с двумя `switch`, conntrack -F и рестартом dnsmasq, видимыми клиентам.
            # Кап: у awg-цели `.transport` уже переписан на awg ⇒ следующий тик пойдёт awg-веткой
            # с её собственным капом FAILOVER_MAX, поэтому сужать лестницу до TUNNEL_RETRY_MAX там
            # незачем (у awg несущая остаётся тёплой — см. коммент к константе).
            if [ "$other" = awg ]; then
                [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
                fo_backoff_bump
            else
                ensure_direct_mode "$other"
                fo_backoff_bump "$TUNNEL_RETRY_MAX"
            fi
        fi
        finish
    fi

    # direct, либо cross но цель уже пробована/отсутствует (анти-петля) → прямой режим.
    # Действуем и уведомляем ТОЛЬКО на переходе (xcur != FAILED): иначе при стойком сбое
    # (tunnel-only / исчерпанный cross) эта ветка крутилась бы каждый тик = спам.
    if [ "$xcur" != FAILED ]; then
        log "$TRANSPORT-пул исчерпан → прямой режим (escalate=$esc)"
        sh "$TRANSPORT_SH" down "$TRANSPORT" >>"$LOG" 2>&1
        [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
        echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
        ip=$(ext_ip)
        if [ "$NF_LANG" = en ]; then
            notify_ev "vpn-failopen" 0 "BE7000: $TLABEL and its backups are unreachable -> direct mode" \
"$TLABEL went down and none of its backups came up. The router is in DIRECT mode
(safety_off): traffic and DNS bypass the VPN — if the ISP link is up, the internet
works; listed sites are unavailable.
External IP now: ${ip:-unknown}.
To bring the VPN back by hand: panel :8088 -> the VPN card."
        else
        notify_ev "vpn-failopen" 0 "BE7000: $TLABEL и резервы недоступны -> прямой режим" \
"$TLABEL упал, и ни один его резерв не поднялся. Роутер в ПРЯМОМ режиме
(safety_off): трафик и DNS идут мимо VPN — если связь с провайдером есть,
интернет работает; сайты из списка недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.
Вернуть VPN вручную: панель :8088 -> карточка VPN."
        fi
        # Бэкофф тут НЕ растим: это ПЕРВЫЙ отказ эпизода, и первая повторная попытка должна
        # прийтись на базовые 10 мин (растим со второй — см. ветку ниже).
    else
        # Повторная попытка (по троттлу выше) провалилась. Растим паузу И ОБЯЗАТЕЛЬНО возвращаем
        # прямой режим: ФАЗА 0 плагина внутри failover могла поднять несущую под мёртвый VPS, а
        # письмо/переход здесь уже не повторяются — раньше на этом месте оставался блэкхол.
        fo_backoff_bump "$TUNNEL_RETRY_MAX"
        ensure_direct_mode "$TRANSPORT"
        log "$TRANSPORT-пул исчерпан, остаёмся в прямом режиме (escalate=$esc)"
    fi
    finish
fi

# awg0 ИСЧЕЗ при transport=awg (сюда доходим только с awg/пустым transport — tunnel-ветка
# отработала выше). Раньше тут был безусловный `ip link show awg0 || exit 0`: если демон
# amneziawg-go умер/убит OOM среди дня, TUN-интерфейс awg0 уходит вместе с процессом →
# сторож молча выходил, а heal.sh заперт boot-локом (1×/boot) и НЕ поднимет awg0 до ребута.
# При этом dnsmasq форвардит upstream в дохлый туннель → DNS-SPOF на всю сеть, safety_off
# никто не зовёт. Теперь: если awg установлен и WAN жив — уводим в fail-open (safety_off,
# DNS→публичный: снимаем SPOF немедленно) и СНИМАЕМ heal-лок, чтобы heal на следующем cron-тике
# (*/1) пересоздал awg0 (пересоздание несущей — его зона, не дублируем awg_setup тут). Когда
# handshake вернётся, следующий тик сторожа (ветка «VPS жив», cur=FAILOPEN) вернёт VPN-роутинг.
#
# ТЕКУЩИЙ РЕЖИМ читаем ЗДЕСЬ, а не после блока handshake ниже: ветка «awg0 исчез» сравнивает
# $cur с FAILOPEN, а переменная присваивалась ПОСЛЕ неё ⇒ была пуста ВСЕГДА, «переход» считался
# каждый тик и письмо «awg0 упал» уходило раз в 2 минуты, пока интерфейса нет (тот же класс
# шума, что и повод 03.08.2026; notify() тут прямой, без throttle и без журнала событий).
cur="NORMAL"
[ -f "$STATE" ] && cur=$(cat "$STATE")

if ! ip link show awg0 >/dev/null 2>&1; then
    if ! wan_up; then exit 0; fi    # WAN опущен: и чинить нечего, и свип выходов дал бы ложные отказы
    # КОМПОНЕНТА НЕТ ВООБЩЕ: `awg.conf` есть (намерение), а бинарей AmneziaWG на роутере не было
    # ни разу — типовой сценарий переезда «свежая установка + импорт бэкапа с другого роутера»
    # (замерено на AX3600 16.08.2026). Пересоздать awg0 нечем, и heal тут бессилен ПО ОПРЕДЕЛЕНИЮ,
    # а прежний код снимал ему лок КАЖДЫЕ две минуты — heal вечно гонял ПОЛНЫЙ бутовый сценарий
    # (cron/мин, до ребута), его вердикт слал письмо «после загрузки VPN НЕ поднялся», и человек
    # искал поломку там, где её нет: ставить надо компонент. Говорим ОДИН раз и называем лечение.
    # Ветку держим ВЫШЕ обычной: ниже awg.conf — единственный гард, и порядок тут и есть смысл.
    if [ -f "$ENODIA_STATE/awg.conf" ] && ! carrier_installed awg; then
        if [ "$cur" != "FAILOPEN" ]; then
            log "transport=awg, но компонент не установлен (бинарей нет) — heal-лок НЕ снимаю, пересоздавать awg0 нечем"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            transport_missing_event AmneziaWG
        fi
        finish
    fi
    if [ -f "$ENODIA_STATE/awg.conf" ]; then
        if [ "$cur" != "FAILOPEN" ]; then
            # ЧИНИМ ОДИНАКОВО, ГОВОРИМ РАЗНОЕ. Действие тут одно (снять DNS-SPOF + отдать heal'у
            # право пересоздать awg0), а вот повод — два: несущая УПАЛА или её ЕЩЁ НЕ ПОДНИМАЛИ
            # (компонент доехал после импорта бэкапа; `packages.sh` ставит, но не активирует).
            # Письмо «awg0 упал» во втором случае описывает падение того, чего не было, и человек
            # ищет аварию вместо того, чтобы просто дождаться heal (замерено на AX3600 17.08.2026:
            # письмо ушло через минуту после установки компонента, а ещё через минуту туннель
            # встал сам). Ответ даёт СВОЁ наблюдение — отметка $AWG0_SEEN, см. её у boot-grace.
            if [ ! -f "$AWG0_SEEN" ]; then
                log "transport=awg, но awg0 в эту загрузку ещё не поднимался (компонент/конфиг приехали позже) → safety_off + снимаю heal-лок; письма нет — это не падение"
                [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
                echo "FAILOPEN" > "$STATE"
                rm -f "$HEAL_LOCK" 2>/dev/null
                heal_reason carrier-not-up   # причина СВОЯ: в логе heal видно, что несущую поднимают ВПЕРВЫЕ, а не чинят падение
                finish
            fi
            log "awg0 ИСЧЕЗ при transport=awg → safety_off (снимаю DNS-SPOF) + снимаю heal-лок (heal пересоздаст awg0)"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            rm -f "$HEAL_LOCK" 2>/dev/null
            heal_reason carrier-lost
            ip=$(ext_ip)
            # ЧЕРЕЗ обёртку событий, а не прямым notify: повод повторяемый (демон может падать по
            # OOM раз за разом), а прямое письмо не троттлится и не попадает в «центр уведомлений»
            # панели — человек видел письма, а в истории роутера пусто.
            if [ "$NF_LANG" = en ]; then
                notify_ev "awg0-down" 3600 "BE7000: awg0 went down — direct mode" \
"The awg0 interface is gone (the amneziawg-go daemon died or was killed). The router is
temporarily in DIRECT mode: traffic and DNS bypass the VPN (with a live ISP link the
internet works), listed sites are unavailable.
Auto-recovery of awg0 is running (heal.sh).
External IP now: ${ip:-unknown}."
            else
            notify_ev "awg0-down" 3600 "BE7000: awg0 упал — прямой режим" \
"Интерфейс awg0 исчез (демон amneziawg-go умер/убит). Роутер временно в ПРЯМОМ
режиме: трафик и DNS идут мимо VPN (при живой связи с провайдером интернет
работает), сайты из списка недоступны.
Идёт авто-восстановление awg0 (heal.sh).
Внешний IP сейчас: ${ip:-неизвестен}."
            fi
        else
            rm -f "$HEAL_LOCK" 2>/dev/null   # уже FAILOPEN — просто дать heal попробовать поднять awg0
            heal_reason carrier-lost
            log "awg0 всё ещё отсутствует, уже FAILOPEN — снял heal-лок, жду heal"
        fi
    fi
    finish            # доп-выходы несут СВОИ несущие — их здоровье от awg0 не зависит
fi
[ -z "$WG" ] && finish   # без бинаря awg судить об основном туннеле нечем, а выходы сторожим

# Возраст последнего handshake. Считает age_since (clock-lib.sh), а НЕ «now - hs»: часы на роутере
# без RTC прыгают вперёд через ~13 мин после загрузки, и голая разность объявляла живой VPS мёртвым
# (замерено 10.08.2026: «77282с назад» при рукопожатии минуту назад ⇒ лестница failover на ровном
# месте). [[watchdog-clock-step-false-death]]
hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
age=$(age_since "$hs")

if [ "$age" -ge "$HS_DEAD" ]; then
    # ===== VPS не отвечает =====
    # Резолвер — из туннеля вон, по той же причине, что и у tunnel-транспортов: при DoH он заперт
    # маркой в awg0, и молчащий VPS означает дом без DNS. Ветку «интернета нет вообще» это не
    # портит: там DNS всё равно не работает, а правило снимется само на первом здоровом тике.
    doh_follow_carrier suspect
    # Интернета нет ВООБЩЕ → handshake устарел НЕ из-за VPS, а из-за отсутствия аплинка:
    # перебирать awg-резервы и cross-транспорты бессмысленно (все серверы недостижимы), да и
    # reup ниже рвал бы awg0 впустую. Просто ждём аплинк, состояние/маршруты не трогаем (трафика
    # всё равно нет; когда связь и VPS вернутся, handshake оживёт → ветка «VPS жив»).
    if ! inet_reachable; then
        log "VPS handshake устарел (${age}с), но интернета нет вообще — не перебираю, жду аплинка"
        exit 0
    fi
    # --- Reup: ОДИН переподъём ТЕКУЩЕЙ несущей ПЕРЕД перебором резервов ---
    # ГРАБЛЯ (железо 30.07.2026): «handshake устарел» ≠ «VPS умер». На буте heal поднимает awg0
    # на 39-й секунде аптайма — одновременно с fw3 reload и до того, как сеть устоялась; если
    # первый handshake не прошёл, несущая ЗАЛИПАЕТ (данных через туннель нет ⇒ инициировать
    # рукопожатие нечему), и живой сервер выглядит мёртвым. Сторож честно отрабатывал failover и
    # уводил на резерв, хотя исходный VPS отвечал за секунду — проверено тест-инстансом.
    # Симметрично byedpi (там смерть демона чинится НА МЕСТЕ через reup_carrier, а cross — только
    # если не вышло): сперва пересоздаём awg0 из ТЕКУЩЕГО конфига (конфиг НЕ меняем — это не
    # failover), и лишь если handshake так и не пришёл, идём по лестнице резервов.
    # Троттл обязателен: reup рвёт awg0 на несколько секунд, крутить его каждый тик нельзя.
    # Гейт [ -f awg.conf ]: без конфига пересоздавать нечего (hy2/xray-only установка).
    if [ "$cur" != "FAILOPEN" ] && [ -f "$ENODIA_STATE/awg.conf" ] && [ -f "$TRANSPORT_SH" ] \
       && [ "$(stamp_age "$REUP_STAMP")" -ge "$REUP_RETRY" ]; then
        date +%s > "$REUP_STAMP"
        log "handshake ${age}с → сперва ОДИН переподъём awg0 (резервы — только если не поможет)"
        ip link del awg0 2>/dev/null
        sh "$TRANSPORT_SH" up awg >>"$LOG" 2>&1
        i=0
        while [ "$i" -lt 25 ]; do
            sleep 1
            hs2=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$hs2" in
                ''|0) ;;
                *)  if [ "$(age_since "$hs2")" -lt "$HS_DEAD" ]; then
                        log "reup помог: handshake вернулся на текущем конфиге — резервы не трогаю"
                        finish
                    fi ;;
            esac
            i=$((i + 1))
        done
        log "reup не помог (handshake так и не пришёл) — иду по лестнице failover"
    fi
    mode=$(fo_mode)
    nbk=$(count_backups)
    if [ "$cur" != "FAILOPEN" ]; then
        # --- переход: VPS только что умер --- (новый эпизод аварии)
        episode_reset; episode_add awg; date +%s > "$FAILOVER_STAMP"
        if [ "$mode" != "off" ] && [ "$nbk" -ge 1 ] && [ -f "$SWITCH_VPN" ]; then
            # есть awg-резервы → перебор (письма шлёт switch-vpn); awg-пул исчерпан →
            # cross на другой транспорт (вариант A), иначе остаёмся в прямом режиме.
            log "VPS МЁРТВ (handshake ${age}с) → failover (режим=$mode, резервов=$nbk)"
            run_failover || cross_awg_to_other || fo_backoff_bump
        elif [ "$mode" != "off" ] && [ "$(fo_escalate)" = "cross" ] && [ -n "$(cross_target_from_awg)" ]; then
            # failover включён, awg-резервов нет → сразу cross на другой транспорт (A)
            log "VPS МЁРТВ (handshake ${age}с), awg-резервов нет → cross на другой транспорт"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            cross_awg_to_other || fo_backoff_bump
        else
            # режим off, либо нет ни awg-резервов, ни другого транспорта — классический fail-open
            log "VPS МЁРТВ (handshake ${age}с) → прямой режим (режим=$mode, резервов=$nbk)"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            active=$(cat "$ACTIVE_NAME" 2>/dev/null)
            ip=$(ext_ip)
            # «vpn-toggle меню → 9» — пункт из времён, когда сервером управляли по SSH. Сейчас
            # сервер меняют в панели, и совет вёл в никуда именно тогда, когда он нужен.
            if [ "$NF_LANG" = en ]; then
                notify_ev "vpn-failopen" 0 "BE7000: the VPN went down, direct mode" \
"The VPS does not answer (last handshake ${age} s ago).
Config: ${active:-?}.

The router switched to DIRECT mode: traffic and DNS bypass the VPN — if the ISP
link is up, the internet works; listed sites are temporarily unavailable.
External IP now: ${ip:-unknown}.

When the VPS comes back, the VPN returns automatically and a second email
arrives. If the VPS stays down for long — check it, or switch the server:
panel :8088 -> the VPN card."
            else
            notify_ev "vpn-failopen" 0 "BE7000: VPN упал, прямой режим" \
"VPS не отвечает (последний handshake ${age} сек назад).
Конфиг: ${active:-?}.

Роутер перешёл в ПРЯМОЙ режим: трафик и DNS идут мимо VPN — если связь
с провайдером есть, интернет работает; сайты из списка временно недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.

Когда VPS снова заработает, VPN вернётся автоматически и придёт
второе письмо. Если VPS долго не оживает — проверь его или смени
сервер: панель :8088 -> карточка VPN."
            fi
        fi
    else
        # --- уже FAILOPEN: периодически (троттл) пробуем восстановиться заново ---
        # Каждый ретрай = свежая попытка ВСЕЙ лестницы (awg-пул + cross на другой транспорт):
        # сбрасываем эпизод-гард, вдруг что-то ожило. Без флаппинга — раз в FAILOVER_RETRY.
        # Пауза между свипами РАСТЁТ (fo_retry: 10→20→40→80→120 мин), пока попытки безуспешны —
        # иначе исчерпанный пул перебирается всю ночь в одном ритме (повод 03.08.2026).
        if [ "$mode" != "off" ] && [ "$(stamp_age "$FAILOVER_STAMP")" -ge "$(fo_retry)" ]; then
            date +%s > "$FAILOVER_STAMP"; episode_reset; episode_add awg
            log "VPS всё ещё мёртв (${age}с), FAILOPEN → повторная попытка восстановления"
            if [ "$nbk" -ge 1 ] && [ -f "$SWITCH_VPN" ]; then
                run_failover || cross_awg_to_other || fo_backoff_bump
            else
                cross_awg_to_other || fo_backoff_bump
            fi
        else
            log "VPS всё ещё мёртв (${age}с), уже FAILOPEN — без изменений (следующая попытка через $(( ($(fo_retry) - $(stamp_age "$FAILOVER_STAMP")) / 60 )) мин)"
        fi
    fi
elif [ "$age" -le "$HS_ALIVE" ]; then
    # ===== VPS жив =====
    # Туннель здоров ⇒ прошлый reup-троттл своё отработал: снимаем штамп, чтобы СЛЕДУЮЩАЯ авария
    # снова получила попытку «починить на месте», а не упёрлась в остаток получасового окна.
    rm -f "$REUP_STAMP" 2>/dev/null
    health_back   # бэкофф перебора и эпизод «интернета нет» закрыты: handshake свежий ⇒ аплинк жив
    doh_follow_carrier ok       # awg0 везёт ⇒ резолвер можно вернуть в туннель
    if [ "$cur" = "FAILOPEN" ]; then
        log "VPS ОЖИЛ (handshake ${age}с назад) → возврат VPN"
        # 1) awg-несущая обратно: mark-core + transport-awg.sh up (default dev awg0 +
        #    FORWARD + MASQUERADE + туннельный DNS). Замена ретайрнутого split-route.sh.
        restore_awg_carrier
        # 2) DNS-upstream. ВЛАДЕЛЕЦ ОДИН — плагин: `restore_awg_carrier` выше уже позвал
        #    `transport-awg.sh up` → `restore_vpn_dns`, а тот ПЕРВОЙ строкой спрашивает
        #    `doh_apply_dns tunnel`. Здесь жил дубль мимо этого вопроса (ровно тот, что вырезали из
        #    switch-vpn.sh на ревью батча 4): он переписывал 00-upstream.conf туннельным адресом
        #    поверх 127.0.0.1#5053 и МОЛЧА выключал шифрованный DNS на каждом возврате из FAILOPEN.
        #    Починить это было некому — `doh_start` бежит, только когда демон УПАЛ, а он жив;
        #    панель при этом продолжала показывать «Шифрованный DNS: включён».
        #    Маршрут к резолверу и рестарт dnsmasq делает тот же `restore_vpn_dns` — второй раз не надо.
        if [ ! -f "$XT_AWG" ]; then
            # Старый layout без плагина: владельца DNS нет, пишем сами — как было.
            VPN_DNS=$(grep -E '^DNS\s*=' "$ENODIA_STATE/awg.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
            [ -z "$VPN_DNS" ] && VPN_DNS=172.29.172.254
            printf 'no-resolv\nserver=%s\n' "$VPN_DNS" > /etc/dnsmasq.d/00-upstream.conf
            ip route replace "$VPN_DNS/32" dev awg0 2>/dev/null
            /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
        fi
        echo "NORMAL" > "$STATE"; episode_reset   # эпизод аварии закрыт
        ip=$(ext_ip)
        if [ "$NF_LANG" = en ]; then
            notify_ev "vpn-restored" 0 "BE7000: the VPN is back" \
"The VPS answers again (last handshake ${age} s ago).
VPN routing and DNS through the tunnel are restored.
External IP: ${ip:-unknown}."
        else
        notify_ev "vpn-restored" 0 "BE7000: VPN восстановлен" \
"VPS снова отвечает (последний handshake ${age} сек назад).
Вернул VPN-роутинг и DNS через туннель.
Внешний IP: ${ip:-неизвестен}."
        fi
    else
        # Rule-heal: awg жив (handshake свежий) + NORMAL, но fw3-reload мог снести FORWARD/сплит
        # (mipctld-guard вернул бы лишь маркировку, не FORWARD несущей) → переиграть правила.
        # [[boot-race-fw3-reload-wipes-rules]]
        split_rules_wiped awg && heal_split_rules awg
        # …и вторая половина того же вопроса: правила на месте, а САМ МАРШРУТ несущей пропал
        # (table 1000 пуста) ⇒ маркированный трафик молча идёт напрямую. См. carrier_route_lost.
        carrier_route_lost awg && heal_carrier_route awg
        # ===== уже NORMAL: в режиме home пробуем вернуться на основной =====
        # После прошлого failover мы можем работать на РЕЗЕРВНОМ конфиге. Если
        # режим home и активный != основного — раз в FAILBACK_INTERVAL проверяем,
        # ожил ли основной: ping его Endpoint (НЕ срывая рабочий резерв), и при
        # успехе зовём switch-vpn <home> (он сам проверит handshake и при неудаче
        # откатится на текущий резерв). ICMP-проба — чтобы не дёргать рабочий
        # туннель впустую; если VPS блокирует ICMP, авто-возврат не сработает —
        # вернуться можно вручную (меню 9).
        home_t=$(transport_home)
        if [ "$(fo_mode)" = "home" ] && [ -n "$home_t" ] && [ "$home_t" != "awg" ] && transport_ready "$home_t" \
           && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
            # ===== home-транспорт = tunnel (xray/hy2), а мы на awg (после cross) → вернуться на него =====
            # Reality/маскирующиеся туннели НЕ отвечают на ICMP и неотличимы по TCP (под HTTPS)
            # → «ожил ли сервер» надёжно проверяется ТОЛЬКО подъёмом транспорта + egress-пробой.
            # Делаем редко (FAILBACK_INTERVAL) и откатываемся на awg, если не встал. Это
            # opt-in (mode=home): краткая просадка раз в интервал, пока домашний транспорт мёртв.
            home_lbl=$(transport_label "$home_t")
            date +%s > "$FAILBACK_STAMP"
            log "home-transport: проба возврата на домашний $home_lbl (подъём + egress-проба)"
            sh "$TRANSPORT_SH" switch "$home_t" >>"$LOG" 2>&1   # оркестратор: релинквиш awg + mark-core + подъём $home_t
            if sh "$TRANSPORT_SH" health "$home_t" >/dev/null 2>&1; then
                echo HEALTHY > "$XSTATE"; log "home-transport: вернулись на $home_lbl"
            else
                sh "$TRANSPORT_SH" switch awg >>"$LOG" 2>&1; log "home-transport: $home_lbl ещё мёртв — остаёмся на awg"
            fi
        elif [ "$(fo_mode)" = "home" ]; then
            home=$(cat "$FAILOVER_HOME_FILE" 2>/dev/null)
            [ -z "$home" ] && home="default"
            active=$(cat "$ACTIVE_NAME" 2>/dev/null)
            if [ -n "$active" ] && [ "$active" != "$home" ] \
               && [ -f "$CONFIGS_DIR/$home.conf" ] && [ -f "$SWITCH_VPN" ] \
               && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
                date +%s > "$FAILBACK_STAMP"
                ep=$(grep -E '^Endpoint' "$CONFIGS_DIR/$home.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//' | tr -d ' ')
                if [ -n "$ep" ] && ping -c 1 -W 2 "$ep" >/dev/null 2>&1; then
                    log "home-failback: основной '$home' (endpoint $ep) ожил → возврат"
                    sh "$SWITCH_VPN" "$home" >>"$LOG" 2>&1
                else
                    log "home-failback: основной '$home' ещё недоступен — остаёмся на '$active'"
                fi
            fi
        fi
    fi
fi
# Зона ${HS_ALIVE}..${HS_DEAD} — гистерезис, режим не трогаем.

# --- ХВОСТ ТИКА: сюда доходят awg-ветки (NORMAL/FAILOPEN/гистерезис), которые НЕ вышли раньше ---
# Выход ТОЛЬКО через finish(), как и у всех прочих путей. ГРАБЛЯ (ревью 09.08.2026): раньше здесь
# стоял голый `slot_health_sweep; exit 0` — свипы перечислялись ВТОРОЙ копией, и всё, что дописали
# в finish() позже, на awg просто не бежало. Цена: на каноничном роутере (.transport=awg) тик
# живости авто-DoH не выполнялся НИ РАЗУ — в том числе в fail-open, где авто-DoH как раз и
# взводится (safety_off → doh_apply_dns direct), то есть ровно в сценарии, ради которого он
# написан; тем же путём терялся периодический прогрев доменных правил. Новый свип дописывают
# в finish() и НИКОГДА сюда.
finish
