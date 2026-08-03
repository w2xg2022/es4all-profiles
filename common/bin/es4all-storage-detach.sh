#!/bin/sh
# es4all: 停用聚合 —— 把 upper 的内容【回写】进内部盘, 然後拆掉 overlay。
#
# 用法:
#   es4all-storage-detach.sh --check    只估算, 不动任何东西(给 ES 的确认框用)
#   es4all-storage-detach.sh            真的执行
#
# ============================================================================
# 为什么「停用」不能只是 umount
# ============================================================================
# 聚合开着的时候, ES 的所有写入都落在 upper —— 游玩次数、收藏、重新刮的图,
# 以及 **savestates**(Paths.cpp 的 mSaveStatesPath 就在 /storage/roms 底下)。
# 直接 umount 等於把这些东西一次藏起来: 档案还在, 但使用者眼里就是「存档不见了」。
# 所以停用 = 先把 upper 合并回内部盘, 确认成功, 才清空、才拆。
#
# ============================================================================
# 顺序(每一步的失败都停在【原状】, 而不是中间状态)
# ============================================================================
#   ① 估算大小 + 检查内部盘空间   -> 不够就直接拒绝, 什么都不动
#   ② 复制 upper -> 内部盘
#   ③ 验证(档案数比对)
#   ④ 验证过了才清空 upper
#   ⑤ umount overlay, 内部盘 move 回 /storage/roms
#
# ★为什么先算空间★: 内部 ROM 分区(EmuELEC 的 EEROMS)是 vfat 而且通常不大。
# 复制到一半空间爆掉是最糟的状态 —— 那时 upper 不能清、overlay 不能拆, 卡在中间。
#
# ⚠️ 完成後 upper 变空, 於是【下次开机 es4all-storage.sh 自己就不会再叠 overlay】——
# 不需要另外去改任何设定。动作本身就是状态转换。

set -u

if [ -f /storage/.config/system/configs/system.cfg ] || [ -d /storage/.config/emuelec ]; then
	ROMS=/storage/roms
	WORK_BASE=/storage
else
	WORK_BASE="${HOME:-/storage}"
	ROMS="${ES4ALL_ROMS:-${WORK_BASE}/roms}"
fi

INTERNAL_HOLD="${WORK_BASE}/games-internal"
UPPER="${WORK_BASE}/.es4all-roms/upper"
WORKDIR="${WORK_BASE}/.es4all-roms/work"
LOG="${WORK_BASE}/.config/es4all/storage.log"
[ -d "${WORK_BASE}/.config/es4all" ] || LOG="${WORK_BASE}/.es4all-roms/storage.log"

log() {
	mkdir -p "$(dirname "${LOG}")" 2>/dev/null
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] detach: $*" >> "${LOG}"
}
say() { echo "$*"; }          # 给 ES / 使用者看的

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ---------------------------------------------------------------------------
# ① 估算
# ---------------------------------------------------------------------------
if [ ! -d "${UPPER}" ] || [ -z "$(ls -A "${UPPER}" 2>/dev/null)" ]; then
	say "NOTHING_TO_DO"
	say "聚合没有产生任何资料, 不需要回写。"
	exit 0
fi

# 目标 = 内部盘。它现在应该挂在 ${INTERNAL_HOLD}(聚合中); 若没有就是 ${ROMS} 本身。
TARGET_DIR="${INTERNAL_HOLD}"
[ -d "${TARGET_DIR}" ] && [ -n "$(ls -A "${TARGET_DIR}" 2>/dev/null)" ] || TARGET_DIR="${ROMS}"

NEED_KB=$(du -sk "${UPPER}" 2>/dev/null | cut -f1)
FREE_KB=$(df -k "${TARGET_DIR}" 2>/dev/null | awk 'NR==2 { print $4 }')
[ -n "${NEED_KB}" ] || NEED_KB=0
[ -n "${FREE_KB}" ] || FREE_KB=0

say "NEED_KB=${NEED_KB}"
say "FREE_KB=${FREE_KB}"
say "TARGET=${TARGET_DIR}"

# 留 5% 余裕: 档案系统快满时写入会变慢甚至失败, 而且 vfat 没有预留空间的概念。
if [ "${NEED_KB}" -gt 0 ] && [ "$((NEED_KB + NEED_KB / 20))" -ge "${FREE_KB}" ]; then
	say "NOT_ENOUGH_SPACE"
	say "内部储存空间不足: 需要约 $((NEED_KB / 1024)) MB, 只剩 $((FREE_KB / 1024)) MB。"
	log "拒绝: 空间不足 (need=${NEED_KB}KB free=${FREE_KB}KB)"
	exit 2
