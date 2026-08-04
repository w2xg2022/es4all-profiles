#!/bin/sh
# 产生一份【档名与 input_device 用 udev 名】的 RetroArch joypad autoconfig。
#
# ★为什么需要这一支(ROCKNIX 专用)★
#   ROCKNIX 的 setsettings.sh 在每次启动游戏时从 joypad 档反推 RA 热键, 而它找档的方式是
#   MY_CONTROLLER=从 /proc/bus/input/devices 取【udev 名】, 再读 /tmp/joypads/<那个名字>.cfg。
#   而 es_input.cfg 记的是 SDL 名("Xbox 360 Controller" vs "Microsoft X-Box 360 pad") ——
#   档名对不上就永远读不到我们这份, 表现是「精灵设了半天, 游戏里的热键还是出厂那套」。
#   EmuELEC 侧早就这么做了(get_udev_name_from_guid), 这里补上 R 的等价物。
#
# ★★内容【照抄 es_input.cfg 的编号】, 绝对不要去问 evdev★★(2026-08-04 血泪)
#   我曾经改成「用 evdev 的能力位算出方位编号」, 理由是 RA 的 udev driver 就是那样编号的。
#   算得出来、也与 ROCKNIX 出厂档逐格相同 —— 但实机一测, 按印刷 X 出来的是 FPS。
#   真因: ★山寨手柄的回报本身就不一致★。实测这颗(印刷是任天堂式: X 在上、Y 在左):
#       印刷 X(实体在【北】) 按下去报的是 BTN_WEST
#       印刷 A(实体在【东】) 按下去报的是 BTN_EAST
#   也就是 A/B 照【位置】报、X/Y 照【字母】报。这种手柄上,
#   「evdev 语意 = 实体方位」这个前提根本不成立, 照它算必然歪。
#
#   唯一可靠的来源是【使用者在精灵里实际按下的那一颗】—— 那正是 es_input.cfg 记的东西。
#   EmuELEC 的 configscripts 从头到尾就是照抄 ES 的编号(见 face_key 那段注解:
#   「任天堂式(true)时印刷与方位天生一致, 直通即可」), 而同一颗手柄在 E 上是好的。
#   所以 R 照抄同一套模型, 别自作聪明。
#
# 面键的唯一换算(与 EmuELEC 的 face_key 完全一致):
#   Xbox 式印刷(InvertButtons=false, 印刷 A 在南):
#       印刷A=南->RetroPad B、印刷B=东->A、印刷X=西->Y、印刷Y=北->X
#   任天堂式印刷(true, 印刷 A 在东): 印刷与 RetroPad 方位天生一致 -> 原样直通
#
# 用法: es-joypad-evdev.sh <es_temporaryinput.cfg> <输出目录> [es_settings.cfg]
set -u

ES_INPUT="${1:?需要 es_input 档}"
OUT_DIR="${2:?需要输出目录}"
ES_SETTINGS="${3:-}"

[ -f "${ES_INPUT}" ] || exit 0
mkdir -p "${OUT_DIR}" || exit 0

BIN_DIR="$(dirname "$0")"

# ---- GUID -> VID/PID -> udev 名 --------------------------------------------
GUID="$(sed -n 's/.*deviceGUID="\([0-9a-fA-F]*\)".*/\1/p' "${ES_INPUT}" | head -1)"
[ -n "${GUID}" ] || exit 0
hx() { printf '%d' "0x$1"; }
VID=$(printf '%04x' $(( $(hx "$(echo "${GUID}" | cut -c11-12)") * 256 + $(hx "$(echo "${GUID}" | cut -c9-10)") )))
PID=$(printf '%04x' $(( $(hx "$(echo "${GUID}" | cut -c19-20)") * 256 + $(hx "$(echo "${GUID}" | cut -c17-18)") )))

# 这支 helper 现在【只用来拿名字】—— 它算的编号刻意不用了, 理由见档首。
DEV_NAME="$(sh "${BIN_DIR}/es-joypad-evdevmap.sh" "${VID}" "${PID}" 2>/dev/null | sed -n 's/^NAME=//p' | head -1)"
[ -n "${DEV_NAME}" ] || exit 0

SDL_NAME="$(sed -n 's/.*deviceName="\([^"]*\)".*/\1/p' "${ES_INPUT}" | head -1)"
[ "${DEV_NAME}" = "${SDL_NAME}" ] && exit 0   # 两个名字一样就不必多产一份

# ---- 印刷布局: 只有 Xbox 式需要换算 ----------------------------------------
XBOX=1
[ -n "${ES_SETTINGS}" ] && [ -f "${ES_SETTINGS}" ] && \
	grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" && XBOX=0

face_key() {   # 印刷字母 -> 该按键实际所在方位对应的 RetroPad 面键
	if [ "${XBOX}" = "1" ]; then
		case "$1" in a) echo b ;; b) echo a ;; x) echo y ;; y) echo x ;; esac
	else
		echo "$1"
	fi
}

