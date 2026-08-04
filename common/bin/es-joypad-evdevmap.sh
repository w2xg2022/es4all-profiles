#!/bin/sh
# 印出某个 evdev 装置的「udev 编号表」—— RA 的 udev joypad driver 就是照能力位里
# BTN_*/ABS_* 的出现顺序编号的, 所以照着数就能重现它的编号, 不必猜也不必翻译 SDL id。
#
# 用法: evdevmap.sh <vendor4hex> <product4hex>
# 输出: NAME=<evdev 名> 之后每行一个 "BTN_SOUTH=0" / "ABS_X=0" 这样的对照。
set -u
V="$1"; P="$2"

DEV=""
for d in /sys/class/input/event*/device; do
	[ "$(cat "$d/id/vendor" 2>/dev/null)" = "$V" ] || continue
	[ "$(cat "$d/id/product" 2>/dev/null)" = "$P" ] || continue
	DEV="$d"; break
done
[ -n "${DEV}" ] || exit 1

echo "NAME=$(cat "${DEV}/name" 2>/dev/null)"

emit_table() {   # $1=capabilities 档  $2=名称前缀表(awk 里定义)
	awk -v bits="$(cat "${DEV}/capabilities/$1" 2>/dev/null)" -v kind="$1" '
	BEGIN {
		nw = split(bits, w, " ")
		# capabilities 是一串 64 位元的十六进位字组, 最右边那个是最低位。
		for (wi = nw; wi >= 1; wi--) {
			hex = tolower(w[wi]); L = length(hex)
			for (c = L; c >= 1; c--) {
				v = index("0123456789abcdef", substr(hex, c, 1)) - 1
				for (b = 0; b < 4; b++)
					if (int(v / (2 ^ b)) % 2 == 1)
						code[(nw - wi) * 64 + (L - c) * 4 + b] = 1
			}
		}

		if (kind == "key") {
			N["BTN_SOUTH"]=304; N["BTN_EAST"]=305; N["BTN_C"]=306; N["BTN_NORTH"]=307
			N["BTN_WEST"]=308;  N["BTN_Z"]=309;    N["BTN_TL"]=310; N["BTN_TR"]=311
			N["BTN_TL2"]=312;   N["BTN_TR2"]=313;  N["BTN_SELECT"]=314; N["BTN_START"]=315
			N["BTN_MODE"]=316;  N["BTN_THUMBL"]=317; N["BTN_THUMBR"]=318
			MAXC = 1023
		} else {
			N["ABS_X"]=0; N["ABS_Y"]=1; N["ABS_Z"]=2
			N["ABS_RX"]=3; N["ABS_RY"]=4; N["ABS_RZ"]=5
			N["ABS_HAT0X"]=16; N["ABS_HAT0Y"]=17
			MAXC = 63
		}

		# 依 code 由小到大给序号 —— 与 driver 的走访顺序相同
		i = 0
		for (c2 = 0; c2 <= MAXC; c2++)
			if (c2 in code) { seq[c2] = i; i++ }

		for (k in N)
			if (N[k] in seq) print k "=" seq[N[k]]
	}'
}

emit_table key
emit_table abs
