#!/bin/sh
# notify-event.sh — единая точка отправки СОБЫТИЙНЫХ писем с BE7000.
#
# Зачем отдельно от notify.sh:
#   notify.sh — «тупой» транспорт (ведёт SMTP-диалог и всё). А поводов для
#   письма стало много: критические сбои switch-vpn, не поднявшийся после
#   ребута туннель, утренняя сводка iplist. Если звать notify.sh из каждого
#   места напрямую — получим (а) СПАМ (cron повторяет один и тот же сбой
#   каждый тик) и (б) дублирование проверки .notify-off в каждом скрипте.
#   Эта обёртка решает оба: throttle по ключу + единый выключатель.
#   Она же — единственная точка, через которую события попадают в ЖУРНАЛ панели
#   (events.sh): раз все поводы уже сходятся сюда, история пишется тут, а не
#   размазывается по десяти вызывающим скриптам.
#
# Использование:
#   notify-event.sh <key> <throttle_sec> "Тема" "Текст"
#     key          — идентификатор класса события ([a-z0-9_-]); по нему
#                    ведётся throttle и пишется отметка времени.
#     throttle_sec — не слать письмо с тем же key чаще раза в N секунд.
#                    0 = без ограничения (для редких событий: сводка раз в
#                    сутки, разовое письмо о загрузке — там throttle не нужен).
#
# Известные ключи (класс события → кто шлёт):
#   boot-ok / boot-fail                — heal.sh (после загрузки/ребута)
#   switch-rollback / switch-failopen  — switch-vpn.sh (ручная смена страны)
#   failover-ok / failover-fail        — switch-vpn.sh failover (авто-перебор резервов)
#   iplist-digest / iplist-fail        — iplist-update.sh (утренняя сводка / сбой)
#   wan-down / wan-up                  — watchdog.sh (интернета нет ВООБЩЕ / аплинк вернулся:
#                                        перебор VPN-серверов на это время подавлен)
#   panel-wan-ip                       — web-ui.sh (провайдер сменил внешний адрес: ссылка на
#                                        панель снаружи протухла, в письме — новая)
#
# throttle-отметки лежат в /tmp (сбрасываются при ребуте — после загрузки
# первое письмо любого класса пройдёт сразу, это желаемо: ребут = повод
# узнать актуальное состояние). .notify-off глушит всё разом, как у watchdog.
#
# ВАЖНО (грабли DNS): письмо об упавшем VPN уйдёт только если DNS уже
# переведён на публичный (safety_off). smtp.yandex.ru идёт мимо туннеля
# по маршруту, НО резолвится через dnsmasq → upstream внутри туннеля.
# switch-vpn зовёт notify-event ПОСЛЕ safety_off (DNS уже на 1.1.1.1) —
# там письмо уйдёт. А «boot-fail» из heal.sh может не уйти, пока watchdog
# (≤2 мин) не сделает safety_off — он же продублирует своим письмом.

ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
NOTIFY="$ENODIA_DIR/notify.sh"
NOTIFY_OFF="$ENODIA_STATE/.notify-off"
EVENTS="$ENODIA_DIR/events.sh"
LOG=/tmp/notify-event.log

# Возраст throttle-отметки (clock-lib.sh). Голая разность «now - last» тут врала ровно тем сбоем,
# ради которого throttle и существует: часы прыгают вперёд через ~13 мин после загрузки, и ВСЕ
# отметки классов «протухают» одним махом — то есть в самый шумный момент (бут, первая авария)
# письма пошли бы повторами. Шим = прежнее поведение для установки без библиотеки.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

KEY="$1"
THROTTLE="$2"
SUBJECT="$3"
BODY="$4"

