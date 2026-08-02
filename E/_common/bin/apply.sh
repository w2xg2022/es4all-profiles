#!/bin/bash
# es4all: profile 套用钩子(机制层) —— ES 每次启动、profile 同步之后调用一次。
#
# ★这支是【通用入口】★: ES 只认得 "有没有 bin/apply.sh" 这一件事, 里面做什么完全由
# 本仓库决定。于是以后要新增任何一次性设定(PSP 预设、keylayout、模拟器选择…),
# 都只需要改本仓库, **不必再动 ES、更不必重编固件**。
#
# 幂等: 每一项各自用标记档把关, 只在【第一次】套用。
# ★为什么是「预设」而不是「强制」★: 使用者在 PPSSPP 里自己改过画质/后端之后, 不该被
# 下一次开机改回去。要强制的话就是每次启动都写(像 ppsspp.sh 对 UI 语言那样), 但那是
# 「跟随 ES 设定」的语意, 与「出厂预设值」不同, 别混为一谈。

set -u

# ★必须 source /etc/profile★ —— set_ee_setting / get_ee_setting 是**定义在那里面的
# shell 函式**, 不是 /usr/bin 里的可执行档。少了这行, 下面 `command -v set_ee_setting`
# 一律不成立, 所有靠它写的设定会被**静默跳过**:选单看起来正常、标记档也照样建立,
# 但设定一个都没写进 emuelec.conf。实机踩过(2026-08-02):PSP/DC 的模拟器预设
# 从头到尾没生效, 先前看到的 psp.core=PPSSPPSDL 是韧体本来就有的值, 不是这里设的。
# 这类「守卫把自己挡掉」的失败最难发现, 因为它不报错也不留痕迹。
# ⚠️ source 前后要关掉 `set -u`:EmuELEC 的 /etc/profile.d/10-locale.conf 会引用未定义的
#    LOCPATH, 在 `set -u` 下直接让整支脚本中止(实机踩过, 表现同样是「什么都没发生」)。
set +u
[ -f /etc/profile ] && . /etc/profile
set -u

STAMP_DIR=/storage/.config/es4all
DATA_DIR=/storage/.config/es4all          # 机型资料(<T>/<机型>/storage-config/es4all/) 的落点
PPINI=/storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini

mkdir -p "${STAMP_DIR}"

