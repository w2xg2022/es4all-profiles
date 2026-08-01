#!/bin/sh
# es4all: 写入 eMMC(机制层) —— 由 ES 退出选单的「写入 eMMC」调用。
#
# ★本档【不含任何分区逻辑】★, 只是发行版那支已验证安装器的一层薄包装。
#   分区、格式化、复制、GPT 处理全在 /usr/bin/installtoemmc.sh 里 ——
#   那支是「一支程序 + 内置 board 表」的设计(黄金标准: EmuELEC docs/emmc-install.md),
#   MD1000 的 case 已经在里面(METHOD=repartition, 仿 ROCKNIX 同板那支写的、实机验过)。
#   ★这种「做错就开不了机」的东西不该重写第二份★ —— 重写 = 两份逻辑各自演化,
#   哪天分岔了不会有人发现, 直到有人的盒子变砖。
#
# 本档存在的价值:
#   ① 把「哪台机器用哪个 board 名」这个【资料】与流程分开(资料在
#      <机型>/storage-config/es4all/emmc-layout.conf), 加机型不必改本档。
#   ② 一键化: 发行版那支会 read 等使用者敲 YES, 从选单调用时没有 stdin,
#      而且电视盒常常只有手柄、根本打不了字。ES 那边已经有确认对话框了。
#   ③ ★把过程放到终端机上让使用者【看得见】★ —— 见下。
#
# ─────────────────────────────────────────────────────────────────────────────
# 为什么要停掉 ES 再跑, 而不是让 ES 在背景跑完
#   这是【数分钟】的复制作业。画面没反应的机器最容易被当成当机而直接拔电,
#   而这偏偏是最不能被打断的操作。所以停掉 ES、把画面交给终端机, 全程看得到进度。
#
# ★两个会让人踩死的细节, 都已经验证过★
#   1) **子行程会不会被一起杀掉**: `systemctl stop` 预设会杀掉整个 cgroup。
#      本机 emustation.service 是 `KillMode=process`(实机确认), 只杀主行程,
#      子行程活得下来。但这条命太重要, 不赌在别人的服务档上 ——
#      有 systemd-run 就先把自己搬进独立 scope, 彻底脱离 emustation 的 cgroup。
#   2) **画面**: ES 走 SDL kmsdrm, 当过 DRM master 之后, 只往 legacy fbdev 写像素
#      的 fbterm 会「有内容但没有扫描输出」= 全黑(EmuELEC 这个坑修过一轮)。
#      kmscon 是 DRM/KMS 原生: 自己开 VT、自己 modeset、把 buffer 挂上输出平面。
#      故优先 kmscon; 没有才退回 ee_console + /dev/tty0。
# ─────────────────────────────────────────────────────────────────────────────
#
# 日志一律同时写档: /storage/.config/es4all/installtoemmc.log(画面看漏了还查得到)。

set -u

CONF=/storage/.config/es4all/emmc-layout.conf
LOG=/storage/.config/es4all/installtoemmc.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }

# ── 阶段 1: 脱离 emustation 的 cgroup ────────────────────────────────────────
# ★守卫必须用【参数】不能用环境变数★
#   原本写成 `ES4ALL_EMMC_DETACHED=1 systemd-run --scope --setenv=... "$0"`,
#   实机结果是那个变数【没有传进子行程】-> 守卫失效 -> 自己又去 systemd-run 一次
#   -> **无限自我重生**。表现极难判读: 杀掉 kmscon 马上又冒一个新的、ES 起不来、
#   画面一直被占住, 看起来像「系统坏了」。参数一定会传到, 用它才可靠。
if [ "${1:-}" != "--detached" ] && command -v systemd-run >/dev/null 2>&1; then
	# 已经有一份在跑就不要再开(避免使用者连按两次, 两份同时对同一颗 eMMC 动手)。
	if systemctl is-active es4all-installtoemmc.scope >/dev/null 2>&1; then
		log "已有一份安装程序在执行中, 忽略这次请求。"
		exit 0
	fi
	systemd-run --scope --quiet --unit=es4all-installtoemmc "$0" --detached >/dev/null 2>&1 &
	exit 0
fi

