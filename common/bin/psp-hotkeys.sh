#!/bin/sh
# 每次启动 PPSSPP 前重写和弦(组合键), 热键从键位精灵透传。
# 移植自 EmuELEC 侧的 ppsspp.sh(override), 逻辑一致。
#
# ★为什么必须每次启动都写、不能只靠 controls.ini 模板★
#   PPSSPP 在【乾净退出】时会用记忆体里的映射覆写 controls.ini, 而它不保留
#   Exit App / Save State / Load State 的和弦值, 会还原成自己的预设。
#   ⚠️ 早期误判过「模板复制一次就永久有效」: 那次是用 SELECT+START 退出(硬杀行程),
#      PPSSPP 根本没机会写档, 所以看起来没被动。
#
# ★热键要透传, 得先把「实体按键编号」翻成「SDL 语意码」★
#   PPSSPP 吃的是 device-10 的 SDL 语意码(10-196=BACK、10-189=a ...),
#   而 es_input.cfg 记的是实体按键编号(b7)。中间那一步要查 gamecontrollerdb:
#       hotkeyenable=b7 -> db 里哪一笔是 :b7 -> back -> 10-196
#   ★不能写死 10-196★ —— 那只是「多数手柄的热键碰巧是 SELECT」。
#   EmuELEC 侧踩过: 旧写法直接 `6|8) 10-196 ;; 7|9) 10-197`, 隐含假设
#   「实体 6=SELECT」; 使用者把热键设在实体 7 时产出 `Exit App = 10-197:10-197`
#   —— 修饰键与第二颗同码, 和弦按不出来。★之所以一直没被发现★: 保底值刚好也是
#   10-196, 输出与「透传成功」逐字节相同 —— 别拿产出的值当透传生效的证据, 要看 log。
#
# 用法: psp-hotkeys.sh [controls.ini] [es_input.cfg] [gamecontrollerdb]
set -u

CONTROLS_INI="${1:-/storage/.config/ppsspp/PSP/SYSTEM/controls.ini}"
ES_INPUT="${2:-/storage/.config/emulationstation/es_input.cfg}"
GCDB="${3:-${SDL_GAMECONTROLLERCONFIG_FILE:-/storage/.config/es4all/gamecontrollerdb.txt}}"

[ -f "${CONTROLS_INI}" ] || exit 0

HOTKEY="10-196"        # 落不到时的保底 = SELECT

# ---- 选单键 = 【印刷 X】那一颗 ---------------------------------------------
# ★与 RA / flycast 对齐: 三个模拟器都是「热键 + 印着 X 的那颗」开选单★
#   ⚠️ 这一点【刻意与 EmuELEC 现况不同】: E 在 2026-08-02 改成一律按位置(西)。
#   实机 2026-08-04 试出来的问题: 这支手柄是任天堂式印刷(X 在北、Y 在西),
#   按位置的话选单键落在【印着 Y】那颗 —— 而同一台机器上 RA 与 DC 都是印刷 X,
#   使用者在三个模拟器之间换来换去, 手指记的是「按 X」, 不是「按西边那颗」。
#   面键在游戏内必须屈就位置(那是游戏的语意), 但组合键没有这个包袱。
#   → E 那边建议一并改回印刷, 免得三边又分岔(待办)。
#
# 10-188~191 是 SDL 语意键(Y/A/B/X = 北/南/东/西), 位置固定;
# 「印着 X 的是哪一颗」只有 ES 知道 —— 布局侦测写进 es_settings.cfg 的 InvertButtons:
#   false = Xbox 式印刷(A 在南) -> 印刷 X 在西 = SDL X = 10-191
#   true  = 任天堂式印刷(A 在东) -> 印刷 X 在北 = SDL Y = 10-188
MENU_KEY="10-191"
if grep -q '"InvertButtons" value="true"' \
   "$(dirname "${ES_INPUT}")/es_settings.cfg" 2>/dev/null; then
	MENU_KEY="10-188"
fi

