#!/bin/sh
# totp.sh — ВТОРОЙ ФАКТОР входа в панель (TOTP, RFC 6238) + сессии панели.
#
# ЗАЧЕМ. Панель открыта наружу по WAN IP (web-ui.sh wan-on), и единственной защитой там был
# HTTP-Basic: браузер шлёт пароль на КАЖДЫЙ запрос, вторым фактором его расширить нельзя в
# принципе (диалог рисует браузер, не мы). Поэтому Basic ОСТАЁТСЯ первым фактором — uhttpd
# по-прежнему не пускает никого без пароля, — а второй проверяем сами: код из приложения
# (Google Authenticator / Aegis / 1Password) → сессионная кука → все CGI её требуют.
# WebAuthn/passkeys вместо TOTP невозможны без доменного имени (RP-ID по IP браузер не даёт),
# поэтому TOTP — не «промежуточный шаг», а единственный работающий по IP второй фактор.
#
# ПОЧЕМУ ГЕЙТ ГЛОБАЛЬНЫЙ, а не «только снаружи». Перед uhttpd стоит наш panel-tls, и до CGI
# доезжает REMOTE_ADDR терминатора (LAN-адрес роутера) — отличить «пришли из интернета» от
# «пришли из дома» панель НЕ МОЖЕТ ни при каких условиях. Поэтому 2FA либо включён для всех
# входов, либо выключен; пер-адресная защита от перебора живёт этажом ниже, в hashlimit
# цепочки PANEL_WAN (web-ui.sh). Здесь — счётчик неудач, общий на панель (см. totp_lock_*).
#
# КРИПТО — БЕЗ НОВЫХ БИНАРЕЙ: HMAC-SHA1 считает стоковый openssl (1.1.1l), который уже
# вендорится ради notify.sh и сертификата panel-tls: `openssl dgst -sha1 -mac HMAC -macopt
# hexkey:<HEX>`. Ключ бинарный (в нём NUL-байты), поэтому строковый `-hmac` не годится, а
# 8-байтовый счётчик собираем восьмеричными escape'ами printf. Проверено вектором RFC 6238
# (секрет 12345678901234567890, T=59 → 287082) прямо на роутере.
#
# ЧАСЫ. RTC на роутере НЕТ: до ntpsetclock время = 1970 и код не сойдётся НИКОГДА. Врать
# «неверный код» в этом случае нельзя (человек начнёт сверять телефон) — verify возвращает
# отдельный код 2 «часы не синхронизированы», а панель показывает это прямым текстом.
# Коды восстановления от часов НЕ зависят и работают даже тогда.
#
# СЕССИИ — НА /data, А НЕ В /tmp. Иначе каждый ребут разлогинивал бы все устройства ровно в
# тот момент, когда часы ещё не синхронизированы (см. выше) — то есть войти было бы нечем,
# кроме кода восстановления. В файле лежит SHA-256 токена, а не сам токен: полный бэкап панели
# (cgi-bin/backup) собирается по whitelist и .totp* в него не входит, но и утечка файла не
# должна давать готовый ключ от панели.
#
# ЕСЛИ ПОТЕРЯН ТЕЛЕФОН: 8 кодов восстановления (одноразовые, показываются один раз при
# включении) либо аварийный выключатель с роутера по SSH:  sh totp.sh disable --force

ENODIA_DIR=/data/usr/app/enodia
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}

TOTP_SEC="$ENODIA_STATE/.totp"             # активный секрет: "hex b32 created"
TOTP_PEND="$ENODIA_STATE/.totp-pending"    # секрет в процессе привязки (до подтверждения кодом)
TOTP_REC="$ENODIA_STATE/.totp-recovery"    # sha256 кодов восстановления; использованный помечен '-'
TOTP_SESS="$ENODIA_STATE/.totp-sessions"   # sha256(токен)⇥истекает⇥выдан⇥UA⇥адрес (см. «Сессии»)
TOTP_LAST=/tmp/.totp-last             # анти-replay: последний ПРИНЯТЫЙ счётчик шагов
TOTP_FAIL=/tmp/.totp-fail             # "неудач разблокировка_ts" (RAM: ребут = чистый лист)

