#!/bin/sh
# es4all: 内外部盘【聚合】—— 把内部 ROM 与外接盘 ROM 合并成同一个 /storage/roms。
#
# 由 emustation.service 的 ExecStartPre 呼叫(见 system.d/emustation.service.d/)。
# 「重启 ES」= 「重新套用挂载」, 所以选单不需要另一个「立即挂载」按钮。
#
# ============================================================================
# 为什么用 mergerfs 而不是 overlayfs
# ============================================================================
# ★overlayfs 无法用于 FAT/exFAT/NTFS —— 连当 lowerdir 都不行★(2026-08-03 实机坐实)
#   内核讯息: `overlay: filesystem on /storage/games-external/roms not supported`
#   对应 ovl_dentry_weird(): 只要档案系统有自订的 dentry 比对函式(d_hash/d_compare)
#   overlayfs 一律拒收 —— 而那正是**大小写不敏感**档案系统的特徵。
#   所以这不是「FAT 太旧」, 是架构上不相容, 换 exFAT 或 NTFS 一样被拒。
#   ⚠️ 本档早期版本写着「lowerdir 不要求 xattr, FAT/NTFS 都行」, **那是错的**。
#
#   而多数人的 ROM 碟就是 FAT/exFAT(要在 Windows 上拷贝), 所以 overlayfs 这条路
#   对多数使用者根本不可用。ROCKNIX 遇到这情况会退回 bind(变成二选一), 我们不要。
#
# mergerfs 是 FUSE 层的 union, **分支是什么档案系统都无所谓**。实机验证(MD1000):
#   内盘 ext4 + 外盘 vfat -> psp 目录同时看到两边的游戏, 平台数 112 -> 152。
#   FUSE 本来就在映像里(ntfs-3g 在用, /usr/bin/fusermount 与 libfuse 都在), 无新增依赖。
#
# ============================================================================
# 设定键: ★只有一个★
# ============================================================================
#   system.gamesdevice   空 = 只用内部盘;  <LABEL> = 该外接盘与内部盘【聚合】
#
# 选中一颗外接盘就代表「要合并」—— 不需要第二个「要不要合并」的开关。
#
# ★用 mergerfs 之后, 「切回内部盘」不再有资料消失的问题★
#   overlayfs 时代所有写入都堆在 upper, 不挂就等於全部藏起来(连存档一起),
#   所以当时必须「一旦启用过就永远挂着」。mergerfs 没有 upper ——
#   写入直接落在内盘的**真实档案**上, 所以不挂 = 单纯只看内盘, 什么都没少。
#   於是也不需要「停用聚合并回写」那套流程了。
#
# 重试(沿用 EmuELEC 既有的两个键):
#   ee_mount.retry  次数(空=预设 10)     ee_load.delay  每次间隔秒数(空=预设 2)
# ★为什么非有不可★: USB 列举可能比开机服务晚很多 —— ROCKNIX 实机量过
# 「sda 开机 +3.9s 认出、sdb 要 +65.9s」, 它的 automount 在 +9.8s 就跑完并判定
# 「没有外接碟」。没有重试的话, 我们会踩一模一样的坑。
#
# ============================================================================
# ★这支挂在 ES 的 ExecStartPre 上, 所以【绝不能跑不完】★
# ============================================================================
# 实机踩过(2026-08-03): gamelist 合并无差别扫过 152 个平台、还穿过 FUSE 与 vfat,
# systemd 等到超时 -> **ES 根本没被执行到**, 开机停在黑画面。
# `ExecStartPre=-` 前面那个 `-` 只忽略【失败】, 不限制【时间】。
# 所以: 每一个可能变慢的步骤都要有 timeout, 而且超时就放弃该步骤、继续让 ES 起来。

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

BIN_DIR="$(dirname "$0")"
INTERNAL="${WORK_BASE}/games-internal"        # 内盘 ROM(bind 出来的独立路径)
EXT_BASE="${WORK_BASE}/games-external"        # 外接盘挂这里
MERGED="${WORK_BASE}/.es4all-roms/merged"     # mergerfs 挂这里, 再 bind 到 ${ROMS}
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

# 某个路径现在是不是挂载点。★不能用 mountpoint★: busybox 那支对档案一律失败。
is_mounted() {
	awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/mounts
}

fstype_of() {
	awk -v p="$1" '$2 == p { print $3 }' /proc/mounts | tail -1
}

