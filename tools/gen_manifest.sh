#!/bin/sh
# 重算 manifest.json。改过任何配置文件后都要跑一次，并连同 manifest.json 一起 commit。
#
# version 默认取 UTC 日期 + 当天序号(同一天多次改动会递增)，也可以自己指定：
#   ./tools/gen_manifest.sh 2026.07.31.3
set -eu

cd "$(dirname "$0")/.."

SCHEMA=1
MIN_ES4ALL=1.1

if [ $# -ge 1 ]; then
	VERSION=$1
else
	today=$(date -u +%Y.%m.%d)
	# 同一天重跑就把序号 +1，避免设备端因 version 没变而跳过更新
	prev=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"'"$today"'\.\([0-9]*\)".*/\1/p' manifest.json 2>/dev/null || true)
	VERSION="$today.$(( ${prev:-0} + 1 ))"
fi

# 收录 common/ 与 A|E|R/ 底下的一切；排除仓库自身的元数据
files=$(find common A E R -type f 2>/dev/null | sed 's|^\./||' | sort || true)

{
	printf '{\n'
	printf '  "schema": %s,\n' "$SCHEMA"
	printf '  "version": "%s",\n' "$VERSION"
	printf '  "min_es4all_version": "%s",\n' "$MIN_ES4ALL"
	printf '  "files": [\n'

	first=1
	for f in $files; do
		case $f in *.gitkeep) continue ;; esac
		md5=$(md5sum "$f" | cut -d' ' -f1)
		size=$(wc -c < "$f" | tr -d ' ')
		[ $first -eq 1 ] || printf ',\n'
		first=0
		printf '    { "path": "%s", "md5": "%s", "size": %s }' "$f" "$md5" "$size"
	done
	[ $first -eq 1 ] || printf '\n'

	printf '  ]\n'
	printf '}\n'
} > manifest.json.tmp

mv manifest.json.tmp manifest.json
echo "manifest.json 已更新: version=$VERSION"