TOTP_STEP=30                          # шаг TOTP, с (RFC 6238; менять нельзя — приложения ждут 30)
TOTP_WINDOW=1                         # ±1 шаг: покрывает расхождение часов телефона до 30 с
TOTP_SESS_TTL=2592000                 # 30 суток — «не спрашивать на этом устройстве»
TOTP_REC_N=8                          # кодов восстановления
TOTP_MAX_FAILS=5                      # после стольких неудач подряд включается пауза
TOTP_LOCK_CAP=900                     # потолок паузы, с (15 мин): дальше удваивать бессмысленно

TOTP_B32A=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567

totp_now() { date +%s 2>/dev/null; }

# Часы «настоящие»? Тот же порог, что у выписки сертификата в web-ui.sh: до ntpsetclock на
# роутере 1970 год, и любое время-зависимое решение в этот момент — ложь.
totp_clock_ok() {
	n=$(totp_now)
	[ -n "$n" ] && [ "$n" -ge 1700000000 ] 2>/dev/null
}

totp_enabled() { [ -s "$TOTP_SEC" ]; }

# ЗАВЕРШАЮЩИЙ `echo` ОБЯЗАТЕЛЕН: `tr -cd` съедает перевод строки вместе со всем «лишним», и
# без него `totp_sha256 >> файл` склеивал все хеши В ОДНУ СТРОКУ — восемь кодов восстановления
# превращались в один нераспознаваемый огрызок (grep по `^хеш$` не находил ни одного, а панель
# рапортовала «осталось 1»). Потребителям через `$(...)` перевод строки не мешает — он срезается.
totp_sha256() { printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | sed 's/.*= *//' | tr -cd 'a-f0-9'; echo; }

# HMAC-SHA1(ключ_hex, счётчик) → 40 hex. Счётчик уходит в openssl ВОСЬМЕРИЧНЫМИ escape'ами:
# в 8-байтовом big-endian представлении почти всегда есть NUL, а через переменную shell такой
# байт не пронести — printf пишет его прямо в пайп.
totp_hmac_hex() {
	_c=$2; _esc=""; _i=8
	while [ "$_i" -gt 0 ]; do
		_b=$((_c % 256)); _c=$((_c / 256))
		_esc="\\$(printf '%03o' "$_b")$_esc"
		_i=$((_i - 1))
	done
	printf "$_esc" | openssl dgst -sha1 -mac HMAC -macopt hexkey:"$1" -hex 2>/dev/null |
		sed 's/.*= *//' | tr -cd 'a-f0-9'
}

# Динамическая усечка (RFC 4226 §5.4): младший полубайт последнего байта = смещение,
# оттуда 4 байта, старший бит гасим (знак), остаток от 10^6.
totp_code() {
	_h=$(totp_hmac_hex "$1" "$2")
	[ "${#_h}" -eq 40 ] || return 1
	_off=$(( 0x$(printf '%s' "$_h" | cut -c40) * 2 + 1 ))
	_p=$(printf '%s' "$_h" | cut -c"$_off"-$((_off + 7)))
	_v=$(( 0x$_p & 0x7fffffff ))
	printf '%06d' $((_v % 1000000))
}

# 40 hex (160 бит) → 32 символа base32 БЕЗ паддинга: 160 кратно 5, ровно как ждёт otpauth.
# Идём пятёрками hex (20 бит = 4 символа), чтобы уместиться в арифметику shell.
totp_b32() {
	_h="$1"; _out=""; _i=1
	while [ "$_i" -le 40 ]; do
		_v=$(( 0x$(printf '%s' "$_h" | cut -c"$_i"-$((_i + 4))) ))
		for _s in 15 10 5 0; do
			_n=$(( (_v >> _s) & 31 ))
			_out="$_out$(printf '%s' "$TOTP_B32A" | cut -c$((_n + 1)))"
		done
		_i=$((_i + 5))
	done
	printf '%s' "$_out"
}

totp_secret_hex() { [ -s "$TOTP_SEC" ] || return 1; read _hx _rest < "$TOTP_SEC"; printf '%s' "$_hx"; }
totp_secret_b32() { [ -s "$TOTP_SEC" ] || return 1; read _hx _b3 _rest < "$TOTP_SEC"; printf '%s' "$_b3"; }

