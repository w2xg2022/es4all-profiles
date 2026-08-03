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
CONVERTER="${ROOT_CFG}/es4all/bin/es-input-to-retroarch.py"
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
python3 "${CONVERTER}" "${ES_INPUT}" "${OUT_DIR}" >> "${LOG}" 2>&1
log "controls-changed: 完成(exit=$?)"

exit 0
