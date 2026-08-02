#!/bin/bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2019-present Shanti Gilbert (https://github.com/shantigilbert)

. /etc/profile

ROMSPPSSPPFOLDER=/storage/roms/savestates/PPSSPPSDL/PSP
PPSSPPFOLDER=/storage/.config/ppsspp/PSP/
AUTOGP=$(get_ee_setting ppssppsdl_auto_gamepad)
CHEEVOS=$(get_ee_setting global.retroachievements)


if [[ "${AUTOGP}" == "1" ]]; then
	set_ppsspp_joy.sh
fi

if [[ "${CHEEVOS}" == "1" ]]; then
	ppssppcheevos.sh
fi

# NOTE(w2xg2022): 强制PPSSPP独立模拟器UI语言跟随ES/system.language,比照setsettings.sh
# 对RetroArch的做法(读system.language→写进配置)。PPSSPP的语言码就是assets/lang/*.ini
# 的文件名(zh_CN/zh_TW/ja_JP...),与system.language基本一致,只需处理几个别名;并用「翻译
# 档存在」把关,映射不到就保留原值不乱设。每次启动都同步=ES设什么语言,PSP独立模拟器就跟着走。
EE_LANG=$(get_ee_setting system.language)
case "${EE_LANG}" in
	cs_CZ)       PPLANG="cz_CZ" ;;   # PPSSPP捷克语文件名是cz_CZ
	en_GB)       PPLANG="en_US" ;;
	es_MX|eu_ES) PPLANG="es_ES" ;;
	*)           PPLANG="${EE_LANG}" ;;
esac
PPINI="/storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
if [ -n "${PPLANG}" ] && [ -f "/storage/.config/ppsspp/assets/lang/${PPLANG}.ini" ] && [ -f "${PPINI}" ]; then
	# 只改[General]里UI语言那行(值以字母开头),避开另一行数字的 Language = N(模拟PSP主机语言)
	sed -i "s/^Language = [a-zA-Z].*/Language = ${PPLANG}/" "${PPINI}"
fi

# Make sure we have the correct symlinks
for dir in Cheats PPSSPP_STATE SAVEDATA TEXTURES; do
    mkdir -p "${ROMSPPSSPPFOLDER}"
    
   if [ ! -L /storage/.config/ppsspp/PSP/${dir} ]; then
		cp -rf /storage/.config/ppsspp/PSP/${dir}/. ${ROMSPPSSPPFOLDER}/${dir}/
		rm -rf /storage/.config/ppsspp/PSP/${dir}
		ln -sf ${ROMSPPSSPPFOLDER}/${dir} /storage/.config/ppsspp/PSP/${dir}
    fi
done

if [ ! -s "${ROMSPPSSPPFOLDER}/Cheats/cheat.db" ];then 
	mkdir -p "${ROMSPPSSPPFOLDER}/Cheats/"
	cp -rf /usr/config/ppsspp/PSP/SYSTEM/Cheats/. "${ROMSPPSSPPFOLDER}/Cheats/" 

	CHEAT_DB_VERSION="06d4d6148b66109005f7d51c37e8344f0bc042cc"
	curl -sLo "${ROMSPPSSPPFOLDER}/Cheats/cheat.db" -f "https://raw.githubusercontent.com/Saramagrean/CWCheat-Database-Plus-/${CHEAT_DB_VERSION}/cheat.db" || true
fi