# --- Пауза после неудач ------------------------------------------------------
# Счётчик ОБЩИЙ на панель, а не пер-адресный: см. шапку — адрес клиента до CGI не доезжает.
# Растёт удвоением от 60 с, потолок 15 мин: перебор 6 цифр становится безнадёжным, а хозяин
# теряет максимум четверть часа (и всегда может войти кодом восстановления).
totp_lock_left() {
	_f=0; _u=0
	[ -s "$TOTP_FAIL" ] && read _f _u _rest < "$TOTP_FAIL" 2>/dev/null
	case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
	case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
	_n=$(totp_now)
	if [ "$_u" -gt "${_n:-0}" ] 2>/dev/null; then echo $((_u - _n)); else echo 0; fi
}

totp_lock_bump() {
	_f=0; _u=0
	[ -s "$TOTP_FAIL" ] && read _f _u _rest < "$TOTP_FAIL" 2>/dev/null
	case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
	_f=$((_f + 1)); _u=0
	if [ "$_f" -ge "$TOTP_MAX_FAILS" ]; then
		_d=60; _k=$((_f - TOTP_MAX_FAILS))
		while [ "$_k" -gt 0 ] && [ "$_d" -lt "$TOTP_LOCK_CAP" ]; do _d=$((_d * 2)); _k=$((_k - 1)); done
		[ "$_d" -gt "$TOTP_LOCK_CAP" ] && _d=$TOTP_LOCK_CAP
		_u=$(( $(totp_now) + _d ))
	fi
	printf '%s %s\n' "$_f" "$_u" > "$TOTP_FAIL" 2>/dev/null
}

totp_lock_reset() { rm -f "$TOTP_FAIL" 2>/dev/null; return 0; }

# --- Проверка кода -----------------------------------------------------------
# Коды: 0 = принят · 1 = не подошёл · 2 = часы не синхронизированы · 3 = пауза после неудач.
# Анти-replay: принятый счётчик запоминаем и больше не принимаем — иначе подсмотренный код
# работал бы все 30 с окна ещё раз (и ещё раз в окне ±1 у соседнего запроса).
totp_check_code() {
	[ "$(totp_lock_left)" -gt 0 ] 2>/dev/null && return 3
	_in=$(totp_rec_norm "$1")
	# Код восстановления РАЗБИРАЕМ ПО ДЛИНЕ (10), а не по наличию букв: hex-код вполне может
	# выпасть чисто цифровым (шанс ~1%), и «есть буквы» отправило бы его в ветку TOTP, где он
	# не подойдёт никогда. Проверяем его ПЕРВЫМ — он не зависит от часов и остаётся единственным
	# входом, когда телефон потерян или время ещё не синхронизировано.
	if [ "${#_in}" -eq 10 ]; then
		if totp_check_recovery "$_in"; then totp_lock_reset; return 0; fi
		totp_lock_bump; return 1
	fi
	_in=$(printf '%s' "$1" | tr -cd '0-9')
	[ "${#_in}" -eq 6 ] || { totp_lock_bump; return 1; }
	totp_clock_ok || return 2
	_hex=$(totp_secret_hex) || return 1
	_base=$(( $(totp_now) / TOTP_STEP ))
	_last=$(cat "$TOTP_LAST" 2>/dev/null)
	case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
	_d=$((0 - TOTP_WINDOW))
	while [ "$_d" -le "$TOTP_WINDOW" ]; do
		_c=$((_base + _d))
		if [ "$_c" -gt "$_last" ] && [ "$(totp_code "$_hex" "$_c")" = "$_in" ]; then
			echo "$_c" > "$TOTP_LAST" 2>/dev/null
			totp_lock_reset
			return 0
		fi
		_d=$((_d + 1))
	done
	totp_lock_bump
	return 1
}