# ---- 从 es_input.cfg 取实体按键编号 ---------------------------------------
# ★只认 type="button"★: L2/R2 与摇杆在 ES 里记成 type="axis", 拿轴当和弦的修饰键
#   做不出来, 回传空值让呼叫端落回保底。(精灵那边已加说明, 建议热键选 SELECT。)
# ★按 GUID 查、不按名字★: 同一支手柄有三个名字(udev / SDL / db 映射名),
#   按名字必然静默落空。执行期 GUID 带 SDL 2.26+ 的 CRC-16, 故两种都试。
# ★GUID 不能从 es_input.cfg 抓第一笔★(2026-08-04 踩过)
#   那个档是【所有手柄的总表】(ROCKNIX 出厂就带六十几笔), 第一笔是 InputPlumber,
#   拿它的 hotkeyenable=8 去查, 结果既不报错也不是这支手柄的值 —— 完全静默的错。
#   EmuELEC 侧是用 gamepad_info 取执行期 GUID, ROCKNIX 没有那支工具。
#   改用我们自己产的那份 SDL 对照(es-sdl-gcdb.sh)的第一栏: 它就是键位精灵刚设定
#   的那支手柄, 与下面查语意名用的是同一行, 两边天生一致。
GUID="$(cut -d, -f1 "${GCDB}" 2>/dev/null | head -1)"
# 没有那份档(没跑过精灵)才退回 es_temporaryinput.cfg —— 那是 ES 存的「刚设定的那一支」。
[ -n "${GUID}" ] || GUID="$(sed -n 's/.*deviceGUID="\([0-9a-fA-F]*\)".*/\1/p' \
	"$(dirname "${ES_INPUT}")/es_temporaryinput.cfg" 2>/dev/null | head -1)"
GUID_NOCRC=""
[ ${#GUID} -ge 8 ] && GUID_NOCRC="$(echo "${GUID}" | cut -c1-4)0000$(echo "${GUID}" | cut -c9-)"

es_input_btn() {
	[ -f "${ES_INPUT}" ] && [ -n "${GUID}" ] || return 0
	awk -v g1="deviceGUID=\"${GUID}\"" -v g2="deviceGUID=\"${GUID_NOCRC}\"" \
	    -v nm="name=\"${1}\"" '
		index($0, g1) || index($0, g2) { inblock = 1 }
		inblock && index($0, nm) && /type="button"/ {
			if (match($0, /id="[0-9]+"/)) { print substr($0, RSTART+4, RLENGTH-5); exit }
		}
		inblock && /<\/inputConfig>/ { inblock = 0 }
	' "${ES_INPUT}"
}

GC_LINE="$(grep -m1 -E "^(${GUID}|${GUID_NOCRC})," "${GCDB}" 2>/dev/null)"
# 实体按键编号 -> SDL 语意名。查 db 里 `名称:bN` 哪一笔的 N 等於给定编号。
gc_semantic_of() {
	echo "${GC_LINE}" | tr ',' '\n' | awk -F: -v n="b${1}" '$2 == n { print $1; exit }'
}

HK_ID="$(es_input_btn hotkeyenable)"
# 语意名 -> device-10 的 NKCODE。位置语意固定(a=南 b=东 x=西 y=北), 与 PSP 的
# ✕○□△ 位置对齐一致, 故这张表与手柄的实体排列无关, 永远成立。
case "$(gc_semantic_of "${HK_ID}")" in
	a)             HOTKEY="10-189" ;;   # 南 ✕
	b)             HOTKEY="10-190" ;;   # 东 ○
	x)             HOTKEY="10-191" ;;   # 西 □
	y)             HOTKEY="10-188" ;;   # 北 △
	back)          HOTKEY="10-196" ;;   # SELECT
	start)         HOTKEY="10-197" ;;   # START
	leftshoulder)  HOTKEY="10-193" ;;   # L1
	rightshoulder) HOTKEY="10-192" ;;   # R1
	leftstick)     HOTKEY="10-106" ;;   # L3
	rightstick)    HOTKEY="10-107" ;;   # R3
	*)             ;;                   # 认不得(含空值 / guide 无对应码)就保底
