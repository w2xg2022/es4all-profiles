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
# ★写 1.2pre 不是 1.2★: 门槛的语意是「第一个**读得懂新目录**的版本」, 而那就是
# 开发中的 1.2pre —— 写 1.2 会把我们自己的开发build挡在外面(1.2pre < 1.2),
# 实机踩过 2026-08-03: log 写「本机 ES 版本低于配置要求的 1.2, 已跳过」。
# 旧的正式版 1.1 仍然 < 1.2pre, 照样被挡住, 保护效果不变。
MIN_ES4ALL=1.2pre

if [ $# -ge 1 ]; then
	VERSION=$1
else
	today=$(date -u +%Y.%m.%d)
	# 同一天重跑就把序号 +1，避免设备端因 version 没变而跳过更新
	prev=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"'"$today"'\.\([0-9]*\)".*/\1/p' manifest.json 2>/dev/null || true)
	VERSION="$today.$(( ${prev:-0} + 1 ))"
fi

# 收录 common/ 与三个发行版目录底下的一切；排除仓库自身的元数据
#
# ★档名可能有空格★(例: "Microsoft X-Box 360 pad.cfg" —— RetroArch 的 autoconfig
# 是按手柄名命名的，手柄名本来就带空格)。所以这里【一律走 while read 逐行读】，
# 不用 `for f in $files` —— 那会按空白拆开，一个档名变四个不存在的路径，
# 而且 find/md5sum 各自报错、manifest 里默默多出几笔垃圾。
files=$(find common armbian emuelec rocknix -type f 2>/dev/null | sed 's|^\./||' | sort || true)

# ★同名档漂移检查★(2026-08-02 加)
# 真实需求不是「三边共用」而是「E+R 共用」——唯读 squashfs 那两边做法相同、
# 可写 rootfs 的 armbian 不同，现有 scope 表达不了「部分 target 共用」。
# 与其为此加一层组合 scope(下次可能又是别的组合)，不如让工具挡住会实际发生的事：
# 忘记同步。同名不同内容就警告，同名同内容视为刻意的复制、只在冗长模式提示。
#
# ★只比对【明确声明应该一致】的那几支★(SHARED_SAME)。
#
# 一开始写成「所有 <target>/_common/ 底下同名档都比」，那是错的前提:
# 三边同名不同内容【本来就是设计】—— setaudio.sh(裸 ALSA vs PipeWire vs ~/.asoundrc)、
# installtoemmc.sh(两套分区逻辑)、selfmount unit(essway vs emustation)全都必须不同。
# 那样一跑就是四条误报, 而噪音多的检查等於没有检查, 下次真漂移了也不会有人看。
#
# 所以改成白名单: 只有「刻意维持位元组相同」的复本才在这里盯。
# 目前只有 selfmount.sh(emuelec 与 rocknix 共用同一支实作)。
SHARED_SAME='bin/selfmount.sh'

for rel in ${SHARED_SAME}; do
	printf '%s\n' "${files}" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		case $f in */_common/"${rel}") ;; *) continue ;; esac
		printf '%s\t%s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$f"
	done | sort | awk -F'\t' -v rel="${rel}" '
		{ md5 = $1; path = $2
		  if (NR > 1 && md5 != prevmd5)
		      printf "⚠️  应该一致的档内容不同(忘了同步?): %s <-> %s\n", prevpath, path > "/dev/stderr"
		  prevmd5 = md5; prevpath = path }
	'
done

{
	printf '{\n'
	printf '  "schema": %s,\n' "$SCHEMA"
	printf '  "version": "%s",\n' "$VERSION"
	printf '  "min_es4all_version": "%s",\n' "$MIN_ES4ALL"
	printf '  "files": [\n'

	first=1
	printf '%s\n' "${files}" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		case $f in *.gitkeep) continue ;; esac
		md5=$(md5sum "$f" | cut -d' ' -f1)
		size=$(wc -c < "$f" | tr -d ' ')
		[ $first -eq 1 ] || printf ',\n'
		first=0
		printf '    { "path": "%s", "md5": "%s", "size": %s }' "$f" "$md5" "$size"
	done
	printf '\n'

	printf '  ]\n'
	printf '}\n'
} > manifest.json.tmp

mv manifest.json.tmp manifest.json
echo "manifest.json 已更新: version=$VERSION"

# 顺手检查「固件 baseline」那几个双份档有没有漂移(见 sync_baseline.sh 的说明)。
# 只警告不挡 —— 不在同一台机器上、或没 clone es4all 的人也要能跑 gen_manifest。
sh tools/sync_baseline.sh --check || true