# Проверка кода ВВОДИМОГО СЕКРЕТА (привязка): тот же алгоритм, но секрет ещё в .totp-pending.
totp_check_pending() {
	[ -s "$TOTP_PEND" ] || return 1
	totp_clock_ok || return 2
	read _hex _rest < "$TOTP_PEND"
	_in=$(printf '%s' "$1" | tr -cd '0-9')
	[ "${#_in}" -eq 6 ] || return 1
	_base=$(( $(totp_now) / TOTP_STEP ))
	_d=$((0 - TOTP_WINDOW))
	while [ "$_d" -le "$TOTP_WINDOW" ]; do
		[ "$(totp_code "$_hex" "$((_base + _d))")" = "$_in" ] && return 0
		_d=$((_d + 1))
	done
	return 1
}

# --- Коды восстановления -----------------------------------------------------
# Хранится SHA-256, а не сам код: файл на флеше, а код — это вход в панель. Соли нет
# намеренно: код случайный (40 бит), словарь по нему не построить.
#
# ГРАБЛЯ (железо): отдельного `tr -d '- '` тут быть НЕ МОЖЕТ — busybox видит ведущий дефис в
# наборе и падает «unrecognized option», функция возвращала ПУСТО, и код восстановления не
# подходил НИКОГДА (а именно он — единственный вход при потерянном телефоне). Дефисы и пробелы
# и так уходят в комплементарном `-cd`: он оставляет ровно [a-z0-9], всё прочее удаляет.
totp_rec_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }

totp_check_recovery() {
	[ -s "$TOTP_REC" ] || return 1
	_n=$(totp_rec_norm "$1")
	[ "${#_n}" -eq 10 ] || return 1
	_h=$(totp_sha256 "$_n")
	grep -q "^$_h\$" "$TOTP_REC" 2>/dev/null || return 1
	# Одноразовость: помечаем строку дефисом (не удаляем — панель показывает, сколько осталось).
	sed "s/^$_h\$/-$_h/" "$TOTP_REC" > "$TOTP_REC.tmp" 2>/dev/null &&
		mv "$TOTP_REC.tmp" "$TOTP_REC" 2>/dev/null
	chmod 600 "$TOTP_REC" 2>/dev/null
	return 0
}

totp_rec_left() {
	_c=$(grep -c '^[0-9a-f]' "$TOTP_REC" 2>/dev/null)
	case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
	echo "$_c"
}

