#!/bin/sh
# vpn-toggle.sh — глобальное вкл/выкл VPN и исключение конкретных устройств.
#
# v2 (май 2026): cmd_on теперь идемпотентно восстанавливает ВСЕ правила
# (mangle PREROUTING + NAT MASQUERADE + FORWARD + ip rule), а не только
# ip rule. Это лечит ситуацию, когда fw3/firewall на роутере reload-ится
# (после изменений в веб-морде Xiaomi или ребута init.d/firewall) и сносит
# ВСЕ iptables-таблицы — heal.sh при этом не помогает, потому что
# у него лок /tmp/enodia-heal.lock один раз за boot.
# Дополнительно добавлена команда `repair` для явного восстановления
# правил без переключения VPN on/off.
#
# Использование:
#   vpn-toggle.sh status              — текущее состояние
#   vpn-toggle.sh off                 — выключить VPN для всех (трафик через провайдера)
#   vpn-toggle.sh on                  — включить + восстановить правила (идемпотентно)
#   vpn-toggle.sh repair              — только восстановить правила (mangle/NAT/FORWARD)
#   vpn-toggle.sh exclude 192.168.31.50  — выключить VPN для одного устройства
#   vpn-toggle.sh include 192.168.31.50  — вернуть устройство в VPN
#   vpn-toggle.sh excluded            — показать список исключённых IP

TABLE=1000
MARK=0x1
EXCLUDE_CHAIN_PRE="VPN_EXCLUDE"   # mangle PREROUTING исключения
ENODIA_LIST="enodia_list"
IPLIST_SET="iplist_set"
HEAL_LOCK="/tmp/enodia-heal.lock"
SWITCH_LOCK="/tmp/enodia-switching.lock"   # ОБЩАЯ идиома «идёт смена несущей — сторож и heal не вмешиваются» (transport.sh, switch-vpn.sh, cgi hold_switch); держим её и на подъёме несущей в cmd_on
ENODIA_DIR="/data/usr/app/enodia"        # для apply-bypass.sh (персист исключений)
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
if ! command -v ct_flush >/dev/null 2>&1; then
    ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
    ct_flush_src_n(){ [ -n "$1" ] && conntrack -D --src "$1" 2>/dev/null | wc -l; return 0; }
fi

# ВАЖНО про target ACCEPT (а НЕ RETURN) в user-chain VPN_EXCLUDE:
# Каскад в PREROUTING после ensure_chain выглядит так:
#   1) -j VPN_EXCLUDE
#   2) -m set --match-set enodia_list dst -j MARK --set-mark 0x1
#   3) -m set --match-set iplist_set dst -j MARK --set-mark 0x1
# Если в VPN_EXCLUDE стоит `-j RETURN`, то после совпадения мы возвращаемся
# в PREROUTING на правило 2, и пакет ВСЁ РАВНО получает mark → идёт в VPN.
# Если стоит `-j ACCEPT`, в mangle table это останавливает обход всех
# оставшихся правил в этой таблице → mark не ставится → пакет идёт через
# main route (провайдер). Именно это и нужно для exclude.
# Не переписывай обратно на RETURN — оно молча сломает exclude.
#
# ВАЖНО про conntrack -D после exclude/include:
# На BE7000 активен Qualcomm NSS (ECM + PPE + SFE) — ускоритель пакетов.
# Он offload-ит установленные соединения через быстрый путь, минуя iptables.
# Если просто добавить правило в VPN_EXCLUDE, существующие соединения этого
# IP продолжат идти через VPN (ECM кэширует решение).
# Поэтому после изменения exclude-правил мы вызываем `conntrack -D --src $IP`
# — это удаляет conntrack-записи для IP, ECM получает уведомление и сбрасывает
# offload. Новые пакеты пойдут через iptables и увидят свежее правило.