esac
if [ -n "${HK_ID}" ]; then
	echo "PSP HOTKEY from ES: button ${HK_ID} -> ${HOTKEY}"
else
	echo "PSP HOTKEY not usable from ES (missing, or bound to an analog axis such as L2/R2) -> fallback ${HOTKEY}"
fi

# ---- SELECT / START ---------------------------------------------------------
# ⚠️ 这里与热键是两件事, 别混: 上面处理「热键那颗的语意是什么」,
#    这里处理「使用者对 SELECT/START 的指定与 db 是否相反」。
# 「哪一颗算 SELECT」本来就没有客观答案(任天堂式手柄上是「−」与「+」),
# 只有使用者在精灵里的选择算数。相反就把两行的语意码对调, 结果等价。
# ★R 版正常情况下【不会触发】★: 这里的 db 就是我们从 es_input 产的(es-sdl-gcdb.sh),
#   back/start 本来就照使用者的选择排。留着是为了 db 换成社群那份时仍然正确。
ES_SEL="$(es_input_btn select)"; ES_STA="$(es_input_btn start)"
GC_BACK="$(echo "${GC_LINE}"  | grep -oE 'back:b[0-9]+'  | grep -oE '[0-9]+$')"
GC_START="$(echo "${GC_LINE}" | grep -oE 'start:b[0-9]+' | grep -oE '[0-9]+$')"
if [ -n "${ES_SEL}" ] && [ -n "${ES_STA}" ] && [ -n "${GC_BACK}" ] && [ -n "${GC_START}" ] &&
   [ "${ES_SEL}" = "${GC_START}" ] && [ "${ES_STA}" = "${GC_BACK}" ]; then
	echo "PSP: ES 的 SELECT/START 与 gamecontrollerdb 相反(ES select=b${ES_SEL} start=b${ES_STA}), 对调 controls.ini"
	sed -i "/^Select = /s/10-19[67]/10-197/" "${CONTROLS_INI}"
	sed -i "/^Start = /s/10-19[67]/10-196/"  "${CONTROLS_INI}"
fi

# ---- 四组和弦 ---------------------------------------------------------------
set_chord() {   # $1=键名 $2=值; 键名含空格, sed 的位址要完整比对到 " = "
	if grep -q "^${1} = " "${CONTROLS_INI}"; then
		sed -i "/^${1} = /c\\${1} = ${2}" "${CONTROLS_INI}"
	else
		echo "${1} = ${2}" >> "${CONTROLS_INI}"
	fi
}
set_chord "Exit App"   "${HOTKEY}:10-197"   # 热键+START 退出
set_chord "Save State" "${HOTKEY}:10-192"   # 热键+R1    存档
set_chord "Load State" "${HOTKEY}:10-193"   # 热键+L1    读档

# ★Pause 只换和弦那一段, 不整行覆盖★
#   模板可能长成 `Pause = 1-111,10-196:10-191` —— 前面那段是键盘绑定,
#   整行盖掉会把它弄丢。
if grep -q '^Pause = ' "${CONTROLS_INI}"; then
	if grep -qE '^Pause = .*10-[0-9]+:10-[0-9]+' "${CONTROLS_INI}"; then
		sed -i "/^Pause = /s|10-[0-9]*:10-[0-9]*|${HOTKEY}:${MENU_KEY}|" "${CONTROLS_INI}"
	else
		sed -i "/^Pause = /s|\$|,${HOTKEY}:${MENU_KEY}|" "${CONTROLS_INI}"
	fi
else
	echo "Pause = ${HOTKEY}:${MENU_KEY}" >> "${CONTROLS_INI}"
fi

echo "PSP HOTKEYS set: hotkey=${HOTKEY}, menu(hotkey+印刷X) = ${HOTKEY}:${MENU_KEY}"