# ГЕНЕРИМ В ЧЕРНОВИК, ВЫКЛАДЫВАЕМ ЦЕЛИКОМ. Прежняя форма ПЕРВЫМ делом обнуляла боевой файл
# (`: > "$TOTP_REC"`) и лишь потом набивала его в цикле: любой обрыв на середине (openssl не дал
# случайности, кончилось место на /data) оставлял человека БЕЗ ЕДИНОГО кода восстановления — а
# перевыпуск он затевал как раз потому, что коды нужны. Наружу при этом уходило честное «не
# удалось», то есть потерю никто бы не заметил до дня, когда телефон потерян. Теперь провал
# оставляет СТАРЫЕ коды в силе: они хуже новых только тем, что часть уже использована.
totp_rec_gen() {
	_tmp="$TOTP_REC.new"
	: > "$_tmp" 2>/dev/null || return 1
	chmod 600 "$_tmp" 2>/dev/null
	_i=0; _out=""
	while [ "$_i" -lt "$TOTP_REC_N" ]; do
		_c=$(openssl rand -hex 5 2>/dev/null | tr -cd 'a-f0-9' | cut -c1-10)
		[ "${#_c}" -eq 10 ] || { rm -f "$_tmp" 2>/dev/null; return 1; }
		totp_sha256 "$_c" >> "$_tmp" || { rm -f "$_tmp" 2>/dev/null; return 1; }
		_out="$_out $(printf '%s' "$_c" | cut -c1-5)-$(printf '%s' "$_c" | cut -c6-10)"
		_i=$((_i + 1))
	done
	# Сверяем ЧИСЛО строк, а не только код возврата: `>>` на переполненном /data может дать
	# короткую запись без ошибки, и файл с пятью кодами из восьми выглядел бы исправным.
	_n=$(grep -c '^[0-9a-f]' "$_tmp" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
	[ "$_n" -eq "$TOTP_REC_N" ] || { rm -f "$_tmp" 2>/dev/null; return 1; }
	mv "$_tmp" "$TOTP_REC" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
	chmod 600 "$TOTP_REC" 2>/dev/null
	printf '%s\n' "${_out# }"
}

# --- Сессии ------------------------------------------------------------------
# ФОРМАТ СТРОКИ: sha256(токен)⇥истекает⇥выдан⇥UA⇥адрес. Две последние колонки добавлены позже
# ради экрана «устройства»; МИГРАЦИЯ НЕ НУЖНА и не пишется: `read`/`awk` по трёхколоночной
# строке просто отдают пустые UA и адрес, а сама строка продолжает работать как раньше. Ради
# двух подписей переписывать файл, в котором лежат ключи от панели, — лишний риск.
#
# ЧТО МЫ НЕ ПИШЕМ: «последний раз видели». Кука проверяется на КАЖДЫЙ запрос панели (поллинг
# шапки — раз в несколько секунд), и обновление отметки означало бы запись на флеш в том же
# ритме. Ради подписи, которую и так заменяет «вошли тогда-то», флеш не насилуем.
#
# АДРЕС СОХРАНЯЕМ КАК ЕСТЬ, но честно: за `panel-tls` до CGI доезжает REMOTE_ADDR терминатора,
# то есть LAN-адрес самого роутера (разбор — в шапке файла). Отличить «зашли из интернета» от
# «зашли из дома» нельзя в принципе, поэтому здесь мы не гадаем: панель сравнивает адрес со
# СВОИМ LAN-адресом (он у неё уже есть в срезе web-ui.sh) и подписывает такие входы «через
# HTTPS». Второй копии детектора LAN-адреса тут не заводим.

# Санитайзеры полей. Значения приходят из ЗАГОЛОВКОВ запроса, то есть полностью подконтрольны
# клиенту: в файл (TSV) не должны просочиться табы и переводы строк, а в JSON — кавычки и
# обратные слэши. Поэтому не «удаляем плохое», а оставляем ТОЛЬКО заведомо безопасное.
# ГРАБЛЯ busybox: дефис в наборе `tr` обязан стоять ПОСЛЕДНИМ — ведущий читается как опция
# («unrecognized option»), и функция вернула бы пусто.
totp_sess_ua()   { printf '%s' "$1" | tr -cd 'A-Za-z0-9 ().,;:/_-' | cut -c1-120; }
totp_sess_addr() { printf '%s' "$1" | tr -cd '0-9A-Fa-f.:' | cut -c1-45; }

totp_sess_gc() {
	[ -s "$TOTP_SESS" ] || return 0
	_n=$(totp_now)
	awk -F'\t' -v n="${_n:-0}" '$2+0 > n' "$TOTP_SESS" > "$TOTP_SESS.tmp" 2>/dev/null &&
		mv "$TOTP_SESS.tmp" "$TOTP_SESS" 2>/dev/null
	chmod 600 "$TOTP_SESS" 2>/dev/null
	return 0
}

totp_sess_new() {                     # totp_sess_new [UA] [адрес]
	_t=$(openssl rand -hex 32 2>/dev/null | tr -cd 'a-f0-9')
	[ "${#_t}" -eq 64 ] || return 1
	totp_sess_gc
	printf '%s\t%s\t%s\t%s\t%s\n' "$(totp_sha256 "$_t")" "$(( $(totp_now) + TOTP_SESS_TTL ))" \
		"$(totp_now)" "$(totp_sess_ua "${1:-}")" "$(totp_sess_addr "${2:-}")" >> "$TOTP_SESS"
	chmod 600 "$TOTP_SESS" 2>/dev/null
	printf '%s\n' "$_t"
}

# Проверка НЕ трогает файл (её зовёт КАЖДЫЙ запрос панели) — чистка живёт в выдаче/логауте.
totp_sess_check() {
	_tg_t=$(printf '%s' "$1" | tr -cd 'a-f0-9')
	[ "${#_tg_t}" -eq 64 ] || return 1
	[ -s "$TOTP_SESS" ] || return 1
	awk -F'\t' -v h="$(totp_sha256 "$_tg_t")" -v n="$(totp_now)" \
		'$1==h && $2+0 > n+0 {ok=1} END{if(ok) exit 0; exit 1}' "$TOTP_SESS"
}

totp_sess_count() {
	totp_sess_gc
	_c=$(grep -c . "$TOTP_SESS" 2>/dev/null)
	case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
	echo "$_c"
}

totp_sess_clear() { : > "$TOTP_SESS" 2>/dev/null; chmod 600 "$TOTP_SESS" 2>/dev/null; return 0; }

# Список сессий для панели. `id` = САМ ХЕШ токена, а не его кусок: сравнение потом идёт точным
# `$1==id` (у busybox awk нет ни index(), ни своих функций — на substr закладываться не хочется),
# а знание хеша входа не даёт: гейт считает sha256 от предъявленного токена, обратно не ходит.
# Своей сортировки нет — её делает панель: единственный порядок, который тут можно навязать,
# всё равно пришлось бы дублировать в UI при первом же «а покажи сначала текущую».
totp_sess_list() {                    # totp_sess_list [токен текущей сессии]
	totp_sess_gc
	_sl_h=""
	_sl_t=$(printf '%s' "${1:-}" | tr -cd 'a-f0-9')
	# Условия — через `if`, а НЕ цепочкой `[ … ] && var=…`: этот файл СОРСЯТ чужие CGI, и простая
	# команда, вернувшая 1, у вызывающего с `set -e` уронила бы весь запрос (та же грабля, из-за
	# которой в store-lib переписан bin_path).
	if [ "${#_sl_t}" -eq 64 ]; then _sl_h=$(totp_sha256 "$_sl_t"); fi
	printf '['
	if [ -s "$TOTP_SESS" ]; then
		_sl_first=1
		# Редирект, а НЕ пайп: в пайпе цикл ушёл бы в подоболочку и `_sl_first` не пережил бы
		# итерацию — запятые в JSON поехали бы (класс «busybox без local», уже ловленный).
		while IFS="$(printf '\t')" read -r _sl_id _sl_exp _sl_iss _sl_ua _sl_ad; do
			[ -n "$_sl_id" ] || continue
			case "$_sl_exp" in ''|*[!0-9]*) _sl_exp=0 ;; esac
			case "$_sl_iss" in ''|*[!0-9]*) _sl_iss=0 ;; esac
			_sl_cur=false
			if [ -n "$_sl_h" ] && [ "$_sl_id" = "$_sl_h" ]; then _sl_cur=true; fi
			[ "$_sl_first" = 1 ] || printf ','
			_sl_first=0
			printf '{"id":"%s","cur":%s,"issued":%s,"expires":%s,"ua":"%s","addr":"%s"}' \
				"$_sl_id" "$_sl_cur" "$_sl_iss" "$_sl_exp" "$_sl_ua" "$_sl_ad"
		done < "$TOTP_SESS"
	fi
	printf ']'
}

