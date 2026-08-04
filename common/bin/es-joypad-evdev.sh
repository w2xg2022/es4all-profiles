#!/bin/sh
# 依【核心 evdev 的编号】产生一份 RetroArch joypad autoconfig。
#
# ★为什么需要这一支(2026-08-04 ROCKNIX 实机)★
#   同一支手柄有三个名字, 也有【两套按钮编号】:
#       SDL  : a=1 b=0 x=3 y=2 select=7 start=6   <- es_input.cfg 记的
#       udev : a=0 b=1 x=2 y=3 select=6 start=7   <- 核心 evdev 顺序
#   每一组都是对调的。而 RetroArch 与 ROCKNIX 的 setsettings.sh 用的都是 udev 那套,
#   照抄 SDL 编号的档案会让热键落在错的实体键上(热键变 START、选单变 Y)。
#
#   本脚本不做「SDL -> udev」的翻译(两者没有固定公式), 而是【直接从 evdev 算】:
#   RA 的 udev driver 就是照能力位里 BTN_*/ABS_* 的出现顺序编号的, 照着数就能重现。
#   实机验证: 算出的 SOUTH=0 EAST=1 NORTH=2 WEST=3 TL=4 TR=5 SELECT=6 START=7
#   THUMBL=9 THUMBR=10, 与 ROCKNIX 出厂那份 joypad 档逐格相同。
#
# ★键位精灵的结果是黄金标准★
#   哪一颗当热键、印刷 X 在哪, 都只有 ES 知道, 所以这两项仍从 es_input.cfg /
#   es_settings.cfg 取, 再对应到实体按键:
#     hotkeyenable 记的是 SDL id -> 反查同一份 es_input 里哪个语意名用同一个 id
#                                -> 那个名字对应的 BTN_* -> udev 编号
#     印刷 A/B/X/Y 的【位置】由 InvertButtons(布局侦测的结果)决定
#
# 用法: es-joypad-evdev.sh <es_temporaryinput.cfg> <输出目录> [es_settings.cfg]
set -u

ES_INPUT="${1:?需要 es_input 档}"
OUT_DIR="${2:?需要输出目录}"
ES_SETTINGS="${3:-}"

[ -f "${ES_INPUT}" ] || exit 0
mkdir -p "${OUT_DIR}" || exit 0

BIN_DIR="$(dirname "$0")"

# ---- 取这支手柄的 GUID -> VID/PID ------------------------------------------
GUID="$(sed -n 's/.*deviceGUID="\([0-9a-fA-F]*\)".*/\1/p' "${ES_INPUT}" | head -1)"
[ -n "${GUID}" ] || exit 0
hex2() { printf '%d' "0x$1"; }
VID_LO=$(hex2 "$(echo "${GUID}" | cut -c9-10)");  VID_HI=$(hex2 "$(echo "${GUID}" | cut -c11-12)")
PID_LO=$(hex2 "$(echo "${GUID}" | cut -c17-18)"); PID_HI=$(hex2 "$(echo "${GUID}" | cut -c19-20)")
VID=$(printf '%04x' $((VID_HI * 256 + VID_LO)))
PID=$(printf '%04x' $((PID_HI * 256 + PID_LO)))

MAP="$(sh "${BIN_DIR}/es-joypad-evdevmap.sh" "${VID}" "${PID}" 2>/dev/null)" || exit 0
[ -n "${MAP}" ] || exit 0

get() { echo "${MAP}" | sed -n "s/^$1=//p" | head -1; }
DEV_NAME="$(get NAME)"
[ -n "${DEV_NAME}" ] || exit 0

# ---- 布局: 印刷 A 在南(Xbox 式) 还是在东(任天堂式) --------------------------
INVERT=0
[ -n "${ES_SETTINGS}" ] && [ -f "${ES_SETTINGS}" ] && \
	grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" && INVERT=1

if [ "${INVERT}" = "1" ]; then          # 任天堂式印刷: A 东 / B 南 / X 北 / Y 西
	P_A=BTN_EAST;  P_B=BTN_SOUTH; P_X=BTN_NORTH; P_Y=BTN_WEST
else                                     # Xbox 式印刷: A 南 / B 东 / X 西 / Y 北
	P_A=BTN_SOUTH; P_B=BTN_EAST;  P_X=BTN_WEST;  P_Y=BTN_NORTH
fi

# ---- es_input 里各语意名的 SDL id(拿来反查热键键是哪一颗) -------------------
sdlid() { sed -n "s/.*name=\"$1\"[^>]*id=\"\([0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
HK_SDL="$(sdlid hotkeyenable)"

# hotkeyenable 记的是 SDL id, 反查哪个语意名用同一个 id, 就知道使用者按的是哪颗实体键。
HK_BTN=""
for nm in select start leftshoulder rightshoulder a b x y leftthumb rightthumb; do
	[ -n "${HK_SDL}" ] || break
	[ "$(sdlid "${nm}")" = "${HK_SDL}" ] || continue
	case "${nm}" in
		select) HK_BTN=BTN_SELECT ;; start) HK_BTN=BTN_START ;;
		leftshoulder) HK_BTN=BTN_TL ;; rightshoulder) HK_BTN=BTN_TR ;;
		leftthumb) HK_BTN=BTN_THUMBL ;; rightthumb) HK_BTN=BTN_THUMBR ;;
		a) HK_BTN="${P_A}" ;; b) HK_BTN="${P_B}" ;; x) HK_BTN="${P_X}" ;; y) HK_BTN="${P_Y}" ;;
	esac
	break