# 把聚合整个拆掉, 让 ${ROMS} 回到发行版原本挂上来的那份内盘。
#
# ★顺序必须由上往下★: ${ROMS} 上那层 bind -> mergerfs 本体 -> 外接盘 -> 内盘的 bind。
# 内盘那层留到最后 —— 它底下就是真正的 ROM 分区, 提早拆会变成卸不掉的残留。
MERGE_UNIT=es4all-mergerfs

teardown() {
	# mergerfs 现在跑在自己的 transient unit 里(见下), 先把它停掉再拆挂载。
	command -v systemctl >/dev/null 2>&1 && {
		systemctl stop "${MERGE_UNIT}.service" 2>/dev/null
		systemctl reset-failed "${MERGE_UNIT}.service" 2>/dev/null
	}
	# ★用 -l(lazy)★: 守护进程若已经死了, 挂载点会是「Transport endpoint is not connected」,
	# 一般的 umount 对这种殭尸挂载会失败, 拆不掉就永远卡在那里。
	[ "$(fstype_of "${ROMS}")" = "fuse.mergerfs" ] && { umount "${ROMS}" 2>/dev/null || umount -l "${ROMS}" 2>/dev/null; }
	is_mounted "${MERGED}"   && { umount "${MERGED}" 2>/dev/null || umount -l "${MERGED}" 2>/dev/null; }
	is_mounted "${EXT_BASE}" && umount "${EXT_BASE}" 2>/dev/null
	is_mounted "${INTERNAL}" && umount "${INTERNAL}" 2>/dev/null
	return 0
}

# 挂载点是不是「殭尸」—— 挂载记录还在, 但 FUSE 守护进程已经死了。
# 症状是任何存取都回 ENOTCONN(Transport endpoint is not connected),
# 而 fstype 看起来仍然是 fuse.mergerfs, 光看 /proc/mounts 会以为一切正常。
is_dead_fuse() {
	[ "$(fstype_of "$1")" = "fuse.mergerfs" ] || return 1
	ls "$1" >/dev/null 2>&1 && return 1
	return 0
}

