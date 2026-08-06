#!/bin/bash
# Собирает материал для решения о размере SemVer-бампа: что изменилось с последнего
# релиза и есть ли среди изменений ломающие сигналы.
#
# Скрипт ничего не решает — он только приносит факты в одном и том же виде, чтобы
# один и тот же набор изменений не получал разный вердикт в разные дни. Решение
# принимает навык .claude/skills/release по своей таблице.
set -euo pipefail
cd "$(dirname "$0")/../../../.."

BASE="${1:-}"
if [ -z "$BASE" ]; then
    BASE=$(git describe --tags --abbrev=0 2>/dev/null || true)
fi

if [ -z "$BASE" ]; then
    echo "ПОСЛЕДНИЙ РЕЛИЗ: нет ни одного тега"
    echo "  Это первый релиз — вердикт по версии принимается вручную (обычно 1.0.0)."
    exit 0
fi

BASE_SHA=$(git rev-parse --short "$BASE")
BASE_DATE=$(git log -1 --format=%ad --date=short "$BASE")
COUNT=$(git rev-list --count "$BASE..HEAD")

echo "ПОСЛЕДНИЙ РЕЛИЗ: $BASE ($BASE_SHA, $BASE_DATE)"
echo "КОММИТОВ С ТЕХ ПОР: $COUNT"

if [ "$COUNT" -eq 0 ]; then
    echo
    echo "Выпускать нечего: HEAD совпадает с последним релизом."
    exit 0
fi

echo
echo "КОММИТЫ:"
git log --format='  %h %s' "$BASE..HEAD"

echo
echo "ЗАТРОНУТЫЕ ОБЛАСТИ (изменённых файлов):"
# Первый сегмент пути: каталоги верхнего уровня и файлы корня — по ним видно,
# трогали ли код приложения или только обвязку.
git diff --name-only "$BASE..HEAD" \
    | awk -F/ '{ print (NF > 1 ? $1 "/" : $1) }' \
    | sort | uniq -c | sort -rn \
    | awk '{ printf "  %-34s %s\n", $2, $1 }'

echo
# Релиз публикует собранный бандл, а не историю репозитория. Если ни один файл,
# попадающий в артефакт, не изменился, новая сборка отличалась бы от прошлой
# только строкой версии — выпускать нечего. Спеки, доки, CI и тесты сюда не
# входят намеренно: изменения в них либо ещё не реализованы, либо к содержимому
# бандла отношения не имеют.
#
# Состав списка — по project.yml: sources обоих таргетов, xcconfig подписи и сам
# project.yml, задающий настройки сборки. Меняется project.yml — пересматривай.
ARTIFACT_PATHS=(App Application Domain Infrastructure Helper project.yml Signing.xcconfig)
SOURCE_FILES=$(git diff --name-only "$BASE..HEAD" -- "${ARTIFACT_PATHS[@]}")

if [ -z "$SOURCE_FILES" ]; then
    echo "ИСХОДНИКИ АРТЕФАКТА: не менялись"
    echo
    echo "Релизить нечего: бандл собрался бы тем же, что в $BASE. Изменения"
    echo "затронули только обвязку (см. блок выше) — они не меняют то, что"
    echo "получает пользователь."
    exit 0
fi

echo "ИСХОДНИКИ АРТЕФАКТА (изменённых файлов: $(wc -l <<<"$SOURCE_FILES" | tr -d ' ')):"
sed 's/^/  /' <<<"$SOURCE_FILES"