done
# 没设 hotkeyenable 就拿 SELECT 顶上(与 EmuELEC 的 configscripts 同一套做法)
[ -n "${HK_BTN}" ] || HK_BTN=BTN_SELECT

safe=$(echo "${DEV_NAME}" | sed 's/[^A-Za-z0-9 _-]/_/g; s/^ *//; s/ *$//')
OUT="${OUT_DIR}/${safe}.cfg"

put() { [ -n "$2" ] && echo "$1 = \"$2\"" >> "${OUT}"; }

: > "${OUT}"
echo "input_driver = \"udev\"" >> "${OUT}"
echo "input_device = \"${DEV_NAME}\"" >> "${OUT}"
put input_vendor_id  "$((0x${VID}))"
put input_product_id "$((0x${PID}))"

# 面键: 按【物理位置】固定对齐 RetroPad 的几何(A=东 B=南 X=北 Y=西), 与印刷无关。
put input_a_btn "$(get BTN_EAST)"
put input_b_btn "$(get BTN_SOUTH)"
put input_x_btn "$(get BTN_NORTH)"
put input_y_btn "$(get BTN_WEST)"

put input_select_btn "$(get BTN_SELECT)"
put input_start_btn  "$(get BTN_START)"
put input_l_btn      "$(get BTN_TL)"
put input_r_btn      "$(get BTN_TR)"
put input_l3_btn     "$(get BTN_THUMBL)"
put input_r3_btn     "$(get BTN_THUMBR)"

# 方向键: xpad 类装置的十字键是 hat(ABS_HAT0X/Y), RA 用 h0up 这种写法。
if [ -n "$(get ABS_HAT0X)" ]; then
	echo 'input_up_btn = "h0up"'       >> "${OUT}"
	echo 'input_down_btn = "h0down"'   >> "${OUT}"
	echo 'input_left_btn = "h0left"'   >> "${OUT}"
	echo 'input_right_btn = "h0right"' >> "${OUT}"
fi

# 摇杆与扳机: 轴编号同样照 evdev 顺序算。
LX="$(get ABS_X)"; LY="$(get ABS_Y)"; RX="$(get ABS_RX)"; RY="$(get ABS_RY)"
put input_l_x_plus_axis  "${LX:+ +${LX}}"; put input_l_x_minus_axis "${LX:+ -${LX}}"
put input_l_y_plus_axis  "${LY:+ +${LY}}"; put input_l_y_minus_axis "${LY:+ -${LY}}"
put input_r_x_plus_axis  "${RX:+ +${RX}}"; put input_r_x_minus_axis "${RX:+ -${RX}}"
put input_r_y_plus_axis  "${RY:+ +${RY}}"; put input_r_y_minus_axis "${RY:+ -${RY}}"
put input_l2_axis "$(get ABS_Z  | sed 's/^/+/')"
put input_r2_axis "$(get ABS_RZ | sed 's/^/+/')"
sed -i 's/= " /= "/' "${OUT}"   # 上面 ${LX:+ +..} 会多一个空格, 收掉

# ---- 热键 ------------------------------------------------------------------
# ★以键位精灵的结果为准★: 热键键就是使用者在精灵里按的那一颗实体键。
HK="$(get "${HK_BTN}")"
if [ -n "${HK}" ]; then
	put input_enable_hotkey_btn "${HK}"
	# 绑到【印刷】键: 说明书写的是 SELECT+X, 使用者看的是手柄上的字母。
	put input_menu_toggle_btn "$(get "${P_X}")"
	put input_fps_toggle_btn  "$(get "${P_Y}")"
	put input_save_state_btn  "$(get BTN_TR)"
	put input_load_state_btn  "$(get BTN_TL)"
	# 退出 = SELECT/START 之中【不是热键键】的那一颗, 组合才按得出来。
	if [ "${HK_BTN}" = "BTN_START" ]; then
		put input_exit_emulator_btn "$(get BTN_SELECT)"
	else
		put input_exit_emulator_btn "$(get BTN_START)"
	fi
else
	# ★没有热键键就一个热键都不写★: RA 在没有 input_enable_hotkey 时热键是
	# 【单键直接触发】—— 游戏中按一下 X 就跳出选单, 完全没法玩。
	echo "警告: 找不到热键键, 热键整批跳过"
fi

echo "写入 ${OUT} (evdev 编号, 热键依精灵结果: ${HK_BTN})"