# ── 阶段 2: 检查资料 ─────────────────────────────────────────────────────────
# 资料档不在 = 这台没验证过 -> 拒绝。★绝不用 auto 猜★: 猜错 board 就是拿别台的
# 分区方案砍这台的 eMMC。(ES 那边本来也用「有没有这个档」决定选单显不显示,
# 这里再挡一次, 免得有人直接从命令列跑。)
if [ ! -f "${CONF}" ]; then
	log "拒绝执行: 找不到 ${CONF}, 本机型未验证过写入 eMMC。"
	exit 1
fi

BOARD=$(sed -n 's/^[[:space:]]*BOARD[[:space:]]*=[[:space:]]*//p' "${CONF}" | head -1)
if [ -z "${BOARD}" ]; then
	log "拒绝执行: ${CONF} 里没有 BOARD=。"
	exit 1
fi

# 发行版的安装器。两家的档名与一键参数不同:
#   EmuELEC : /usr/bin/installtoemmc.sh <board>        互动式, 用管线喂 YES
#   ROCKNIX : /usr/bin/installtoemmc    <board> --yes  原生支援一键
# (本档在 E/_common, 只会下发给 EmuELEC; ROCKNIX 那份日后放 R/_common。)
if [ -x /usr/bin/installtoemmc.sh ]; then
	INSTALLER=/usr/bin/installtoemmc.sh
	ONECLICK=pipe
elif [ -x /usr/bin/installtoemmc ]; then
	INSTALLER=/usr/bin/installtoemmc
	ONECLICK=flag
else
	log "拒绝执行: 找不到发行版的 eMMC 安装器。"
	exit 1
fi

log "===== 开始: board=${BOARD} installer=${INSTALLER} ====="

# ── 阶段 3: 挡住 automount ───────────────────────────────────────────────────
# ★实机踩过★: 安装器开头会把 eMMC 上已挂载的分区卸掉, 但**重新分区本身会触发 udev**,
#   /usr/lib/udev/rules.d/95-udevil-mount.rules 里
#       ACTION=="add|change", RUN+="systemctl restart udevil-mount@/dev/%k.service"
#   于是新分区【立刻又被挂回去】, 轮到 mkfs 时就:
#       mkfs.vfat: /dev/mmcblk0p2 contains a mounted filesystem.
#       ERROR: mkfs.vfat failed.
#   结果是分区已经换掉(Armbian 没了)、档案系统却没建起来 —— 装到一半的状态。
#
# 修在这里而不是改发行版的安装器: 改那支要重编固件, 而这层本来就是为了「不必重编」
# 才存在的。mask 模板单元 -> udev 那句 restart 会失败 -> 新分区不会被挂上。
AUTOMOUNT_MASKED=""
if systemctl mask udevil-mount@.service >/dev/null 2>&1; then
	AUTOMOUNT_MASKED=1
	log "已 mask udevil-mount@.service(挡住重新分区后的自动挂载)"
fi

restore_automount() {
	[ -n "${AUTOMOUNT_MASKED}" ] && systemctl unmask udevil-mount@.service >/dev/null 2>&1
}

