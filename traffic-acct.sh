#!/bin/sh
# traffic-acct.sh — фоновый НАКОПИТЕЛЬ трафика для веб-панели (cron */5).
#
# Зачем: счётчики /proc/net/dev (awg0/xtun = VPN-несущая, eth0 = WAN) КУМУЛЯТИВНЫ и
# обнуляются при ребуте и смене транспорта (TUN-iface пересоздаётся). Чтобы панель
# показывала «за сегодня/неделю/месяц/год», копим ДЕЛЬТЫ в посуточный файл на /data
# (он переживает ребут, в отличие от RAM-счётчиков). Обнуление счётчика ТОГО ЖЕ iface
# (стал меньше прошлого) → дельта = текущее значение (отсчёт от 0); а вот СМЕНА iface
# = «истории под этим именем нет» → интервал пропускаем, см. разбор у dvrx ниже.
#
# Почему cron, а не CGI: учёт должен идти и когда панель закрыта. Почему счётчики
# /proc/net/dev, а не iptables/conntrack по IP: Qualcomm NSS/ECM-offload уводит потоки
# мимо netfilter → per-IP учёт недостоверен (см. CLAUDE.md). awg0/xtun — userspace-TUN,
# их счётчики offload переживают. Флеш-износ: файл крошечный (≤~25 КБ), перезапись раз
# в 5 мин под UBIFS wear-leveling безопасна.
ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
LAST="$ENODIA_STATE/.traffic-last"      # сырой прошлый замер: "vif vrx vtx wrx wtx wif" (wif дописан
                                   # В КОНЕЦ — старый файл из пяти полей читается как прежде;
                                   # формат — КОНТРАКТ с web/cgi-bin/traffic, править ОБА)
DAILY="$ENODIA_STATE/.traffic-daily"    # посуточно: "epoch YYYY-MM-DD vrx vtx wrx wtx"
LOCK=/tmp/traffic-acct.lock
KEEP=400                           # сколько последних дней хранить (>1 года)

# Лок с ОТМЕТКОЙ ВРЕМЕНИ: убитый -9 (или зависший на awk по большому файлу) тик оставлял бы
# пустой файл навсегда, и учёт трафика молча умирал до ребута — панель показывала бы «за сегодня»
# на момент смерти. Протухший лок перехватываем (то же сделано в watchdog.sh).
LOCK_STALE=${LOCK_STALE:-3600}
# Возраст лока — через age_since (clock-lib.sh): лок в /tmp рождается после загрузки, а часы без RTC
# прыгают вперёд через ~13 мин ⇒ голая разность объявляет живой лок протухшим и пускает второй тик
# считать те же дельты. Шим = прежнее поведение. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
if [ -e "$LOCK" ]; then
    _lt=$(cat "$LOCK" 2>/dev/null); case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
    [ "$(age_since "$_lt")" -lt "$LOCK_STALE" ] && exit 0
fi
date +%s > "$LOCK"; trap 'rm -f "$LOCK"' EXIT INT TERM HUP

# Часы ещё не выставлены? У BE7000 НЕТ RTC — после холодного ребута время неверно,
# пока не отработает ntpsetclock (cron */15). Пропускаем тик, иначе записали бы дельту
# с битой датой (напр. 1970-01-01) — осиротевшая строка в истории. Следующий тик после
# синхронизации часов учтёт накопленный трафик (дельта считается от .traffic-last).
[ "$(date +%s)" -lt 1700000000 ] && exit 0

# trim + дефолт: `cat || echo awg` НЕ ловит пустой-но-существующий .transport (t="" → vif=xtun, и
# трафик awg0 молча считался бы нулём). Зеркало той же строки в cgi-bin/traffic — читатель эту
# граблю уже пережил, писатель отстал.
t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
# Пусто = ЛИБО роутер старше флага (несущая awg), ЛИБО установка «только панель», где транспорта
# нет вовсе; отличает их оркестратор (код 2 = старая копия ⇒ как раньше). Зеркало вилки в
# cgi-bin/traffic — читатель и писатель обязаны звать один и тот же интерфейс.
if [ -z "$t" ]; then
    t=awg
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
        [ "$?" = 1 ] && t=none
    fi
