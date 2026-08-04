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

# ★evdev 别名只在【单一装置】的输入档上做★
#
# 同一支手柄有三个名字, ROCKNIX 的 setsettings.sh 是按【evdev 名】找档的
# (见 flush_device 的说明), 所以我们要多写一份用 evdev 名命名的副本。
# 但 evdev 名是靠 VID/PID 反查【当前接着的装置】得到的 —— 如果输入档里有好几笔
# 共用同一组 VID/PID(ROCKNIX 出厂的 es_input.cfg 就有三笔 045e:028e),
# 那几笔会全部写到同一个档名上, 最后一笔胜出, 而那不一定是使用者刚设定的那支。
#
# ES 在触发 controls-changed 之前会另存一份【只含刚设定的那一支】的
# es_temporaryinput.cfg —— 用它来做别名就精准。所以规则定成:
#   输入档里只有一个 joystick -> 做别名; 有多个 -> 只写 SDL 名, 不猜。
DEVCOUNT=$(grep -c '<inputConfig[^>]*type="joystick"' "${ES_INPUT}" 2>/dev/null || echo 0)
ALIAS=0
[ "${DEVCOUNT}" = "1" ] && ALIAS=1

awk -v out_dir="${OUT_DIR}" -v do_alias="${ALIAS}" '
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

# 用 VID/PID 反查核心给这支手柄的 evdev 名。
# 走 /sys/class/input/event*/device/{id/vendor,id/product,name} —— 与 /proc/bus/input/devices
# 同一份真相, 但不必解析那个多行格式。找不到就回空字串(呼叫端自己处理)。
function evdev_name(want_vid, want_pid,   cmd, line, out) {
	if (want_vid == "" || want_pid == "") return ""
	cmd = "for d in /sys/class/input/event*/device; do" \
	      " v=$(cat $d/id/vendor 2>/dev/null); p=$(cat $d/id/product 2>/dev/null);" \
	      " if [ \"$v\" = \"" sprintf("%04x", want_vid) "\" ] && [ \"$p\" = \"" sprintf("%04x", want_pid) "\" ];" \
	      " then cat $d/name 2>/dev/null; break; fi; done"
	out = ""
	while ((cmd | getline line) > 0) { out = line; break }
	close(cmd)
	sub(/[ \t\r\n]+$/, "", out)
	return out
}

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

	# ---- 热键: 先决定「热键键」是哪一颗 ------------------------------------
	# ★没设 hotkeyenable 就拿 SELECT 顶上★(与 EmuELEC 的 configscripts 同一套做法)
	hk_id = id_of["hotkeyenable"]
	if (hk_id == "") hk_id = id_of["select"]

	if (hk_id == "") {
		# ★连 SELECT 都没有 -> 所有热键【整批不写】★(EmuELEC 也是这样做的)
		#   RetroArch 在没有 input_enable_hotkey 时, 热键是【单键直接触发】的 ——
		#   意思是游戏中按一下 X 就跳出 RA 选单、按 Y 就切 FPS, 完全没法玩。
		#   宁可没有热键, 也不能变成单键误触。
		print "注意: 没有 hotkeyenable 也没有 select, 热键整批跳过(否则会变成单键直接触发)"
	} else {
		emit("input_enable_hotkey_btn = \"" hk_id "\"")
		for (i = 1; i <= hkn; i++) emit(hk[i])

		# ★退出键 = SELECT / START 之中【不是热键键】的那一颗★
		#   ES 的 es_input.cfg 没有「退出」这个栏位, 纯透传绑不出来, 只能推。
		#   意图是「SELECT+START 退出」, 而使用者把哪一颗当热键并不固定
		#   (2026-08-04 实机: 使用者【刻意】把 hotkeyenable 设成 START)。
		#   EmuELEC 是把 exit 写死绑 START —— 那在这种设定下会让热键键与退出键
		#   变成同一颗, 组合永远按不出来。改成取另一颗: 不论他挑哪一颗当热键,
		#   SELECT+START 这个组合都成立; 而在一般情形(热键=SELECT)结果与写死完全相同。
		#   ⚠️ 推不出另一颗时不产生退出键(宁缺勿错: 绑到同一颗只会让人以为
		#      「按了没反应」, 比明白地没有更难查)。
		exit_id = (hk_id == id_of["start"]) ? id_of["select"] : id_of["start"]
		if (exit_id != "" && exit_id != hk_id)
			emit("input_exit_emulator_btn = \"" exit_id "\"")
	}

	# ★同一支手柄有三个名字, 这里要写【两份】★(2026-08-04 ROCKNIX 实机)
	#
	#   SDL 名 : "Xbox 360 Controller"      <- es_input.cfg 记的、我们本来只写这个
	#   evdev 名: "Microsoft X-Box 360 pad"  <- 核心驱动给的
	#
	# ROCKNIX 的 setsettings.sh 在每次启动游戏时【从 joypad 档反推 RA 热键】,
	# 而它找档的方式是: MY_CONTROLLER=从 /proc/bus/input/devices 取【evdev 名】,
	# 然后读 /tmp/joypads/<那个名字>.cfg。档名对不上就永远读不到我们这份 ——
	# 表现是「精灵设了半天, 游戏里的热键还是出厂那套」, 而且完全静默。
	# RA 自己配对 autoconfig 也一样: udev driver 看到的是 evdev 名, 不是 SDL 名。
	#
	# 所以 evdev 名那份才是主角; SDL 名那份仍然写, 给 sdl2 joypad driver 的场合用。
	# 两份内容只差 input_device 那一行。
	ev = (do_alias == "1") ? evdev_name(vid, pid) : ""
	if (ev != "" && ev != dev_name) {
		safe2 = ev
		gsub(/[^A-Za-z0-9 _-]/, "_", safe2)
		sub(/^ +/, "", safe2); sub(/ +$/, "", safe2)
		path2 = out_dir "/" safe2 ".cfg"
		printf "" > path2
		for (i = 1; i <= n; i++) {
			line = out[i]
			if (line ~ /^input_device = /) line = "input_device = \"" ev "\""
			print line >> path2
		}
		close(path2)
		print "写入 " path2 " (evdev 名, 供 udev driver 与 ROCKNIX setsettings 使用)"
	}

	printf "" > path
	for (i = 1; i <= n; i++) print out[i] >> path
	close(path)
	print "写入 " path

	n = 0; hkn = 0; dev_name = ""; dev_guid = ""; vid = ""; pid = ""
	split("", dpad_hat); split("", dpad_btn); split("", id_of); split("", hk)
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
	# ★退出键【不在这张表里】★: ES 的 es_input.cfg 根本没有「退出」这个栏位,
	# 纯透传绑不出来。它在 flush_device() 里由 select/start 与热键键的关系推出来。

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
		# 记下实体 id: 热键键/退出键要靠 select、start、hotkeyenable 的关系推(见 flush_device)
		id_of[nm] = id
		# ★input_enable_hotkey_btn 不在这里写★: 它可能要退回 select, 统一到 flush 决定。
		if (nm != "hotkeyenable") {
			v = (nm in POS) ? POS[nm] : id      # 面键按位置写死, 其余照实体 id
			emit(BTN[nm] " = \"" v "\"")
		}
		# ★热键先收着不写★: 没有热键键时整批都不能写(否则变成单键直接触发), 见 flush_device。
		if (nm in HK) hk[++hkn] = HK[nm] " = \"" id "\""
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
