#!/bin/sh
# 把键位精灵的结果翻译成 flycast(独立模拟器, Dreamcast)的 SDL mapping。
#
# ★为什么不沿用 ROCKNIX 原本那条路★
#   ROCKNIX 让 gptokeyb 把组合键翻成【键盘键】, 再由 SDL_Keyboard.cfg 对到 flycast 动作。
#   问题是 ★gptokeyb 不读 es_input.cfg★ —— 使用者在精灵里指定的热键它完全不知道,
#   它自己的热键预设是 Guide 键, 而这类山寨手柄七成没有 Guide 键, 於是整套组合键
#   按不出来, 而且没有任何提示。
#   flycast v4 原生支援真正的按键组合([combo]区块), 不必外挂 —— 与 EmuELEC 侧
#   (set_flycast_joy.sh)同一套做法, 三边心智模型一致: 热键 + START/L1/R1/印刷X。
#
# ★档名必须用【SDL 映射名】, 不是核心名★(EmuELEC 侧血泪, 直接沿用结论)
#   flycast 组档名是 api_name() + "_" + name()(gamepad_device.cpp), 而 SDL 对已识别
#   手柄回传的 name() 是 gamecontrollerdb 里的【映射名】(本机 "Xbox 360 Controller"),
#   不是核心名("Microsoft X-Box 360 pad")。写错名字 flycast 找不到 -> 一路用内建预设,
#   我们产的整份设定【从来没被读过】。★这个洞极难发现★: 内建预设的游戏内按键刚好
#   是对的, 看起来「有生效」, 只有组合键这种预设没有的东西才会暴露。
#   es_input.cfg 的 deviceName 记的正好就是这个映射名, 直接拿来用。
#
# ★面键按位置对齐, 而 DC 的佈局与 Xbox 相同★: 上(北)=Y 下(南)=A 左(西)=X 右(东)=B
#   所以「位置对齐」在 DC 上就是【不翻转】。
#   ⚠️ 已知的取舍: flycast 选单没有独立的导航绑定, 直接拿 DC 的 A 当「确认」
#   (core/ui/gui.cpp: ImGuiKey_GamepadFaceDown <- DC_BTN_A), 而 DC 原厂 A 在南。
#   选单与游戏内共用同一份映射, 改选单必然连游戏内一起改, 没有两全 —— 游戏手感优先。
#
# ★热键那颗绝不能留任何单键绑定★
#   flycast 在【按下的当下】就比对一次, 而单键与组合键在同一张表里。只要热键那颗
#   自己就有作用, 按下的瞬间它先触发, 第二颗键被吃掉 -> 组合键永远凑不成。
#   (EmuELEC 侧实机坐实: [back]=btn_menu 就是所有组合键失效的元凶。)
#
# 用法: es-flycast-mapping.sh <es_input.cfg> <mappings 目录> [es_settings.cfg]
set -u

ES_INPUT="${1:?需要 es_input 档}"
MAP_DIR="${2:?需要 mappings 目录}"
ES_SETTINGS="${3:-}"

[ -f "${ES_INPUT}" ] || exit 0
mkdir -p "${MAP_DIR}" || exit 0

