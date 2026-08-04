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

# ── 阶段 0: 发行版差异 ───────────────────────────────────────────────────────
# ★2026-08-03 本档从 emuelec/_common 提升到 common/, 两个发行版共用★
#   在那之前 ROCKNIX 【根本没有包装层】: ES 呼叫的 installtoemmc.sh 直接就是引擎本体。
#   而 ES 是用 `... >/dev/null 2>&1 &` 在背景呼叫的, 引擎走到 `read ans` 等人敲 YES 时
#   没有 stdin -> 立刻读到 EOF -> 判定「没输入 YES」-> abort, 输出还全被 /dev/null 吃掉。
#   ★表现是「按了完全没反应」★, 从头到尾静默。
#
# ★判据用「设定档在哪」而不是猜发行版名★: 与 apply.sh / es4all-storage.sh 同一套 ——
#   那个档的位置就是 ES 自己(Paths.cpp)认定的 config store, 与 ES 同源。
if [ -f /storage/.config/system/configs/system.cfg ]; then
	TARGET=rocknix
	# ★ROCKNIX 的 ES 服务不叫 emustation★: 它跑在 sway 里, 单元名是 essway.service
	# (见 rocknix/_common/storage-config/system.d/es4all-selfmount.service)。
	# 停错服务不会报错, 后果是**画面没交出来** —— 使用者盯着一个不动的 ES 画面
	# 看好几分钟, 而这偏偏是最容易被拔电的时候。
	ES_SERVICE=essway.service
	# ROCKNIX 的引擎是我们自己写的, 支援 --yes 旗标。
	ONECLICK=flag
else
	TARGET=emuelec
	ES_SERVICE=emustation.service
	# EmuELEC 的引擎沿用上游那支的互动式确认, 没有旗标 -> 只能把 YES 灌进 stdin。
	ONECLICK=pipe
fi

# ── 阶段 1: 脱离 ES 的 cgroup ────────────────────────────────────────
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

# 真正干活的引擎(分区/格式化/复制/改开机设定)。
#
# ★引擎【就在本仓库里】, 不再是固件的 /usr/bin/installtoemmc.sh★
#   —— 执行「installtoemmc 随 profiles 发行、不随机型全固件发行」那条决策:
#   改一行分区逻辑却要跑数小时云编译 + 使用者重刷机, 成本完全不成比例;
#   走 profiles 则是「push -> 设备下次开机自己拉」。
#   固件侧 packages/sx05re/emuelec/bin/installtoemmc.sh 已删除,
#   ★不要为了「保底」再放回去★: 两份会各自演化, 分岔了没人发现,
#   直到有人的盒子变砖。
#
# 为什么仍然分成两个档而不合并: 本档做的是「怎么让使用者看得见、按不到 YES 也能跑」,
# 引擎做的是「怎么动这颗碟」, 两者的坑与改动节奏都不一样, 合起来是一支七百行的脚本。
#
# ★引擎按 target 各一份, 但档名相同★(E/_common 与 R/_common 各放一支
#   installtoemmc-engine.sh) —— 分区方案本来就不同:
#     EmuELEC/MD1000 : p1 EMUELEC | p2 STORAGE | p3 EEROMS(ROM 独立分区)
#     ROCKNIX/MD1000 : p1 BOOT(不动) | p2 ROCKNIX | p3 STORAGE(ROM 在里面)
#   本档只负责「怎么跑」, 不碰「怎么分」。
ENGINE="$(dirname "$0")/installtoemmc-engine.sh"
if [ ! -x "${ENGINE}" ]; then
	log "拒绝执行: 找不到 eMMC 安装引擎 (${ENGINE})。"
	exit 1
fi
INSTALLER="${ENGINE}"