# ---------------------------------------------------------------------------
# es4all: 选单热键(和弦)—— SELECT+X 呼出 PPSSPP 主选单,★跟着 ES 的印刷布局走★
# ---------------------------------------------------------------------------
# 本段移植自 ROCKNIX 的 start_ppsspp.sh(同一套做法,黄金标准在那边),
# 经由 es4all-profiles 的 /usr/bin override 下发, **不必重编固件**。
#
# ★为什么必须每次启动都写、不能只靠 controls.ini 模板★
#   PPSSPP 在【乾净退出】时会用记忆体里的映射覆写 controls.ini, 而它不保留
#   Exit App / Save State / Load State 的和弦值, 会还原成自己的预设。
#   EmuELEC 这边原本只有一份静态模板、没有任何重写步骤 —— 现在看起来还在,
#   是因为还没有人乾净退出过(用 SELECT+START 退出是硬杀行程, PPSSPP 没机会写档),
#   迟早会掉。ROCKNIX 那边已经实机坐实过这个现象。
#
# ★两样东西都从 ES 透传:热键本身 + 「印着 X 的是哪一颗」★
#   ① **热键**(四组和弦共用的修饰键):来自 es_input.cfg 的 hotkeyenable。
#      使用者在 ES 里改热键, 独立模拟器要跟着改 —— 这是「严格从 ES 透传」的要求,
#      不能写死 10-196(那只是「多数手柄的热键碰巧是 SELECT」)。
#   ② **印刷 X 在哪**:10-188~191 是 SDL GameController 的语意键(Y/A/B/X),
#      **位置本来就跟 ES 对齐**(两边都从 gamecontrollerdb 推导), 位置不必传;
#      唯独「印着 X 的是哪一颗」是印刷资讯, 只有 ES 知道 —— 布局侦测
#      (GuiDetectLayout, 只按一次 A)把结果写进 es_settings.cfg 的 InvertButtons:
#        false = Xbox 式印刷(A 在南) → 印刷 X 在西 = SDL X = 10-191
#        true  = 任天堂式印刷(A 在东) → 印刷 X 在北 = SDL Y = 10-188
#   两项都有保底:读不到就落回 SELECT + Xbox 式, 与改动前同值, 行为不变。
#
# ⚠️ PSP 与 DC 在这里**不对称, 别互相照抄**:
#    Flycast **单按热键就开主选单**, 所以那边不需要和弦、也没有印刷歧义(已简化);
#    PPSSPP 没有单键开选单, 必须用「热键+X」, 所以 ② 这半在这里非留不可。
ES_SETTINGS="/storage/.config/emulationstation/es_settings.cfg"
CONTROLS_INI="/storage/.config/ppsspp/PSP/SYSTEM/controls.ini"

