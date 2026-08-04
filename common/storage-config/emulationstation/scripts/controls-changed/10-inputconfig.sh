#!/bin/sh
# es4all: 键位精灵存档后, 把 es_input.cfg 翻译成各模拟器的设定(机制层)。
#
# ★为什么要有这支★
#   ES 存完键位其实【发了两条路】:
#     ① Scripting::fireEvent("controls-changed")  <- 本支挂在这条
#     ② InputManager::doOnFinish()                <- 读 es_input.cfg 里的 <inputAction type="onfinish">
#   发行版原本只用 ②。问题是 ② 的触发条件写在 es_input.cfg 里面, 而那个档:
#     - 在使用者可写的 /storage 底下
#     - 会被 ES 自己覆写、也常被部署/还原整份取代
#   只要那五行 onfinish 掉了, 整条「精灵 -> RA/PSP/DC」的链就【无声断掉】——
#   精灵照跑、es_input.cfg 照更新, 但没有人去产生 /tmp/joypads/*.cfg,
#   RetroArch 继续用上一次的旧键位, 而且没有任何错误讯息。
#   (实机踩过 2026-08-02: MD1000/EmuELEC, es_input.cfg 被换成不含 onfinish 的版本,
#    RA 那份键位停在几分钟前的旧档, select/start 刚好是对调的。)
#
#   ① 这条路的触发条件在【档案摆放位置】, 不在任何可被覆写的内容里, 所以拿它当正路。
#   两条同时存在也没关系: 事件是同步执行的(controls-changed 不在 _asyncEvents 里),
#   跑完才轮到 doOnFinish, 不会两支同时写 /tmp/joypads; 重复跑一次的结果也一样。
#
# ★执行位★: ES 是直接执行本档, 没有 +x 就跑不起来。profile 同步只对落在 bin/ 的档
#   补执行位, 本档落在 storage-config/ 底下, 所以由 bin/apply.sh 的 input_hook() 补。

set -u

# 与 apply.sh 同一套判据: 用 ES 自己(Paths.cpp)认定的 config store 在哪来分辨,
# 别另外去猜发行版名 —— 多一套真相就多一个会不一致的地方。
if [ -f /storage/.config/system/configs/system.cfg ] || [ -d /storage/.config/emuelec ]; then
	ROOT_CFG=/storage/.config
else
	ROOT_CFG="${HOME:-/storage}/.config"
fi

ES_SCRIPTS="${ROOT_CFG}/emulationstation/scripts"
INPUTCONFIG="${ES_SCRIPTS}/inputconfiguration.sh"
ES_INPUT="${ROOT_CFG}/emulationstation/es_input.cfg"
# ★转换器已从 python 改成 sh + awk★(2026-08-04)
#   python3 不是三个发行版都保证有 —— 少了它, 下面那句呼叫会直接失败, 表现是
#   「键位精灵跑完了, RetroArch 里却完全没生效」, 而且没有任何提示。
#   awk 是 busybox 都内建的, E/R/A 三边一定跑得起来, 少一个会静默失效的前提。
CONVERTER="${ROOT_CFG}/es4all/bin/es-input-to-retroarch.sh"
LOG="${ROOT_CFG}/es4all/controls-changed.log"

mkdir -p "$(dirname "${LOG}")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }

# ---- ① EmuELEC: 走发行版自带的 configscripts 链 ----------------------------
if [ -f "${INPUTCONFIG}" ]; then
	log "controls-changed: 执行 inputconfiguration.sh"
	bash "${INPUTCONFIG}" >> "${LOG}" 2>&1
	log "controls-changed: 完成(exit=$?)"
	exit 0
fi

# ---- ② ROCKNIX / Armbian: 用本仓库的转换器直接产 autoconfig ----------------
# ★2026-08-03 本档提升到 common/, 三个发行版共用一支★
#   翻译【工具】三边不同, 但「什么时候翻译」是同一件事, 不该各写一份钩子:
#     emuelec : 有整套 configscripts(inputconfiguration.sh -> retroarch.sh/gamecontrollerdb.sh)
#     rocknix : 没有那套, 改用本仓库的 es-input-to-retroarch.py 直接产 autoconfig
#     armbian : 同 rocknix(那支 python 本来就是 es4all-1key 在用的)
#
# ★autoconfig 目录三边不同★:
#   rocknix 是 /storage/joypads(它是 /tmp/joypads 这个 overlay 的 upper, 写入即持久);
#   armbian 是 RetroArch 标准的 ~/.config/retroarch/autoconfig。
#   写错地方 RA 根本不看它, 而且不会报错。
if [ -d /storage/joypads ]; then
	OUT_DIR=/storage/joypads
