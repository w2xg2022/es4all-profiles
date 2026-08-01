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

STAMP_DIR=/storage/.config/es4all
DATA_DIR=/storage/.config/es4all          # 机型资料(<T>/<机型>/storage-config/es4all/) 的落点
PPINI=/storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini

mkdir -p "${STAMP_DIR}"

# ---------------------------------------------------------------------------
# PSP 预设: 独立模拟器 + 画面后端 + 内部分辨率
# ---------------------------------------------------------------------------
psp_defaults() {
	local stamp="${STAMP_DIR}/.psp-defaults-applied"
	[ -f "${stamp}" ] && return 0

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

	touch "${stamp}"
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

psp_defaults
selfmount_service

exit 0
