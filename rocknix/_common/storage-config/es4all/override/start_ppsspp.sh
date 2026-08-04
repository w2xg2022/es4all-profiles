#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2023 JELOS (https://github.com/JustEnoughLinuxOS)

. /etc/profile
set_kill set "-9 ppsspp"

SOURCE_DIR="/usr/config/ppsspp"
CONF_DIR="/storage/.config/ppsspp"
PPSSPP_INI="PSP/SYSTEM/ppsspp.ini"

# Check if conf dir exists
if [ ! -d "${CONF_DIR}" ]
then
  cp -rf ${SOURCE_DIR} ${CONF_DIR}
fi

# Check if savestate dir exists
if [ ! -d "/storage/roms/savestates/psp/ppsspp-sa" ]; then
  mkdir -p "/storage/roms/savestates/psp/ppsspp-sa"
fi

#Emulation Station Features
GAME=$(echo "${1}"| sed "s#^/.*/##")
PLATFORM=$(echo "${2}"| sed "s#^/.*/##")
ASKIP=$(get_setting auto_frame_skip "${PLATFORM}" "${GAME}")
FPS=$(get_setting show_fps "${PLATFORM}" "${GAME}")
IRES=$(get_setting internal_resolution "${PLATFORM}" "${GAME}")
GRENDERER=$(get_setting graphics_backend "${PLATFORM}" "${GAME}")
SKIPB=$(get_setting skip_buffer_effects "${PLATFORM}" "${GAME}")
VSYNC=$(get_setting vsync "${PLATFORM}" "${GAME}")
CLOCK_SPEED=$(get_setting clock_speed "${PLATFORM}" "${GAME}")

#Set the cores to use
CORES=$(get_setting "cores" "${PLATFORM}" "${GAME}")
if [ "${CORES}" = "little" ]; then
  EMUPERF="${SLOW_CORES}"
elif [ "${CORES}" = "big" ]; then
  EMUPERF="${FAST_CORES}"
else
  ### All..
  unset EMUPERF
fi

  #Auto Frame Skip
	if [ "${ASKIP}" = "1" ]; then
		sed -i '/AutoFrameSkip =/c\AutoFrameSkip = True' ${CONF_DIR}/${PPSSPP_INI}
	else
		sed -i '/^AutoFrameSkip =/c\AutoFrameSkip = False' ${CONF_DIR}/${PPSSPP_INI}
        fi

  #Graphics Backend
        if [ "${GRENDERER}" = "opengl" ]; then
                sed -i '/^GraphicsBackend =/c\GraphicsBackend = 0 (OPENGL)' ${CONF_DIR}/${PPSSPP_INI}
        elif [ "${GRENDERER}" = "vulkan" ]; then
                sed -i '/^GraphicsBackend =/c\GraphicsBackend = 3 (VULKAN)' ${CONF_DIR}/${PPSSPP_INI}
        else
		sed -i '/^GraphicsBackend =/c\GraphicsBackend = @GRENDERER@' ${CONF_DIR}/${PPSSPP_INI}
	fi

  #Internal Resolution
	if [ "${IRES}" = "2" ]; then
		sed -i '/^InternalResolution/c\InternalResolution = 2' ${CONF_DIR}/${PPSSPP_INI}
	elif [ "${IRES}" = "3" ]; then
		sed -i '/^InternalResolution/c\InternalResolution = 3' ${CONF_DIR}/${PPSSPP_INI}
	elif [ "${IRES}" = "4" ]; then
                sed -i '/^InternalResolution/c\InternalResolution = 4' ${CONF_DIR}/${PPSSPP_INI}
	else
		sed -i '/^InternalResolution/c\InternalResolution = 1' ${CONF_DIR}/${PPSSPP_INI}
        fi

  #Show FPS
	if [ "${FPS}" = "1" ]; then
		sed -i '/^iShowStatusFlags =/c\iShowStatusFlags = 2' ${CONF_DIR}/${PPSSPP_INI}
	else
		sed -i '/^iShowStatusFlags =/c\iShowStatusFlags = 0' ${CONF_DIR}/${PPSSPP_INI}
	fi

  #Skip Buffer Effects
	if [ "${SKIPB}" = "1" ]; then
		sed -i '/^SkipBufferEffects =/c\SkipBufferEffects = True' ${CONF_DIR}/${PPSSPP_INI}
	else
		sed -i '/^SkipBufferEffects =/c\SkipBufferEffects = False' ${CONF_DIR}/${PPSSPP_INI}
	fi

  #VSYNC
	if [ "${VSYNC}" = "1" ]; then
		sed -i '/^VSyncInterval =/c\VSyncInterval = True' ${CONF_DIR}/${PPSSPP_INI}
	else
		sed -i '/^VSyncInterval =/c\VSyncInterval = False' ${CONF_DIR}/${PPSSPP_INI}
	fi

  #Clock Speed
	if [ "${CLOCK_SPEED}" = "222" ]; then
		sed -i '/^CPUSpeed =/c\CPUSpeed = 222' ${CONF_DIR}/${PPSSPP_INI}
  elif [ "${CLOCK_SPEED}" = "333" ]; then
		sed -i '/^CPUSpeed =/c\CPUSpeed = 333' ${CONF_DIR}/${PPSSPP_INI}
	else
		sed -i '/^CPUSpeed =/c\CPUSpeed = 0' ${CONF_DIR}/${PPSSPP_INI}
	fi