ensure_chain() {
    iptables -t mangle -L "$EXCLUDE_CHAIN_PRE" -n >/dev/null 2>&1 || {
        iptables -t mangle -N "$EXCLUDE_CHAIN_PRE"
    }
    # Гарантируем, что наш chain вызывается ПЕРВЫМ в PREROUTING
    # (для трафика, идущего ЧЕРЕЗ роутер — LAN-клиенты → VPN-цели).
    iptables -t mangle -D PREROUTING -j "$EXCLUDE_CHAIN_PRE" 2>/dev/null
    iptables -t mangle -I PREROUTING 1 -j "$EXCLUDE_CHAIN_PRE"
    # И в OUTPUT (для трафика, который ГЕНЕРИРУЕТ сам роутер — daemons
    # типа xq_info_sync_mqtt / messagingagent, ходящие на Xiaomi cloud).
    # Без этого Mi Home модуль BE7000 ломается: router-cloud-tunnel идёт
    # через VPN → cloud видит "не родной" IP, отказ. См. xiaomi-bypass.sh.
    iptables -t mangle -D OUTPUT -j "$EXCLUDE_CHAIN_PRE" 2>/dev/null
    iptables -t mangle -I OUTPUT 1 -j "$EXCLUDE_CHAIN_PRE"
    # Позицию СРЕДИ ПРОЧИХ цепочек (VPN_PORTS выше нас, VPN_FORCE ниже) знает один
    # владелец — apply-bypass.sh. Своя вставка на позицию 1 задвинула бы VPN_PORTS под
    # наш ACCEPT, а он обрывает обход mangle → правила по портам молча перестали бы
    # работать. Best-effort: нет apply-bypass — остаётся ровно прежнее поведение.
    [ -f "$ENODIA_DIR/apply-bypass.sh" ] && sh "$ENODIA_DIR/apply-bypass.sh" order >/dev/null 2>&1
    return 0
}

cmd_status() {
    if ip rule show | grep -q "fwmark $MARK"; then
        echo "VPN: ON (глобально)"
    else
        echo "VPN: OFF (глобально)"
    fi
    # Доп-выходы (слоты) — ОТДЕЛЬНАЯ строка, а не молчание: у каждого своя марка 0x2..0x4 и свой
    # ip rule, поэтому по одной лишь марке основного туннеля судить о них нельзя (ревью 04.08.2026 —
    # раньше `off` их не снимал, а status показывал «OFF» при живых выходах).
    _slr=$(ip rule show 2>/dev/null | grep -c 'fwmark 0x[234]')
    case "$_slr" in ''|*[!0-9]*) _slr=0 ;; esac   # busybox: grep -c при нуле даёт код 1
    [ "$_slr" -gt 0 ] && echo "Доп-выходы: правил маршрутизации активно: $_slr"
    echo
    echo "awg0 интерфейс:"
    ip a show awg0 2>/dev/null | grep -E 'inet |state' | head -2
    echo
    echo "Исключённые IP (трафик идёт мимо VPN):"
    iptables -t mangle -L "$EXCLUDE_CHAIN_PRE" -n 2>/dev/null | awk '/ACCEPT/{print "  " $4}'
}