# «Выйти на ОСТАЛЬНЫХ устройствах». Гард обязателен: если предъявленной сессии в файле нет
# (протухла между запросом и нажатием), пустой фильтр вычистил бы файл целиком — то есть
# кнопка «кроме текущей» сделала бы ровно «выйти везде», включая здесь.
totp_sess_keep_only() {               # totp_sess_keep_only <токен>
	_ko_t=$(printf '%s' "${1:-}" | tr -cd 'a-f0-9')
	totp_sess_check "$_ko_t" || return 1
	awk -F'\t' -v h="$(totp_sha256 "$_ko_t")" '$1==h' "$TOTP_SESS" > "$TOTP_SESS.tmp" 2>/dev/null &&
		mv "$TOTP_SESS.tmp" "$TOTP_SESS" 2>/dev/null
	chmod 600 "$TOTP_SESS" 2>/dev/null
	return 0
}

# Отзыв ОДНОЙ сессии по её id (= хеш из totp_sess_list). Возврат 1, если такой строки нет —
# иначе панель рапортовала бы «отвязано» о несуществующем устройстве.
totp_sess_revoke() {                  # totp_sess_revoke <id>
	_rv_i=$(printf '%s' "${1:-}" | tr -cd 'a-f0-9')
	[ "${#_rv_i}" -eq 64 ] || return 1
	[ -s "$TOTP_SESS" ] || return 1
	# Существование проверяем ТЕМ ЖЕ awk, а не grep'ом с табом в шаблоне: литеральный таб внутри
	# кавычек — первое, что теряется при копировании файла редактором.
	awk -F'\t' -v h="$_rv_i" '$1==h{f=1} END{exit f?0:1}' "$TOTP_SESS" 2>/dev/null || return 1
	awk -F'\t' -v h="$_rv_i" '$1!=h' "$TOTP_SESS" > "$TOTP_SESS.tmp" 2>/dev/null &&
		mv "$TOTP_SESS.tmp" "$TOTP_SESS" 2>/dev/null
	chmod 600 "$TOTP_SESS" 2>/dev/null
	return 0
}

