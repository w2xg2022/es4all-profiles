#!/bin/sh
# es4all: 内外部盘【聚合】—— 把内部 ROM 与外接盘 ROM 合并成同一个 /storage/roms。
#
# 由 es4all-storage.service 在 ES 启动【之前】执行(与 selfmount 同一套摆法)。
#
# ============================================================================
# 为什么不照抄 ROCKNIX 那套
# ============================================================================
# ROCKNIX 的 automount 用:
#     lowerdir=<主储存以外那个>/roms  upperdir=<主储存>/roms
# 也就是**拿其中一颗盘当 upper**。overlayfs 要求 upperdir 支援 xattr,
# 於是 FAT/exFAT/NTFS 盘一律不能当 upper —— 它的处理是**退回 bind mount**(变成二选一),
# 而且 ★UI 上开关还亮着、全程零提示★(2026-07-23 实机证实)。
#
# 实机现况让这个限制更致命: EmuELEC 的 ROM 分区 **EEROMS 本身就是 vfat**
# (三分区映像: p1 EMUELEC/vfat, p2 STORAGE/ext4, p3 EEROMS/vfat)。
# 照 ROCKNIX 的做法, 内部盘永远不能当 upper; 若外接盘也是 FAT(最常见), 就完全做不了聚合。
#
# ============================================================================
# 本脚本的做法: ★所有盘都当 lower, upper 另外放在 ext4 上★
# ============================================================================
#     lowerdir=<外接1>:<外接2>:…:<内部>     ← 只读合并, **不要求 xattr**, FAT/NTFS 都行
#     upperdir=<STORAGE 上的目录>            ← ext4, 一定支援 xattr
#
# 好处:
#   ① **任何档案系统组合都能聚合**, 不再有「FAT 盘就做不到」这件事
#   ② ES 产生的写入(gamelist.xml、抓取的图片…)落在 ext4 的 upper,
#      不会去戳 FAT 的目录项, 也避开了 FAT 不支援的属性
#   ③ 优先序由 lowerdir 的**顺序**决定(左边优先), 同名档案外接盘赢 —— 语意直观
#
# 代价(必须写清楚, 别让人以为是 bug):
#   ⚠️ 在 /storage/roms 里**新增/修改**档案会落到 upper(STORAGE 分区), 不是落到那颗盘上。
#      要把游戏真的放进外接盘, 请直接写到该盘的挂载点(本脚本会保留 /storage/games-external*)。
#   ⚠️ upper 与 STORAGE 分区共用空间。EmuELEC 的 savestates 在 /storage/roms 底下,
#      长期会累积在 upper 上 —— 空间告急时先看这里。
#
# ============================================================================
# 设定键(与 ROCKNIX automount 同名同义, 好让 R 版将来共用同一套 UI)
# ============================================================================
#   system.merged.storage  1/0        1=聚合(本脚本), 0=维持发行版原本的二选一行为(预设)
#   system.gamesdevice     /dev/xxx   指定外接装置; 空或 auto = 自动扫描
#   system.merged.device   internal|external   同名档谁赢(external=外接优先, 预设)
#
# ★预设关闭★: 这会改动 /storage/roms 的挂载结构, 出错的代价是「ES 看不到游戏」。
# 不该有人在不知情的情况下被切过去。

set -u

# ---------------------------------------------------------------------------
# 三边差异: 与 apply.sh 同一套判据(ES 自己认定的 config store 在哪)
# ---------------------------------------------------------------------------
if [ -f /storage/.config/system/configs/system.cfg ]; then
	TARGET=rocknix
	SYS_CONF=/storage/.config/system/configs/system.cfg
	ROMS=/storage/roms
	WORK_BASE=/storage
elif [ -d /storage/.config/emuelec ]; then
	TARGET=emuelec
	SYS_CONF=/storage/.config/emuelec/configs/emuelec.conf
	ROMS=/storage/roms
	WORK_BASE=/storage
else
	TARGET=armbian
	SYS_CONF="${HOME:-/storage}/.emulationstation/system.conf"
	ROMS="${ES4ALL_ROMS:-${HOME:-/storage}/roms}"
	WORK_BASE="${HOME:-/storage}"
