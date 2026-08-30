#!/bin/sh
# usb-offload.sh — ДВИЖОК внешнего накопителя: смонтировать «наше» хранилище и переселить на
# него тяжёлые бинари (и вернуть обратно). Пара к store-lib.sh: тот ОТВЕЧАЕТ, где лежит бинарь,
# этот — ДЕЛАЕТ так, чтобы ответ был правдой.
#
# ЗАЧЕМ. /data на BE7000 = 20.6 МБ, и 13.4 из 14.3 МБ бинарей — это ДВА файла (xray 8.2 +
# hysteria 5.2). Отсюда весь блок «альты взаимоисключающи»: три транспорта разом просто не
# влезают. Накопитель снимает потолок, но остаётся ОПЦИЕЙ: у большинства флешки нет и не будет,
# поэтому без маркера .bin-store каждый верб здесь — no-op, а роутер работает как прежде.
#
# ГРАНИЦА «что уезжает» ЖИВЁТ НЕ ЗДЕСЬ, а в store-lib.sh ($STORE_MOVABLE): движок обязан
# двигать ровно то, что резолвер потом найдёт. Два списка разъехались бы на первой же правке.
#
# ИДЕНТИЧНОСТЬ НАКОПИТЕЛЯ — ПО СЕНТИНЕЛУ, не по устройству и не по точке монтирования:
# `blkid` на роутере НЕТ, имя sdX динамическое (на переткычке ядро давало то sda, то sdb),
# серийник тома есть только у exFAT. Ищем каталог с $STORE_SENTINEL — это работает при любой
# ФС, любой букве и нескольких воткнутых накопителях.
#
# СВОЙ МОНТАЖ НУЖЕН В ЛЮБОМ СЛУЧАЕ, хотя сток монтирует флешку сам (/mnt/usb-<серийник>,
# hotplug.d/block): /mnt — ramfs, стоковый automount асинхронен нашему cron, и рассчитывать на
# то, что к первому тику heal.sh флешка уже смонтирована, нельзя. Порядок такой: сперва ищем
# УЖЕ смонтированное (не плодим второй монтаж того же устройства — на FAT/exFAT два писателя
# = битая ФС), и только если не нашли — монтируем сами в $MNT.
#
# МАРКЕР — СЛЕД, А НЕ КОНФИГ. Точка монтирования от загрузки к загрузке может меняться, поэтому
# mount-ensure ПЕРЕПИСЫВАЕТ .bin-store фактическим путём. Протухший маркер безопасен: store-lib
# на каждом source проверяет сентинел и молча возвращается к резидентным путям.
#
# ПЕРЕЕЗД — С ПРОВЕРКОЙ, А НЕ `mv`. Бинарь, который несёт трафик, нельзя потерять из-за битой
# копии: сперва копия + md5 + запуск («ELF реально исполняется с этой ФС» — ровно то, что
# проверял спайк), и только потом удаление исходника. Не сошлось — файл остаётся резидентным,
# остальные едут дальше: СМЕШАННАЯ раскладка законна (store-lib судит по факту, не по реестру).
#
# rm живёт ЗДЕСЬ (PS-guard на литерал rm). НЕ используем set -e — шаги best-effort.
#
# Вербы:
#   usb-offload.sh detect            — какие накопители видит роутер (TSV: dev fs точка наш?)
#   usb-offload.sh mount-ensure      — идемпотентно сделать хранилище доступным (boot/hotplug)
#   usb-offload.sh enable [dev|точка] — подготовить хранилище и переселить на него тяжёлые бинари
#   usb-offload.sh disable           — вернуть всё на /data и забыть накопитель
#   usb-offload.sh status            — человеку: где что лежит и сколько где свободно
#   usb-offload.sh json              — то же машине (панель)

ENODIA_DIR=/data/usr/app/enodia
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}

# store-lib.sh — REQUIRED: без него у движка нет ни маркера, ни списка «что можно выносить».
# Шима тут быть не может (в отличие от потребителей bin_path): нечего было бы двигать.
# Гард `if [ -f ]` обязателен: провалившийся `.` в busybox ash убивает шелл НА МЕСТЕ (см. шапку
# store-lib.sh) — без гарда сообщение ниже не напечаталось бы никогда, а панель получила бы
# пустой ответ CGI, то есть «сбой запроса» вместо «обнови скрипты».
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
if ! command -v bin_dest >/dev/null 2>&1 || [ -z "$STORE_SUB" ] || [ -z "$STORE_MNT" ] || [ -z "$DATA_RESERVE_B" ]; then
    echo "нет store-lib.sh (или он старый) — обнови скрипты" >&2
    exit 1