# ---------------------------------------------------------------------------
# PSP 预设: 独立模拟器 + 画面后端 + 内部分辨率
# ---------------------------------------------------------------------------
psp_defaults() {
	local stamp="${STAMP_DIR}/.psp-defaults-applied"

	# 全机种预设值。机型资料档可覆盖(见下), 没有资料档就用这两个。
	#   BACKEND: OPENGL | VULKAN     RESOLUTION: 内部分辨率倍数(2 = 2X)
	# ★为什么预设是 OpenGL 而不是 Vulkan★: Vulkan 要驱动真的支援才快, 在旧的
	# Mali(如 G31/450)上不是变慢就是黑屏; OpenGL 是所有机型都跑得起来的安全值。
	# 跑得动 Vulkan 的机型(如 MD1000/RK3566 的 G52)自己用机型资料档覆盖。
	local BACKEND=OPENGL
	local RESOLUTION=2

	# 机型资料(<T>/<机型>/storage-config/es4all/psp-defaults.conf), 有才覆盖。
	# 格式就是两行 KEY=VALUE, 见 E/MD1000 那份。
	local conf="${DATA_DIR}/psp-defaults.conf"
	if [ -f "${conf}" ]; then
		# 只取认得的两个键, 不 source 整个档(资料档不该有执行能力)
		local v
		v=$(sed -n 's/^[[:space:]]*BACKEND[[:space:]]*=[[:space:]]*//p' "${conf}" | head -1)
		[ -n "${v}" ] && BACKEND="${v}"
		v=$(sed -n 's/^[[:space:]]*RESOLUTION[[:space:]]*=[[:space:]]*//p' "${conf}" | head -1)
		[ -n "${v}" ] && RESOLUTION="${v}"
	fi

	# ★2026-08-02:标记档改成【记住套用了什么值】, 不再只记「做过了」★
	#   实机踩到的洞(MD1000): 标记档 08:27 生成、机型资料档 11:57 才下发 ——
	#   `[ -f stamp ] && return` 在资料到位【之前】就永久封印了这段,
	#   于是 psp-defaults.conf 写着 VULKAN, 实机却一直是 OpenGL,
	#   而且**完全静默**, 看设定档只会觉得「设了没用」。
	#   改成比对内容后, 这两种情形都能自愈:
	#     ①机型资料晚于首次开机才下发  ②我们日后调整了建议值(改 conf 就会重新套用)
	#   ⚠️ 仍**不是**每次开机强制: 值没变就不动, 使用者自己在 PPSSPP 里改过的画质会留着。
	#     只有「profile 给的建议值本身变了」才会再套一次 —— 那正是我们要它生效的时候。
	#   (旧的空标记档内容不等于任何 want, 会自动重跑一次, 不必手动清。)
	local want="BACKEND=${BACKEND} RESOLUTION=${RESOLUTION}"
	[ "$(cat "${stamp}" 2>/dev/null)" = "${want}" ] && return 0

	# ① 预设用【独立】PPSSPP 而不是 libretro 核心。
	#    psp.core / psp.emulator 优先于 es_systems.cfg 的默认值(两个键都要设,
	#    ES 的选单与实际启动路径分别读它们)。
	if command -v set_ee_setting >/dev/null 2>&1; then
		set_ee_setting psp.core PPSSPPSDL
		set_ee_setting psp.emulator PPSSPPSDL
	fi

	# ② 后端与分辨率写进 ppsspp.ini。
	#    ⚠️ PPSSPP 写这行的格式是 `GraphicsBackend = 3 (VULKAN)` —— 数字后面还带括号名称,
	#    只写数字虽然能读, 但下次 PPSSPP 存档时格式会被它自己改回去; 这里直接照它的格式写,
	#    比对/除错时看得懂, 也不会每次开机都被判定成「变更」。
	if [ -f "${PPINI}" ]; then
		local BE_NUM BE_NAME
		case "$(echo "${BACKEND}" | tr '[:lower:]' '[:upper:]')" in
			VULKAN) BE_NUM=3; BE_NAME=VULKAN ;;
			*)      BE_NUM=0; BE_NAME=OPENGL ;;
		esac
		sed -i "s|^GraphicsBackend = .*|GraphicsBackend = ${BE_NUM} (${BE_NAME})|" "${PPINI}"
		sed -i "s|^InternalResolution = .*|InternalResolution = ${RESOLUTION}|" "${PPINI}"
	fi

	echo "${want}" > "${stamp}"
	echo "es4all: PSP defaults applied -> ${want}"
}

# ---------------------------------------------------------------------------
# 开机自挂载服务: 让自己编的 ES 与 /usr/bin 覆盖档撑过重开机
# ---------------------------------------------------------------------------
# ★这项不用标记档、每次都跑★: enable 是幂等的, 而且刷新固件、换 /storage 之后
# 这个 enable 会消失 —— 每次开机确认一遍才不会某天默默失效。
# (失效的表现极隐蔽: ES 跑回固件自带的旧版, 版本号还很像, 会被误判成「改动没生效」。)
selfmount_service() {
	[ -f /storage/.config/system.d/es4all-selfmount.service ] || return 0
	command -v systemctl >/dev/null 2>&1 || return 0

	if ! systemctl is-enabled es4all-selfmount.service >/dev/null 2>&1; then
		systemctl daemon-reload 2>/dev/null
		systemctl enable es4all-selfmount.service >/dev/null 2>&1
	fi
}

# ---------------------------------------------------------------------------
# DC 预设: 用独立模拟器(Flycast-SA)而不是 libretro 核心
# ---------------------------------------------------------------------------
# 与 PSP 同一套做法: dreamcast.core / dreamcast.emulator 两个键都要设 ——
# ES 的选单与实际启动路径分别读它们, 只设一个会出现「选单显示 A、实际跑 B」。
# 值取自 es_systems.cfg 的 <emulator name="flycastsa"><core default="true">flycastsa。
# ★同样只在第一次套用★(标记档把关): 使用者后来自己改回 libretro 不该被开机流程覆盖。
# 这里的值写死在本档、没有机型资料档, 所以不会有 psp_defaults 那个「资料晚到」的洞;
# 但要是哪天 DC 也加了机型资料, 记得比照 psp_defaults 改成【比对内容】的标记档。
dc_defaults() {
	local stamp="${STAMP_DIR}/.dc-defaults-applied"
	[ -f "${stamp}" ] && return 0

	if command -v set_ee_setting >/dev/null 2>&1; then
		set_ee_setting dreamcast.core flycastsa
		set_ee_setting dreamcast.emulator flycastsa
	fi

	touch "${stamp}"
}

psp_defaults
dc_defaults
selfmount_service

exit 0
