#!/bin/bash
# Сборка и публикация релиза на GitHub.
#
# Сборка локальная, а не в CI: релизный артефакт обязан быть подписан самоподписанным
# сертификатом из Signing.xcconfig — helper пускает к себе только клиента, подписанного
# тем же сертификатом (Helper/ClientRequirement.swift). Приватный ключ этого сертификата
# и есть единственный гейт к привилегированному демону, поэтому в секретах Actions ему
# не место. Ad-hoc сборка из CI на роль релиза тоже не годится: без сертификата
# requirement вырождается в проверку одного identifier, и к root-демону проходит любой
# процесс с нужным bundle id.
#
# Сертификат встроен в подпись и едет вместе с бандлом, так что на целевой машине
# ни Xcode, ни связка ключей автора не нужны (README, «Перенос на другую машину»).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Little Snitch VPN Companion.app"
HELPER_NAME="dev.sunnyday.lsvpncompanion.helper"

usage() {
    cat >&2 <<'USAGE'
Использование: Scripts/release.sh <версия> [--publish]

  версия      1.1 или 1.1.0 — тег будет v<версия>, MARKETING_VERSION тоже
  --publish   опубликовать сразу; по умолчанию релиз создаётся черновиком,
              чтобы вычитать заметки и проверить вложение перед публикацией
USAGE
    exit 2
}

fail() { echo "Ошибка: $*" >&2; exit 1; }

VERSION=""
DRAFT=(--draft)
for arg in "$@"; do
    case "$arg" in
        --publish) DRAFT=() ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] || usage; VERSION="${arg#v}" ;;
    esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || fail "версия должна быть вида 1.1 или 1.1.0, получено «$VERSION»"
TAG="v$VERSION"
ZIP_NAME="LSVPNCompanion-$TAG.zip"
ZIP="build/$ZIP_NAME"

# --- Проверки до сборки: всё, что делает релиз негодным, должно всплыть за секунды,
# --- а не после пятиминутного xcodebuild.

for tool in gh xcodegen; do
    command -v "$tool" >/dev/null || fail "нужен $tool (brew install $tool)"
done
gh auth status >/dev/null 2>&1 || fail "gh не авторизован — запусти: gh auth login"

# Собираем ровно то, что лежит в теге: с грязным деревом артефакт не соответствует
# коммиту, на который встанет релиз, и разобраться потом уже нельзя.
[ -z "$(git status --porcelain --untracked-files=no)" ] \
    || fail "рабочее дерево грязное — закоммить или отложи изменения"

HEAD_SHA=$(git rev-parse HEAD)
[ -n "$(git branch --remotes --contains "$HEAD_SHA" 2>/dev/null)" ] \
    || fail "коммит $HEAD_SHA не запушен — GitHub не сможет поставить на него тег"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    && fail "локальный тег $TAG уже существует"
gh release view "$TAG" >/dev/null 2>&1 \
    && fail "релиз $TAG уже опубликован"

# Сертификат: без него xcodebuild молча свалится на ad-hoc, а ослабленный
# requirement — ровно то, чего в релизе быть не должно.
IDENTITY=$(awk -F= '/^CODE_SIGN_IDENTITY[[:space:]]*=/ {
    sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }' Signing.xcconfig)
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] \
    || fail "в Signing.xcconfig не задан настоящий сертификат (CODE_SIGN_IDENTITY = «${IDENTITY:-пусто}»)"
security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\"" \
    || fail "сертификата «$IDENTITY» нет в связке ключей — см. инструкцию в Signing.xcconfig"

echo "Релиз $TAG из $HEAD_SHA, подпись «$IDENTITY»"

# --- Сборка

echo "Собираю Release…"
xcodegen generate >/dev/null
# clean: релиз не то место, где стоит доверять инкрементальной сборке — MARKETING_VERSION
# приходит из аргумента и должен попасть в Info.plist обоих таргетов.
xcodebuild -project LittleSnitchVPNCompanion.xcodeproj \
    -scheme LittleSnitchVPNCompanion -configuration Release \
    -derivedDataPath build/DerivedData \
    MARKETING_VERSION="$VERSION" \
    clean build >/dev/null

