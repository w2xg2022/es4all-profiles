#!/bin/sh
# 把 EmulationStation 的手柄按键映射(es_input.cfg)转换成 RetroArch 的 autoconfig，
# 让键位精灵设定好的手柄直接在 RetroArch / 各游戏核心中可用。
#
# 用法: es-input-to-retroarch.sh [es_input.cfg] [autoconfig 目录]
#
# ★为什么改用 sh + awk 而不是 python★(2026-08-04)
#   原本是 python3 脚本, 但 python3 【不是三个发行版都保证有】—— 少了它, 钩子
#   10-inputconfig.sh 那句 `python3 转换器` 会直接失败, 表现是「键位精灵跑完了,
#   RetroArch 里却完全没生效」, 而且没有任何提示。awk 则是 busybox 都内建的,
#   E/R/A 三边一定跑得起来, 少一个会静默失效的前提。
#   (es_input.cfg 的格式是一行一个 <input .../>, 用 awk 逐行解析绰绰有余,
#    不需要真正的 XML parser。)

set -u

ES_INPUT="${1:-${HOME:-/storage}/.emulationstation/es_input.cfg}"
OUT_DIR="${2:-${HOME:-/storage}/.config/retroarch/autoconfig}"

[ -f "${ES_INPUT}" ] || exit 0
mkdir -p "${OUT_DIR}" || exit 0

awk -v out_dir="${OUT_DIR}" '
# ---- 取属性值: attr($0, "deviceName") ----
function attr(line, key,   s) {
	if (match(line, key "=\"[^\"]*\"")) {
		s = substr(line, RSTART, RLENGTH)
		sub(key "=\"", "", s)
		sub("\"$", "", s)
		return s
	}
	return ""
}

function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }

# SDL GUID 里的 16 位元值是【小端】: 每 2 字元一个位元组, 低位在前。
#   030000005e0400008e02000072050000 -> bus 0003 / vendor 045e / product 028e
function le16(guid, off,   b0, b1) {
	if (length(guid) < off + 3) return 0
	b0 = hexval(substr(guid, off,     1)) * 16 + hexval(substr(guid, off + 1, 1))
	b1 = hexval(substr(guid, off + 2, 1)) * 16 + hexval(substr(guid, off + 3, 1))
	return b1 * 256 + b0
}

function emit(line) { out[++n] = line }

function flush_device(   i, safe, path, name, key) {
	if (dev_name == "") return

	safe = dev_name
	gsub(/[^A-Za-z0-9 _-]/, "_", safe)
	sub(/^ +/, "", safe); sub(/ +$/, "", safe)
	path = out_dir "/" safe ".cfg"

	# 方向键: hat 优先(有 hat 就用 hat), 否则用按钮
	for (key in DPAD) {
		if (key in dpad_hat)      emit(DPAD[key] " = \"" dpad_hat[key] "\"")
		else if (key in dpad_btn) emit(DPAD[key] " = \"" dpad_btn[key] "\"")
	}

	printf "" > path
	for (i = 1; i <= n; i++) print out[i] >> path
	close(path)
	print "写入 " path

	n = 0; dev_name = ""; dev_guid = ""
	split("", dpad_hat); split("", dpad_btn)
}

