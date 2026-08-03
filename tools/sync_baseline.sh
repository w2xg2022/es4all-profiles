#!/bin/sh
# 把「本仓库是正本、但固件也必须内建一份」的档同步到 es4all 仓库的 dist/。
#
# ★为什么会有这种双份档★
#   本仓库的东西一般是「设备连上网自己拉」，所以固件不必带。但有少数档
#   在**还没拉到 profile 的那一刻就必须存在**，否则功能是断的：
#
#     configscripts/retroarch.sh —— 刷完机第一次开机会强制跑键位精灵(这是刻意的
#       保底设计)，精灵存完的**当下**就要有人把 es_input.cfg 翻译成 RetroArch 设定。
#       那一刻通常还没连上网，profile 拿不到 → 只能靠固件内建那份。
#
#   这类档就是「一份 payload 三种送达」里的**固件 baseline 通道**。
#
# ★规则:正本永远是本仓库，dist 那份是产物★
#   两边各自维护必然漂移(而且漂移了不会有人发现——两份都能跑，只是行为不同)。
#   改这类档只改本仓库，然后跑一次本脚本。
#
# 用法: ./tools/sync_baseline.sh [--check]
#   不带参数 = 复制过去；--check = 只比对不写(给 gen_manifest 与 CI 用)。
set -eu

cd "$(dirname "$0")/.."

ES4ALL=${ES4ALL_DIR:-../es4all}
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# 对照表: <本仓库路径>|<es4all 仓库内路径>
#
# 后两条不是「首刷就必须有」那类, 而是**这两支原本住在 es4all**、现在正本搬来了 ——
# 留着对照是为了让 es4all 那份不会被人当成可以各自修改的复本(改了没人会发现)。
# 哪天确定固件不必带, 从这张表移除并删掉 dist 那份即可。
MAP='emuelec/_common/storage-config/emulationstation/scripts/configscripts/retroarch.sh|dist/emuelec/config/scripts/configscripts/retroarch.sh
rocknix/_common/bin/setaudio.sh|dist/rocknix/sources/es4all-setauddev
rocknix/_common/bin/installtoemmc.sh|dist/rocknix/sources/installtoemmc'

if [ ! -d "${ES4ALL}" ]; then
	# 不在同一台机器上也要能跑 —— 本脚本是辅助，不是必要条件。
	[ "${CHECK}" = "1" ] && exit 0
	echo "找不到 es4all 仓库: ${ES4ALL}(可用 ES4ALL_DIR= 指定)" >&2
	exit 1
fi

rc=0
echo "${MAP}" | while IFS='|' read -r src dst; do
	[ -n "${src}" ] || continue
	full="${ES4ALL}/${dst}"
	if [ "${CHECK}" = "1" ]; then
		if [ ! -f "${full}" ] || ! cmp -s "${src}" "${full}"; then
			echo "⚠️  baseline 与正本不同步: ${dst}(跑 ./tools/sync_baseline.sh 修)" >&2
			rc=1
		fi
	else
		mkdir -p "$(dirname "${full}")"
		cp -f "${src}" "${full}"
		echo "已同步 ${src} -> ${dst}"
	fi
done

exit ${rc}
