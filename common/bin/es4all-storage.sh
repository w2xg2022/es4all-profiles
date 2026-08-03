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
# 设定键: ★只有一个★
# ============================================================================
#   system.gamesdevice   空 = 只用内部盘;  <LABEL> = 该外接盘与内部盘【聚合】
#
# 选中一颗外接盘就代表「要合并」—— 不需要第二个「要不要合并」的开关。
# 两个开关表达一件事, 只会制造「选了碟却没开合并」这种自相矛盾的状态。
#
# 重试(沿用 EmuELEC 既有的两个键, 语意相同):
#   ee_mount.retry  次数(空=预设 10)     ee_load.delay  每次间隔秒数(空=预设 2)
# ★为什么非有不可★: USB 列举可能比开机服务晚很多 —— ROCKNIX 实机量过
# 「sda 开机 +3.9s 认出、sdb 要 +65.9s」, 它的 automount 在 +9.8s 就跑完并判定
# 「没有外接碟」。没有重试的话, 我们会踩一模一样的坑。
#
# ============================================================================
# 什么时候才叠 overlay
# ============================================================================
#     upper 是空的  且  没选外接盘   ->  不叠(等同从未启用过, 零改动)
#     其他任何情况                  ->  叠
#
# ★upper 自己就是状态★: 「有没有启用过聚合」不需要另外存一个旗标 ——
# 看 upper 有没有内容就知道。少一个会不同步的东西。
#
# ⚠️ ★为什么「选回内部盘」不能就不叠了★
#   聚合开着时, ES 的所有写入都落在 upper —— 包含 **savestates**
#   (Paths.cpp: mSaveStatesPath = /storage/roms/savestates, 就在 roms 底下)。
#   若切回内部盘就不叠, 使用者那一刻失去的不只是刮削资料, **是存档**;
#   而档案其实还在 upper 里, 只是看不到 —— 这种「不见了但没真的不见」最难处理。
#   所以: 「选内部盘」= 不要外接盘的游戏(显示层), 「停用聚合」= 拆掉这套机制(结构层),
#   两者是不同的事, 後者由 es4all-storage-detach.sh 负责(会先回写再清空)。

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
GAMES_DEV=$(conf_get system.gamesdevice)

# upper 里有没有东西(= 以前启用过聚合、而且 ES 已经往里面写过)
upper_has_content() {
	[ -d "${UPPER}" ] || return 1
	[ -n "$(ls -A "${UPPER}" 2>/dev/null)" ]
}

if [ -z "${GAMES_DEV}" ] && ! upper_has_content; then
	# 从未启用过、这次也没选外接盘 -> 什么都不做。
	# 这里不留 log —— 这是绝大多数机器的常态, 每次开机写一行只会淹掉真正的讯息。
	exit 0
fi

log "===== 聚合开始 (target=${TARGET}, gamesdevice='${GAMES_DEV:-内部盘}') ====="

if is_mounted "${ROMS}" && grep -q " ${ROMS} overlay " /proc/mounts; then
	log "跳过: ${ROMS} 已经是 overlay(可能是重跑或发行版自己做的)"
	exit 0
fi

# ① 内部 ROM: 现在挂在 ${ROMS} 的那一份, 整个搬到 ${INTERNAL_HOLD}
#    ★用 mount --move 而不是 umount+mount★: 不必知道它是从哪个装置、用什么参数挂上来的,
#    也就不会在重挂时把发行版精心设定的挂载选项(codepage/iocharset 之类)弄丢。
mkdir -p "${INTERNAL_HOLD}" "${EXT_BASE}" "${UPPER}" "${WORKDIR}"
MOVED=0
BOUND=0
if is_mounted "${ROMS}"; then
	if mount --move "${ROMS}" "${INTERNAL_HOLD}" 2>/dev/null; then
		MOVED=1
		log "内部 ROM 已移到 ${INTERNAL_HOLD}"
	else
		log "★放弃★: 无法把 ${ROMS} move 到 ${INTERNAL_HOLD}"
		exit 0
	fi