echo
echo "OPENSPEC:"
# Путь капабилити берётся целиком, а не первым сегментом: с обновления OpenSpec
# (1.8.0) спеки могут лежать во вложенных каталогах — «identity/user-auth», — и
# срезанный до «identity» путь склеил бы разные капабилити в одну.
caps() {
    git diff --name-only --diff-filter="$1" "$BASE..HEAD" -- openspec/specs \
        | grep '/spec\.md$' \
        | sed -e 's|^openspec/specs/||' -e 's|/spec\.md$||' \
        | sort -u | paste -sd', ' -
}
# `|| true` обязателен: спеки могли не меняться вовсе, тогда grep внутри caps
# возвращает 1 и под pipefail обрывает весь скрипт до печати остальных блоков.
NEW_CAPS=$(caps A || true)
GONE_CAPS=$(caps D || true)
TOUCHED_CAPS=$(caps M || true)
# SHALL — форма записи требования в спеках; прирост таких строк означает новое
# обещание пользователю, убыль — снятое.
SPEC_DIFF=$(git diff "$BASE..HEAD" -- openspec/specs)
SHALL_ADDED=$(grep -c '^+.*SHALL' <<<"$SPEC_DIFF" || true)
SHALL_REMOVED=$(grep -c '^-.*SHALL' <<<"$SPEC_DIFF" || true)
ARCHIVED=$(git diff --name-only --diff-filter=A "$BASE..HEAD" -- openspec/changes/archive \
    | grep '/proposal\.md$' \
    | sed -e 's|^openspec/changes/archive/||' -e 's|/proposal\.md$||' \
    | sort -u | paste -sd', ' - || true)

echo "  Новые capability:      ${NEW_CAPS:-нет}"
echo "  Удалённые capability:  ${GONE_CAPS:-нет}"
echo "  Изменённые спеки:      ${TOUCHED_CAPS:-нет}"
echo "  Строк SHALL:           +$SHALL_ADDED / -$SHALL_REMOVED"
echo "  Архивировано changes:  ${ARCHIVED:-нет}"

echo
echo "СИГНАЛЫ MAJOR:"

# printf с %-Ns здесь не годится: ширину он считает в байтах, а кириллическая
# метка занимает по два байта на символ — колонки разъезжаются. Поэтому отступы
# проставлены в самих строках, как в блоке выше.
verdict() {
    local before="$1" after="$2"
    if [ "$before" = "$after" ]; then echo "${after:-?} (не менялся)"; else echo "${before:-?} → ${after:-?}  ← ПРОВЕРИТЬ"; fi
}

# Порог macOS: машины ниже него перестают получать обновления — это ломающее
# изменение, даже если в коде ничего не «сломалось».
read_yaml_value() { awk -F: "/$2/ { gsub(/[\" ]/, \"\", \$2); print \$2; exit }" 2>/dev/null <<<"$1"; }
TARGET_BEFORE=$(read_yaml_value "$(git show "$BASE:project.yml" 2>/dev/null || true)" MACOSX_DEPLOYMENT_TARGET)
TARGET_AFTER=$(read_yaml_value "$(cat project.yml)" MACOSX_DEPLOYMENT_TARGET)
echo "  Порог macOS:           $(verdict "$TARGET_BEFORE" "$TARGET_AFTER")"

# Смена сертификата подписи ломает установленный helper: его XPC-requirement
# привязан к листовому сертификату, и старый демон не пустит новое приложение.
read_identity() { awk -F= '/^CODE_SIGN_IDENTITY[[:space:]]*=/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' <<<"$1"; }
SIGN_BEFORE=$(read_identity "$(git show "$BASE:Signing.xcconfig" 2>/dev/null || true)")
SIGN_AFTER=$(read_identity "$(cat Signing.xcconfig)")
echo "  Сертификат:            $(verdict "$SIGN_BEFORE" "$SIGN_AFTER")"

# Смена этих идентификаторов рвёт связь с уже зарегистрированным демоном и
# сохранёнными настройками пользователя.
IDS=$(git diff "$BASE..HEAD" -- project.yml Helper/Info.plist Helper/HelperProtocol.swift \
    | grep -E '^[-+].*(PRODUCT_BUNDLE_IDENTIFIER|machServiceName|CFBundleIdentifier)' || true)
if [ -n "$IDS" ]; then
    echo "  Идентификаторы:        менялись  ← ПРОВЕРИТЬ"
    sed 's/^/    /' <<<"$IDS"
else
    echo "  Идентификаторы:        не менялись"
fi

if [ -n "$GONE_CAPS" ] || [ "$SHALL_REMOVED" -gt "$SHALL_ADDED" ]; then
    echo "  Снятые обещания:       возможны  ← ПРОВЕРИТЬ дифф спек"
else
    echo "  Снятые обещания:       не видно"
fi