BUILT="build/DerivedData/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || fail "не нашёл собранное приложение в $BUILT"

# --- Проверки артефакта

check_signature() {
    local path="$1" what="$2" info
    info=$(codesign -dvv "$path" 2>&1) || true
    # У ad-hoc подписи строки Authority нет вовсе: это и отличает её от подписи
    # сертификатом, а не какой-нибудь флаг.
    grep -qxF "Authority=$IDENTITY" <<<"$info" \
        || fail "$what подписан не сертификатом «$IDENTITY»: $(grep -E '^(Authority|Signature)' <<<"$info" | tr '\n' ' ')"
}

check_universal() {
    local path="$1" what="$2" archs
    archs=$(lipo -archs "$path")
    for arch in arm64 x86_64; do
        grep -qw "$arch" <<<"$archs" || fail "в $what нет среза $arch (есть: $archs)"
    done
}

codesign --verify --deep --strict "$BUILT" || fail "подпись бандла не проходит проверку"
check_signature "$BUILT" "бандл приложения"
check_signature "$BUILT/Contents/MacOS/$HELPER_NAME" "встроенный helper"
check_universal "$BUILT/Contents/MacOS/Little Snitch VPN Companion" "бинаре приложения"
check_universal "$BUILT/Contents/MacOS/$HELPER_NAME" "бинаре helper"

[ -f "$BUILT/Contents/Library/LaunchDaemons/$HELPER_NAME.plist" ] \
    || fail "в бандле нет launchd-plist демона — SMAppService такой бандл не зарегистрирует"

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
[ "$BUILT_VERSION" = "$VERSION" ] \
    || fail "в Info.plist версия $BUILT_VERSION, а релиз $VERSION — MARKETING_VERSION не подхватился"

# --- Упаковка и публикация

echo "Упаковываю $ZIP…"
rm -f "$ZIP"
# ditto -c -k сохраняет подпись и оба среза; zip(1) — нет.
ditto -c -k --sequesterRsrc --keepParent "$BUILT" "$ZIP"

NOTES=$(cat <<'NOTES'
## Установка

1. Скачать `__ZIP__` и распаковать **сразу в `~/Applications`** — запуск из
   `~/Downloads` привяжет демона к этому пути в базе BTM:

   ```
   ditto -x -k ~/Downloads/__ZIP__ ~/Applications
   ```

2. Снять карантин — приложение подписано самоподписанным сертификатом и не
   нотаризовано, без этого шага первый запуск отклоняется:

   ```
   xattr -dr com.apple.quarantine ~/Applications/"Little Snitch VPN Companion.app"
   ```

   Альтернатива для тех, кто не хочет команд: открыть и пройти
   **Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»**.
   Control-click → «Открыть» в Sequoia уже не работает.

3. Открыть приложение, пройти онбординг, одобрить объект входа в Системных настройках.

Нужны macOS 15.7+ и Little Snitch 6 с включённым доступом для CLI
(**Little Snitch → Настройки → Безопасность**). Артефакт универсальный, `arm64` + `x86_64`.
Подробности и разбор граблей — в [README](__REPO__#readme).
NOTES
)
NOTES=${NOTES//__ZIP__/$ZIP_NAME}
# Абсолютная ссылка: относительные пути в теле релиза GitHub разрешает не от корня
# репозитория, и «../blob/main/README.md» ведёт в никуда.
NOTES=${NOTES//__REPO__/$(gh repo view --json url -q .url)}

echo "Создаю релиз $TAG…"
gh release create "$TAG" "$ZIP" \
    --target "$HEAD_SHA" \
    --title "$TAG" \
    --notes "$NOTES" \
    --generate-notes \
    "${DRAFT[@]+"${DRAFT[@]}"}"

if [ ${#DRAFT[@]} -gt 0 ]; then
    echo
    echo "Создан черновик. Вычитай заметки и нажми Publish release — тег $TAG"
    echo "появится на GitHub только после публикации."
fi