fi

# Раскладка ($STORE_SUB), своя точка монтирования ($STORE_MNT) и резерв /data ($DATA_RESERVE_B)
# приходят из store-lib.sh: их знает не только движок, но и uninstall.sh с packages.sh.
MNT="$STORE_MNT"
MISS_STAMP=/tmp/.usb-offload-missing   # «уже говорили, что накопителя нет» — /tmp=RAM, живёт до ребута
DEDUP_STAMP=/tmp/.usb-offload-dedup    # «дубли уже разбирали в эту загрузку» (см. resolve_dups)

# --- примитивы --------------------------------------------------------------------------

# Свободно/всего байт на ФС, которой принадлежит путь. df -k: busybox печатает 1К-блоки,
# у разных сборок разное число колонок ⇒ считаем от КОНЦА строки (NF), как в packages.sh.
# ВСЕГДА печатаем число: пустой ответ df (нет пути, чужой формат) уходил бы в json панели
# как `"data_free_b":,` — синтаксически битый JSON, то есть «карточка не открылась».
num()        { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }
df_free_b()  { num "$(df -k "$1" 2>/dev/null | tail -1 | awk 'NF>=5{printf "%.0f", $(NF-2)*1024}')"; }
df_total_b() { num "$(df -k "$1" 2>/dev/null | tail -1 | awk 'NF>=5{printf "%.0f", $(NF-4)*1024}')"; }
size_b()     { _n=$(stat -c%s "$1" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac; printf '%s' "$_n"; }
mb()         { _v=${1:-0}; echo "$((_v/1048576)).$(( (_v%1048576)*10/1048576 ))"; }

# Сколько на накопителе занимаем МЫ — du по каталогу-хранилищу, а не сумма size_b бинарей:
# на FAT/exFAT кластер крупный, и «сколько файл весит» расходится с «сколько он занял» тем
# сильнее, чем мельче файл. ЧУЖОЕ (файлы юзера) НЕ обходим ни здесь, ни где-либо ещё: его
# объём панель считает разностью с df — гулять по чужой файлопомойке ради цифры незачем, да
# и du по гигабайтам чужого добра стоил бы секунд на каждом открытии карточки.
du_b() {
    _k=$(du -xsk "$1" 2>/dev/null | awk 'NR==1{print $1}')
    case "$_k" in ''|*[!0-9]*) _k=0 ;; esac
    printf '%s' "$((_k * 1024))"
}

# ФС точки монтирования — из /proc/mounts (третье поле). `mount` без аргументов на busybox
# печатает то же самое, но /proc/mounts не зависит от наличия /etc/mtab.
fs_of_mount() {
    while read -r _d _m _t _rest; do
        [ "$_m" = "$1" ] && { printf '%s' "$_t"; return 0; }
    done < /proc/mounts
    return 1
}

# Каталог-хранилище внутри точки монтирования, если он НАШ (иначе пусто).
store_of_mount() { [ -f "$1/$STORE_SUB/$STORE_SENTINEL" ] && printf '%s' "$1/$STORE_SUB"; }

# Уже смонтированное хранилище (обошли /proc/mounts). Стоковый automount отрабатывает раньше нас
# в большинстве загрузок — тогда своей точки не заводим вовсе.
find_mounted_store() {
    while read -r _d _m _t _rest; do
        case "$_d" in /dev/sd*) ;; *) continue ;; esac
        _s=$(store_of_mount "$_m")
        [ -n "$_s" ] && { printf '%s' "$_s"; return 0; }
    done < /proc/mounts
    return 1
}

# Разделы-кандидаты, которые ЕЩЁ НЕ смонтированы. Разделы первыми, целое устройство — следом:
# ФС прямо на устройстве (без таблицы разделов) редка, но встречается, а неудачный mount дёшев.
mount_candidates() {
    while read -r _maj _min _blk _name; do
        case "$_name" in sd[a-z][0-9]*) ;; *) continue ;; esac
        [ -b "/dev/$_name" ] || continue
        grep -q "^/dev/$_name " /proc/mounts && continue
        printf '/dev/%s\n' "$_name"
    done < /proc/partitions
    while read -r _maj _min _blk _name; do
        case "$_name" in sd[a-z]) ;; *) continue ;; esac
        [ -b "/dev/$_name" ] || continue
        grep -q "^/dev/$_name " /proc/mounts && continue
        printf '/dev/%s\n' "$_name"
    done < /proc/partitions
}

