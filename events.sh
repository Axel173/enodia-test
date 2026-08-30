#!/bin/sh
# events.sh — ЖУРНАЛ СОБЫТИЙ роутера («центр уведомлений» веб-панели).
#
# Зачем отдельно от notify-event.sh:
#   notify-event.sh решает «слать ли ПИСЬМО» (throttle + .notify-off). Но панель
#   должна показывать, что происходило, ДАЖЕ когда почта не настроена, выключена
#   или письмо задушено throttle'ом. Это два разных вопроса: «уведомить наружу»
#   и «запомнить для истории». Поэтому журнал — свой скрипт, а notify-event.sh
#   зовёт его ДО своих гейтов. Побочный плюс: журнал переиспользуем — любой
#   скрипт может писать событие, не втягивая SMTP.
#
# Использование:
#   events.sh add <key> <dedup_sec> "Тема" "Текст"
#   events.sh list [n]        — JSON для панели (по умолчанию все, кольцо ≤ MAX)
#   events.sh mark-read       — пометить всё прочитанным (отметка = «сейчас»)
#   events.sh clear           — очистить журнал
#
# dedup_sec — окно СХЛОПЫВАНИЯ повторов того же key (передаём тот же throttle,
#   что и у письма: событие, письмо о котором задушено, не должно плодить строки).
#   Повтор в окне не добавляет строку, а обновляет существующую: count+1 и свежий
#   ts/текст. 0 = не схлопывать (редкие события: boot, утренняя сводка).
#
# Хранилище — на /data (переживает ребут): журнал ценен именно после ребута
# («что было ночью, пока меня не было»), в /tmp он бы стирался ровно тогда, когда
# нужен. Запись идёт только по событию (boot / switch / failover / сводка) —
# несколько строк в сутки, флеш это не изнашивает.
#
# Формат строки — TSV, ровно 6 полей:
#   ts \t key \t level \t count \t base64(title) \t base64(text)
# ПОЧЕМУ base64 у текста: тело события многострочное и содержит кавычки/юникод, а
# JSON-экранирования на busybox нет (нет ни jq, ни awk-функций). Плоский TSV с
# base64-полями и разбирается awk'ом в одну строку, и в JSON уезжает без единого
# спецсимвола — панель декодирует своим b64toUtf8 (уже есть у редактора списков).
# Побочно это защищает CGI-JSON от порчи чужим текстом.

ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
EV="$ENODIA_STATE/.events"
READ_MARK="$ENODIA_STATE/.events-read"
LOCK=/tmp/enodia-events.lock
MAX=100            # кольцо: держим последние N событий (≈20 КБ) — панели больше не нужно

# Единый детект модели: заголовки событий callers хардкодят «BE7000:» — на AX3600/BE3600
# журнал панели врал моделью. router_relabel переписывает лидирующий код на реальный.
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi

# Возраст ЛОКА — через age_since (clock-lib.sh): лок живёт в /tmp, то есть рождается после
# загрузки, а скачок часов вперёд делает СВЕЖИЙ лок «протухшим» — и в журнал полезли бы два
# писателя разом. Возраст записи в самом журнале считается иначе, там отметка переживает ребут
# (см. `# clock-raw:` ниже). Шим = прежнее поведение для установки без библиотеки.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
	case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
	[ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

now=$(date +%s)

# --- Лок: cron-скрипты (heal/watchdog) могут писать событие одновременно ------
# mkdir — атомарный на busybox (паттерн lists-update.sh). Устаревший лок (скрипт
# умер, не убрав) снимаем по возрасту, иначе журнал замолчал бы навсегда.
lock_take() {
	i=0
	while [ "$i" -lt 30 ]; do
		mkdir "$LOCK" 2>/dev/null && return 0
		i=$((i + 1))
		if [ -d "$LOCK" ]; then
			# Возраст лока. `date -r` есть не в каждой сборке busybox (на BE7000 есть — проверено
			# 04.08.2026), и прежний фолбэк `|| echo 0` в этом случае давал возраст «эпоха» ⇒ ЖИВОЙ
			# лок сносился на ПЕРВОЙ же итерации, то есть на сборке без `-r` лока не было вовсе.
			# Не смогли узнать возраст — считаем лок свежим: подождать безопаснее, чем топтать журнал.
			lt=$(date -r "$LOCK" +%s 2>/dev/null)
			case "$lt" in ''|*[!0-9]*) lt=$now ;; esac
			[ "$(age_since "$lt")" -gt 60 ] && { rm -rf "$LOCK" 2>/dev/null; continue; }
		fi
		sleep 1
	done
	return 1
}
lock_free() { rm -rf "$LOCK" 2>/dev/null; }

# --- Уровень события выводим ИЗ КЛЮЧА ----------------------------------------
# Так вызывающим (их 10 мест) не надо менять сигнатуру и помнить про уровни —
# ключ у события и так есть. Порядок веток ЗНАЧИМ: «failover-ok» содержит «fail»,
# поэтому -ok/rollback разбираются РАНЬШЕ общей fail-ветки.
level_of() {
	case "$1" in
		*failover-ok|*rollback)   echo warn ;;   # работает, но не штатно (ушли на резерв / откатились)
		wan-down)                 echo warn ;;   # интернета нет ВООБЩЕ: авария у провайдера, VPN ни при чём
		# «fail» ГДЕ УГОДНО в ключе, а не только в конце: ключ доп-выхода — `slot-fail-2`, он
		# кончается НОМЕРОМ, и прежние глобы (*-fail|*fail) его не брали ⇒ письмо «доп-выход
		# недоступен» лежало в центре уведомлений нейтральным info. Замерено на AX3600 17.08.2026.
		*fail*|awg0-down|subs-nospace) echo err ;;
		# Ключи, у которых беда не названа словом «fail». Их НЕ выводит никакой глоб — только
		# перечисление, и новый ключ по умолчанию попадает в info: заводя событие о поломке или
		# деградации, впиши его СЮДА, иначе панель покажет его наравне с «подписки обновлены».
		# cross-switch — несущую сменил АВТОМАТ (awg↔альт): связь есть, но не та, что выбрал
		# человек. rule-heal — правила сплита кто-то снёс (fw3-reload), роутер вернул их сам.
		# Оба «работает, но не штатно» — тот же уровень, что у failover-ok\rollback выше;
		# тревожного слова в ключе нет, значит глоб их не возьмёт — только это перечисление.
		transport-missing|geo-snap-skip|doh-auto-off|subs-active-gone|cross-switch|rule-heal) echo warn ;;
		*)                        echo info ;;
	esac
}

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\r\n'; }

