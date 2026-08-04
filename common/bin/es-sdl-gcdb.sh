#!/bin/sh
# 从键位精灵的结果产生一份【SDL gamecontrollerdb 对照行】。
#
# ★为什么需要它: 有一类模拟器不吃我们写的键位档, 只吃 SDL 的语意★
#   PPSSPP(以及所有走 SDL GameController API 的程式)拿到的不是「按钮 6」这种原始编号,
#   而是 BACK / START / A / B 这种【语意名】—— 哪一颗实体键算 BACK, 是 SDL 查
#   gamecontrollerdb 决定的, 与 ES、与使用者在精灵里按了什么完全无关。
#
#   ⚠️ 所以「改 controls.ini 里的数字」是改不动 SELECT/START 的 —— 那份档记的是
#      语意码(10-196 = NKCODE_BUTTON_9 = SDL BACK), 换个数字只是换成别的语意,
#      不会换成别颗实体键。★我一度按原始按钮索引重算那份档, 那是错的★:
#      固件原本的 Cross=189/Circle=190/Square=191/Triangle=188 换算成语意正好是
#      A(南)/B(东)/X(西)/Y(北), 本来就对; 面键在这条路上天生按位置, 也不该由我们决定。
#
#   实机(MD1000/ROCKNIX 2026-08-04): SDL 内建的 xpad 对照是 back:b6 start:b7,
#   而精灵记的是 select=7 start=6 —— 刚好相反, 於是 PSP 里两颗键的行为是反的。
#
#   真正的槓桿只有一个: 覆盖 SDL 的对照表。SDL 认 SDL_GAMECONTROLLERCONFIG_FILE,
#   优先於内建表, 所以我们自己产一份、只写这一支手柄那一行。
#
# ★GUID 写 ES 档里那个(不含 CRC)就行★
#   执行期 SDL 2.26+ 会在 GUID 第 5~8 字元塞 CRC-16, 但比对时对「没有 CRC 的对照行」
#   会略过那段, 两边仍然对得上。
#
# 用法: es-sdl-gcdb.sh <es_input.cfg> <输出档>
set -u

ES_INPUT="${1:?需要 es_input 档}"
OUT="${2:?需要输出档}"

[ -f "${ES_INPUT}" ] || exit 0
mkdir -p "$(dirname "${OUT}")" || exit 0