# Смонтировать что угодно в $2. АВТОДЕТЕКТ ФС: сперва `-t auto` (busybox перебирает
# /proc/filesystems сам), затем явный перебор — на стоке есть exfat/ext4/vfat/ntfs3.
# fmask/dmask ставят FAT-семейству права 0777 (иначе бинарь на exFAT не исполняемый), а ext4
# такие опции ОТВЕРГАЕТ ⇒ каждый тип пробуем дважды: с опциями и без.
try_mount() {
    for _t in auto exfat ext4 vfat ntfs3 ntfs ext3 ext2; do
        case "$_t" in
            ext*) _o="rw,noatime" ;;
            *)    _o="rw,noatime,fmask=0000,dmask=0000" ;;
        esac
        mount -t "$_t" -o "$_o" "$1" "$2" 2>/dev/null && return 0
        mount -t "$_t" "$1" "$2" 2>/dev/null && return 0
    done
    return 1
}

# ПРОБА чужого накопителя — ТОЛЬКО на чтение. Нас зовёт cron: mount-ensure перебирает кандидатов
# на КАЖДОМ тике сторожа (2 минуты), пока маркер есть, а нашего хранилища нет — то есть ровно
# тогда, когда в порт воткнута ЧУЖАЯ флешка. Монтировать чужие данные на запись 720 раз в сутки
# только чтобы прочитать сентинел — так нельзя: у exFAT/NTFS каждый rw-цикл ставит и снимает
# «грязный» бит тома, и обрыв питания в этот момент бьёт файлы пользователя, а не наши.
# Опознали своё — размонтируем и поднимем заново на запись через try_mount (перемонтировать
# `remount,rw` мало: fmask/dmask у FAT-семейства задаются только при монтировании, а без них
# бинарь на флешке не исполняемый).
try_mount_ro() {
    for _t in auto exfat ext4 vfat ntfs3 ntfs ext3 ext2; do
        mount -t "$_t" -o ro "$1" "$2" 2>/dev/null && return 0
    done
    return 1
}

# Записать/снять маркер и ПЕРЕСЧИТАТЬ резолвер: store-lib вычисляет STORE_DIR/BIN_DIR при
# source, поэтому после смены маркера его надо перечитать — иначе bin_dest в этом же процессе
# продолжит указывать на старое место.
# Гард `if [ -f ]` и здесь: файл проверен на старте, но исчезни он к этому моменту (обновление
# скриптов ровно в этот миг) — без гарда мы умерли бы ПОСРЕДИ переезда, а так просто доработаем
# со старым резолвером.
mark_write() { printf '%s\n' "$1" > "$STORE_MARK"; if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi; }
mark_drop()  { rm -f "$STORE_MARK"; if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi; }

# Запускается ли файл С ЭТОЙ ФС. Коды 126 (не исполняемый) и 127 (не найден) — единственные
# «нет»; всё прочее, включая ошибку самого бинаря и таймаут, означает «ядро его запустило».
# Универсально по бинарям: у каждого свои ключи, и таблица «чем проверять xray, а чем nfqws»
# протухла бы на первой новой связке. Снятый риск — не exec-бит (его даёт fmask), а
# самораспаковка UPX: ей нужен анонимный исполняемый маппинг.
#
# ЗАВЕДОМО НЕВЕРНЫЙ АРГУМЕНТ ОБЯЗАТЕЛЕН, и это не косметика. Без аргументов ciadpi не «стартует
# и выходит», а штатно поднимает SOCKS на СВОИХ дефолтах — 0.0.0.0:1080, и здесь ещё и от root
# (весь остальной проект зовёт его `-c nobody -i 127.0.0.1`). При стоковой политике INPUT=ACCEPT
# это открытый прокси, видимый из LAN и гостевой, на каждом enable/disable. Getopt/cobra у всех
# пятерых отвергают неизвестный ключ и выходят сразу, а exec и распаковка UPX к этому моменту
# уже случились — то есть проба меряет ровно то же, но ничего не слушает.
# cd /tmp: демоны без аргументов читают конфиг из текущего каталога, и делать это в $ENODIA_DIR
# незачем; 3 с — потолок на случай бинаря, который неизвестный ключ проглотит.
exec_ok() {
    ( cd /tmp 2>/dev/null && timeout -t 3 "$1" --be7000-exec-probe >/dev/null 2>&1 )
    _rc=$?
    [ "$_rc" != 126 ] && [ "$_rc" != 127 ]
}