# Хеш токена наружу — панели нужно понять, свою ли сессию отзывают (тогда надо гасить куку).
totp_sess_id() { totp_sha256 "$(printf '%s' "${1:-}" | tr -cd 'a-f0-9')"; }

# --- Гейт для CGI ------------------------------------------------------------
# Кука приходит в HTTP_COOKIE (uhttpd её пробрасывает — проверено на железе; в его whitelist
# заголовков HTTP_COOKIE есть). Флаг Secure НЕ ставим: панель работает и по обычному HTTP в
# домашней сети, а с Secure кука там просто не сохранилась бы. Утечки это не добавляет —
# по тому же каналу и так идёт Basic-пароль; снаружи же панель открывается ТОЛЬКО по HTTPS
# (web-ui.sh наружу голый порт не выставляет никогда).
totp_cookie() {
	printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | sed 's/^ *//' |
		grep '^panel2fa=' | head -1 | cut -d= -f2 | tr -cd 'a-f0-9'
}

# Переменные гейта нарочно с префиксом `_tg_`: этот файл СОРСЯТ все CGI, а они держат свои
# «локальные» имена вида `_c`/`_t`/`_f` по соглашению — совпадение имён здесь означало бы порчу
# чужого состояния из совершенно другого файла, и искать такое пришлось бы очень долго.
totp_gate() {
	totp_enabled || return 0
	_tg_c=$(totp_cookie)
	[ -n "$_tg_c" ] || return 1
	totp_sess_check "$_tg_c"
}

# Зовут CGI ОДНОЙ строкой (см. web/cgi-bin/*). Отдаём 403 + машинный признак need2fa: фронт
# по нему поднимает окно ввода кода, а не показывает «сбой запроса» на каждом поллинге.
totp_gate_deny() {
	totp_gate && return 0
	echo "Status: 403 Forbidden"
	echo "Content-Type: application/json; charset=utf-8"
	echo "Cache-Control: no-store"
	echo ""
	printf '{"ok":false,"need2fa":true,"msg":"нужен код подтверждения"}\n'
	exit 0
}

totp_status_json() {
	_on=false; totp_enabled && _on=true
	_pd=false; [ -s "$TOTP_PEND" ] && _pd=true
	_ck=false; totp_clock_ok && _ck=true
	printf '{"engine":true,"on":%s,"pending":%s,"clock":%s,"recovery":%s,"sessions":%s,"lock":%s}\n' \
		"$_on" "$_pd" "$_ck" "$(totp_rec_left)" "$(totp_sess_count)" "$(totp_lock_left)"
}