#UI 语言跟随 ES(system.language),比照 setsettings.sh 强制 RetroArch 的做法
# PPSSPP 的语言码 = assets/lang/*.ini 的文件名,与 system.language 基本一致,只有几个别名要转。
# ★ppsspp.ini 有两行 Language★:[General] 里字母值的是 UI 语言,另一行 `Language = 1` 是模拟的
#   PSP 主机语言。sed 必须用 [a-zA-Z] 只锁 UI 那行,别误动数字行。
ESLANG=$(get_setting system.language)
case "${ESLANG}" in
  cs_CZ) PPLANG="cz_CZ" ;;
  en_GB) PPLANG="en_US" ;;
  es_MX|eu_ES) PPLANG="es_ES" ;;
  "") PPLANG="zh_CN" ;;
  *) PPLANG="${ESLANG}" ;;
esac
# 没有对应翻译档就退回默认,别写进一个 PPSSPP 不认得的码
if [ ! -f "${CONF_DIR}/assets/lang/${PPLANG}.ini" ]; then
  PPLANG="zh_CN"
fi
sed -i "/^Language = [a-zA-Z]/c\\Language = ${PPLANG}" ${CONF_DIR}/${PPSSPP_INI}
echo "UI LANGUAGE set to: ${PPLANG} (from system.language=${ESLANG})"

# ★SELECT / START 从键位精灵透传 —— 唯一的槓桿是 SDL 的对照表★
#
# PPSSPP 走 SDL GameController API: 拿到的是 BACK / START / A / B 这种【语意名】,
# 哪一颗实体键算 BACK 由 gamecontrollerdb 决定 —— ★改下面 controls.ini 里的数字
# 改不动它★(10-196 就是 BACK 的语意码, 换个数字只是换成别的语意)。
#
# 实机 2026-08-04: 使用者刻意把「＋」(一般 START 的位置)设成 SELECT 兼热键、
# 「−」设成 START; 但 SDL 内建的 xpad 对照是 back:b6(=「−」), 於是热键落在「−」上,
# 与他设的正好相反。而「哪一颗算 SELECT」本来就没有客观答案, 只有精灵里的选择算数。
#
# 那份对照由 es4all-profiles 的 controls-changed 钩子(es-sdl-gcdb.sh)产生;
# 没有就维持 SDL 内建表 —— 没跑过精灵的机器行为完全不变。
ES4ALL_GCDB="/storage/.config/es4all/gamecontrollerdb.txt"
[ -f "${ES4ALL_GCDB}" ] && export SDL_GAMECONTROLLERCONFIG_FILE="${ES4ALL_GCDB}"

