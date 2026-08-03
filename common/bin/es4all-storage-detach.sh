#!/bin/sh
# es4all: 拆掉聚合 —— 把 /storage/roms 还原成「只有内盘」的样子。
#
# ============================================================================
# ★这支现在很短, 而且【没有回写】—— 那是刻意的★
# ============================================================================
# overlayfs 时代所有写入都堆在 upperdir, 拆掉之前必须先把 upper 的内容回写进内盘,
# 否则使用者的存档与刮削资料会「凭空消失」(档案还在, 只是没挂就看不到)。
# 那一版有整套「估算空间 -> 复制 -> 验证 -> 清空 -> 卸载」的流程。
#
# 换成 mergerfs 之后那些全部不需要了:
# **写入直接落在各分支的真实档案上** —— 内盘的东西本来就在内盘, 外接盘的本来就在
# 外接盘。拆掉 union 只是不再合并显示, 没有任何资料需要搬。
#
# 所以「停用聚合」在使用者那一侧就只是「把外接装置选回内部储存」而已;
# 这支的用途是**不重开机就套用**(以及救援用)。
#
# 用法: es4all-storage-detach.sh

set -u

if [ -f /storage/.config/system/configs/system.cfg ] || [ -d /storage/.config/emuelec ]; then
	ROMS=/storage/roms
	WORK_BASE=/storage
else
	WORK_BASE="${HOME:-/storage}"
	ROMS="${ES4ALL_ROMS:-${WORK_BASE}/roms}"
fi

INTERNAL="${WORK_BASE}/games-internal"
EXT_BASE="${WORK_BASE}/games-external"
MERGED="${WORK_BASE}/.es4all-roms/merged"
LOG="${WORK_BASE}/.config/es4all/storage.log"
[ -d "${WORK_BASE}/.config/es4all" ] || LOG="${WORK_BASE}/.es4all-roms/storage.log"

log() {
	mkdir -p "$(dirname "${LOG}")" 2>/dev/null
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] detach: $*" >> "${LOG}"
}

is_mounted() {
	awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/mounts
}

fstype_of() {
	awk -v p="$1" '$2 == p { print $3 }' /proc/mounts | tail -1
}

if [ "$(fstype_of "${ROMS}")" != "fuse.mergerfs" ]; then
	echo "NOT_MERGED"
	echo "目前没有在聚合, 不需要拆。"
	exit 0
fi

log "开始拆除"

# ★顺序: 由上往下拆★
#   ${ROMS} 上面那层 bind -> mergerfs 本体 -> 外接盘 -> 内盘的 bind
# 拆错顺序会「装置忙碌」, 而且 ES 正开着 roms 时最上面那层本来就可能卸不掉。
if ! umount "${ROMS}" 2>/dev/null; then
	echo "BUSY"
	echo "有程序正在使用游戏目录(通常是 EmulationStation), 请先关闭再试, 或直接重新启动。"
	log "★${ROMS} 卸载失败(忙碌)★ —— 未做任何变更"
	exit 2
fi

is_mounted "${MERGED}"   && umount "${MERGED}" 2>/dev/null
is_mounted "${EXT_BASE}" && umount "${EXT_BASE}" 2>/dev/null
# ★内盘那层 bind 留到最后★: 它底下就是真正的 ROM 分区, 提早拆掉的话
# 上面几层还引用着它, 会变成卸不掉的残留(实机踩过, 只能重开机清)。
is_mounted "${INTERNAL}" && umount "${INTERNAL}" 2>/dev/null

if [ "$(fstype_of "${ROMS}")" = "fuse.mergerfs" ]; then
	echo "REBOOT_REQUIRED"
	echo "已停止合并, 但仍有残留挂载; 重新启动后即完全恢复。"
	log "注意: 仍有残留挂载"
	exit 0
fi

echo "DONE"
echo "已停止合并, 现在只使用内部储存。"
log "拆除完成"
exit 0