fi
# «-», а НЕ пустая строка: `.traffic-last` читается через `read vif vrx vtx wrx wtx wif`, и пустое
# первое поле сдвинуло бы ВСЕ остальные (та же грабля, из-за которой в файл добавляли шестое поле).
# zapret — В ОДНОЙ ВЕТКЕ С none: несущей у десинка нет ВООБЩЕ, весь трафик идёт напрямую, и
# `*)` записывал бы счётчики несуществующего xtun. Ту же вилку держит web/cgi-bin/traffic —
# правя одну, правь обе (у него ветка та же, но пишет он "" вместо "-": читателю пустое поле
# не мешает, а нам сдвинуло бы все остальные при `read`).
case "$t" in none|zapret) vif="-" ;; awg) vif=awg0 ;; *) vif=xtun ;; esac
wan_if=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

# "rx tx" по имени iface; нет iface → "0 0". sed снимает двоеточие (счётчик может
# слипнуться с именем без пробела: "eth0:39189...").
devbytes() { sed 's/:/ /' /proc/net/dev 2>/dev/null | awk -v i="$1" '$1==i{print $2" "$10; f=1} END{if(!f)print "0 0"}'; }
set -- $(devbytes "$vif");          vrx=${1:-0}; vtx=${2:-0}
set -- $(devbytes "${wan_if:-_}");  wrx=${1:-0}; wtx=${2:-0}

# прошлый замер
lvif=""; lvrx=0; lvtx=0; lwrx=0; lwtx=0; lwif=""
[ -f "$LAST" ] && read lvif lvrx lvtx lwrx lwtx lwif < "$LAST"
for n in lvrx lvtx lwrx lwtx; do eval "x=\$$n"; case "$x" in ''|*[!0-9]*) eval "$n=0";; esac; done

# WAN-iface ПРОПАЛ (нет дефолт-маршрута: пере-дозвон PPPoE, флап порта, авария провайдера — то
# есть ровно те моменты, ради которых учёт и ведут). devbytes отдаёт "0 0", и прежний код писал
# эти НУЛИ в .traffic-last: на СЛЕДУЮЩЕМ тике wrx(реальный, кумулятивный с буста) >= lwrx(0) ⇒
# дельта = ВЕСЬ счётчик eth0 ⇒ в «сегодня» прилетали десятки гигабайт, которых не было.
# Правильно — не судить: переносим прошлый замер как есть (дельта 0), а когда iface вернётся,
# дельта честно посчитается за весь пропуск. Имя iface теперь тоже в файле: смена (eth0→pppoe-wan)
# = чужой счётчик, трактуем как обнуление — зеркало логики vif.
if [ -z "$wan_if" ]; then
    wan_if="$lwif"; wrx=$lwrx; wtx=$lwtx
fi

had_last=0; [ -f "$LAST" ] && had_last=1
printf '%s %s %s %s %s %s\n' "$vif" "$vrx" "$vtx" "$wrx" "$wtx" "${wan_if:-?}" > "$LAST"   # для следующей дельты
# Первый запуск (нет прошлого замера) — НЕ вкидываем «всё с буста» в сегодня.
[ "$had_last" = 0 ] && exit 0