#组合键(和弦) —— ★每次启动都重写,不能只靠 controls.ini 模板★
#
# ★为什么必须每次重写★:PPSSPP 在【乾净退出】时会用内存里的映射覆写 controls.ini,
# 而它不保留 `Exit App` 与 `Save State`/`Load State` 的和弦值,会还原成自己的预设
# (10-4010 / 10-4008)。实机坐实:全新安装跑一轮后,韧体模板里那三行就没了,
# 只有 `Pause` 活着 —— 因为下面这段每次启动都把它写回去。
# ⚠️ 早期误判过「模板复制一次就永久有效」:那次是用 SELECT+START 退出(走 input_sense
#    的 killall -9),行程被硬杀、PPSSPP 根本没机会写档,所以看起来没被动。
#
# 键码说明:10-188~191 是 SDL GameController 的语意键(Y/A/B/X),位置本来就跟 ES 对齐
# (两边都从 gamecontrollerdb 推导)。唯独「印着 X 的是哪一颗」只有 ES 知道 ——
# ES 的布局侦测(GuiDetectLayout,只按一次 A)把结果写进 es_settings.cfg 的 InvertButtons:
#   false = Xbox 式印刷(A 在南) → 印刷 X 在西 = SDL X = 10-191
#   true  = 任天堂式印刷(A 在东) → 印刷 X 在北 = SDL Y = 10-188
# 其余三组(SELECT+START/R1/L1)与印刷无关,固定值。
ES_SETTINGS="/storage/.config/emulationstation/es_settings.cfg"
CONTROLS_INI="${CONF_DIR}/PSP/SYSTEM/controls.ini"
if [ -f "${CONTROLS_INI}" ]; then
  MENU_KEY="10-191"
  if grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null; then
    MENU_KEY="10-188"
  fi
  # 有该行就改、没有就补;键名含空格,sed 的位址要完整比对到 " = "
  set_chord() {   # $1=键名  $2=值
    if grep -q "^${1} = " "${CONTROLS_INI}"; then
      sed -i "/^${1} = /c\\${1} = ${2}" "${CONTROLS_INI}"
    else
      echo "${1} = ${2}" >>"${CONTROLS_INI}"
    fi
  }
  set_chord "Exit App"   "10-196:10-197"   # SELECT+START 退出
  set_chord "Save State" "10-196:10-192"   # SELECT+R1   存档
  set_chord "Load State" "10-196:10-193"   # SELECT+L1   读档
  set_chord "Pause"      "10-196:${MENU_KEY}"  # SELECT+X 呼出菜单(跟印刷布局走)
  echo "PSP HOTKEYS set: exit/save/load fixed, menu(SELECT+X) = 10-196:${MENU_KEY}"

  # ★热键改从键位精灵透传 —— 上面那套写死的只当保底★(2026-08-04)
  #   上面写死 10-196(=SDL BACK)当修饰键, 隐含假设「使用者的热键一定是 SELECT」。
  #   实际要两层查表: hotkeyenable=b7 -> 查 db 哪一笔是 :b7 -> back -> 10-196。
  #   这段逻辑放在 psp-hotkeys.sh(与 EmuELEC 的 ppsspp.sh 同一套), 三边行为一致。
  #   ⚠️ 别拿产出的值当透传生效的证据: 保底值常与实际热键撞成同值, 输出逐字节相同。
  [ -x /storage/.config/es4all/bin/psp-hotkeys.sh ] && sh /storage/.config/es4all/bin/psp-hotkeys.sh
fi

#Retroachievements
/usr/bin/cheevos_ppsspp.sh

ARG=${1//[\\]/}

# Debugging info:
  echo "GAME set to: ${GAME}"
  echo "PLATFORM set to: ${PLATFORM}"
  echo "CONF DIR: ${CONF_DIR}/${PPSSPP_INI}"
  echo "CPU CORES set to: ${EMUPERF}"
  echo "AUTO FRAME SKIP set to: ${ASKIP}"
  echo "GRAPHICS RENDERER set to: ${GRENDERER}"
  echo "INTERNAL RESOLUTION set to: ${IRES}"
  echo "FPS set to: ${FPS}"
  echo "SKIP BUFFER EFFECTS set to: ${SKIPB}"
  echo "VSYNC set to: ${VSYNC}"
  echo "Launching /usr/bin/ppsspp ${ARG}"

${EMUPERF} ppsspp --pause-menu-exit "${ARG}"
