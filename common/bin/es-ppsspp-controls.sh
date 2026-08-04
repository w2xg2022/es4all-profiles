#!/bin/sh
# 把键位精灵的结果翻译成 PPSSPP(独立模拟器)的 controls.ini。
#
# ★为什么不能继续用固件里那份写死的 controls.ini★
#   原本 controls.ini 是固件里一份写死的档, 每次开机由膠水复制上来。那份的
#   Select=10-196 / Start=10-197(=按钮 8 / 9)是照【某一颗手柄】量出来的,
#   换一颗就整个错位 —— 实机这颗精灵记的是 select=7 / start=6, 於是 SELECT 与 START
#   在 PSP 里完全没反应, 而且不会有任何提示。
#   与 RA 那条链同一个道理: ★键位的唯一真相是使用者在精灵里按的那一颗★。
#
# ★PPSSPP 的编码规则★(SDL 后端: NativeKey(deviceId, keyCode))
#   deviceId 10 = 手柄; 按钮 b 的 keyCode = NKCODE_BUTTON_1 + b = 188 + b
#   摇杆轴 a 的正方向 = 4000 + a*2, 负方向 = 4000 + a*2 + 1
#   方向键走 NKCODE_DPAD_*(19..22), 与手柄的 hat 无关, 所以直接写死。
#   组合键用 ':' 连接(先热键再触发键)。
#
# ★面键按【位置】对齐, 不按印刷字母★
#   PSP 的 ✕ 在南、○ 在东、□ 在西、△ 在北 —— 这是印在主机上的物理位置,
#   玩家看画面提示「按 ✕」时找的是【手柄下方那颗】, 不是印着某个字母那颗。
#   所以先把印刷字母换算成方位(与 RA 那支的 face_key 同一套), 再对到 ✕○□△。
#
# 用法: es-ppsspp-controls.sh <es_input.cfg> <controls.ini 路径> [es_settings.cfg]
set -u

ES_INPUT="${1:?需要 es_input 档}"
OUT="${2:?需要输出档}"
ES_SETTINGS="${3:-}"

[ -f "${ES_INPUT}" ] || exit 0
mkdir -p "$(dirname "${OUT}")" || exit 0

sdlid()  { sed -n "s/.*name=\"$1\"[^>]*id=\"\([0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdlval() { sed -n "s/.*name=\"$1\".*value=\"\(-\?[0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }

btn() {   # 印刷字母/语意名 -> PPSSPP 按钮码
	_i="$(sdlid "$1")"
	[ -n "${_i}" ] || return 1
	echo "10-$((188 + _i))"
}

axis() {  # $1=es_input 名 -> PPSSPP 轴码
	_i="$(sdlid "$1")"; [ -n "${_i}" ] || return 1
	case "$(sdlval "$1")" in
		-*) echo "10-$((4000 + _i * 2 + 1))" ;;
		*)  echo "10-$((4000 + _i * 2))" ;;
	esac
}

# ---- 印刷布局 -> 方位 ------------------------------------------------------
# Xbox 式印刷(InvertButtons=false, 印刷 A 在南): 南=A 东=B 西=X 北=Y
# 任天堂式印刷(true, 印刷 A 在东):               南=B 东=A 西=Y 北=X
if [ -n "${ES_SETTINGS}" ] && [ -f "${ES_SETTINGS}" ] && \
   grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}"; then
	L_SOUTH=b; L_EAST=a; L_WEST=y; L_NORTH=x
else
	L_SOUTH=a; L_EAST=b; L_WEST=x; L_NORTH=y
fi

# ---- 热键 ------------------------------------------------------------------
# 与 RA 那支同一套判据: 精灵设了 hotkeyenable 就用它, 没设拿 SELECT 顶上。
HK="$(sdlid hotkeyenable)"
[ -n "${HK}" ] || HK="$(sdlid select)"
HK_CODE=""
[ -n "${HK}" ] && HK_CODE="10-$((188 + HK))"

# 退出 = SELECT/START 之中【不是热键】的那一颗, 组合才按得出来。
EXIT_ID="$(sdlid start)"
[ "${HK}" = "${EXIT_ID}" ] && EXIT_ID="$(sdlid select)"

TMP="${OUT}.es4all.tmp"
{
	echo '[ControlMapping]'
	# 方向键: PPSSPP 用 DPAD keycode, 与手柄回报 hat 或按钮无关。
	echo 'Up = 10-19'
	echo 'Down = 10-20'
	echo 'Left = 10-21'
	echo 'Right = 10-22'

	echo "Cross = $(btn "${L_SOUTH}")"
	echo "Circle = $(btn "${L_EAST}")"
	echo "Square = $(btn "${L_WEST}")"
	echo "Triangle = $(btn "${L_NORTH}")"

	echo "Start = $(btn start)"
	echo "Select = $(btn select)"
	echo "L = $(btn leftshoulder)"
	echo "R = $(btn rightshoulder)"

	for p in "An.Up:leftanalogup" "An.Down:leftanalogdown" \
	         "An.Left:leftanalogleft" "An.Right:leftanalogright"; do
		_k="${p%%:*}"; _n="${p#*:}"
		_c="$(axis "${_n}")" && echo "${_k} = ${_c}"
	done

	# 组合键: 没有热键键就一个都不写 —— 否则会变成单键直接触发(游戏中一按就跳出)。
	if [ -n "${HK_CODE}" ]; then
		echo "Pause = ${HK_CODE}:$(btn "${L_NORTH}")"
		echo "Save State = ${HK_CODE}:$(btn rightshoulder)"
		echo "Load State = ${HK_CODE}:$(btn leftshoulder)"
		[ -n "${EXIT_ID}" ] && echo "Exit App = ${HK_CODE}:10-$((188 + EXIT_ID))"
	fi
} > "${TMP}"

# 有空值(某个键精灵没设)就整份放弃, 别写出半套 —— 半套比旧的那份更难查。
if grep -q '= *$' "${TMP}"; then
	echo "★controls.ini 有键没对到值, 整份放弃★"
	rm -f "${TMP}"
	exit 1
fi
mv -f "${TMP}" "${OUT}"
echo "写入 ${OUT} (PPSSPP; 面键按位置, 热键=${HK_CODE:-无})"
