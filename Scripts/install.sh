#!/bin/bash
# Установка приложения в ~/Applications.
#
# Путь внутри DerivedData не годится для повседневной работы: он меняется при
# смене конфигурации сборки, а System Settings (песочное приложение) не может
# прочитать оттуда бандл — в «Объектах входа» вместо иконки серый плейсхолдер.
# `/Applications` требует прав администратора, поэтому по умолчанию ставим в
# пользовательский каталог.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="${1:-$HOME/Applications}"
APP_NAME="Little Snitch VPN Companion.app"
DEST="$DEST_DIR/$APP_NAME"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

echo "Собираю Release…"
xcodegen generate >/dev/null
xcodebuild -project LittleSnitchVPNCompanion.xcodeproj \
    -scheme LittleSnitchVPNCompanion -configuration Release build >/dev/null

BUILT=$(find ~/Library/Developer/Xcode/DerivedData/LittleSnitchVPNCompanion-*/Build/Products/Release \
    -maxdepth 1 -name "$APP_NAME" | head -1)
[ -n "$BUILT" ] || { echo "Не нашёл собранное приложение"; exit 1; }

pkill -f "$APP_NAME" 2>/dev/null || true
sleep 1
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

codesign --verify --strict "$DEST" || { echo "Подпись повреждена"; exit 1; }
"$LSREG" -f -R -trusted "$DEST" >/dev/null 2>&1 || true

echo "Установлено: $DEST"
open "$DEST"
echo
echo "Если менялся helper — нажми Настройки → Общие → «Переустановить…»"
echo "и одобри объект входа в Системных настройках."