sdlid()  { sed -n "s/.*name=\"$1\"[^>]*id=\"\([0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdltyp() { sed -n "s/.*name=\"$1\"[^>]*type=\"\([a-z]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdlval() { sed -n "s/.*name=\"$1\".*value=\"\(-\?[0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }

NAME="$(sed -n 's/.*deviceName="\([^"]*\)".*/\1/p' "${ES_INPUT}" | head -1)"
[ -n "${NAME}" ] || exit 0
OUT="${MAP_DIR}/SDL_${NAME}.cfg"

# ---- 面键位置 --------------------------------------------------------------
if [ -n "${ES_SETTINGS}" ] && [ -f "${ES_SETTINGS}" ] && \
   grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}"; then
	P_SOUTH="$(sdlid b)"; P_EAST="$(sdlid a)"; P_WEST="$(sdlid y)"; P_NORTH="$(sdlid x)"
else
	P_SOUTH="$(sdlid a)"; P_EAST="$(sdlid b)"; P_WEST="$(sdlid x)"; P_NORTH="$(sdlid y)"
fi
for v in "${P_SOUTH}" "${P_EAST}" "${P_WEST}" "${P_NORTH}"; do
	[ -n "${v}" ] || { echo "★面键资讯不完整, 整份放弃(不写半套)★"; exit 1; }
done

HK="$(sdlid hotkeyenable)"
[ -n "${HK}" ] || HK="$(sdlid select)"
# 组合键的第二颗按【印刷】: 「热键 + 印着 X 的那颗」在任何手柄上讲的都是同一句话。
PRINT_X="$(sdlid x)"
L1="$(sdlid leftshoulder)"; R1="$(sdlid rightshoulder)"
START="$(sdlid start)"
# 退出 = SELECT/START 之中不是热键的那一颗。
EXIT_BTN="${START}"
[ "${HK}" = "${EXIT_BTN}" ] && EXIT_BTN="$(sdlid select)"

# ---- 方向键 ----------------------------------------------------------------
# hat 在 flycast 里不是按钮编号, 而是 255 起算的一组虚拟码(与 EmuELEC 的 BTN_H0 同源):
#   SDL hat 值 1=上 2=右 4=下 8=左 -> 256/259/257/258
if [ "$(sdltyp up)" = "hat" ]; then
	D_UP=256; D_DOWN=257; D_LEFT=258; D_RIGHT=259
else
	D_UP="$(sdlid up)"; D_DOWN="$(sdlid down)"
	D_LEFT="$(sdlid left)"; D_RIGHT="$(sdlid right)"
fi

TMP="${OUT}.es4all.tmp"

# ---- [analog] --------------------------------------------------------------
{
	echo '[analog]'
	n=0
	for p in "leftanalogleft:btn_analog_left"   "leftanalogright:btn_analog_right" \
	         "leftanalogup:btn_analog_up"       "leftanalogdown:btn_analog_down" \
	         "rightanalogleft:axis2_left"       "rightanalogright:axis2_right" \
	         "rightanalogup:axis2_up"           "rightanalogdown:axis2_down"; do
		_n="${p%%:*}"; _a="${p#*:}"
		_i="$(sdlid "${_n}")"; [ -n "${_i}" ] || continue
		case "$(sdlval "${_n}")" in -*) _s='-' ;; *) _s='+' ;; esac
		echo "bind${n} = ${_i}${_s}:${_a}"; n=$((n + 1))
	done
	LT="$(sdlid lefttrigger)"; RT="$(sdlid righttrigger)"
	[ -n "${LT}" ] && { echo "bind${n} = ${LT}+:btn_trigger_left";  n=$((n + 1)); }
	[ -n "${RT}" ] && { echo "bind${n} = ${RT}+:btn_trigger_right"; n=$((n + 1)); }

	# ---- [digital] -----------------------------------------------------
	echo
	echo '[digital]'
	n=0
	emit() { [ -n "$1" ] || return 0
	         # 热键那颗不给任何单键绑定(理由见档首)。
	         [ "$1" = "${HK}" ] && return 0
	         echo "bind${n} = $1:$2"; n=$((n + 1)); }
	emit "${P_SOUTH}" btn_a
	emit "${P_EAST}"  btn_b
	emit "${P_WEST}"  btn_x
	emit "${P_NORTH}" btn_y
	emit "${L1}" btn_c
	emit "${R1}" btn_d
	emit "${START}" btn_start
	emit "${D_UP}"    btn_dpad1_up
	emit "${D_DOWN}"  btn_dpad1_down
	emit "${D_LEFT}"  btn_dpad1_left
	emit "${D_RIGHT}" btn_dpad1_right

	# ---- [combo] -------------------------------------------------------
	# sequential=0 = 「同时按住」而非「依序按下」(flycast ButtonCombo::sequential)。
	# 缺任一颗就跳过该组, 不产无效 combo。
	# ⚠️ flycast 原生没有 FPS 显示切换的可绑定动作, 这项无法比照 RA。
	if [ -n "${HK}" ]; then
		echo
		echo '[combo]'
		n=0
		[ -n "${EXIT_BTN}" ] && { echo "bind${n} = ${HK},${EXIT_BTN}:btn_escape:0"; n=$((n + 1)); }
		[ -n "${R1}" ]      && { echo "bind${n} = ${HK},${R1}:btn_quick_save:0";    n=$((n + 1)); }
		[ -n "${L1}" ]      && { echo "bind${n} = ${HK},${L1}:btn_jump_state:0";    n=$((n + 1)); }
		[ -n "${PRINT_X}" ] && { echo "bind${n} = ${HK},${PRINT_X}:btn_menu:0";     n=$((n + 1)); }
	else
		echo "警告: 找不到热键键, [combo] 整段跳过" >&2
	fi

	echo
	echo '[emulator]'
	echo "mapping_name = ${NAME}"
	echo 'dead_zone = 10'
	echo 'saturation = 100'
	echo 'rumble_power = 100'
	# ★version 必须是 4★: [combo] 是 v4 才有的区块, 写 3 会被当旧格式。
	echo 'version = 4'
	LT="$(sdlid lefttrigger)"; RT="$(sdlid righttrigger)"
	[ -n "${LT}" ] && [ -n "${RT}" ] && echo "triggers = ${LT},${RT}"
} > "${TMP}"

mv -f "${TMP}" "${OUT}"
echo "写入 ${OUT} (flycast; 面键按位置, 热键=${HK:-无})"