# Дельты через awk (double, точно до 2^53 ≈ 9 ПБ) — НЕ через $(()) (busybox-арифметика
# может быть 32-битной, а eth0-счётчик уже >2^31). Детект обнуления/смены несущей.
# lwif пустой = файл СТАРОГО формата (пять полей): судим как раньше, только по счётчику.
deltas=$(awk -v vif="$vif" -v lvif="$lvif" -v vrx="$vrx" -v vtx="$vtx" -v wrx="$wrx" -v wtx="$wtx" \
             -v lvrx="$lvrx" -v lvtx="$lvtx" -v lwrx="$lwrx" -v lwtx="$lwtx" \
             -v wif="$wan_if" -v lwif="$lwif" 'BEGIN{
    OFMT="%.0f"; CONVFMT="%.0f";
    wsame=(lwif=="" || wif==lwif);   # lwif пуст = файл СТАРОГО формата: судим только по счётчику
    wunk=(lwif=="?");                # в прошлый замер WAN-iface не существовало и истории нет:
                                     # сравнивать не с чем ⇒ ЧЕСТНЕЕ пропустить интервал (0), чем
                                     # засчитать «сегодня» весь кумулятивный счётчик с буста
    # СМЕНИЛСЯ IFACE ⇒ интервал ПРОПУСКАЕМ (0), а не заряжаем весь счётчик нового имени. Счётчик
    # интерфейса кумулятивен с его СОЗДАНИЯ, а старый iface при смене остаётся жив: awg0 при
    # активном xray — «тёплый резерв», eth0 — под pppoe-wan. Возврат на него (ручное переключение,
    # cross-failover, редозвон) заряжал в «сегодня» ВСЁ, что уже учли до отхода. Замерено на
    # импорте бэкапа BE7000 (AX3600, 17.08.2026): за 08-14 «через VPN» 64.5 ГБ против 31.6 ГБ
    # «через WAN» — физически невозможно, VPN всегда ПОДМНОЖЕСТВО WAN, и панель печатала
    # «через VPN 60.2 ГБ · напрямую 0 Б · всего 29.5 ГБ». Истории под новым именем у нас нет ⇒
    # честнее потерять один пятиминутный интервал (та же логика, что у wunk выше).
    # ЧИТАТЕЛЬ (web/cgi-bin/traffic, «незаписанная дельта») так считает С САМОГО НАЧАЛА — это
    # ВТОРОЙ случай, когда писатель отстал от читателя в ОДНОМ контракте (первый — вилка `none`
    # выше). Правя одну сторону, сверяй обе.
    dvrx=(vif==lvif && vrx>=lvrx)?vrx-lvrx:(vif==lvif?vrx:0);
    dvtx=(vif==lvif && vtx>=lvtx)?vtx-lvtx:(vif==lvif?vtx:0);
    dwrx=wunk?0:((wsame && wrx>=lwrx)?wrx-lwrx:(wsame?wrx:0));
    dwtx=wunk?0:((wsame && wtx>=lwtx)?wtx-lwtx:(wsame?wtx:0));
    printf "%.0f %.0f %.0f %.0f", dvrx,dvtx,dwrx,dwtx
}')
set -- $deltas; dvrx=${1:-0}; dvtx=${2:-0}; dwrx=${3:-0}; dwtx=${4:-0}

now=$(date +%s); today=$(date +%F)
[ -f "$DAILY" ] || : > "$DAILY"
# Прибавить дельты к сегодняшней строке (или создать). CONVFMT=%.0f — иначе awk при
# пересборке $0 отформатировал бы большие числа как "1.23e+09" и побил бы значения.
awk -v today="$today" -v now="$now" -v a="$dvrx" -v b="$dvtx" -v c="$dwrx" -v d="$dwtx" 'BEGIN{OFMT="%.0f";CONVFMT="%.0f"}
  $2==today { $3+=a; $4+=b; $5+=c; $6+=d; seen=1 }
  { print }
  END { if(!seen) printf "%.0f %s %.0f %.0f %.0f %.0f\n", now, today, a, b, c, d }
' "$DAILY" > "$DAILY.tmp" && mv "$DAILY.tmp" "$DAILY"

# подрезать историю до KEEP последних дней
lines=$(wc -l < "$DAILY" 2>/dev/null); case "$lines" in ''|*[!0-9]*) lines=0;; esac
[ "$lines" -gt "$KEEP" ] && { tail -n "$KEEP" "$DAILY" > "$DAILY.tmp" && mv "$DAILY.tmp" "$DAILY"; }
exit 0