# 失败时把已经做的挂载拆掉。
# ★停在中间状态最糟★: 那时 ES 看到的是空的或半套的 roms, 使用者会以为游戏没了。
rollback() {
	log "★回滚★"
	teardown
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
GAMES_DEV=$(conf_get system.gamesdevice)

if [ -z "${GAMES_DEV}" ]; then
	# 没选外接盘 = 只用内盘。
	#
	# ★但要先确认没有【上一轮留下来的】聚合★(实机踩过 2026-08-03):
	# 挂载是系统层的东西, 重启 ES 不会动到它 —— 使用者在选单里切回内部储存、
	# ES 重启完, /storage/roms 却还挂着上一轮的 mergerfs, 画面上照样是两颗盘的游戏,
	# 看起来就是「设定没生效」。切换动作本身现在会重开机(见 ES 侧), 这里是第二道保险,
	# 也涵盖「有人直接改设定档」的情形。
	if [ "$(fstype_of "${ROMS}")" = "fuse.mergerfs" ]; then
		log "已切回内部盘, 拆除上一轮的聚合"
		teardown
		log "拆除完成 -> ${ROMS} 现在是 $(fstype_of "${ROMS}")"
	fi
	# 平常什么都不做时不留 log —— 那是绝大多数机器的常态, 每次开机写一行只会淹掉真正的讯息。
	exit 0
fi

# ★先处理殭尸挂载★(2026-08-04 实机踩过, 症状是 ES「找不到任何系统」然后不断重启)
# 守护进程死掉后挂载记录还在, fstype 仍是 fuse.mergerfs —— 若照下面那条「已经挂好了」
# 的判断直接 exit, 就会把坏掉的挂载留给 ES, 而 ES 看到的是一个连 ls 都失败的 ROM 目录。
if is_dead_fuse "${ROMS}"; then
	log "★侦测到殭尸挂载(FUSE 守护进程已死)★, 先拆掉再重建"
	teardown
fi

# 已经是 mergerfs 了(重跑) -> 什么都不做, 免得叠上去
if [ "$(fstype_of "${ROMS}")" = "fuse.mergerfs" ]; then
	exit 0
fi

log "===== 聚合开始 (target=${TARGET}, gamesdevice='${GAMES_DEV}') ====="

MERGERFS=""
for c in "${BIN_DIR}/mergerfs" /usr/bin/mergerfs /storage/mergerfs; do
	[ -x "${c}" ] && { MERGERFS="${c}"; break; }
done
if [ -z "${MERGERFS}" ]; then
	log "★找不到 mergerfs 执行档★, 聚合跳过(ES 照常起, 只用内盘)"
	exit 0
fi

# ① 内盘: bind 出一个独立路径当分支
#
# ★为什么是 bind 而不是 move★(实机 2026-08-03): /storage/roms 是 **shared** 挂载,
# 而 shared 挂载不能被 move —— `mount --move` 与 `mount -o move` 都回 EINVAL。
# ★bind 完要 make-private★: bind 会加入同一个传播群组, 之后往 ${ROMS} 上挂东西
# 会跟着传播进这个分支里, 变成「分支里包含合并结果」的循环。
mkdir -p "${INTERNAL}" "${EXT_BASE}" "${MERGED}"
if ! is_mounted "${INTERNAL}"; then
	if ! mount --bind "${ROMS}" "${INTERNAL}" 2>/dev/null; then
		log "★放弃★: 无法 bind ${ROMS} -> ${INTERNAL}"
		exit 0
	fi
	mount --make-private "${INTERNAL}" 2>/dev/null
fi
log "内盘 -> ${INTERNAL}"

# ② 外接盘: 只认选中的那一颗(LABEL), 带重试等 USB 列举
RETRY=$(conf_get ee_mount.retry); [ -n "${RETRY}" ] || RETRY=10
DELAY=$(conf_get ee_load.delay);  [ -n "${DELAY}" ] || DELAY=2

i=0
DEV=""
while [ "${i}" -lt "${RETRY}" ]; do
	# 用 LABEL 解析成装置节点。★不存 /dev/sdb1 这种名字★: 它会随插拔顺序变,
	# 换个 USB 孔就指到别颗碟上(ROCKNIX 就是踩这个)。
	DEV=$(blkid -L "${GAMES_DEV}" 2>/dev/null)
	[ -n "${DEV}" ] && break
	i=$((i + 1))
	[ "${i}" -lt "${RETRY}" ] && sleep "${DELAY}"
done

if [ -z "${DEV}" ]; then
	log "★等不到外接盘 '${GAMES_DEV}'★ (试了 ${RETRY} 次 x ${DELAY} 秒), 只用内盘"
	rollback
	exit 0
fi
[ "${i}" -gt 0 ] && log "外接盘在第 $((i + 1)) 次尝试才出现(等了约 $((i * DELAY)) 秒)"

# 已经被别人挂走的先收回来(udevil 常把 U 盘挂到 /var/media/…)。
# ★ROCKNIX 的 find_games 把「已出现在 /proc/mounts」当成不可用直接放弃★,
# 明明它自己後面就有 umount /var/media/* 的处理, 却永远走不到。别学。
OLD_MP=$(awk -v d="${DEV}" '$1 == d { print $2 }' /proc/mounts | head -1)
if [ -n "${OLD_MP}" ] && [ "${OLD_MP}" != "${EXT_BASE}" ]; then
	log "外接盘已被挂在 ${OLD_MP}, 先卸下"
	umount "${OLD_MP}" 2>/dev/null
fi

if ! is_mounted "${EXT_BASE}"; then
	if ! mount "${DEV}" "${EXT_BASE}" 2>/dev/null; then
		log "★挂不上 ${DEV}★, 只用内盘"
		rollback
		exit 0
	fi
fi
SRC="${EXT_BASE}"
[ -d "${EXT_BASE}/roms" ] && SRC="${EXT_BASE}/roms"
log "外接盘 ${DEV}(${GAMES_DEV}) -> ${SRC}"

# ③ gamelist 合并 —— 在挂 mergerfs 之前, 直接写内盘的真实档案
#
# 目录会合并、**同名档案不会**: 两边都有 gamelist.xml 时只会呈现其中一份,
# 另一份的刮削资料整个被遮蔽。合并脚本只处理【两边都有 gamelist.xml】的平台,
# 其余三种情形本来就只有一份、不需要动作。
#
# ★timeout 是硬性要求★: 这支挂在 ES 的 ExecStartPre 上, 跑不完就等於开不了机。
# 超时就放弃合并(顶多某个平台的刮削资料少一半), 绝不能拖住 ES。
MERGER="${BIN_DIR}/es4all-gamelist-merge.py"
if [ -f "${MERGER}" ] && command -v python3 >/dev/null 2>&1; then
	if ! timeout 60 python3 "${MERGER}" "${INTERNAL}" "${SRC}" >> "${LOG}" 2>&1; then
		log "注意: gamelist 合并未完成(超时或出错), 挂载照常继续"
	fi
fi

# ④ mergerfs
#
# ★不能直接挂在 ${ROMS} 上★(实机 2026-08-03): mergerfs 会拒绝
# 「branches can not include the mountpoint」—— 因为 ${INTERNAL} 是 ${ROMS} 的 bind。
# 所以挂在私有路径 ${MERGED}, 再 bind 过去。
#
# ★两个分支都给 RW★: 若把外接盘设 RO, 那些「只有外接盘才有」的平台其 gamelist
# 会落在唯读分支上 -> ES 每次更新游玩次数都拿到 EROFS。mergerfs **不做 copy-up**,
# 所以 RO 不像 overlayfs 那样有退路。写入本来在二选一模式下也是直接写那颗碟的。
# category.create=ff + 内盘在前 => 新档案优先落在内盘(ext4), 不去戳 FAT。
MERGE_OPTS="branches=${INTERNAL}=RW:${SRC}=RW,category.create=ff,use_ino,allow_other"

# ★mergerfs 必须跑在【自己的 unit】里, 不能留在 ES 服务的 cgroup 中★
#   (2026-08-04 实机踩死: ES 反覆重启 + 画面「WE CAN'T FIND ANY SYSTEMS!」)
#
#   本脚本挂在 ES 服务的 ExecStartPre 上, 直接启动的 mergerfs 会成为【该服务 cgroup 的
#   成员】。ES 只要退出一次(重启、当掉、切换设定), systemd 收拾 cgroup 就把 mergerfs
#   一起杀掉 —— 挂载记录还在、fstype 仍是 fuse.mergerfs, 但守护进程没了,
#   ROM 目录变成「Transport endpoint is not connected」, ES 一个系统都找不到就退出,
#   然后 Restart=always 再拉起来, 无限循环。
#   journal 里的原话: "Found left-over process (mergerfs) in control group while starting unit"
#
#   systemd-run 会把它放进一个**独立的 transient unit**, 与 ES 的生死完全脱钩,
#   ES 重启几次都不影响挂载。★mergerfs 要加 -f★: 让它待在前景, 由该 unit 直接托管;
#   否则它自己 fork 到背景, unit 立刻算结束, 又变回没人管的孤儿。
if command -v systemd-run >/dev/null 2>&1; then
	systemctl stop "${MERGE_UNIT}.service" 2>/dev/null
	systemctl reset-failed "${MERGE_UNIT}.service" 2>/dev/null
	systemd-run --unit="${MERGE_UNIT}" --collect \
		--description="es4all 内外盘聚合(mergerfs)" \
		"${MERGERFS}" -f -o "${MERGE_OPTS}" "${MERGED}" >> "${LOG}" 2>&1
	# 等它真的挂上来(最多 10 秒)。systemd-run 是非同步的, 立刻 bind 会 bind 到空目录。
	i=0
	while [ "${i}" -lt 50 ]; do
		is_mounted "${MERGED}" && break
		i=$((i + 1))
		sleep 0.2
	done
else
	# 没有 systemd-run 的环境(理论上三个 target 都有 systemd, 这里只是保底)
	log "注意: 找不到 systemd-run, mergerfs 只能跑在 ES 的 cgroup 里(ES 重启会断线)"
	"${MERGERFS}" -o "${MERGE_OPTS}" "${MERGED}" >> "${LOG}" 2>&1
fi

if ! is_mounted "${MERGED}"; then
	log "★mergerfs 挂载失败★, 只用内盘"
	rollback
	exit 0
fi

# ⑤ 接到 ${ROMS} 上
if ! mount --bind "${MERGED}" "${ROMS}" 2>/dev/null; then
	log "★无法把合并结果 bind 到 ${ROMS}★"
	rollback
	exit 0
fi

log "已聚合 -> ${ROMS}  (内盘=${INTERNAL}, 外接=${SRC})"
log "===== 聚合结束 ====="
exit 0