GUID="$(sed -n 's/.*deviceGUID="\([0-9a-fA-F]*\)".*/\1/p' "${ES_INPUT}" | head -1)"
NAME="$(sed -n 's/.*deviceName="\([^"]*\)".*/\1/p' "${ES_INPUT}" | head -1)"
[ -n "${GUID}" ] && [ -n "${NAME}" ] || exit 0
# 抹掉 CRC 段, 让这一行对「有 CRC」与「没 CRC」两种执行期 GUID 都成立。
[ ${#GUID} -ge 8 ] && GUID="$(echo "${GUID}" | cut -c1-4)0000$(echo "${GUID}" | cut -c9-)"

sdlid()  { sed -n "s/.*name=\"$1\"[^>]*id=\"\([0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdltyp() { sed -n "s/.*name=\"$1\"[^>]*type=\"\([a-z]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }
sdlval() { sed -n "s/.*name=\"$1\".*value=\"\(-\?[0-9]*\)\".*/\1/p" "${ES_INPUT}" | head -1; }

M=""
add() { [ -n "$2" ] && M="${M}$1:$2,"; }

btn()  { _i="$(sdlid "$1")"; [ -n "${_i}" ] && echo "b${_i}"; }
axis() { _i="$(sdlid "$1")"; [ -n "${_i}" ] && echo "a${_i}"; }
# 扳机在 ES 里是轴, SDL 写成 +aN(单向)。
trig() { _i="$(sdlid "$1")"; [ -n "${_i}" ] && echo "+a${_i}"; }
hat()  { # SDL hat 值: 1=上 2=右 4=下 8=左
	[ "$(sdltyp "$1")" = "hat" ] || { btn "$1"; return; }
	_h="$(sdlid "$1")"; _v="$(sdlval "$1")"
	[ -n "${_h}" ] && [ -n "${_v}" ] && echo "h${_h}.${_v}"
}

# ★面键照【印刷字母】写★, 不做位置换算 —— SDL 的 a/b/x/y 定义就是位置(a=南 b=东
# x=西 y=北), 但那要对照行【真的按位置写】才成立。这里的来源是精灵:
# 使用者按印刷 A 时按的是哪一颗, 位置资讯由 ES 的 InvertButtons 决定 ——
# 所以要先换算成位置再写, 否则 PPSSPP 的 ✕ 会跑到错的方位。
if grep -q '"InvertButtons" value="true"' \
   "$(dirname "${ES_INPUT}")/es_settings.cfg" 2>/dev/null; then
	S=b; E=a; W=y; N=x     # 任天堂式印刷: 印刷 A 在东
else
	S=a; E=b; W=x; N=y     # Xbox 式印刷: 印刷 A 在南
fi
add a "$(btn ${S})"; add b "$(btn ${E})"; add x "$(btn ${W})"; add y "$(btn ${N})"

# ★这两颗才是本脚本存在的理由★: 哪一颗是 SELECT / START 没有客观答案
# (任天堂式手柄上是「−」与「+」), 只有使用者在精灵里的选择算数。
add back  "$(btn select)"
add start "$(btn start)"

add leftshoulder  "$(btn leftshoulder)"
add rightshoulder "$(btn rightshoulder)"
add leftstick     "$(btn leftthumb)"
add rightstick    "$(btn rightthumb)"
# ★guide 只在它不与 back/start 撞号时才写★
#   热键多半就设成 SELECT, 直接写下去会变成同一颗实体键掛两个语意名(back:b7,guide:b7),
#   SDL 的行为就不确定了 —— 而且这类手柄本来就没有实体 Guide 键, 少一个反而干净。
_hk="$(btn hotkeyenable)"
if [ -n "${_hk}" ] && [ "${_hk}" != "$(btn select)" ] && [ "${_hk}" != "$(btn start)" ]; then
	add guide "${_hk}"
fi
add dpup    "$(hat up)";   add dpdown  "$(hat down)"
add dpleft  "$(hat left)"; add dpright "$(hat right)"
add leftx  "$(axis leftanalogright)";  add lefty  "$(axis leftanalogdown)"
add rightx "$(axis rightanalogright)"; add righty "$(axis rightanalogdown)"
add lefttrigger  "$(trig lefttrigger)"
add righttrigger "$(trig righttrigger)"

# 缺 back 或 start 就没有意义了 —— 整份放弃, 让 SDL 用它的内建表。
case "${M}" in
	*back:*) : ;;
	*) echo "★精灵没记到 select, SDL 对照表不产★"; exit 1 ;;
esac

LINE="$(printf '%s,%s,%splatform:Linux,' "${GUID}" "${NAME}" "${M}")"
printf '%s\n' "${LINE}" > "${OUT}"
echo "写入 ${OUT} (SDL 对照; back=$(btn select) start=$(btn start))"

# ---------------------------------------------------------------------------
# ★光靠环境变数不够 —— PPSSPP 会自己【再载入一次】db, 把我们的盖掉★
# ---------------------------------------------------------------------------
# 2026-08-04 实机: start_ppsspp.sh 已经 export 了 SDL_GAMECONTROLLERCONFIG_FILE,
# SDL 也支援这个 hint(2.32.10), 但热键仍旧落在错的实体键上。真因是 ppsspp 二进位里
# 写死了一条路径, 启动时自己呼叫 AddMappingsFromFile 再载入一次 ——
#     /storage/.config/SDL-GameControllerDB/gamecontrollerdb.txt
# 而 SDL 是【后载入的同 GUID 覆盖先前的】, 所以它稳赢过 hint。
# (strings /usr/bin/ppsspp 直接看得到那条路径与 "gamecontrollerdb.txt missing?"。)
#
# → 把同一行也追加到那个档。出厂它是指向唯读 /usr/config 的符号连结,
#   所以要先「实体化」成一份真档再改; 不动原始那份, 只是让 /storage 这边可写。
# 追加在【最后】: 同 GUID 后来居上, 出厂那笔自然失效, 不必去删它。
# 这个档 gptokeyb 也在用(它的 control.ini 指向同一条路径), 两边同一份真相反而更好。
SYS_DB=/storage/.config/SDL-GameControllerDB/gamecontrollerdb.txt
if [ -e "${SYS_DB}" ]; then
	if [ -L "${SYS_DB}" ]; then
		_src="$(readlink -f "${SYS_DB}")"
		rm -f "${SYS_DB}" && cp -f "${_src}" "${SYS_DB}" || exit 0
		echo "已把 ${SYS_DB} 从符号连结实体化(原本指向唯读固件)"
	fi
	# 幂等: 先删掉自己上次追加的那两行(标记 + 对照行), 别误删出厂的同 GUID 行。
	# ★标记必须【另起一行】★: SDL 的解析器只认「整行以 # 开头」的注解,
	#   把 `# es4all` 接在对照行尾巴会被当成一个多出来的栏位, 行为不可预期。
	sed -i '/^# es4all-mapping$/,+1d' "${SYS_DB}"
	printf '# es4all-mapping\n%s\n' "${LINE}" >> "${SYS_DB}"
	echo "已追加同一行到 ${SYS_DB}(PPSSPP 自己会载入这个档)"
fi