if [ -f "${CONTROLS_INI}" ]; then
	# ★2026-08-02:选单键改成【按位置】(一律西 = SDL X = 10-191), 不再看印刷★
	#   原本按印刷找「印着 X 的那颗」, 实机第二支手柄(任天堂式印刷)上炸掉:
	#   算成北键, 而 RA 的 input_menu_toggle_btn 是**西**(RA 自己就按位置),
	#   同一台机器上 RA 与 PSP/DC 要按不同颗。改按位置后三边统一, 也不再依赖佈局侦测。
	#   代价:任天堂式手柄上那颗印的是 Y 不是 X —— 但 RA 本来就是这样, 一致。
	MENU_KEY="10-191"

	# ★热键(和弦的修饰键)也从 ES 透传, 不再写死 10-196★
	#   ES 的 es_input.cfg 记的是**实体按键编号**:
	#       <input name="hotkeyenable" type="button" id="7" />
	#   PPSSPP 要的是 device-10 的 NKCODE, 中间要转换。
	#   ⚠️ 四组和弦(退出/存档/读档/选单)的修饰键**必须一起跟着变**,
	#      只改选单那组会变成「选单用新热键、其余三组还用旧的」。
	#
	#   ★2026-08-02 修正②:实体编号 -> NKCODE 不能用【写死的对照表】,
	#     必须经过 gamecontrollerdb 转成 SDL 语意名再查★
	#     旧写法直接 `6|8) 10-196 ;; 7|9) 10-197`, 隐含假设「实体 6=SELECT、7=START」
	#     的 X360 惯例。实机第二支手柄(GUID ...72050000)**正好相反**:
	#         gamecontrollerdb: back:b7  start:b6
	#     使用者把热键设在实体 7(他的 SELECT), 旧表却给出 10-197(START) ->
	#     产出 `Exit App = 10-197:10-197` —— **修饰键与第二颗同码**, 和弦按不出来,
	#     四组全废。(RA / DC 不受影响: 它们的组合键直接写实体编号, 不经过语意层。)
	#
	#     正确链路: ES 给实体编号 -> gamecontrollerdb 查它在 SDL 眼中叫什么
	#               -> 语意名对应 NKCODE。这样任何按键排列的手柄都对。
	#   ★2026-08-02 修正:改按【GUID(剥掉 CRC)】查, 不能按装置名★
	#     旧写法用 /sys/class/input/js0/device/name(= UDEV 名 "Microsoft X-Box 360 pad"),
	#     但 ES 写进 es_input.cfg 的 deviceName 是 **gamecontrollerdb 映射名**
	#     ("Xbox 360 Controller") —— 同一支手柄三个名字(还有 SDL_JoystickName
	#     "X360 Controller"), 用 UDEV 名查**永远落空**。
	#     ★之所以一直没被发现★:保底值刚好是 10-196(SELECT), 而这支手柄的
	#       hotkeyenable 也正好是 6(SELECT), 输出与「透传成功」逐字节相同。
	#       验证要看有没有印出 "PSP HOTKEY from ES", 别看结果值。
	#     GUID 比对:执行期带 CRC-16(030081b8...), ES 档里是 03000000...,
	#     只差第 5~8 字元 —— ES 自己也是抹掉那段再比, 这里两种写法都试。
	HOTKEY="10-196"                       # 落不到时的保底 = SELECT(与改动前同值)
	PAD_GUID="$(gamepad_info -more 2>/dev/null | awk '/SDL GUID:/{print $3; exit}')"
	PAD_GUID_NOCRC=""
	[ ${#PAD_GUID} -ge 8 ] && PAD_GUID_NOCRC="$(echo "${PAD_GUID}" | cut -c1-4)0000$(echo "${PAD_GUID}" | cut -c9-)"
	ES_INPUT_FILE="${ES_SETTINGS%es_settings.cfg}es_input.cfg"

	# 从 es_input.cfg 取某一颗键的实体按键编号($1 = select / start / hotkeyenable)。
	# ★只认 type="button"★: L2/R2 与摇杆在 ES 里记成 type="axis", 拿轴当和弦的修饰键
	#   做不出来, 回传空值让呼叫端落回保底。(精灵那边已加说明, 建议热键选 SELECT。)
	es_input_btn() {
		awk -v g1="deviceGUID=\"${PAD_GUID}\"" \
		    -v g2="deviceGUID=\"${PAD_GUID_NOCRC}\"" \
		    -v nm="name=\"${1}\"" '
			index($0, g1) || index($0, g2) { inblock=1 }
			inblock && index($0, nm) && /type="button"/ {
				if (match($0, /id="[0-9]+"/)) { print substr($0, RSTART+4, RLENGTH-5); exit }
			}
			inblock && /<\/inputConfig>/ { inblock=0 }
		' "${ES_INPUT_FILE}"
	}

	GCDB_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-/storage/.config/SDL-GameControllerDB/gamecontrollerdb.txt}"
	GC_LINE=$(grep -m1 -E "^(${PAD_GUID}|${PAD_GUID_NOCRC})," "${GCDB_FILE}" 2>/dev/null)

	# 实体按键编号 -> SDL 语意名(a/b/x/y/back/start/...)。查的是 gamecontrollerdb
	# 里 `名称:bN` 那些栏位, 找出 N 等于给定编号的那一笔。查不到回传空值。
	gc_semantic_of() {
		echo "${GC_LINE}" | tr ',' '\n' | awk -F: -v n="b${1}" '$2 == n { print $1; exit }'
	}

	if [ -n "${PAD_GUID}" ] && [ -f "${ES_INPUT_FILE}" ]; then
		HK_ID=$(es_input_btn hotkeyenable)
		# 语意名 -> device-10 的 NKCODE。位置语意固定(a=南 b=东 x=西 y=北),
		# 与 PSP 的 ✕○□△ 位置对齐一致, 故这张表与手柄的实体排列无关, 永远成立。
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

		# ★SELECT / START 也从 ES 透传 —— 但机制与 flycast 完全不同, 别照抄★
		#   起因(实机第二支手柄坐实): 那支是任天堂式手柄, 面板只有「−」与「+」两颗,
		#   哪一颗算 SELECT、哪一颗算 START **没有客观答案**, 反过来指定也说得通
		#   —— 既然是使用者的选择, 就只有键位精灵写进 es_input.cfg 的那笔算数。
		#
		#   ⚠️ flycast 的 [combo] 直接写**实体按键编号**, 把 ES 的值填进去就成;
		#      PPSSPP 用的是 device-10 的 **SDL 语意码**(10-196=BACK、10-197=START),
		#      「哪颗实体键产生 10-196」是 **SDL 依 gamecontrollerdb 决定的**, 改不了。
		#   → 故做法是**侦测使用者的选择是否与 gamecontrollerdb 相反**,
		#     相反就把 controls.ini 里 Select / Start 两行的语意码对调, 结果等价。
		#   两边都读得到才比对; 任一读不到就什么都不做(维持原样), 不猜。
		#   ⚠️ 与上面的热键转换是两件事, 别混:上面处理「热键那颗的语意是什么」,
		#      这里处理「使用者对 SELECT/START 的指定与 db 是否相反」。db 本身就
		#      照使用者的想法排(如本机 back:b7/start:b6)时, 这段不会触发, 是正常的。
		ES_SELECT_ID=$(es_input_btn select)
		ES_START_ID=$(es_input_btn start)
		GC_BACK_ID=$(echo "${GC_LINE}"  | grep -oE 'back:b[0-9]+'  | grep -oE '[0-9]+$')
		GC_START_ID=$(echo "${GC_LINE}" | grep -oE 'start:b[0-9]+' | grep -oE '[0-9]+$')
		if [ -n "${ES_SELECT_ID}" ] && [ -n "${ES_START_ID}" ] &&
		   [ -n "${GC_BACK_ID}" ] && [ -n "${GC_START_ID}" ] &&
		   [ "${ES_SELECT_ID}" = "${GC_START_ID}" ] && [ "${ES_START_ID}" = "${GC_BACK_ID}" ]; then
			echo "PSP: ES 的 SELECT/START 与 gamecontrollerdb 相反(ES select=b${ES_SELECT_ID} start=b${ES_START_ID}), 对调 controls.ini"
			sed -i "/^Select = /s/10-19[67]/10-197/" "${CONTROLS_INI}"
			sed -i "/^Start = /s/10-19[67]/10-196/"  "${CONTROLS_INI}"
		fi

		# -------------------------------------------------------------------
		# ★面键按【位置】重排:✕南 ○东 □西 △北★
		# -------------------------------------------------------------------
		# ★真因(实机第二支手柄 GUID ...72050000 坐实)★
		#   SDL 的 a/b/x/y **按定义是位置**(a=南 b=东 x=西 y=北), 我们一直靠这点
		#   直接把 10-189/190/191/188 当成位置用 —— 但那要 gamecontrollerdb 的
		#   条目**真的按位置写**才成立。这支山寨手柄的条目是**按字母写的**:
		#       db: a:b1  b:b0  x:b3  y:b2
		#       ES: a=1(印刷A)  b=0  x=3  y=2   且 InvertButtons=true(A 在东)
		#   → db 的 "a" 指到的是【印着 A 的那颗】, 而它在**东**, 不在南。
		#   于是 Cross(✕)=10-189=db 的 a 就跑到东边去, ○✕ 与 □△ 全部位置颠倒。
		#   出厂模板一个字没改 —— 不是被改坏, 是模板的位置假设对这支手柄不成立。
		#
		# ★怎么拿到「真实位置」: 只有 ES 知道★
		#   ES 有两样 db 没有的东西:①印刷字母 -> 实体编号(键位精灵)
		#   ②印刷佈局(GuiDetectLayout 的 InvertButtons)。两者一组合就能反推位置:
		#       InvertButtons=false(Xbox 式, A 在南): 南=a 东=b 西=x 北=y
		#       InvertButtons=true (任天堂式, A 在东): 南=b 东=a 西=y 北=x
		#   再把「位置对应的实体编号」经 db 转回 SDL 语意名 -> NKCODE, 就是要写的值。
		#
		# ⚠️ 四颗**全部**拿得到、且四个 NKCODE 互不相同才动手; 少一个就整组不改,
		#    宁可维持模板原样也不要产出半套(半套比全错更难查)。
		nkcode_of_phys() {
			case "$(gc_semantic_of "${1}")" in
				a) echo "10-189" ;;  b) echo "10-190" ;;
				x) echo "10-191" ;;  y) echo "10-188" ;;
			esac
		}
		if grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null; then
			NK_SOUTH=$(nkcode_of_phys "$(es_input_btn b)")
			NK_EAST=$(nkcode_of_phys  "$(es_input_btn a)")
			NK_WEST=$(nkcode_of_phys  "$(es_input_btn y)")
			NK_NORTH=$(nkcode_of_phys "$(es_input_btn x)")
		else
			NK_SOUTH=$(nkcode_of_phys "$(es_input_btn a)")
			NK_EAST=$(nkcode_of_phys  "$(es_input_btn b)")
			NK_WEST=$(nkcode_of_phys  "$(es_input_btn x)")
			NK_NORTH=$(nkcode_of_phys "$(es_input_btn y)")
		fi
		if [ -n "${NK_SOUTH}" ] && [ -n "${NK_EAST}" ] && [ -n "${NK_WEST}" ] && [ -n "${NK_NORTH}" ] &&
		   [ "$(printf '%s\n' "${NK_SOUTH}" "${NK_EAST}" "${NK_WEST}" "${NK_NORTH}" | sort -u | wc -l)" = "4" ]; then
			# 只换那一段 10-xxx, 保留前面的键盘绑定(如 Cross 那行的 1-52)。
			sed -i "/^Cross = /s/10-[0-9]*/${NK_SOUTH}/"    "${CONTROLS_INI}"
			sed -i "/^Circle = /s/10-[0-9]*/${NK_EAST}/"    "${CONTROLS_INI}"
			sed -i "/^Square = /s/10-[0-9]*/${NK_WEST}/"    "${CONTROLS_INI}"
			sed -i "/^Triangle = /s/10-[0-9]*/${NK_NORTH}/" "${CONTROLS_INI}"
			# ★选单和弦的第二颗也必须用这里算出来的「西」★
			#   否则会退回写死的 10-191(= db 的 x), 在这种手柄上落到北,
			#   而 RA 的 input_menu_toggle_btn 是按实体编号给的西 —— 两边又会不一致。
			MENU_KEY="${NK_WEST}"
			echo "PSP face buttons by position: X(south)=${NK_SOUTH} O(east)=${NK_EAST} [](west)=${NK_WEST} /\\(north)=${NK_NORTH}"
		else
			echo "PSP face buttons: 位置资讯不完整, 维持模板原样(未重排)"
		fi
	fi

	# 有该行就改、没有就补。键名含空格, sed 的位址要完整比对到 " = "。
	set_chord() {   # $1=键名  $2=值
		if grep -q "^${1} = " "${CONTROLS_INI}"; then
			sed -i "/^${1} = /c\\${1} = ${2}" "${CONTROLS_INI}"
		else
			echo "${1} = ${2}" >>"${CONTROLS_INI}"
		fi
	}

	set_chord "Exit App"   "${HOTKEY}:10-197"   # 热键+START 退出
	set_chord "Save State" "${HOTKEY}:10-192"   # 热键+R1    存档
	set_chord "Load State" "${HOTKEY}:10-193"   # 热键+L1    读档

	# ★Pause 只换和弦那一段, 不整行覆盖★: EmuELEC 的模板是
	#   Pause = 1-111,10-196:10-191
	# 前面那个 1-111 是键盘键(接 USB 键盘时用得到)。ROCKNIX 那边整行重写没问题
	# 是因为它的模板本来就只有和弦; 这里照抄会把键盘那半吃掉。
	if grep -q '^Pause = ' "${CONTROLS_INI}"; then
		if grep -qE '^Pause = .*10-[0-9]+:10-[0-9]+' "${CONTROLS_INI}"; then
			sed -i "/^Pause = /s|10-[0-9]*:10-[0-9]*|${HOTKEY}:${MENU_KEY}|" "${CONTROLS_INI}"
		else
			sed -i "/^Pause = /s|\$|,${HOTKEY}:${MENU_KEY}|" "${CONTROLS_INI}"
		fi
	else
		echo "Pause = ${HOTKEY}:${MENU_KEY}" >>"${CONTROLS_INI}"
	fi

	echo "PSP HOTKEYS set: hotkey=${HOTKEY}, menu(hotkey+X) = ${HOTKEY}:${MENU_KEY}"
fi

ARG=${1//[\\]/}
export SDL_AUDIODRIVER=alsa
PPSSPPSDL --fullscreen "${ARG}"