fi

if [ "${CHECK_ONLY}" = "1" ]; then
	say "OK_TO_DETACH"
	exit 0
fi

# ---------------------------------------------------------------------------
# ② 复制
# ---------------------------------------------------------------------------
log "开始回写: ${UPPER} -> ${TARGET_DIR} (约 $((NEED_KB / 1024)) MB)"

# ★用 cp -a 而不是 mv★: mv 跨档案系统时是「复制+删除」, 中断的话来源已经少了一块,
# 没办法重来。cp 完全不动来源, 失败就还在原地, 重试是安全的。
#
# ⚠️ overlayfs 的 whiteout(被删除档案的标记)在 upper 里是字元装置节点。
# cp -a 会把它当成一般装置档复制过去, 在内部盘上变成一个没有意义的 0 字节节点。
# 这里把它们过滤掉 —— 使用者在聚合期间删掉的档案, 回写後会「复活」,
# 但那远比在 ROM 目录里留下一堆 c--------- 的怪档案好。
if ! (cd "${UPPER}" && find . ! -type c -print | while IFS= read -r f; do
		case "${f}" in .) continue ;; esac
		if [ -d "${f}" ]; then
			mkdir -p "${TARGET_DIR}/${f}"
		else
			mkdir -p "$(dirname "${TARGET_DIR}/${f}")"
			cp -p "${f}" "${TARGET_DIR}/${f}" || exit 1
		fi
	done); then
	say "COPY_FAILED"
	say "回写失败, 已保持原状(资料仍在合并层里, 可以重试)。"
	log "★回写失败★, 未做任何清理"
	exit 3
fi

# ---------------------------------------------------------------------------
# ③ 验证: 比对档案数(不含 whiteout)
# ---------------------------------------------------------------------------
SRC_N=$(cd "${UPPER}" && find . ! -type c ! -type d | wc -l)
OK_N=0
MISS=0
for f in $(cd "${UPPER}" && find . ! -type c ! -type d); do
	if [ -e "${TARGET_DIR}/${f}" ]; then
		OK_N=$((OK_N + 1))
	else
		MISS=$((MISS + 1))
		log "★缺档★ ${f}"
	fi
done

if [ "${MISS}" -gt 0 ]; then
	say "VERIFY_FAILED"
	say "回写後有 ${MISS} 个档案对不上, 已保持原状。"
	log "★验证失败★ ${OK_N}/${SRC_N} 成功, ${MISS} 个缺档 —— 不清空 upper"
	exit 4
fi
log "验证通过: ${OK_N}/${SRC_N}"

# ---------------------------------------------------------------------------
# ④ 清空 upper (验证过了才做)
# ---------------------------------------------------------------------------
rm -rf "${UPPER}" "${WORKDIR}"
mkdir -p "${UPPER}" "${WORKDIR}"
log "upper 已清空"

# ---------------------------------------------------------------------------
# ⑤ 拆掉 overlay, 内部盘归位
# ---------------------------------------------------------------------------
if awk -v p="${ROMS}" '$2 == p && $3 == "overlay" { f = 1 } END { exit !f }' /proc/mounts; then
	if umount "${ROMS}" 2>/dev/null; then
		log "overlay 已卸载"
		if awk -v p="${INTERNAL_HOLD}" '$2 == p { f = 1 } END { exit !f }' /proc/mounts; then
			mount --move "${INTERNAL_HOLD}" "${ROMS}" 2>/dev/null \
				&& log "内部盘已移回 ${ROMS}"
		fi
	else
		# 卸不掉通常是还有程序在用(ES 自己就开着 roms)。
		# 资料已经回写完了, 所以这不是危险状态 —— 重开机就会回到乾净的样子。
		say "REBOOT_REQUIRED"
		say "资料已回写完成, 但需要重新启动才能完全解除合并。"
		log "注意: overlay 卸载失败(有程序占用), 但资料已回写; 重开机即完成"
		exit 0
	fi
fi

say "DONE"
say "已停用聚合, 资料都在内部储存里了。"
log "===== 停用完成 ====="
exit 0
