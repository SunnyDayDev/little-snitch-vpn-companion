#!/bin/bash
# Domain — чистый Swift: никаких Apple-фреймворков (§10.1 SPEC.md).
# Разрешён только Foundation-free код; из системного допускается ничего.
set -uo pipefail

cd "$(dirname "$0")/.."

forbidden=$(grep -rn --include="*.swift" -E \
    "^\s*import\s+(Foundation|SwiftUI|AppKit|Network|Combine|OSLog|os|ServiceManagement|UserNotifications|Security|XPC)\b" \
    Domain 2>/dev/null || true)

if [ -n "$forbidden" ]; then
    echo "Domain импортирует Apple-фреймворки — зависимости должны идти только внутрь:"
    echo "$forbidden"
    exit 1
fi

echo "Domain чист: Apple-фреймворки не импортируются"