# 顺手把现在挂着的 eMMC 分区先卸掉(上一次失败可能留下挂载)。
for mp in $(awk '$1 ~ /^\/dev\/mmcblk0p[0-9]+$/ {print $2}' /proc/mounts); do
	case "${mp}" in
		/var/media/*) umount "${mp}" 2>/dev/null && log "卸载 ${mp}" ;;
	esac
done

# ── 阶段 4: 把画面交出来 ─────────────────────────────────────────────────────
systemctl stop emustation 2>/dev/null
sleep 2

# 真正干活的那一小段, 让它同时写画面与日志。
RUNNER=/tmp/es4all-emmc-run.sh
cat > "${RUNNER}" <<RUNEOF
#!/bin/sh
echo "es4all: installing to eMMC (board=${BOARD})"
echo "===== do NOT unplug the power ====="
echo
# ★结束码必须在【管线之内】取★: 写成 `installer | tee` 之后再 echo \$?, 拿到的是
#   **tee** 的结束码 —— tee 永远成功, 于是安装器明明报 ERROR 也会被判成成功。
#   实机踩过: mkfs.vfat 失败了, 外层却走成功路径去关机。
#   在会抹碟的操作上把失败当成功是最危险的一类 bug, 所以把 echo \$? 放进大括号里,
#   让它取的是安装器(或 echo YES | installer 这条管线)的状态。
if [ "${ONECLICK}" = "flag" ]; then
	{ "${INSTALLER}" "${BOARD}" --yes; echo \$? > /tmp/es4all-emmc.rc; } 2>&1 | tee -a "${LOG}"
else
	{ echo YES | "${INSTALLER}" "${BOARD}"; echo \$? > /tmp/es4all-emmc.rc; } 2>&1 | tee -a "${LOG}"
fi

RC=\$(cat /tmp/es4all-emmc.rc 2>/dev/null || echo 1)
echo
if [ "\${RC}" -eq 0 ]; then
	echo "OK - powering off in 10s. Unplug the USB stick before powering on."
	sleep 10
else
	# 失败要停在画面上让人看得到, 不然终端机一闪就没了、只剩「按了没反应」的印象。
	echo "*** FAILED (exit \${RC}) - nothing further was changed. ***"
	echo "*** Log: ${LOG}"
	echo "*** Returning to EmulationStation in 20s."
	sleep 20
fi

# ★跑完要自己把终端机收掉★: kmscon 是用 --login 起的(不加它会拒收后面的命令),
# 而 --login 的语意像 getty —— 命令结束后它【不会退出】, 会继续守着 VT。
# 实机踩过: 安装结束后 kmscon 一直占着画面, ES 起回来也看不到东西,
# 看起来就是「系统挂了」。所以这里主动结束自己的终端机。
pkill -x kmscon 2>/dev/null
RUNEOF
chmod 0755 "${RUNNER}"

if [ -x /usr/bin/kmscon ]; then
	# ★`--login` 不可省★: 少了它 kmscon 会拒收后面那段命令 ——
	#   "Unparsed remaining args starting with: /bin/sh"
	#   然后立刻退出。表现是「按了写入 eMMC, 画面闪一下就回来、什么都没发生」,
	#   而且安装器一行输出都没有(它根本没被执行到)。实机踩过一次。
	#   用法与 EmuELEC 自己的 fbterm.sh 一致, 别自己改写。
	#
	# kmscon 会切到自己的 VT(实测 /dev/tty2), 失败路径要切回原本那个,
	# 否则 ES 起回来会停在别的 VT 上 = 黑屏。成功路径直接关机, 无所谓。
	PREV_VT="$(cat /sys/class/tty/tty0/active 2>/dev/null)"
	PREV_VT="${PREV_VT#tty}"

	kmscon --font-size 24 --login -- /bin/sh "${RUNNER}"

	# 双保险: runner 结尾会自己 pkill kmscon, 但万一它没跑到(例如被中断),
	# 这里再收一次 —— 留着不管的话画面会一直被占住。
	pkill -x kmscon 2>/dev/null
	sleep 1
	[ -n "${PREV_VT}" ] && chvt "${PREV_VT}" 2>/dev/null
else
	command -v ee_console >/dev/null 2>&1 && ee_console enable
	/bin/sh "${RUNNER}" > /dev/tty0 2>&1
fi

RC=$(cat /tmp/es4all-emmc.rc 2>/dev/null || echo 1)
log "===== 结束: exit=${RC} ====="

if [ "${RC}" -ne 0 ]; then
	# 失败不关机, 让 ES 起回来: 使用者还能进系统看日志。
	# 安装器在动手前会做大小/装置检查, 检查不过就拒跑 —— 那种失败是安全的(什么都没改)。
	log "失败, 重新启动 ES。日志见 ${LOG}"
	restore_automount
	systemctl start emustation 2>/dev/null
	exit "${RC}"
fi

# 成功: 把 automount 恢复回去再关机, 别把 mask 状态留给下一个系统。
restore_automount

# ★成功后关机而不是重开★: 这类板子的 u-boot 每次开机都先试 SD/USB 再试 eMMC,
# 只要 U 盘还插着就永远开回 U 盘 —— 软重开【不会】帮使用者把 U 盘拔掉。
# 关机才让使用者有机会拔掉 U 盘再通电, 那样才真的会从 eMMC 开机。
log "成功, 关机。请拔掉 U 盘后再通电。"
sync
poweroff