# ★不再回退 /usr/bin/installtoemmc★(2026-08-03 移除)
#   ①固件侧那支已经删掉了(installtoemmc 改随 profiles 发行);
#   ②ROCKNIX 的 /usr/bin 底下有一支【上游的 installtointernal】, 名字很像但不是同一支
#     —— MD1000 用了它会开不了机。留着回退路径等於给「找不到引擎时自动改用一支
#     会把机器弄坏的程序」开了后门。宁可直接失败。

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
#
# ★单元名各发行版不同, 所以扫一遍★: EmuELEC 是 udevil-mount@.service,
#   ROCKNIX 还有自己那套 automount。这个坑与发行版无关(是 udev + 重新分区),
#   但挡法要按各家的单元名。写死一个名字的后果不是报错, 是**在另一边完全没挡到**
#   —— 而那种失败要等到 mkfs 那一步才炸, 那时候分区表已经改掉了。
AUTOMOUNT_UNITS="udevil-mount@.service automount.service"
AUTOMOUNT_MASKED=""
for u in ${AUTOMOUNT_UNITS}; do
	# ★先确认这个单元真的存在再 mask★: systemctl mask 对不存在的单元也会「成功」
	# (它只是建一条指向 /dev/null 的符号连结), 于是我们会留下一堆自己造出来的
	# mask 状态, 而且以为挡到了。
	systemctl list-unit-files "${u}" 2>/dev/null | grep -q "^${u}" || continue
	if systemctl mask "${u}" >/dev/null 2>&1; then
		AUTOMOUNT_MASKED="${AUTOMOUNT_MASKED} ${u}"
		log "已 mask ${u}(挡住重新分区后的自动挂载)"
	fi
done

restore_automount() {
	for u in ${AUTOMOUNT_MASKED}; do
		systemctl unmask "${u}" >/dev/null 2>&1
	done
}

# 顺手把现在挂着的 eMMC 分区先卸掉(上一次失败可能留下挂载)。
for mp in $(awk '$1 ~ /^\/dev\/mmcblk0p[0-9]+$/ {print $2}' /proc/mounts); do
	case "${mp}" in
		/var/media/*) umount "${mp}" 2>/dev/null && log "卸载 ${mp}" ;;
	esac
done

# ── 阶段 4: 把画面交出来 ─────────────────────────────────────────────────────
systemctl stop "${ES_SERVICE}" 2>/dev/null
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
	# ★没有 kmscon 的发行版(ROCKNIX 就是)★ —— 不必为此补一个终端机套件:
	# 我们只是要把几十行进度印出来, 用不到终端机模拟器的能力(字型、VT 管理、
	# escape 序列)。核心的 fbcon 本来就绑在 framebuffer 上, 直接写 VT 就看得见。
	#
	# 前提是【DRM master 已经放掉】—— 前面已经 systemctl stop 掉 ES 服务
	# (ROCKNIX 是 essway, 它连 sway 一起收掉), sway 一退出, fbcon 就把画面接回去。
	# 判断这台机器行不行的客观依据(实机查证 MD1000/ROCKNIX):
	#     cat /sys/class/vtconsole/vtcon*/name   -> 要有 "frame buffer device"
	#     cat /sys/class/vtconsole/vtcon*/bind   -> 该行要是 1
	#     ls /dev/fb0
	# 三者都在就写得进去; 少了就只会是黑屏(那种机器才需要 kmscon 那类 DRM 原生终端)。
	command -v ee_console >/dev/null 2>&1 && ee_console enable

	# 写到【当前活跃的那个 VT】而不是写死 tty1: 装置停在哪个 VT 各家不同,
	# 写错就是「跑得好好的却什么都看不到」。/dev/tty0 = 当前 VT 的别名, 最保险。
	TTY_OUT=/dev/tty0
	[ -w "${TTY_OUT}" ] || TTY_OUT=/dev/console

	# 清屏 + 关掉游标闪烁, 让进度看得清楚(纯 ANSI, 不需要终端机套件)。
	printf '\033[2J\033[H\033[?25l' > "${TTY_OUT}" 2>/dev/null

	/bin/sh "${RUNNER}" > "${TTY_OUT}" 2>&1

	printf '\033[?25h' > "${TTY_OUT}" 2>/dev/null   # 游标还原, 免得留给下一个程式
fi

RC=$(cat /tmp/es4all-emmc.rc 2>/dev/null || echo 1)
log "===== 结束: exit=${RC} ====="

if [ "${RC}" -ne 0 ]; then
	# 失败不关机, 让 ES 起回来: 使用者还能进系统看日志。
	# 安装器在动手前会做大小/装置检查, 检查不过就拒跑 —— 那种失败是安全的(什么都没改)。
	log "失败, 重新启动 ES。日志见 ${LOG}"
	restore_automount
	systemctl start "${ES_SERVICE}" 2>/dev/null
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