sdlid()  { sed -n "s/.*name=\"$1\"[^>]*id=\"\([0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdltyp() { sed -n "s/.*name=\"$1\"[^>]*type=\"\([a-z]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdlval() { sed -n "s/.*name=\"$1\".*value=\"\(-\?[0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }

safe=$(echo "${DEV_NAME}" | sed 's/[^A-Za-z0-9 _-]/_/g; s/^ *//; s/ *$//')
OUT="${OUT_DIR}/${safe}.cfg"
put() { [ -n "$2" ] && echo "$1 = \"$2\"" >> "${OUT}"; }

: > "${OUT}"
echo "input_driver = \"udev\""            >> "${OUT}"
echo "input_device = \"${DEV_NAME}\""     >> "${OUT}"
put input_vendor_id  "$((0x${VID}))"
put input_product_id "$((0x${PID}))"

# 面键: 照抄 ES 的编号, 只按印刷布局决定它对应哪一颗 RetroPad 面键。
for L in a b x y; do
	put "input_$(face_key "${L}")_btn" "$(sdlid "${L}")"
done

put input_select_btn "$(sdlid select)"
put input_start_btn  "$(sdlid start)"
put input_l_btn      "$(sdlid leftshoulder)"
put input_r_btn      "$(sdlid rightshoulder)"
put input_l3_btn     "$(sdlid leftthumb)"
put input_r3_btn     "$(sdlid rightthumb)"

# 方向键: hat 优先(有 hat 就用 hat 写法), 否则当一般按钮。
for D in up down left right; do
	if [ "$(sdltyp "${D}")" = "hat" ]; then
		put "input_${D}_btn" "h$(sdlid "${D}")${D}"
	else
		put "input_${D}_btn" "$(sdlid "${D}")"
	fi
done

# 摇杆与扳机: 轴号照抄, 正负号看 es_input 记的 value。
ax() {   # $1=es_input 名  $2=RA 键名
	_id="$(sdlid "$1")"; [ -n "${_id}" ] || return 0
	_v="$(sdlval "$1")"
	case "${_v}" in -*) _s="-" ;; *) _s="+" ;; esac
	echo "$2 = \"${_s}${_id}\"" >> "${OUT}"
}
ax leftanalogleft  input_l_x_minus_axis;  ax leftanalogright input_l_x_plus_axis
ax leftanalogup    input_l_y_minus_axis;  ax leftanalogdown  input_l_y_plus_axis
ax rightanalogleft input_r_x_minus_axis;  ax rightanalogright input_r_x_plus_axis
ax rightanalogup   input_r_y_minus_axis;  ax rightanalogdown  input_r_y_plus_axis
ax lefttrigger     input_l2_axis;         ax righttrigger    input_r2_axis

# ---- 热键 ------------------------------------------------------------------
# ★以键位精灵的结果为黄金标准★: 使用者按哪一颗当热键, 就是哪一颗。
# 没设 hotkeyenable 就拿 SELECT 顶上(与 EmuELEC 的 configscripts 同一套做法)。
HK="$(sdlid hotkeyenable)"
[ -n "${HK}" ] || HK="$(sdlid select)"

if [ -n "${HK}" ]; then
	put input_enable_hotkey_btn "${HK}"
	# 绑到【印刷】键: 说明书写的是 SELECT+X, 使用者看的是手柄上的字母,
	# 所以这里用印刷字母的编号, 不做 face_key 换算。
	put input_menu_toggle_btn "$(sdlid x)"
	put input_fps_toggle_btn  "$(sdlid y)"
	put input_save_state_btn  "$(sdlid rightshoulder)"
	put input_load_state_btn  "$(sdlid leftshoulder)"
	# 退出 = SELECT/START 之中【不是热键键】的那一颗, 组合才按得出来。
	if [ "${HK}" = "$(sdlid start)" ]; then
		put input_exit_emulator_btn "$(sdlid select)"
	else
		put input_exit_emulator_btn "$(sdlid start)"
	fi
else
	# ★没有热键键就一个热键都不写★: RA 在没有 input_enable_hotkey 时热键是
	# 【单键直接触发】—— 游戏中按一下 X 就跳出选单, 完全没法玩。
	echo "警告: 找不到热键键(hotkeyenable 与 select 都没有), 热键整批跳过"
fi

echo "写入 ${OUT} (udev 名; 编号照抄 es_input, 布局=$([ "${XBOX}" = 1 ] && echo Xbox式 || echo 任天堂式))"
