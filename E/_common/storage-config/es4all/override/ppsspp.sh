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
	MENU_KEY="10-191"
	grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null && MENU_KEY="10-188"

	# ★热键(和弦的修饰键)也从 ES 透传, 不再写死 10-196★
	#   ES 的 es_input.cfg 记的是**实体按键编号**:
	#       <input name="hotkeyenable" type="button" id="6" />
	#   PPSSPP 要的是 device-10 的 NKCODE, 中间要查表 —— 这张表与
	#   set_ppsspp_joy.sh 的 GC_PPSSPP_VALUES 同源(实体索引 -> NKCODE),
	#   改那边记得两边一起改。
	#   ⚠️ 四组和弦(退出/存档/读档/选单)的修饰键**必须一起跟着变**,
	#      只改选单那组会变成「选单用新热键、其余三组还用旧的」。
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
	if [ -n "${PAD_GUID}" ] && [ -f "${ES_SETTINGS%es_settings.cfg}es_input.cfg" ]; then
		HK_ID=$(awk -v g1="deviceGUID=\"${PAD_GUID}\"" \
		            -v g2="deviceGUID=\"${PAD_GUID_NOCRC}\"" '
			index($0, g1) || index($0, g2) { inblock=1 }
			inblock && /name="hotkeyenable"/ && /type="button"/ {
				if (match($0, /id="[0-9]+"/)) { print substr($0, RSTART+4, RLENGTH-5); exit }
			}
			inblock && /<\/inputConfig>/ { inblock=0 }
		' "${ES_SETTINGS%es_settings.cfg}es_input.cfg")
		case "${HK_ID}" in
			0)  HOTKEY="10-189" ;;  1)  HOTKEY="10-190" ;;
			2)  HOTKEY="10-191" ;;  3)  HOTKEY="10-188" ;;
			4)  HOTKEY="10-193" ;;  5)  HOTKEY="10-192" ;;
			6|8) HOTKEY="10-196" ;; 7|9) HOTKEY="10-197" ;;
			11) HOTKEY="10-106" ;;  12) HOTKEY="10-107" ;;
			*)  ;;                  # 认不得(含空值/b10 home 无对应码)就保底
		esac
		[ -n "${HK_ID}" ] && echo "PSP HOTKEY from ES: button ${HK_ID} -> ${HOTKEY}"
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
