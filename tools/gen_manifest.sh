#!/bin/sh
# 重算 manifest.json。改过任何配置文件后都要跑一次，并连同 manifest.json 一起 commit。
#
# version 默认取 UTC 日期 + 当天序号(同一天多次改动会递增)，也可以自己指定：
#   ./tools/gen_manifest.sh 2026.07.31.3
set -eu

cd "$(dirname "$0")/.."

SCHEMA=1
# ★2026-08-02 目录改成 <target>/<DEVICE>/<SUBDEVICE> 后必须抬到 1.2★
# 旧客户端只认得 A/E/R 那套，遇到新路径会当成「别的 target」整批略过 ——
# 而且是【静默】略过(不认得 != 知道自己太旧)。靠这个门槛让旧版明确拒绝整包，
# 而不是装作套用成功却一个档都没落地。
MIN_ES4ALL=1.2

if [ $# -ge 1 ]; then
	VERSION=$1
else
	today=$(date -u +%Y.%m.%d)
	# 同一天重跑就把序号 +1，避免设备端因 version 没变而跳过更新
	prev=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"'"$today"'\.\([0-9]*\)".*/\1/p' manifest.json 2>/dev/null || true)
	VERSION="$today.$(( ${prev:-0} + 1 ))"
fi

# 收录 common/ 与三个发行版目录底下的一切；排除仓库自身的元数据
files=$(find common armbian emuelec rocknix -type f 2>/dev/null | sed 's|^\./||' | sort || true)

# ★同名档漂移检查★(2026-08-02 加)
# 真实需求不是「三边共用」而是「E+R 共用」——唯读 squashfs 那两边做法相同、
# 可写 rootfs 的 armbian 不同，现有 scope 表达不了「部分 target 共用」。
# 与其为此加一层组合 scope(下次可能又是别的组合)，不如让工具挡住会实际发生的事：
# 忘记同步。同名不同内容就警告，同名同内容视为刻意的复制、只在冗长模式提示。
#
# ★只比对 <target>/_common/ 这一层★: 那里放的是【机制】(怎么做)，跨 target 常常
# 是同一支脚本的复本(例: selfmount.sh 在 emuelec 与 rocknix 位元组相同)。
# 机型资料档不在比对范围 —— audio_outputs.cfg 每台本来就不同，那是设计不是漂移，
# 拿 basename 全域比会淹没在噪音里，噪音多的检查等於没有检查。
for f in $files; do
	case $f in */_common/*) ;; *) continue ;; esac
	rel=${f#*/_common/}
	printf '%s %s %s\n' "$rel" "$(md5sum "$f" | cut -d' ' -f1)" "$f"
done | sort | awk '
	{ rel = $1; md5 = $2; path = $3
	  if (rel == prevrel && md5 != prevmd5)
	      printf "⚠️  跨 target 的同名机制档内容不同(忘了同步?): %s <-> %s\n", prevpath, path > "/dev/stderr"
	  prevrel = rel; prevmd5 = md5; prevpath = path }
'

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