# Строка otpauth:// для QR и ручного ввода. Издатель — модель роутера (у кого несколько
# роутеров, записи в приложении различимы); пробелы в метке ломают часть сканеров ⇒ дефисы.
totp_uri() {
	_b3="$1"
	_lbl=$(command -v router_model >/dev/null 2>&1 && router_model)
	[ -n "$_lbl" ] || _lbl="Xiaomi"
	_lbl=$(printf '%s' "$_lbl" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-')
	printf 'otpauth://totp/%s:admin?secret=%s&issuer=%s&algorithm=SHA1&digits=6&period=30\n' \
		"$_lbl" "$_b3" "$_lbl"
}

# --- Вербы -------------------------------------------------------------------
cmd_enroll() {
	_hex=$(openssl rand -hex 20 2>/dev/null | tr -cd 'a-f0-9')
	[ "${#_hex}" -eq 40 ] || { echo "не удалось сгенерировать секрет (нет openssl?)"; return 1; }
	_b3=$(totp_b32 "$_hex")
	printf '%s %s %s\n' "$_hex" "$_b3" "$(totp_now)" > "$TOTP_PEND" || return 1
	chmod 600 "$TOTP_PEND" 2>/dev/null
	echo "$_b3"
	totp_uri "$_b3"
}

# Включение = подтверждение кодом ИМЕННО из привязываемого секрета: без этого человек включил
# бы 2FA с неверно перенесённым секретом и запер сам себя (телефон показывает чужие цифры).
cmd_enable() {
	[ -s "$TOTP_PEND" ] || { echo "привязка не начата"; return 1; }
	totp_check_pending "$1"; _r=$?
	[ "$_r" = 2 ] && { echo "часы роутера не синхронизированы — подожди минуту и повтори"; return 2; }
	[ "$_r" = 0 ] || { echo "код не подошёл"; return 1; }
	mv "$TOTP_PEND" "$TOTP_SEC" || return 1
	chmod 600 "$TOTP_SEC" 2>/dev/null
	rm -f "$TOTP_LAST" 2>/dev/null
	totp_lock_reset
	cmd_recovery_new_raw
}

cmd_recovery_new_raw() {
	_codes=$(totp_rec_gen) || { echo "не удалось сгенерировать коды восстановления"; return 1; }
	printf '%s\n' "$_codes"
}

cmd_disable() {
	case "$1" in
		--force) : ;;                       # аварийный путь с роутера (SSH), см. шапку
		*) totp_enabled || { echo "двухфакторный вход и так выключен"; return 0; }
		   totp_check_code "$1"; _r=$?
		   [ "$_r" = 3 ] && { echo "слишком много неудачных попыток — подожди"; return 3; }
		   [ "$_r" = 2 ] && { echo "часы роутера не синхронизированы"; return 2; }
		   [ "$_r" = 0 ] || { echo "код не подошёл"; return 1; } ;;
	esac
	rm -f "$TOTP_SEC" "$TOTP_PEND" "$TOTP_REC" "$TOTP_LAST" 2>/dev/null
	totp_sess_clear
	totp_lock_reset
	echo "двухфакторный вход выключен"
}

case "${TOTP_LIB:-}" in
	"") ;;
	*) return 0 ;;      # sourced из CGI (гейт) — ниже только CLI-диспетчер
esac

# Детект модели — для метки в приложении-аутентификаторе (шим, если lib ещё не залит).
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi

case "$1" in
	status)        totp_status_json ;;
	enroll)        cmd_enroll ;;
	enable)        cmd_enable "$2" ;;
	disable|off)   cmd_disable "$2" ;;
	verify)        totp_check_code "$2"; exit $? ;;
	session-new)   totp_sess_new "$2" "$3" ;;
	session-check) totp_sess_check "$2"; exit $? ;;
	session-list)  totp_sess_list "$2"; echo ;;
	logout-all)    totp_sess_clear; echo "все устройства разлогинены" ;;
	logout-others) totp_sess_keep_only "$2" || { echo "текущая сессия не найдена — выход не сделан"; exit 1; }
	               echo "остальные устройства разлогинены" ;;
	session-del)   totp_sess_revoke "$2" || { echo "нет такой сессии"; exit 1; }
	               echo "устройство отвязано" ;;
	recovery-new)  totp_enabled || { echo "двухфакторный вход выключен"; exit 1; }
	               totp_check_code "$2" || { echo "код не подошёл"; exit 1; }
	               cmd_recovery_new_raw ;;
	uri)           _b=$(totp_secret_b32) && totp_uri "$_b" ;;
	gate)          totp_gate; exit $? ;;
	*) echo "usage: $0 {status|enroll|enable <код>|disable <код>|disable --force|verify <код>|"
	   echo "              recovery-new <код>|session-new [UA] [адрес]|session-check <токен>|"
	   echo "              session-list [токен]|session-del <id>|logout-all|logout-others <токен>|uri|gate}"
	   exit 1 ;;
esac