else
	# ${ROMS} 不是挂载点(例如 ROM 就放在 /storage 分区上的目录, armbian 多半如此)。
	# 这种情形不能 move, 改用 bind 复制一份出来当 lower。
	#
	# ★不能省掉这个 bind、直接拿 ${ROMS} 当 lowerdir★:
	# 那会变成「把 overlay 挂在自己的 lower 上面」, 内核虽然在 mount 当下就解析完路径、
	# 侥幸能跑, 但那是 undefined 的用法, 而且事后完全没办法再碰到底下那份原始目录
	# (卸载顺序一错就救不回来)。bind 出一个独立路径, 结构就清清楚楚。
	if mount --bind "${ROMS}" "${INTERNAL_HOLD}" 2>/dev/null; then
		BOUND=1
		log "注意: ${ROMS} 不是挂载点, 已 bind 到 ${INTERNAL_HOLD} 当内部 ROM"
	else
		log "★放弃★: ${ROMS} 不是挂载点且无法 bind 到 ${INTERNAL_HOLD}"
		exit 0
	fi
fi

# ② 外接盘: 只认【选中的那一颗】(LABEL), 没选就只有内部盘。
#
# ★带重试★: USB 列举可能远晚於本服务 —— ROCKNIX 实机量过 sdb 要开机 +65.9 秒才出现,
# 而它的 automount 在 +9.8 秒就跑完、判定「没有外接碟」, 之後每次都失败。
# 次数/间隔沿用 EmuELEC 既有的两个设定键, 使用者本来就能在选单里调。
RETRY=$(conf_get ee_mount.retry); [ -n "${RETRY}" ] || RETRY=10
DELAY=$(conf_get ee_load.delay);  [ -n "${DELAY}" ] || DELAY=2

LOWER=""
if [ -n "${GAMES_DEV}" ]; then
	i=0
	DEV=""
	while [ "${i}" -lt "${RETRY}" ]; do
		# 用 LABEL 解析成装置节点。★不存 /dev/sdb1 这种名字★ ——
		# 它会随插拔顺序变, 换个 USB 孔就指到别颗碟上(ROCKNIX 就是踩这个)。
		DEV=$(blkid -L "${GAMES_DEV}" 2>/dev/null)
		[ -n "${DEV}" ] && break
		i=$((i + 1))
		[ "${i}" -lt "${RETRY}" ] && sleep "${DELAY}"
	done

	if [ -z "${DEV}" ]; then
		log "★等不到外接盘 '${GAMES_DEV}'★ (试了 ${RETRY} 次 x ${DELAY} 秒)"
	else
		[ "${i}" -gt 0 ] && log "外接盘 '${GAMES_DEV}' 在第 $((i + 1)) 次尝试才出现(等了约 $((i * DELAY)) 秒)"
		# 已经被别人挂走的先收回来(udevil 常把 U 盘挂到 /var/media/…)。
		# ★ROCKNIX 的 find_games 就是把「已出现在 /proc/mounts」当成不可用、直接放弃★,
		# 明明它自己後面就有 umount /var/media/* 的处理, 却永远走不到。别学。
		OLD_MP=$(awk -v d="${DEV}" '$1 == d { print $2 }' /proc/mounts | head -1)
		if [ -n "${OLD_MP}" ] && [ "${OLD_MP}" != "${EXT_BASE}" ]; then
			log "外接盘已被挂在 ${OLD_MP}, 先卸下"
			umount "${OLD_MP}" 2>/dev/null
		fi
		mkdir -p "${EXT_BASE}"
		if is_mounted "${EXT_BASE}" || mount "${DEV}" "${EXT_BASE}" 2>/dev/null; then
			SRC="${EXT_BASE}"
			[ -d "${EXT_BASE}/roms" ] && SRC="${EXT_BASE}/roms"
			LOWER="${SRC}"
			log "外接盘 ${DEV}(${GAMES_DEV}) -> ${SRC}"
		else
			log "★挂不上 ${DEV}★(档案系统不支援?)"
		fi
	fi
fi

# ③ 顺序 = 优先序。lowerdir 左边优先, 同名档案由左边那份胜出。
#    外接盘在左 = 使用者刚插上的那颗赢, 与「我选了它」这个动作的直觉一致。
if [ -z "${LOWER}" ]; then
	LOWER_ALL="${INTERNAL_HOLD}"
	log "本次只有内部盘这一层(upper 仍然生效, 存档与刮削不会消失)"
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
	[ "${BOUND}" = "1" ] && umount "${INTERNAL_HOLD}" 2>/dev/null
fi

log "===== 聚合结束 ====="
exit 0