# Снимаем PBR ВСЕХ выходов: основного (0x1) и доп-выходов (0x2..0x4). Раньше уходила только марка
# основного туннеля, а группы/устройства, привязанные к доп-выходу, продолжали ехать через свой VPS
# при «VPN выключен для всех» (ревью 04.08.2026) — то есть тумблер врал ровно тем, кто настроил
# больше одного выхода. Форм у слот-правила две (своя table 100N и fallback на 1000) — сносим обе,
# как это делает mark-core.sh; обратно их ставит он же на `on`/`repair`.
cmd_off() {
    ip rule del fwmark $MARK table $TABLE 2>/dev/null
    for _s in 2 3 4; do
        ip rule del fwmark "0x$_s" table "100$_s" 2>/dev/null
        ip rule del fwmark "0x$_s" table $TABLE 2>/dev/null
    done
    # НЕМАРКИРУЮЩАЯ НЕСУЩАЯ. Всё выше снимает МАРКИ, а транспорт, который трафик марками не
    # везёт (zapret: весь дом идёт напрямую, категории пробивает nfqws на форварде), этим не
    # выключается ВООБЩЕ: демон жив, NFQUEUE на месте, и шапка через 10 с поллинга возвращала
    # тумблер в ON — «после некоторой магии всё вернулось» (тестер, 18.08.2026). Снять его
    # может только владелец, поэтому зовём оркестратора. НАМЕРЕНИЕ (`.transport`) НЕ трогаем:
    # обратно несущую поднимет `on` (repair + `heal.sh replay`, секция 5.6) — тем же путём,
    # что и после ребута. Спрашиваем владельца, а не свой список: код 2 (старая копия верба не
    # знает) или нет файла ⇒ ведём себя как раньше, байт-в-байт.
    _offt=$(active_transport)
    if [ "$_offt" != none ] && [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" marking "$_offt" >/dev/null 2>&1
        if [ "$?" = 1 ]; then
            echo "Транспорт $_offt везёт трафик не маркой — снимаю его несущую…"
            sh "$ENODIA_DIR/transport.sh" down "$_offt" >/dev/null 2>&1
        fi
    fi
    # NSS/ECM держит УЖЕ установленные сессии на прежнем маршруте — без сброса выключение видно
    # только на новых соединениях (инвариант проекта: после смены маршрутизации — conntrack).
    ct_flush
    echo "VPN глобально ВЫКЛЮЧЕН. Трафик идёт через провайдера (включая доп-выходы)."
    echo "Не забудь: ipconfig /flushdns на клиентах."
}

# ЕДИНЫЙ ответ «какой транспорт активен» для этого файла (repair и on спрашивают одно и то же).
# Пустой флаг: либо роутер старше `.transport` (несущая awg — так было всегда), либо установка
# «только панель», где транспорта нет вовсе. Отличает их оркестратор (см. transport.sh
# configured); код 2 = старая копия скрипта ⇒ как раньше. С `none` repair чинит ВСЁ, кроме ядра
# маркировки и несущей: вырезы, слоты, «доступ домой» и панель живут и без транспорта.
active_transport() {
    _at=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    if [ -z "$_at" ]; then
        _at=awg
        if [ -f "$ENODIA_DIR/transport.sh" ]; then
            sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
            [ "$?" = 1 ] && _at=none
        fi
    fi
    printf '%s' "$_at"
}

# Идемпотентно восстановить ВСЕ правила, которые ставит heal.sh
# (mangle PREROUTING + NAT POSTROUTING + FORWARD + route в таблицу 1000).
# Зачем: fw3/firewall на роутере иногда перезагружается (изменения в
# веб-морде Xiaomi, /etc/init.d/firewall restart) и сносит ВСЕ iptables-
# таблицы. heal.sh при этом сам не восстановит — у него лок
# /tmp/enodia-heal.lock один раз за boot, и cron каждый тик просто выходит.
cmd_repair() {
    # Активный транспорт определяем СРАЗУ: несущая awg и альтов (xray/hy2) живёт на
    # РАЗНЫХ интерфейсах (awg0 vs xtun). Раньше cmd_repair был awg-центричен —
    # безусловно ставил default table 1000 → awg0 + MASQUERADE/FORWARD awg0 и ТРЕБОВАЛ
    # поднятый awg0, а альт переигрывал лишь в конце. На альт-несущей это создавало
    # переходное «awg0 несёт» состояние → health альта спотыкался → watchdog кросс-
    # эскалировал на awg (несущая молча менялась hy2→awg; ровно это ловил пользователь
    # на «VPN выкл → вкл» под Hysteria2). Теперь awg0-шаги — ТОЛЬКО при transport=awg;
    # для альта несущую (default xtun + FORWARD + DNS) идемпотентно ставит его плагин
    # через transport.sh up, а default table 1000 на awg0 НЕ трогаем.
    repair_t=$(active_transport)

    # awg-несущей нужен поднятый awg0; альту — нет (awg0 тёплый резерв / может отсутствовать).
    if [ "$repair_t" = "awg" ] && ! ip link show awg0 >/dev/null 2>&1; then
        # ПОЧЕМУ awg0 нет — два разных ответа, и советы у них противоположные. Если бинарей
        # AmneziaWG на роутере нет, heal не поднимет несущую НИКОГДА, сколько его ни зови, — а
        # именно это мы и советовали, причём командой с `rm -f` лока. Типовой путь сюда: установка
        # «только панель» + ИМПОРТ бэкапа с другого роутера (намерение `.transport=awg` приехало,
        # файлы — нет; замерено на AX3600 16.08.2026). Владелец ответа «готов ли транспорт» один —
        # оркестратор (`list` печатает готовые; у awg «готов» = ОБА бинаря). Нет оркестратора =
        # роутер старше него ⇒ ведём себя как раньше, байт-в-байт.
        if [ -f "$ENODIA_DIR/transport.sh" ] && ! sh "$ENODIA_DIR/transport.sh" list 2>/dev/null | grep -qx awg; then
            echo "AmneziaWG выбран транспортом, но его бинарей на роутере нет."
            echo "  Установи компонент «AmneziaWG» в панели: «Компоненты» — heal тут не поможет."
            return 1
        fi
        echo "awg0 не поднят — сначала запусти heal.sh:"
        echo "  rm -f $HEAL_LOCK && sh /data/usr/app/enodia/heal.sh"
        return 1
    fi

    # --- транспорт-агностичное ядро: reply-guard + маркировка (PREROUTING+OUTPUT) + ip rule ---
    # ЕДИНЫЙ источник — mark-core.sh. Раньше тут был инлайн-дубль, который ОТСТАЛ: не ставил
    # reply-guard (dst-LOCAL ACCEPT — без него возврат прямого трафика рвётся, если WAN-IP ∈
    # iplist_set, грабля Евгения) и OUTPUT-маркировку (трафик самого роутера к CIDR утекал мимо
    # туннеля). Зовём mark-core; инлайн ниже — лишь фолбэк для старых роутеров без него.
    if [ "$repair_t" = none ]; then
        # Транспорта нет — метить некуда: ядро не ставим (иначе repair «чинил» бы правила,
        # которых на этом роутере не заводили).
        echo "транспорт не настроен — ядро маркировки и несущую пропускаю"
    elif [ -f "$ENODIA_DIR/mark-core.sh" ]; then
        sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1
    else
        ip rule del fwmark $MARK table $TABLE 2>/dev/null
        ip rule add fwmark $MARK table $TABLE pref 99
        for set in "$ENODIA_LIST" "$IPLIST_SET"; do
            if ipset list -n 2>/dev/null | grep -qx "$set"; then
                iptables -t mangle -C PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $MARK 2>/dev/null || \
                    iptables -t mangle -A PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $MARK
                iptables -t mangle -C OUTPUT -m set --match-set "$set" dst -j MARK --set-mark $MARK 2>/dev/null || \
                    iptables -t mangle -A OUTPUT -m set --match-set "$set" dst -j MARK --set-mark $MARK
            fi
        done
    fi

    # Цепочка исключений + сами исключения «мимо VPN» из persistent-хранилища. fw3-reload сносит
    # iptables → ensure_chain создаёт VPN_EXCLUDE ПУСТОЙ; без apply устройства/SSID/guest,
    # выведенные напрямую, после repair снова ушли бы в VPN. apply идемпотентен и трогает только
    # прямой путь.
    # ...но при `none` не делаем НИЧЕГО из этого: «мимо VPN» без VPN бессмысленно, а сама пара
    # (цепочка + reply-guard) — единственный наш след в mangle на чистом роутере. Тот же гейт, что
    # в heal 5.5: иначе кнопка «Починить правила» возвращала бы ровно то, что heal не ставит.
    if [ "$repair_t" = none ]; then
        echo "транспорт не настроен — вырезы «мимо VPN» не переигрываю"
    else
        ensure_chain
        [ -f "$ENODIA_DIR/apply-bypass.sh" ] && sh "$ENODIA_DIR/apply-bypass.sh" apply
    fi

    # --- несущая активного транспорта ---
    if [ "$repair_t" = none ]; then
        :
    elif [ "$repair_t" = "awg" ]; then
        # awg несёт сама (awg0): default table 1000 + MASQUERADE + FORWARD на awg0.
        ip route replace default dev awg0 table $TABLE 2>/dev/null
        iptables -t nat -C POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
        iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o awg0 -j ACCEPT
        iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i awg0 -j ACCEPT
    elif [ -f "$ENODIA_DIR/transport.sh" ]; then
        # Альт (xray/hy2): несущую (default xtun + FORWARD xtun + DNS) ставит ПЛАГИН
        # идемпотентно (демоны живы — не перезапускает). default table 1000 на awg0 НЕ
        # трогаем — иначе тот самый «переходный awg0», что ронял health и провоцировал cross.
        sh "$ENODIA_DIR/transport.sh" up "$repair_t"
    fi

    # Zapret-транспорт: активен ⇔ .zapret-on есть (двигается вместе с .transport=zapret). fw3-reload
    # снёс его mangle-правила → переигрываем (apply идемпотентен; при неактивном — no-op/teardown).
    # Подстраховка: когда zapret активен, `transport.sh up` выше уже зовёт apply — дубль дёшев и безопасен.
    [ -f "$ENODIA_DIR/zapret.sh" ] && [ -f "$ENODIA_STATE/.zapret-on" ] && sh "$ENODIA_DIR/zapret.sh" apply >/dev/null 2>&1

    # Доп-выходы (слоты, Ф1): fw3-reload снёс их правила. В СЛОТ-режиме zapret .zapret-on НЕТ
    # (несущая — VPN), поэтому ветка zapret-транспорта выше слот не восстановит. Переигрываем как
    # heal 5.13b: zapret-слот re-wire ACCEPT+scoped NFQUEUE на свои сеты (живут в RAM, пережили
    # reload), non-zapret — марку/ip rule через mark-core. Реестр пуст → no-op.
    [ -f "$ENODIA_DIR/slots.sh" ] && [ -n "$(sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null)" ] && \
        [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" slots-up >/dev/null 2>&1

    # «Доступ домой» (vpn-server.sh): его цепочки (порт наружу, INPUT из туннеля с default-deny,
    # FORWARD) fw3-reload сносит вместе со всеми. Несущая awgs0 при этом ЖИВА, поэтому чинить надо
    # только правила, но зовём `up`, а не `rules`: он идемпотентен (живая несущая = ip link up +
    # правила) и заодно поднимет awgs0, если демон умер сам по себе — иначе такой случай ждал бы
    # следующего ребута. Флага .on нет — секция no-op. Без этого после reload телефон снаружи молча
    # переставал подключаться, а панель показывала «включён»: правила и несущая — РАЗНЫЕ вопросы
    # (тот же урок, что с доп-выходами).
    # -f + `sh`, а не -x: снятый бит превратил бы переигрыш в тихий пропуск (класс Б5-9).
    [ -f "$ENODIA_DIR/vpn-server.sh" ] && [ -f "$ENODIA_STATE/server/.on" ] && \
        sh "$ENODIA_DIR/vpn-server.sh" up >/dev/null 2>&1

    # NSS/ECM offload: правила только что переставлены — для УЖЕ установленных потоков
    # старый маршрут залипает до conntrack-таймаута. Сбрасываем (инвариант проекта).
    ct_flush

    # ЛОК heal.sh НЕ СНИМАЕМ (июль 2026, разбор ночного «роутер перезагрузился»).
    # Раньше здесь стоял `rm -f "$HEAL_LOCK"` «на всякий случай». Цена: heal без лока идёт
    # ПОЛНЫМ бутовым сценарием — `ip link del awg0` + awg_setup.sh (а тот внутри делает
    # `/etc/init.d/firewall reload`!) + рестарт dnsmasq + письмо «загрузка OK, VPN поднят».
    # То есть КАЖДЫЙ тихий rule-heal watchdog'а превращался в псевдо-ребут: пара секунд без
    # VPN и письмо, которое человек читает как «роутер сам перезагрузился». Плюс риск петли:
    # heal сам зовёт fw3 reload = ровно то событие, от которого rule-heal и лечит.
    # Repair и так делает всё, что сделал бы heal (mark-core + несущая + FORWARD/MASQUERADE +
    # DNS + bypass + слоты), пересоздавать awg0 незачем. Единственный законный случай снятия
    # лока — awg0 физически ИСЧЕЗ; его закрывает сам watchdog (см. rm HEAL_LOCK в его ветке
    # «awg0 ИСЧЕЗ»), где пересоздание интерфейса действительно нужно.

    echo "OK: правила восстановлены (транспорт: $repair_t)."
}

cmd_on() {
    # НЕСУЩАЯ МОГЛА НЕ ПОДНИМАТЬСЯ НИ РАЗУ — и тогда клик «Включить VPN» упирался в гард repair'а,
    # который советует SSH-команду. Типовой путь (замерено на AX3600 17.08.2026): установка
    # «только панель» + импорт бэкапа (намерение `.transport=awg` приезжает ФАЙЛОМ, несущую импорт
    # сознательно не поднимает) + доставка компонента в «Компонентах» (`packages.sh` ставит, но НЕ
    # активирует). Поднять awg0 в этот момент некому: heal сидит на бутовом локе, а repair его
    # сознательно не снимает — окно до трёх минут, пока не спохватится сторож. Другого пути в
    # панели у человека НЕТ: пикер транспорта ТЕКУЩИЙ транспорт не переключает (`return` на
    # cur.transport===k), то есть единственная кнопка отказывала и отправляла в SSH.
    # Поднимаем сами и тем же вербом, что зовут heal (5.6) и repair для АЛЬТОВ: у awg ветка
    # repair'а инлайновая и требует ГОТОВЫЙ awg0, у альтов несущую ставит плагин — асимметрия
    # была только в этом. Гейт `ready` ОБЯЗАТЕЛЕН: без бинарей/конфига `up` дошёл бы до
    # awg_setup.sh, а тот кончается `firewall reload` (снос ВСЕХ iptables) ради заведомо
    # провальной попытки. Нет верба (код 2 = старая копия) ⇒ как раньше, байт-в-байт: причину
    # назовёт гард repair'а ниже. Судим по ФАКТУ (интерфейс появился), а не по коду возврата.
    # ЛОК СМЕНЫ НЕСУЩЕЙ ОБЯЗАТЕЛЕН, и по той же причине, что у `switch`: подъём идёт секунды, а
    # внутри ЕЩЁ НЕТ интерфейса и ЕСТЬ `firewall reload` от awg_setup.sh. Тик сторожа (cron */2),
    # попавший в это окно, увидит «awg0 нет» → safety_off + FAILOPEN + снимет бутовый лок heal, и
    # тот через минуту прогонит ПОЛНЫЙ бутовый сценарий (`ip link del awg0` + второй firewall
    # reload + письмо «загрузка OK») — тот самый псевдо-ребут, от которого лечили в июле. Лок
    # существующий, четвёртой семантики не заводим: и сторож, и heal выходят на нём БЕЗУСЛОВНО
    # (`[ -e ] && exit 0`), поэтому держим его ровно вокруг подъёма и снимаем сразу.
    # Лок УЖЕ занят ⇒ прямо сейчас кто-то меняет транспорт: не лезем вовсе (гонка с ним — ровно
    # то, что лок запрещает), причину назовёт гард repair'а ниже.
    if [ "$(active_transport)" = awg ] && ! ip link show awg0 >/dev/null 2>&1 \
       && [ ! -e "$SWITCH_LOCK" ] \
       && [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" ready awg >/dev/null 2>&1; then
        echo "Несущая AmneziaWG не поднята — поднимаю awg0…"
        _sl=0
        # Ловушка нужна и на СИГНАЛАХ (uhttpd прибивает затянувшийся CGI): голый EXIT их не ловит,
        # а забытый лок выключает сторожа и heal НАСОВСЕМ — у обоих проверка без срока годности.
        if : > "$SWITCH_LOCK" 2>/dev/null; then
            _sl=1
            trap 'rm -f "$SWITCH_LOCK" 2>/dev/null' EXIT HUP INT TERM PIPE
        fi
        _up=$(sh "$ENODIA_DIR/transport.sh" up awg 2>&1)
        if [ "$_sl" = 1 ]; then
            rm -f "$SWITCH_LOCK" 2>/dev/null
            trap - EXIT HUP INT TERM PIPE
        fi
        if ip link show awg0 >/dev/null 2>&1; then
            echo "awg0 поднят."
        else
            echo "awg0 поднять не удалось:"
            echo "$_up" | tail -n 3
        fi
    fi
    cmd_repair || return 1
    # `repair` возвращает ПРАВИЛА (он про снос от fw3 reload, где наборы в RAM живы). А после
    # «Отключить VPN» теряются САМИ НАБОРЫ и dnsmasq-сниппеты: их владельцы — groups.sh, geo.sh,
    # lists-update.sh, dns-hosts.sh, и зовёт их РОВНО heal.sh. Тот сидит на бутовом локе, значит
    # без ребута группы, гео, блокировки, десинк и доп-выходы не возвращались вовсе — при том, что
    # панель показывала их включёнными (замерено на железе 08.08.2026: из 13 ipset оставалось 2).
    # Верб `replay` — тот же порядок heal без бутового сценария; дубль части работы с repair
    # дёшев и случается один раз на клик человека.
    if [ -f "$ENODIA_DIR/heal.sh" ]; then
        echo "Возвращаю группы, гео, списки, десинк и доп-выходы…"
        sh "$ENODIA_DIR/heal.sh" replay >/dev/null 2>&1 || true
    fi
    # ...и РАСПИСАНИЕ. После «Отключить VPN» cron-строк нет вовсе (их снял uninstall.sh), а без них
    # роутер живёт без сторожа (мёртвый VPS = дом без интернета: fail-open делать некому), без heal
    # (ребут ничего не поднимет) и без обновления списков — при зелёной панели. Что именно было
    # снято, знает ТОЛЬКО тот, кто снимал: своей копии реестра задач тут не держим. Верб
    # идемпотентен и на обычном `on` (ничего не снимали) молча выходит.
    if [ -f "$ENODIA_DIR/uninstall.sh" ]; then
        sh "$ENODIA_DIR/uninstall.sh" cron-restore >/dev/null 2>&1 || true
    fi
    echo "VPN глобально ВКЛЮЧЁН."
}

cmd_exclude() {
    IP=$1
    [ -z "$IP" ] && { echo "укажи IP: vpn-toggle.sh exclude 192.168.31.50"; exit 1; }
    ensure_chain
    iptables -t mangle -C "$EXCLUDE_CHAIN_PRE" -s "$IP" -j ACCEPT 2>/dev/null && {
        echo "IP $IP уже исключён"; exit 0
    }
    iptables -t mangle -A "$EXCLUDE_CHAIN_PRE" -s "$IP" -j ACCEPT
    # NSS-offload может держать старые соединения через VPN — сбрасываем. Число снятых записей
    # есть ТОЛЬКО там, где в прошивке живёт утилита conntrack: пусто ⇒ строку не печатаем вовсе
    # (раньше на ядре 4.4 тут стояло честное с виду «Сброшено записей: 0» при нулевом сбросе).
    N=$(ct_flush_src_n "$IP")
    # Зеркалим в persistent-хранилище, чтобы исключение пережило ребут/fw3-reload
    # (правило выше живёт только в iptables = RAM). add-ip идемпотентен.
    [ -f "$ENODIA_DIR/apply-bypass.sh" ] && sh "$ENODIA_DIR/apply-bypass.sh" add-ip "$IP" >/dev/null 2>&1
    echo "IP $IP исключён из VPN (трафик пойдёт напрямую).${N:+ Сброшено conntrack-записей: $N}"
    echo "Не забудь на устройстве: ipconfig /flushdns"
}

cmd_include() {
    IP=$1
    [ -z "$IP" ] && { echo "укажи IP: vpn-toggle.sh include 192.168.31.50"; exit 1; }
    if iptables -t mangle -D "$EXCLUDE_CHAIN_PRE" -s "$IP" -j ACCEPT 2>/dev/null; then
        N=$(ct_flush_src_n "$IP")
        echo "IP $IP возвращён в VPN.${N:+ Сброшено conntrack-записей: $N}"
    else
        echo "IP $IP не был в исключениях."
    fi
    # Убираем из persistent-хранилища (чтобы не вернулся после ребута). Идемпотентно.
    [ -f "$ENODIA_DIR/apply-bypass.sh" ] && sh "$ENODIA_DIR/apply-bypass.sh" del-ip "$IP" >/dev/null 2>&1
}

cmd_excluded() {
    iptables -t mangle -L "$EXCLUDE_CHAIN_PRE" -n 2>/dev/null | awk '/ACCEPT/{print $4}'
}

case "$1" in
    status|"")    cmd_status ;;
    off)          cmd_off ;;
    on)           cmd_on ;;
    repair)       cmd_repair ;;
    exclude)      cmd_exclude "$2" ;;
    include)      cmd_include "$2" ;;
    excluded)     cmd_excluded ;;
    *)
        echo "Использование: $0 {status|on|off|repair|exclude IP|include IP|excluded}"
        exit 1
        ;;
esac
