#!/bin/bash
# Root-часть «Защиты» Радарчика (SPEC §3б, этап 2): установка.
# Запускается из `make install-guard`.
#
# Шаг 1 — от тебя, без root: подпись Радарчика (её root-часть будет требовать
# у клиента) и список ключей с исключениями — файлами, которые лежат в git.
# Шаг 2 — от root, через sudo: каждая команда печатается перед выполнением.
set -euo pipefail

HELPER_BUILD="$1"   # собранный radarchik-guardd
APP="$2"            # Radarchik.app — его подписи root-часть будет доверять
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=dev.kuzmenko.radarchik.guardd
RIGHT=dev.kuzmenko.radarchik.guard.unlock
DATA=/var/db/dev.kuzmenko.radarchik.guard
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "1. От тебя: подпись Радарчика и список ключей"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$REQUIREMENT" ]]; then
    echo "   Не вышло прочитать подпись $APP"
    exit 1
fi
if [[ "$REQUIREMENT" == cdhash* ]]; then
    echo "   Радарчик подписан ad-hoc: после первой же пересборки root-часть перестанет его пускать."
    echo "   Нужен постоянный сертификат «Radarchik dev» в Связке ключей (см. Makefile)."
    exit 1
fi
printf '%s\n' "$REQUIREMENT" > "$TMP/client.requirement"
"$APP/Contents/MacOS/Radarchik" --guard export-config > "$TMP/config"
RULES="$(grep -vc -e '^#' -e '^exclude|' "$TMP/config" || true)"
EXCLUDED="$(grep -c '^exclude|' "$TMP/config" || true)"
echo "   подпись: $REQUIREMENT"
echo "   правил: $RULES, исключений (файлы в git): $EXCLUDED"
# Список взят из старого guard, а его конфиг мог править кто угодно от твоего имени.
# Root-часть трогает только обычные файлы внутри домашней папки, но глазами проверить стоит.
echo "   что будет защищать:"
grep -v '^#' "$TMP/config" | sed 's/^/     /'
read -r -p "   Всё верно? [Y/n] " answer
[[ "$answer" == [nNнН]* ]] && { echo "   Остановился. Поправь ~/work/guard/config и запусти снова."; exit 1; }

# Старый демон guard закрывал бы всё, что откроет Радарчик, — с тревогой каждые 30 секунд.
if [[ -f /Library/LaunchDaemons/com.guard.fileguard.plist ]]; then
    echo
    echo "   Старый демон guard (com.guard.fileguard) ещё стоит: он будет закрывать то, что откроет Радарчик."
    read -r -p "   Выгрузить и убрать его? [y/N] " answer
    if [[ "$answer" == [yYдД]* ]]; then
        sudo launchctl bootout system/com.guard.fileguard 2>/dev/null || true
        sudo rm -f /Library/LaunchDaemons/com.guard.fileguard.plist
    else
        echo "   Оставляю. Убери его до того, как открывать ключи из Радарчика."
    fi
fi

echo
echo "2. От root (sudo спросит пароль):"
set -x
sudo install -d -o root -g wheel -m 755 "$DATA"
sudo install -o root -g wheel -m 644 "$TMP/config" "$DATA/config"
sudo install -o root -g wheel -m 644 "$TMP/client.requirement" "$DATA/client.requirement"
[[ -d /Library/PrivilegedHelperTools ]] || sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$HELPER_BUILD" "/Library/PrivilegedHelperTools/$LABEL"
sudo install -o root -g wheel -m 644 "$HERE/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"
sudo security authorizationdb write "$RIGHT" < "$HERE/unlock-right.plist"
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
{ set +x; } 2>/dev/null
# После bootout launchd бывает занят ещё секунду — пробуем запустить несколько раз.
for attempt in 1 2 3 4 5; do
    if sudo launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null; then
        echo "+ sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist"
        break
    fi
    [[ "$attempt" == 5 ]] && { echo "Не вышло запустить root-часть: sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist"; exit 1; }
    sleep 1
done
# Ключи проектов, которые лежат в git (test.key), старый guard держал у root —
# и git не мог их прочитать (`git add .` падал). Отдаём их тебе.
set -x
sudo "/Library/PrivilegedHelperTools/$LABEL" --release-excluded "$USER"
{ set +x; } 2>/dev/null

echo
echo "Готово. Радарчик сейчас перезапустится сам; открой новое окно терминала и проверь:"
echo "  \"$APP/Contents/MacOS/Radarchik\" --guard status"