fi

INTERNAL_HOLD="${WORK_BASE}/games-internal"   # 内部 ROM 被移到这里(原本挂在 ${ROMS})
EXT_BASE="${WORK_BASE}/games-external"        # 外接盘挂这里(多颗时加序号)
UPPER="${WORK_BASE}/.es4all-roms/upper"
WORKDIR="${WORK_BASE}/.es4all-roms/work"
LOG="${WORK_BASE}/.config/es4all/storage.log"
[ -d "${WORK_BASE}/.config/es4all" ] || LOG="${WORK_BASE}/.es4all-roms/storage.log"

log() {
	mkdir -p "$(dirname "${LOG}")" 2>/dev/null
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"
}

conf_get() {
	[ -f "${SYS_CONF}" ] || return 0
	sed -n "s/^$1=//p" "${SYS_CONF}" 2>/dev/null | head -1
}

# 某个路径现在是不是挂载点(★不能用 mountpoint★: busybox 那支对档案一律失败,
# 而且我们这里也要能查目录以外的东西, 统一查 /proc/mounts 最稳)
is_mounted() {
	awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/mounts
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
MERGED=$(conf_get system.merged.storage)
if [ "${MERGED}" != "1" ]; then
	# 预设关闭。这里不留 log —— 关着是常态, 每次开机写一行只会淹掉真正的讯息。
	exit 0
fi

log "===== 聚合开始 (target=${TARGET}) ====="

if is_mounted "${ROMS}" && grep -q " ${ROMS} overlay " /proc/mounts; then
	log "跳过: ${ROMS} 已经是 overlay(可能是重跑或发行版自己做的)"
	exit 0
fi

# ① 内部 ROM: 现在挂在 ${ROMS} 的那一份, 整个搬到 ${INTERNAL_HOLD}
#    ★用 mount --move 而不是 umount+mount★: 不必知道它是从哪个装置、用什么参数挂上来的,
#    也就不会在重挂时把发行版精心设定的挂载选项(codepage/iocharset 之类)弄丢。
mkdir -p "${INTERNAL_HOLD}" "${EXT_BASE}" "${UPPER}" "${WORKDIR}"
MOVED=0
if is_mounted "${ROMS}"; then
	if mount --move "${ROMS}" "${INTERNAL_HOLD}" 2>/dev/null; then
		MOVED=1
		log "内部 ROM 已移到 ${INTERNAL_HOLD}"
	else
		log "★放弃★: 无法把 ${ROMS} move 到 ${INTERNAL_HOLD}"
		exit 0
	fi
else
	# ${ROMS} 不是挂载点(例如 ROM 就放在 /storage 分区上的目录)。
	# 这种情形不能 move, 改成把它当成 lower 之一直接用。
	log "注意: ${ROMS} 不是挂载点, 直接把该目录当内部 ROM"
	INTERNAL_HOLD="${ROMS}"
fi

# ② 外接盘
#    指定优先(system.gamesdevice), 否则扫描。
#    ★扫描时要排除【开机碟本身的分区】★ —— 否则会把 EEROMS 或 /flash 当成「外接盘」
#    再挂一次, 结果是同一份内容出现两次, 而且看起来还很像成功。
GAMES_DEV=$(conf_get system.gamesdevice)
BOOT_DISK=$(awk '$2 == "/flash" { print $1 }' /proc/mounts | sed 's|[0-9]*$||')
[ -n "${BOOT_DISK}" ] || BOOT_DISK=$(awk '$2 == "/storage" { print $1 }' /proc/mounts | sed 's|[0-9]*$||')

ext_candidates() {
	if [ -n "${GAMES_DEV}" ] && [ "${GAMES_DEV}" != "auto" ]; then
		[ -e "${GAMES_DEV}" ] && echo "${GAMES_DEV}"
		return 0
	fi
	blkid 2>/dev/null | cut -d: -f1 | while read -r dev; do
		case "${dev}" in
			"${BOOT_DISK}"*) continue ;;   # 开机碟自己的分区, 跳过
			/dev/loop*|/dev/ram*) continue ;;
		esac
		# 已经被别人挂走的也跳过(udevil 常把 U 盘挂到 /var/media/…)
		awk -v d="${dev}" '$1 == d { found = 1 } END { exit !found }' /proc/mounts && continue
		echo "${dev}"
	done
}

