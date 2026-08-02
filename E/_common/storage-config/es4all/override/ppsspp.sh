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
# ★为什么只有 SELECT+X 需要「透传」, 其余三组不用★
#   10-188~191 是 SDL GameController 的语意键(Y/A/B/X), **位置本来就跟 ES 对齐**
#   (两边都从 gamecontrollerdb 推导), 所以位置资讯不需要传。
#   唯独「印着 X 的是哪一颗」是**印刷资讯**, 只有 ES 知道 —— ES 的布局侦测
#   (GuiDetectLayout, 只按一次 A)把结果写进 es_settings.cfg 的 InvertButtons:
#     false = Xbox 式印刷(A 在南) → 印刷 X 在西 = SDL X = 10-191
#     true  = 任天堂式印刷(A 在东) → 印刷 X 在北 = SDL Y = 10-188
#   其余三组(SELECT+START / R1 / L1)与印刷无关, 固定值。
#   ⚠️ 键还没侦测过时 InvertButtons 不存在 → 落回 Xbox 式, 与现有模板同值, 行为不变。
ES_SETTINGS="/storage/.config/emulationstation/es_settings.cfg"
CONTROLS_INI="/storage/.config/ppsspp/PSP/SYSTEM/controls.ini"

if [ -f "${CONTROLS_INI}" ]; then
	MENU_KEY="10-191"
	grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null && MENU_KEY="10-188"

	# 有该行就改、没有就补。键名含空格, sed 的位址要完整比对到 " = "。
	set_chord() {   # $1=键名  $2=值
		if grep -q "^${1} = " "${CONTROLS_INI}"; then
			sed -i "/^${1} = /c\\${1} = ${2}" "${CONTROLS_INI}"
		else
			echo "${1} = ${2}" >>"${CONTROLS_INI}"
		fi
	}

	set_chord "Exit App"   "10-196:10-197"   # SELECT+START 退出
	set_chord "Save State" "10-196:10-192"   # SELECT+R1    存档
	set_chord "Load State" "10-196:10-193"   # SELECT+L1    读档

	# ★Pause 只换和弦那一段, 不整行覆盖★: EmuELEC 的模板是
	#   Pause = 1-111,10-196:10-191
	# 前面那个 1-111 是键盘键(接 USB 键盘时用得到)。ROCKNIX 那边整行重写没问题
	# 是因为它的模板本来就只有和弦; 这里照抄会把键盘那半吃掉。
	if grep -q '^Pause = ' "${CONTROLS_INI}"; then
		if grep -q '^Pause = .*10-196:' "${CONTROLS_INI}"; then
			sed -i "/^Pause = /s|10-196:10-[0-9]*|10-196:${MENU_KEY}|" "${CONTROLS_INI}"
		else
			sed -i "/^Pause = /s|\$|,10-196:${MENU_KEY}|" "${CONTROLS_INI}"
		fi
	else
		echo "Pause = 10-196:${MENU_KEY}" >>"${CONTROLS_INI}"
	fi

	echo "PSP HOTKEYS set: exit/save/load fixed, menu(SELECT+X) = 10-196:${MENU_KEY}"
fi

ARG=${1//[\\]/}
export SDL_AUDIODRIVER=alsa
PPSSPPSDL --fullscreen "${ARG}"