else
	OUT_DIR="${ROOT_CFG}/retroarch/autoconfig"
fi

if [ ! -f "${CONVERTER}" ]; then
	log "★找不到转换器 ${CONVERTER}, 键位没有翻译给模拟器★"
	exit 0
fi
if [ ! -f "${ES_INPUT}" ]; then
	log "★找不到 ${ES_INPUT}, 无事可做★"
	exit 0
fi

mkdir -p "${OUT_DIR}"
log "controls-changed: 转换 es_input.cfg -> ${OUT_DIR}"
sh "${CONVERTER}" "${ES_INPUT}" "${OUT_DIR}" >> "${LOG}" 2>&1
log "controls-changed: 完成(exit=$?)"

# ★再跑一次, 这次用【只含刚设定那一支】的临时档★
#
# 为什么需要第二趟: ROCKNIX 的 setsettings.sh 按【evdev 名】找 joypad 档
# (MY_CONTROLLER 取自 /proc/bus/input/devices), 而 es_input.cfg 记的是 SDL 名 ——
# 档名对不上就永远读不到我们这份, 於是「精灵设了半天, 游戏里的热键还是出厂那套」。
# 转换器因此会多写一份用 evdev 名命名的副本, 但那个名字是靠 VID/PID 反查
# 【当前接着的装置】得到的, 只在输入档单一装置时才安全 ——
# ROCKNIX 出厂的 es_input.cfg 有三笔共用 045e:028e, 一起转就会互相覆盖。
#
# ES 在触发本钩子【之前】刚好存了一份只含该装置的 es_temporaryinput.cfg
# (InputManager::getTemporaryConfigPath), 拿它来做别名最精准。
# ★只有 ROCKNIX 走这一步★(2026-08-04 定案)
#   A/E 已经验过、行为不动; 这支只补 R 缺的那一块。判据用 /storage/joypads ——
#   那是 ROCKNIX 的 autoconfig 落点(也是 /tmp/joypads 这个 overlay 的 upper)。
if [ -d /storage/joypads ] && [ -x "${ROOT_CFG}/es4all/bin/es-joypad-evdev.sh" ]; then
	ES_TEMP="${ROOT_CFG}/emulationstation/es_temporaryinput.cfg"
	[ -f "${ES_TEMP}" ] || ES_TEMP="${HOME:-/storage}/.emulationstation/es_temporaryinput.cfg"
	if [ -f "${ES_TEMP}" ]; then
		# ★为什么非要另外产一份不可★
		#   同一支手柄有两套按钮编号: SDL(es_input.cfg 记的)与 udev(核心 evdev 顺序),
		#   而且每一组都是对调的(SDL a=1 b=0 select=7 start=6 / udev a=0 b=1 select=6 start=7)。
		#   RetroArch 与 ROCKNIX 的 setsettings.sh 用的都是 udev 那套 —— 照抄 SDL 编号
		#   会让热键落在错的实体键上(热键变 START、选单变 Y)。
		#   而且 setsettings.sh 是按【evdev 名】找档的(MY_CONTROLLER 取自
		#   /proc/bus/input/devices), 档名对不上根本读不到我们这份。
		#   所以这一份用 evdev 名命名、用 evdev 编号, 两个问题一起解决。
		#
		#   ★热键仍以键位精灵的结果为黄金标准★: 哪一颗当热键、印刷 X 在哪只有 ES 知道,
		#   那支脚本会拿 es_input 的 SDL id 反查语意名、再对到实体按键。
		log "controls-changed: 产生 udev 名的 joypad 档(ROCKNIX)"
		sh "${ROOT_CFG}/es4all/bin/es-joypad-evdev.sh" "${ES_TEMP}" "${OUT_DIR}" \
			"${ROOT_CFG}/emulationstation/es_settings.cfg" >> "${LOG}" 2>&1
		log "controls-changed: udev 名版完成(exit=$?)"

		# ★另存一份, 给开机时的还原用★
		#   固件里的 002-es4all-glue 每次开机会无条件把一份写死的 joypad 档盖上来,
		#   把精灵的结果整个抹掉(实机坐实: 重开机后组合键全没了)。
		#   autostart 的 010-es4all-defaults 会拿这份备份盖回去 —— 它跑在膠水之后。
		mkdir -p "${ROOT_CFG}/es4all/joypads"
		cp -f "${OUT_DIR}"/*.cfg "${ROOT_CFG}/es4all/joypads/" 2>/dev/null
	else
		log "注意: 找不到 es_temporaryinput.cfg, 跳过 evdev 版"
	fi
fi

exit 0