md5_of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Хвосты прерванного переезда (питание, выдернутая флешка). Сами они не рассосутся: clean.sh
# знает про `*.new` ТОЛЬКО в $ENODIA_DIR, а на накопителе это до 8.2 МБ, которые du_b честно запишет
# в «наше» — и человек увидит, что хранилище занимает вдвое больше, чем в нём лежит. Метём ИМЕНА
# ИЗ СПИСКА, а не маску `*.new`: рядом ходит apply-scripts, который пишет `<скрипт>.sh.new`, и
# снести его на полпути — уже наша поломка, а не уборка.
drop_stale_new() {
    for _sn in $STORE_MOVABLE; do
        rm -f "$ENODIA_BIN/$_sn.new" 2>/dev/null
        [ "$BIN_DIR" != "$ENODIA_BIN" ] && rm -f "$BIN_DIR/$_sn.new" 2>/dev/null
    done
    return 0
}

# Переселить ОДИН бинарь: копия → sync → сверка md5 → проба запуска → и только потом удаление
# исходника. Порядок именно такой: до последнего шага рабочий файл на месте, а прервись мы в
# любой точке — хуже некуда не станет (две одинаковые копии безопасны, bin_path возьмёт любую).
move_verified() {   # $1 = откуда, $2 = куда, $3 = имя для лога
    _sz=$(size_b "$1")
    _dstdir=${2%/*}
    mkdir -p "$_dstdir" 2>/dev/null
    _free=$(df_free_b "$_dstdir"); case "$_free" in ''|*[!0-9]*) _free=0 ;; esac
    if [ "$_free" -lt "$((_sz + 262144))" ]; then
        echo "  $3: не хватает места в $_dstdir ($(mb "$_free") МБ) — пропускаю"
        return 1
    fi
    rm -f "$2.new" 2>/dev/null
    if ! cp "$1" "$2.new" 2>/dev/null; then
        echo "  $3: не скопировался — пропускаю"; rm -f "$2.new" 2>/dev/null; return 1
    fi
    chmod +x "$2.new" 2>/dev/null      # на exFAT/NTFS права даёт монтирование, chmod там no-op
    sync
    if [ "$(md5_of "$1")" != "$(md5_of "$2.new")" ]; then
        echo "  $3: копия не сошлась по md5 — оставляю на месте"; rm -f "$2.new" 2>/dev/null; return 1
    fi
    if ! exec_ok "$2.new"; then
        echo "  $3: с этой ФС не запускается (noexec?) — оставляю на месте"; rm -f "$2.new" 2>/dev/null; return 1
    fi
    if ! mv -f "$2.new" "$2" 2>/dev/null; then
        echo "  $3: не встал на место — оставляю на месте"; rm -f "$2.new" 2>/dev/null; return 1
    fi
    rm -f "$1" 2>/dev/null
    sync
    echo "  $3: $(mb "$_sz") МБ → $_dstdir"
    return 0
}

# ДВЕ КОПИИ ОДНОГО БИНАРЯ — разбираем в момент, когда хранилище снова доступно.
#
# Откуда они берутся. Пока накопителя нет, store_ready ложно ⇒ bin_dest указывает на /data, и
# установка/обновление кладут бинарь ТУДА. Снять при этом копию с накопителя bin_prune не может
# (BIN_DIR = ENODIA_DIR, накопителя-то нет). Флешку вернули — и bin_path, который предпочитает
# хранилище, начинает отдавать СТАРЫЙ файл: «обновил, и ничего не изменилось» — ровно тот
# симптом, ради которого в store-lib.sh записан инвариант «копия РОВНО одна».
#
# Кто прав: РЕЗИДЕНТНАЯ копия. Её положили позже — тогда, когда хранилища не было. Одинаковые
# файлы (прерванная миграция) просто схлопываем, не гоняя мегабайты.
#
# Цена под контролем. Дешёвая проверка `[ -f ] && [ -f ]` идёт на каждом тике (это builtin, ни
# одного форка), а до md5/копирования дело доходит только при РЕАЛЬНОМ дубле — то есть почти
# никогда. Штамп ставим лишь тогда: если разобрать не вышло (на накопителе нет места), не
# молотить md5 семимегабайтных файлов каждые две минуты до самого ребута.
resolve_dups() {
    [ "$BIN_DIR" != "$ENODIA_BIN" ] || return 0        # хранилища нет — дублей не бывает по определению
    [ -f "$DEDUP_STAMP" ] && return 0
    _any=0
    for _b in $STORE_MOVABLE; do
        if [ -f "$ENODIA_BIN/$_b" ] && [ -f "$BIN_DIR/$_b" ]; then _any=1; break; fi
    done
    [ "$_any" = 0 ] && return 0
    : > "$DEDUP_STAMP" 2>/dev/null
    for _b in $STORE_MOVABLE; do
        [ -f "$ENODIA_BIN/$_b" ] || continue
        [ -f "$BIN_DIR/$_b" ] || continue
        if [ "$(md5_of "$ENODIA_BIN/$_b")" = "$(md5_of "$BIN_DIR/$_b")" ]; then
            rm -f "$ENODIA_BIN/$_b" 2>/dev/null
            echo "usb-offload: $_b — лишняя копия на /data снята (файлы идентичны)"
        else
            echo "usb-offload: $_b на /data отличается от копии в хранилище — переношу свежую"
            if ! move_verified "$ENODIA_BIN/$_b" "$BIN_DIR/$_b" "$_b" >/dev/null 2>&1; then
                echo "usb-offload: $_b перенести не вышло — в хранилище остаётся СТАРАЯ копия, она и запускается"
            fi
        fi
    done
    return 0
}

# --- вербы ------------------------------------------------------------------------------

# detect — что роутер видит ПРЯМО СЕЙЧАС, без монтирования: dev, ФС, точка, наш ли.
# Несмонтированное честно печатается с «?» вместо ФС: узнать её без монтирования нечем
# (blkid на роутере нет), а монтировать в информационном вербе — побочный эффект.
cmd_detect() {
    # ЦЕЛОЕ УСТРОЙСТВО ПРЯЧЕМ, если его раздел уже в списке: физически это ОДНА флешка, а
    # панель по этому списку предлагает выбор («перенести на какой?») — две строки на один
    # носитель читались бы как два накопителя. Разделы у mount_candidates идут первыми, поэтому
    # к моменту разбора sdX список их дисков уже полон.
    _seen=""
    while read -r _d _m _t _rest; do
        case "$_d" in /dev/sd*) ;; *) continue ;; esac
        _o=no; [ -n "$(store_of_mount "$_m")" ] && _o=yes
        _n=${_d#/dev/}
        case "$_n" in sd[a-z][0-9]*) _seen="$_seen ${_n%%[0-9]*}" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$_d" "$_t" "$_m" "$_o"
    done < /proc/mounts
    for _dev in $(mount_candidates); do
        _n=${_dev#/dev/}
        case "$_n" in
            sd[a-z]) case " $_seen " in *" $_n "*) continue ;; esac ;;
            *)       _seen="$_seen ${_n%%[0-9]*}" ;;
        esac
        printf '%s\t?\t-\t?\n' "$_dev"
    done
}

# mount-ensure — сделать хранилище доступным. Зовут heal.sh (ДО подъёма несущей на буте) и
# watchdog.sh (переткнули флешку на ходу). Молчит, когда делать нечего: в норме это тик cron.
# Код 0 = хранилище доступно, 1 = нет (в т.ч. «оффлоад не включали» — самый частый случай).
cmd_mount_ensure() {
    [ -f "$STORE_MARK" ] || return 1        # маркера нет ⇒ накопитель не наш сценарий, no-op
    store_ready && { rm -f "$MISS_STAMP" 2>/dev/null; resolve_dups; return 0; }   # уже на месте
    _s=$(find_mounted_store)
    if [ -n "$_s" ]; then
        mark_write "$_s"
        rm -f "$MISS_STAMP" 2>/dev/null
        echo "usb-offload: хранилище $_s (смонтировано системой)"
        resolve_dups
        return 0
    fi
    mkdir -p "$MNT" 2>/dev/null
    for _dev in $(mount_candidates); do
        try_mount_ro "$_dev" "$MNT" || continue
        _s=$(store_of_mount "$MNT")
        umount "$MNT" 2>/dev/null           # проба окончена: чужое не держим, своё поднимем на запись
        [ -n "$_s" ] || continue
        if ! try_mount "$_dev" "$MNT"; then
            echo "usb-offload: хранилище на $_dev есть, но накопитель не монтируется на запись — пропускаю"
            continue
        fi
        _s=$(store_of_mount "$MNT")
        if [ -n "$_s" ]; then
            mark_write "$_s"
            rm -f "$MISS_STAMP" 2>/dev/null
            echo "usb-offload: хранилище $_s ($_dev, $(fs_of_mount "$MNT"))"
            resolve_dups
            return 0
        fi
        umount "$MNT" 2>/dev/null           # чужой накопитель — не держим его смонтированным
    done
    # «Накопитель включён, но выдернут» — ШТАТНОЕ состояние (панель показывает его третьим),
    # а зовут нас с cron каждые 2 минуты: без штампа это 720 строк в сутки в watchdog-лог,
    # который лежит в /tmp (=ОЗУ) и не ротируется, да ещё и ломает инвариант «в здоровом NORMAL
    # watchdog молчит». Говорим ОДИН раз на загрузку (штамп тоже в /tmp ⇒ после ребута скажем
    # снова), а вернулся накопитель — штамп снимаем, чтобы следующая пропажа не осталась немой.
    if [ ! -f "$MISS_STAMP" ]; then
        : > "$MISS_STAMP" 2>/dev/null
        echo "usb-offload: накопитель с хранилищем не найден — бинари ищутся на /data"
    fi
    return 1
}

# Выбрать накопитель под НОВОЕ хранилище. Явный аргумент (устройство или готовая точка) главнее
# всего; без аргумента годится РОВНО ОДИН кандидат — при нескольких отказываемся и показываем
# список: угадывать, на какую из двух флешек селиться, движок не вправе.
prepare_store() {   # $1 = /dev/sdX1 | точка монтирования | пусто
    _mp=""
    if [ -n "$1" ]; then
        case "$1" in
            /dev/*) _dev="$1" ;;
            /*)     [ -d "$1" ] || { echo "нет такого каталога: $1" >&2; return 1; }
                    _mp="$1"; _dev="" ;;
            *)      _dev="/dev/$1" ;;
        esac
        if [ -n "$_dev" ]; then
            [ -b "$_dev" ] || { echo "нет такого устройства: $_dev" >&2; return 1; }
            _mp=""
            while read -r _d _m _t _rest; do
                [ "$_d" = "$_dev" ] && { _mp="$_m"; break; }
            done < /proc/mounts
            if [ -z "$_mp" ]; then
                mkdir -p "$MNT" 2>/dev/null
                try_mount "$_dev" "$MNT" || { echo "не смонтировался $_dev (ФС не опознана?)" >&2; return 1; }
                _mp="$MNT"
            fi
        fi
    else
        # Считаем ФИЗИЧЕСКИЕ накопители, а не узлы: у одной флешки видны И раздел (sda1,
        # смонтирован стоком), И целое устройство (sda, свободно) ⇒ подсчёт по узлам объявлял
        # единственную воткнутую флешку «несколькими» и требовал указать её руками.
        _n=0; _disks=""; _cand=""
        while read -r _d _m _t _rest; do
            case "$_d" in /dev/sd*) ;; *) continue ;; esac
            _dsk=${_d#/dev/}; _dsk=${_dsk%%[0-9]*}
            case " $_disks " in *" $_dsk "*) ;; *) _disks="$_disks $_dsk"; _n=$((_n+1)) ;; esac
            [ -z "$_mp" ] && _mp="$_m"     # смонтированное предпочтительнее: второй монтаж того же не нужен
        done < /proc/mounts
        for _dev in $(mount_candidates); do
            _dsk=${_dev#/dev/}; _dsk=${_dsk%%[0-9]*}
            case " $_disks " in *" $_dsk "*) ;; *) _disks="$_disks $_dsk"; _n=$((_n+1)) ;; esac
            [ -z "$_cand" ] && _cand="$_dev"
        done
        if [ "$_n" = 0 ]; then
            echo "накопитель не найден: воткни флешку в USB-порт роутера" >&2; return 1
        fi
        if [ "$_n" -gt 1 ]; then
            echo "накопителей несколько — укажи нужный явно (usb-offload.sh enable /dev/sdX1):" >&2
            cmd_detect >&2
            return 1
        fi
        if [ -z "$_mp" ]; then
            mkdir -p "$MNT" 2>/dev/null
            try_mount "$_cand" "$MNT" || { echo "не смонтировался $_cand (ФС не опознана?)" >&2; return 1; }
            _mp="$MNT"
        fi
    fi
    # Готовим раскладку. Запись ПРОВЕРЯЕМ: ФС могла смонтироваться read-only (грязный размонтаж
    # NTFS/exFAT — штатное поведение ядра), и тогда «хранилище создано» было бы враньём.
    mkdir -p "$_mp/$STORE_SUB/bin" 2>/dev/null
    printf 'be7000 bin store\n' > "$_mp/$STORE_SUB/$STORE_SENTINEL" 2>/dev/null
    if [ ! -f "$_mp/$STORE_SUB/$STORE_SENTINEL" ] || [ ! -d "$_mp/$STORE_SUB/bin" ]; then
        echo "на накопителе не пишется ($_mp) — смонтирован только для чтения?" >&2; return 1
    fi
    printf '%s' "$_mp/$STORE_SUB"
    return 0
}

cmd_enable() {
    if ! store_ready; then cmd_mount_ensure >/dev/null 2>&1; fi
    if store_ready; then
        _store=$(store_root)
        echo "Хранилище: $_store (уже подготовлено)"
    else
        # Маркера нет, но на воткнутом накопителе УЖЕ лежит наш сентинел (переустановка, снесённый
        # маркер, флешка от прошлой машины) — это то же хранилище: усыновляем. Иначе выбор диска
        # пошёл бы общим путём и мог сесть на ДРУГОЙ накопитель, оставив прежние бинари сиротами.
        _store=$(find_mounted_store) || _store=""
        if [ -n "$_store" ] && [ -z "$1" ]; then
            mark_write "$_store"
            echo "Хранилище: $_store (найдено на накопителе)"
        else
            _store=$(prepare_store "$1") || return 1
            mark_write "$_store"
            echo "Хранилище: $_store (создано)"
        fi
    fi
    drop_stale_new
    echo "Переселяю тяжёлые бинари:"
    _moved=0; _failed=0; _had=0
    for _b in $STORE_MOVABLE; do
        [ -f "$ENODIA_BIN/$_b" ] || continue
        _had=$((_had+1))
        if move_verified "$ENODIA_BIN/$_b" "$BIN_DIR/$_b" "$_b"; then _moved=$((_moved+1)); else _failed=$((_failed+1)); fi
    done
    [ "$_had" = 0 ] && echo "  (переселять нечего — тяжёлых бинарей на /data нет)"
    echo "Переселено: $_moved, осталось на роутере: $_failed"
    echo "Свободно на /data: $(mb "$(df_free_b /data)") МБ"
    # Несущую НЕ трогаем: запущенный демон продолжает работать со СВОЕГО (уже удалённого) inode,
    # а следующий подъём — хоть watchdog'ом, хоть ребутом — возьмёт копию с накопителя. Рвать
    # рабочий туннель ради проверки, которую только что сделал exec_ok, незачем.
    [ "$_failed" -gt 0 ] && return 1
    return 0
}

cmd_disable() {
    if ! store_ready; then
        cmd_mount_ensure >/dev/null 2>&1
        store_ready || { echo "хранилище недоступно — воткни накопитель, иначе возвращать нечего" >&2; return 1; }
    fi
    _store=$(store_root)
    drop_stale_new      # ДО гарда места: хвост прошлого прогона на /data сам по себе решал бы «не влезет»
    # Гард места СНАЧАЛА и целиком: вернуть половину бинарей и упереться в ENOSPC — худший из
    # исходов (часть транспортов на /data, часть на флешке, места нет ни на что).
    _need=0
    for _b in $STORE_MOVABLE; do
        [ -f "$BIN_DIR/$_b" ] && _need=$((_need + $(size_b "$BIN_DIR/$_b")))
    done
    _free=$(df_free_b /data); case "$_free" in ''|*[!0-9]*) _free=0 ;; esac
    if [ "$((_free - _need))" -lt "$DATA_RESERVE_B" ]; then
        echo "не влезет: вернуть надо $(mb "$_need") МБ, свободно $(mb "$_free") МБ при резерве $(mb "$DATA_RESERVE_B") МБ." >&2
        echo "Сними лишние компоненты в «Компонентах» и повтори." >&2
        return 1
    fi
    echo "Возвращаю бинари на роутер:"
    _moved=0; _failed=0
    for _b in $STORE_MOVABLE; do
        [ -f "$BIN_DIR/$_b" ] || continue
        if move_verified "$BIN_DIR/$_b" "$ENODIA_BIN/$_b" "$_b"; then _moved=$((_moved+1)); else _failed=$((_failed+1)); fi
    done
    if [ "$_failed" -gt 0 ]; then
        echo "Часть бинарей осталась на накопителе — маркер НЕ снимаю (иначе они стали бы недоступны)." >&2
        return 1
    fi
    _mp="$_store"
    mark_drop
    echo "Переселено обратно: $_moved. Накопитель больше не используется."
    echo "Свободно на /data: $(mb "$(df_free_b /data)") МБ"
    # Свою точку отпускаем, стоковую не трогаем: её монтировал не мы.
    case "$_mp" in "$MNT"/*) umount "$MNT" 2>/dev/null ;; esac
    return 0
}

cmd_status() {
    if store_ready; then
        _store=$(store_root)
        # Точка монтирования = хранилище минус /$STORE_SUB.
        _mp=${_store%/$STORE_SUB}
        echo "Внешний накопитель: ВКЛЮЧЁН"
        echo "  хранилище: $_store"
        echo "  ФС: $(fs_of_mount "$_mp" || echo '?'), свободно $(mb "$(df_free_b "$_store")") МБ из $(mb "$(df_total_b "$_store")")"
        echo "  занимаем: $(mb "$(du_b "$_store")") МБ (остальное занятое на накопителе — не наше)"
    elif [ -f "$STORE_MARK" ]; then
        echo "Внешний накопитель: ВКЛЮЧЁН, но НЕДОСТУПЕН (маркер есть, хранилища нет)"
        echo "  ожидался: $(cat "$STORE_MARK" 2>/dev/null)"
        echo "  бинари ищутся на /data; транспорт, чей бинарь уехал, считается неустановленным."
    else
        echo "Внешний накопитель: выключен (всё на /data)"
    fi
    echo "  /data: свободно $(mb "$(df_free_b /data)") МБ из $(mb "$(df_total_b /data)")"
    echo "Тяжёлые бинари:"
    for _b in $STORE_MOVABLE; do
        _w=$(bin_where "$_b")
        case "$_w" in
            store)  printf '  %-12s накопитель  %s МБ\n' "$_b" "$(mb "$(size_b "$(bin_path "$_b")")")" ;;
            router) printf '  %-12s роутер      %s МБ\n' "$_b" "$(mb "$(size_b "$(bin_path "$_b")")")" ;;
            *)      printf '  %-12s не установлен\n' "$_b" ;;
        esac
    done
}

# json — ЕДИНЫЙ срез для панели (Ф3). Второй копии «что где лежит» во фронте быть не должно.
cmd_json() {
    _store=$(store_root)
    _mp=${_store%/$STORE_SUB}
    # store_used_b — НАШЕ на накопителе (du хранилища). Занятое ВСЕГО панель берёт как
    # total−free, чужое = разность: так «разбивка накопителя» сходится с df без обхода чужих
    # файлов. Нет хранилища ⇒ нули, и блок разбивки во фронте просто не рисуется.
    printf '{"on":%s,"ready":%s,"store":"%s","fs":"%s","store_free_b":%s,"store_total_b":%s,"store_used_b":%s,"data_free_b":%s,"data_total_b":%s' \
        "$([ -f "$STORE_MARK" ] && echo true || echo false)" \
        "$(store_ready && echo true || echo false)" \
        "$_store" "$([ -n "$_store" ] && fs_of_mount "$_mp")" \
        "$([ -n "$_store" ] && df_free_b "$_store" || echo 0)" \
        "$([ -n "$_store" ] && df_total_b "$_store" || echo 0)" \
        "$([ -n "$_store" ] && du_b "$_store" || echo 0)" \
        "$(df_free_b /data)" "$(df_total_b /data)"
    printf ',"bins":['
    _f=1
    for _b in $STORE_MOVABLE; do
        [ "$_f" = 1 ] || printf ','
        _f=0
        printf '{"name":"%s","where":"%s","size_b":%s}' "$_b" "$(bin_where "$_b")" "$(size_b "$(bin_path "$_b")")"
    done
    printf '],"cands":['
    _f=1
    # Ёмкость кандидата отдаём, ТОЛЬКО если он уже смонтирован (стоком или нами): монтировать
    # чужую флешку ради красивой цифры в информационном срезе — побочный эффект, а `blkid`,
    # который сказал бы размер без монтирования, на роутере нет. Не смонтирован ⇒ нули, и
    # панель просто не показывает размер — это честнее выдуманного «≈ 32 ГБ».
    cmd_detect | while IFS="$(printf '\t')" read -r _d _t _m _o; do
        [ "$_f" = 1 ] || printf ','
        _f=0
        printf '{"dev":"%s","fs":"%s","mnt":"%s","ours":%s,"free_b":%s,"total_b":%s}' \
            "$_d" "$_t" "$_m" "$([ "$_o" = yes ] && echo true || echo false)" \
            "$([ -d "$_m" ] && df_free_b "$_m" || echo 0)" \
            "$([ -d "$_m" ] && df_total_b "$_m" || echo 0)"
    done
    printf ']}\n'
}

case "$1" in
    detect)       cmd_detect ;;
    mount-ensure) cmd_mount_ensure ;;
    enable)       cmd_enable "$2" ;;
    disable)      cmd_disable ;;
    status|"")    cmd_status ;;
    json)         cmd_json ;;
    *) echo "usage: $0 detect | mount-ensure | enable [dev|точка] | disable | status | json"; exit 2 ;;
esac
