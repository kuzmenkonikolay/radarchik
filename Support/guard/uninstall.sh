#!/bin/bash
# Root-часть «Защиты» Радарчика (SPEC §3б): удаление. Запускается из `make uninstall-guard`.
#
# Перед удалением root-часть возвращает тебе все ключи из своего списка:
# без неё закрытые файлы так и остались бы у root. Каждая команда от root
# печатается перед выполнением.
set -euo pipefail

LABEL=dev.kuzmenko.radarchik.guardd
RIGHT=dev.kuzmenko.radarchik.guard.unlock
DATA=/var/db/dev.kuzmenko.radarchik.guard

echo "Root-часть вернёт тебе все ключи из своего списка (станут обычными файлами) и удалится."
read -r -p "Продолжить? [y/N] " answer
[[ "$answer" == [yYдД]* ]] || exit 0

set -x
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo "/Library/PrivilegedHelperTools/$LABEL" --release-all "$USER" || true
sudo rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL"
sudo security authorizationdb remove "$RIGHT" || true
sudo rm -rf "$DATA"