cmd_add() {
	key="$1"; dedup="$2"; title="$3"; text="$4"
	[ -n "$key" ] || return 0
	command -v router_relabel >/dev/null 2>&1 && title=$(router_relabel "$title")
	# Ключ санитизируем: он уезжает в TSV и в JSON без экранирования.
	key=$(printf '%s' "$key" | tr -c 'a-zA-Z0-9_-' '_')
	case "$dedup" in ''|*[!0-9]*) dedup=0 ;; esac
	lvl=$(level_of "$key")

	lock_take || return 1
	touch "$EV" 2>/dev/null

	cnt=1
	if [ "$dedup" -gt 0 ]; then
		# Последнее событие этого класса: в окне — схлопываем (count+1), строку
		# пересоздаём в конце, чтобы порядок журнала оставался хронологическим.
		old=$(awk -F'\t' -v k="$key" '$2==k{l=$0} END{print l}' "$EV" 2>/dev/null)
		if [ -n "$old" ]; then
			old_ts=$(printf '%s' "$old" | cut -f1)
			old_cnt=$(printf '%s' "$old" | cut -f4)
			case "$old_ts"  in ''|*[!0-9]*) old_ts=0 ;; esac
			case "$old_cnt" in ''|*[!0-9]*) old_cnt=1 ;; esac
			# clock-raw: отметка лежит в САМОМ журнале на /data и переживает ребут ⇒ её возраст
			# законно больше аптайма, а age_since сказал бы «только что» про вчерашнее событие и
			# схлопнул бы его с сегодняшним. Судим голой разностью сознательно.
			if [ "$old_ts" -gt 0 ] && [ "$((now - old_ts))" -lt "$dedup" ]; then
				cnt=$((old_cnt + 1))
				awk -F'\t' -v k="$key" -v t="$old_ts" '!($2==k && $1==t)' "$EV" > "$EV.new" 2>/dev/null
				mv "$EV.new" "$EV" 2>/dev/null
			fi
		fi
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$key" "$lvl" "$cnt" "$(b64 "$title")" "$(b64 "$text")" >> "$EV"
	# Кольцо. Атомарно (.new + mv): CGI может читать журнал ровно в этот момент.
	if [ "$(wc -l < "$EV" 2>/dev/null || echo 0)" -gt "$MAX" ]; then
		tail -n "$MAX" "$EV" > "$EV.new" 2>/dev/null && mv "$EV.new" "$EV" 2>/dev/null
	fi
	lock_free
}

cmd_list() {
	n="$1"
	case "$n" in ''|*[!0-9]*) n=$MAX ;; esac
	rd=$(cat "$READ_MARK" 2>/dev/null)
	case "$rd" in ''|*[!0-9]*) rd=0 ;; esac
	# now отдаём часами РОУТЕРА: у него нет RTC, браузерное «сколько назад» без
	# этого врёт (та же причина, что в emit_sites у iplist_updated).
	printf '{"now":%s,"read_at":%s,"events":[' "$now" "$rd"
	if [ -s "$EV" ]; then
		tail -n "$n" "$EV" 2>/dev/null | awk -F'\t' -v OFS='' '
			NF>=6 {
				if (c++) printf ","
				printf "{\"ts\":%s,\"key\":\"%s\",\"level\":\"%s\",\"count\":%s,\"title\":\"%s\",\"text\":\"%s\"}", $1, $2, $3, $4, $5, $6
			}'
	fi
	printf '],"unread":%s}\n' "$(cmd_unread "$rd")"
}

# Непрочитанные = события свежее отметки. Отметка одна на журнал (а не флаг на
# строку): панель читает список целиком, поштучный read только плодил бы записи
# на флеш.
cmd_unread() {
	rd="$1"
	if [ -z "$rd" ]; then
		rd=$(cat "$READ_MARK" 2>/dev/null)
		case "$rd" in ''|*[!0-9]*) rd=0 ;; esac
	fi
	[ -s "$EV" ] || { echo 0; return; }
	awk -F'\t' -v r="$rd" '$1+0>r{n++} END{print n+0}' "$EV" 2>/dev/null || echo 0
}

case "$1" in
	add)        shift; cmd_add "$1" "$2" "$3" "$4" ;;
	list)       cmd_list "$2" ;;
	unread)     cmd_unread ;;
	mark-read)  echo "$now" > "$READ_MARK"; printf '{"ok":true,"read_at":%s}\n' "$now" ;;
	clear)      lock_take && { : > "$EV"; echo "$now" > "$READ_MARK"; lock_free; }; printf '{"ok":true}\n' ;;
	*)          echo "usage: $0 add <key> <dedup_sec> <title> <text> | list [n] | unread | mark-read | clear" >&2; exit 1 ;;
esac