# МОДЕЛЬ В ТЕМЕ — приводим к реальной ЗДЕСЬ, на входе, а не только в sink'ах. Callers исторически
# зашивают «BE7000:» (watchdog.sh, heal.sh, iplist-update), и переписывали это notify.sh и
# events.sh — каждый у себя. Итог: письмо и журнал панели говорили «AX3600», а СОБСТВЕННЫЙ лог
# этого скрипта — «отправлено 'BE7000: …'». Лог, расходящийся с тем, что реально ушло, дважды за
# день увёл разбор в несуществующий баг. Переписываем один раз на входе; sink'и свой вызов
# сохраняют (их зовут и напрямую), а `router_relabel` идемпотентен — «AX3600:» он отдаёт как есть.
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi
command -v router_relabel >/dev/null 2>&1 && SUBJECT=$(router_relabel "$SUBJECT")

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Журнал для панели («центр уведомлений») — ДО всех почтовых гейтов и НЕЗАВИСИМО
# от них. Письмо и запись в историю — разные вопросы: почта может быть не
# настроена, выключена (.notify-off) или задушена throttle'ом, но пользователь
# всё равно должен увидеть в панели, что VPN падал. Схлопывание повторов в
# журнале идёт по тому же окну, что и throttle письма (см. events.sh).
# Не падаем, если events.sh ещё не залит (обновление со старой установки).
# Гард `-f` + вызов через `sh`, а НЕ `-x`: снятый бит выполнения (заливка по scp/base64, обновление
# скриптов) тихо выключал бы ВЕСЬ центр уведомлений панели — история событий просто перестала бы
# писаться, и ни одной жалобы в логах. Класс Б5-9/Б6-7, тот же приём.
[ -f "$EVENTS" ] && sh "$EVENTS" add "$KEY" "$THROTTLE" "$SUBJECT" "$BODY" >/dev/null 2>&1

# Глобальный выключатель (как в watchdog.sh)
if [ -f "$NOTIFY_OFF" ]; then
    log "notify-event: .notify-off — пропуск '$SUBJECT' (key=$KEY)"
    exit 0
fi

# notify.sh может быть ещё не залит — не падаем. Судим по НАЛИЧИЮ файла (зовём через `sh`): по
# прежнему `-x` снятый бит выполнения означал «почты нет» при полностью настроенном SMTP.
[ -f "$NOTIFY" ] || { log "notify-event: нет $NOTIFY — пропуск '$SUBJECT'"; exit 0; }

# Санитизируем ключ для имени файла-отметки (только безопасные символы)
safe_key=$(printf '%s' "$KEY" | tr -c 'a-zA-Z0-9_-' '_')
STAMP="/tmp/notify-event.$safe_key.stamp"

# Throttle: если с прошлой УСПЕШНОЙ отправки этого ключа прошло меньше
# THROTTLE сек — молчим. busybox date +%s есть; отметка — содержимое файла.
now=$(date +%s)
case "$THROTTLE" in ''|*[!0-9]*) THROTTLE=0 ;; esac
if [ "$THROTTLE" -gt 0 ] && [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    _age=$(age_since "$last")
    if [ "$last" -gt 0 ] && [ "$_age" -lt "$THROTTLE" ]; then
        log "notify-event: throttle (${_age}с < ${THROTTLE}с) — пропуск '$SUBJECT' (key=$safe_key)"
        exit 0
    fi
fi

# Отправляем. Отметку времени ставим ТОЛЬКО при успехе notify.sh, чтобы
# временный сбой отправки (DNS/SMTP) не «съел» throttle-окно и письмо
# повторилось при следующем событии того же класса.
# (notify.sh выходит 0 и когда почта не настроена — это считаем «успехом»:
#  слать нечего, throttle просто не даст спамить логом.)
if sh "$NOTIFY" "$SUBJECT" "$BODY" >>"$LOG" 2>&1; then
    echo "$now" > "$STAMP"
    log "notify-event: отправлено '$SUBJECT' (key=$safe_key)"
    exit 0
else
    log "notify-event: notify.sh НЕ подтвердил отправку '$SUBJECT' (key=$safe_key) — повтор при след. событии"
    exit 1
fi