LOWER=""
N=0
for dev in $(ext_candidates); do
	N=$((N + 1))
	MP="${EXT_BASE}"
	[ "${N}" -gt 1 ] && MP="${EXT_BASE}${N}"
	mkdir -p "${MP}"
	if ! mount "${dev}" "${MP}" 2>/dev/null; then
		log "跳过 ${dev}: 挂不上(档案系统不支援?)"
		rmdir "${MP}" 2>/dev/null
		N=$((N - 1))
		continue
	fi
	# 只认「看起来像 ROM 盘」的: 根目录有 roms/ 就用 roms/, 否则用整颗盘
	SRC="${MP}"
	[ -d "${MP}/roms" ] && SRC="${MP}/roms"
	LOWER="${LOWER}${LOWER:+:}${SRC}"
	log "外接盘 ${dev} -> ${SRC}"
done

if [ -z "${LOWER}" ]; then
	log "没有找到可用的外接盘, 还原成原本的挂法"
	[ "${MOVED}" = "1" ] && mount --move "${INTERNAL_HOLD}" "${ROMS}" 2>/dev/null
	log "===== 聚合结束(未变更) ====="
	exit 0
fi

# ③ 顺序 = 优先序。lowerdir 左边优先, 同名档案由左边那份胜出。
if [ "$(conf_get system.merged.device)" = "internal" ]; then
	LOWER_ALL="${INTERNAL_HOLD}:${LOWER}"
else
	LOWER_ALL="${LOWER}:${INTERNAL_HOLD}"
fi

# ④ ★合并 gamelist★ —— 必须在叠上去【之前】做
#    overlayfs 对目录是联集、对**档案**不是: 同名档只有优先序最高的看得见。
#    gamelist.xml 正好是档案 -> 两颗盘都有 mame 时, 其中一份的刮削资料会被整个遮蔽,
#    表现是「游戏都在, 但有一半突然变成没刮过」, 而图片其实还躺在 media/ 里(目录有合并),
#    只是 XML 里引用它们的 <game> 条目没了。
#    把合并结果写进 upperdir 就解决(upper 优先於所有 lower)。
#    ⚠️ 合并只【补上缺的】、绝不覆盖 upper 已有的条目 —— 那份是 ES 的活档,
#    里面有玩过次数/最后游玩/收藏这些只有 ES 知道的东西, 覆盖等於每次开机洗掉一次。
MERGER="$(dirname "$0")/es4all-gamelist-merge.py"
if [ -f "${MERGER}" ] && command -v python3 >/dev/null 2>&1; then
	# 传入顺序要与 lowerdir 一致(左边优先), 所以直接把 LOWER_ALL 的冒号换成空白。
	# shellcheck disable=SC2086
	if ! python3 "${MERGER}" "${UPPER}" $(echo "${LOWER_ALL}" | tr ':' ' ') >> "${LOG}" 2>&1; then
		log "注意: gamelist 合并失败(不影响挂载, 但两颗盘的刮削资料只会看到一份)"
	fi
else
	log "注意: 找不到 python3 或合并脚本, 跳过 gamelist 合并"
fi

# ⑤ 叠上去
if mount -t overlay es4all-roms \
	-o "lowerdir=${LOWER_ALL},upperdir=${UPPER},workdir=${WORKDIR}" "${ROMS}" 2>/dev/null; then
	log "已聚合 -> ${ROMS}"
	log "  lowerdir=${LOWER_ALL}"
	log "  upperdir=${UPPER}"
else
	# ★失败一定要还原★: 停在「内部 ROM 被移走、overlay 又没挂上」的中间状态,
	# 表现就是「ES 一个游戏都看不到」—— 比不做聚合糟糕得多。
	log "★overlay 挂载失败★, 还原成原本的挂法"
	[ "${MOVED}" = "1" ] && mount --move "${INTERNAL_HOLD}" "${ROMS}" 2>/dev/null
fi

log "===== 聚合结束 ====="
exit 0