BEGIN {
	# ES 按键名 -> RetroArch autoconfig 键名(按钮类)
	BTN["a"]="input_a_btn";           BTN["b"]="input_b_btn"
	BTN["x"]="input_x_btn";           BTN["y"]="input_y_btn"
	BTN["start"]="input_start_btn";   BTN["select"]="input_select_btn"
	BTN["leftshoulder"]="input_l_btn";  BTN["rightshoulder"]="input_r_btn"
	BTN["leftthumb"]="input_l3_btn";    BTN["rightthumb"]="input_r3_btn"
	BTN["hotkeyenable"]="input_enable_hotkey_btn"

	# ★摇杆的键名是 l_x / l_y / r_x / r_y，不是 left_x / right_x★
	#   (2026-08-04 实机查证: 写成 left_x_plus RetroArch 【根本没这个键】,
	#    那几行被静默忽略 -> autoconfig 产生成功、档案里也看得到, 摇杆就是不会动。)
	#   查法: 在机器上把 retroarch 的字串捞出来, 找结尾是 _plus / _minus 的那几个,
	#         会看到 l_x_plus / l_y_minus / r_x_* / r_y_*, 而 left_x_plus 一个都没有。
	#   ⚠️ 本档的 awk 程式是用单引号包起来的, 所以【注解里不能出现单引号】——
	#      会把 awk 区块提前收掉, 变成 shell 语法错误(踩过一次)。
	AX["lefttrigger"]="input_l2_axis";  AX["righttrigger"]="input_r2_axis"
	AX["leftanalogleft"]="input_l_x_minus_axis";   AX["leftanalogright"]="input_l_x_plus_axis"
	AX["leftanalogup"]="input_l_y_minus_axis";     AX["leftanalogdown"]="input_l_y_plus_axis"
	AX["rightanalogleft"]="input_r_x_minus_axis";  AX["rightanalogright"]="input_r_x_plus_axis"
	AX["rightanalogup"]="input_r_y_minus_axis";    AX["rightanalogdown"]="input_r_y_plus_axis"

	DPAD["up"]="input_up_btn";     DPAD["down"]="input_down_btn"
	DPAD["left"]="input_left_btn"; DPAD["right"]="input_right_btn"

	HAT[1]="up"; HAT[2]="right"; HAT[4]="down"; HAT[8]="left"

	# ES 按键名 -> RetroArch 热键。绑到【印刷/实体按键】, 用 es_input 记录的实体 id。
	#
	# ★本表是热键的唯一来源★: es4all-1key 的 retroarch.cfg 里那些写死的按钮编号
	#   已全部改成 nul 让位(它照的是某一颗手柄, 换手柄必错; 实机上甚至把
	#   select/start 写反, 导致「SELECT+X 呼出菜单」毫无反应)。
	#   ⚠️ 推论: 【本表少写一个键 = 那个功能消失】。exit 就这样漏掉过一次。
	#   意图(对齐 EmuELEC controller-guide):
	#     SELECT+R1=存档 / SELECT+L1=读档 / SELECT+X=呼出菜单 / SELECT+Y=帧率 / SELECT+START=退出
	HK["rightshoulder"]="input_save_state_btn"
	HK["leftshoulder"]="input_load_state_btn"
	HK["x"]="input_menu_toggle_btn"
	HK["y"]="input_fps_toggle_btn"
	HK["start"]="input_exit_emulator_btn"

	# 面键(A/B/X/Y): 按【物理位置】写死, 不看 es_input 记录的印刷字母。
	# udev 语义码: 南=0 / 东=1 / 北=2 / 西=3, 而 RetroPad 的几何是 A=东、B=南、X=北、Y=西,
	# 所以这四个值让「按下去的位置」与「核心收到的位置」永远一致, 与手柄印刷无关。
	POS["a"]="1"; POS["b"]="0"; POS["x"]="2"; POS["y"]="3"

	n = 0; dev_name = ""; dev_guid = ""
}

/<inputConfig/ {
	if (attr($0, "type") != "joystick") { skip = 1; next }
	skip = 0
	flush_device()
	dev_name = attr($0, "deviceName")
	dev_guid = attr($0, "deviceGUID")
	emit("input_driver = \"udev\"")
	emit("input_device = \"" dev_name "\"")
	if (dev_guid != "") {
		vid = le16(dev_guid, 9)     # awk 的字串从 1 起算: 第 9 个字元 = python 的 offset 8
		pid = le16(dev_guid, 17)
		if (vid != 0 || pid != 0) {
			emit("input_vendor_id = \"" vid "\"")
			emit("input_product_id = \"" pid "\"")
		}
	}
	next
}

/<\/inputConfig>/ { if (!skip) flush_device(); next }

/<input / {
	if (skip || dev_name == "") next
	nm = attr($0, "name"); tp = attr($0, "type")
	id = attr($0, "id");   vl = attr($0, "value")

	if (nm in BTN) {
		v = (nm in POS) ? POS[nm] : id      # 面键按位置写死, 其余照实体 id
		emit(BTN[nm] " = \"" v "\"")
		if (nm in HK) emit(HK[nm] " = \"" id "\"")   # 热键一律绑实体键
	} else if (nm in AX) {
		if (tp == "axis") emit(AX[nm] " = \"" (vl + 0 >= 0 ? "+" : "-") id "\"")
		else              emit(AX[nm] " = \"" id "\"")
	} else if (nm in DPAD) {
		if (tp == "hat") { d = HAT[vl + 0]; if (d != "") dpad_hat[nm] = "h" id d }
		else             dpad_btn[nm] = id
	}
}

END { flush_device() }
' "${ES_INPUT}"
