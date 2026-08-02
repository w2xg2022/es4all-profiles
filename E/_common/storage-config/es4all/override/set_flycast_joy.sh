#!/bin/bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2020-present Shanti Gilbert (https://github.com/shantigilbert)

# Source predefined functions and variables
. /etc/profile

CONFIG_DIR="/storage/.config/flycast"
EMU_FILE="${CONFIG_DIR}/emu.cfg"
MAPPING_DIR="${CONFIG_DIR}/mappings"

source joy_common.sh "flycast"

CONFIG_TMP_A="/tmp/jc/SDLflycastA.tmp"
CONFIG_TMP_D="/tmp/jc/SDLflycastD.tmp"
CONFIG_TMP_E="/tmp/jc/SDLflycastE.tmp"

BTN_H0=$(get_ee_setting flycast_btn_h0)
[[ -z "${BTN_H0}" ]] && BTN_H0=255

declare -A FLYCAST_D_INDEXES=(
  [h0.1]=$(( BTN_H0+1 ))
  [h0.4]=$(( BTN_H0+2 ))
  [h0.8]=$(( BTN_H0+3 ))
  [h0.2]=$(( BTN_H0+4 ))
)

# NOTE(w2xg2022): 基准为「标签对齐」(物理位置a/b/x/y→DC同名按钮)，对应
# InvertGameButtons=false / InvertXYButtons=false 的「不翻」状态。下面按ES设定
# 决定是否翻成「位置对齐」(与RA per-core remap同源、同语义)。
declare -A FLYCAST_D_BUTTONS=(
  [x]="btn_x"
  [y]="btn_y"
  [a]="btn_a"
  [b]="btn_b"
  [leftshoulder]="btn_c"
  [rightshoulder]="btn_d"
  [lefttrigger]="btn_trigger_left"
  [righttrigger]="btn_trigger_right"
  [back]="btn_menu"
  [start]="btn_start"
  [guide]="btn_escape"
  # NOTE(w2xg2022 2026-08-02): 移除 [rightstick]="btn_fforward" —— 用户明确表示快进不需要。
  #   顺带记一笔两边本来还不一致:EmuELEC 这里绑的是 **R3(右摇杆按下)**,
  #   ROCKNIX 的 flycast.gptk 绑的是 **R2**(r2_hk = f)。现在两边一起拿掉。
  [dpup]="btn_dpad1_up"
  [dpdown]="btn_dpad1_down"
  [dpleft]="btn_dpad1_left"
  [dpright]="btn_dpad1_right"
  [leftx]="axis_x"
  [lefty]="axis_y"
  [rightx]="axis_right_x"
  [righty]="axis_right_y"
)

# NOTE(w2xg2022): 手柄三层架构定案(2026-07)——第三层「游戏内」一律「写死原厂位置对齐」，
# 不再透传、不再看任何 ES 开关(原 InvertGameButtons/InvertXYButtons 已从 ES 移除)。
# 直接写死成「位置对齐」的值(等同旧默认，实机验证正确)：AB 位置对齐(物理南→DC B、
# 东→DC A)、XY 走标签对齐(下面 XY 分支不触发)。保留下面 if 结构以维持输出完全一致。
EE_INVERT_AB="true"
EE_INVERT_XY="false"

if [[ "${EE_INVERT_AB}" == "true" ]]; then
  # AB位置对齐：物理南(a)→DC B、物理东(b)→DC A
  FLYCAST_D_BUTTONS[a]="btn_b"
  FLYCAST_D_BUTTONS[b]="btn_a"
fi
if [[ "${EE_INVERT_XY}" == "true" ]]; then
  # XY位置对齐：物理西(x)→DC Y、物理北(y)→DC X
  FLYCAST_D_BUTTONS[x]="btn_y"
  FLYCAST_D_BUTTONS[y]="btn_x"
fi

declare -A STICK_DIRECTIONS=(
  [axis_x,neg]="btn_analog_left"  [axis_x,pos]="btn_analog_right"
  [axis_y,neg]="btn_analog_up"    [axis_y,pos]="btn_analog_down"
  [axis_right_x,neg]="axis2_left" [axis_right_x,pos]="axis2_right"
  [axis_right_y,neg]="axis2_up"   [axis_right_y,pos]="axis2_down"
)


# Cleans all the inputs for the gamepad with name ${GAMEPAD} and player ${1}
clean_pad() {
  #echo "Cleaning pad ${1} ${2}" #debug
  [[ -f "${CONFIG_TMP_A}" ]] && rm "${CONFIG_TMP_A}"
  [[ -f "${CONFIG_TMP_D}" ]] && rm "${CONFIG_TMP_D}"
  [[ -f "${CONFIG_TMP_E}" ]] && rm "${CONFIG_TMP_E}"
  sed -i "s/device${1}\.2.*/device${1}.2 = 10/g" "${EMU_FILE}"
  sed -i "s/device${1}\.1.*/device${1}.1 = 10/g" "${EMU_FILE}"
  sed -i "s/device${1} .*/device${1} = 10/g" "${EMU_FILE}"
  local i=$(( ${1} - 1 ))
  sed -i "s/maple_sdl_joystick_${i}.*/maple_sdl_joystick_${i} = -1/g" "${EMU_FILE}"
}

# Sets pad depending on parameters.
# ${1} = Player Number
# ${2} = js[0-7]
# ${3} = Device GUID
# ${4} = Device Name

set_pad() {
  echo "set_pad params: ${1} ${2} ${3} ${4}"
  local JOY_NAME="${4}"
  local ORDER=${7}
  local i=$(( ${1} - 1 ))

  # Vars to dinamically set triggers
  local L_TR_AXIS=""
  local R_TR_AXIS=""

  sed -i "s/device${1} .*/device${1} = 0/g" "${EMU_FILE}"


  local device1=1
  local RUMBLE=$(get_ee_setting ee_rumble_strength)
  [[ -z "${RUMBLE}" ]] && RUMBLE=0
  [[ "${RUMBLE}" -gt "0" ]] && device1=3

  sed -i "s/device${1}\.1.*/device${1}.1 = ${device1}/g" "${EMU_FILE}"
  sed -i "s/device${1}\.2.*/device${1}.2 = 1/g" "${EMU_FILE}"
  sed -i "s/maple_sdl_joystick_${i}.*/maple_sdl_joystick_${i} = ${ORDER}/g" "${EMU_FILE}"

  local CONFIG="${MAPPING_DIR}/SDL_${JOY_NAME}.cfg"
  [[ -f "${CONFIG}" ]] && rm "${CONFIG}"

  > "${CONFIG_TMP_A}"; > "${CONFIG_TMP_D}"; > "${CONFIG_TMP_E}"

  local GC_CONFIG="${5}"
  [[ -z ${GC_CONFIG} ]] && return
  local GC_MAP=$(echo ${GC_CONFIG} | cut -d',' -f3-)
  set -f
  local GC_ARRAY=(${GC_MAP//,/ })

  local B_COUNT_A=0
  local B_COUNT_D=0

  # NOTE(w2xg2022): 捕捉SELECT/START/肩键L1R1/西键(X)各自的实体按键码，
  # 供下面统一生成[combo]组合键区块使用(flycast v4原生支持真正的按键组合，
  # 不需要gptokeyb外挂)。
  local NUM_SELECT="" NUM_START="" NUM_L1="" NUM_R1="" NUM_WESTX="" NUM_NORTHY=""

  for REC in "${GC_ARRAY[@]}"; do
      local KEY=$(echo ${REC} | cut -d ":" -f 1)
      local TVAL=$(echo ${REC} | cut -d ":" -f 2)
      local TYPE=${TVAL:0:1}
      local NUM=${TVAL:1}
      local ACTION=${FLYCAST_D_BUTTONS[${KEY}]}

      [[ -z "${ACTION}" ]] && continue

      if [[ "${TYPE}" == "a" ]]; then
          # ANALOG SECTION
          if [[ "${KEY}" == "leftx" || "${KEY}" == "lefty" || "${KEY}" == "rightx" || "${KEY}" == "righty" ]]; then
              echo "bind$((B_COUNT_A++)) = ${NUM}-:${STICK_DIRECTIONS[${ACTION},neg]}" >> "${CONFIG_TMP_A}"
              echo "bind$((B_COUNT_A++)) = ${NUM}+:${STICK_DIRECTIONS[${ACTION},pos]}" >> "${CONFIG_TMP_A}"
          else
              # ITS ANALOG TRIGGER
              echo "bind$((B_COUNT_A++)) = ${NUM}+:${ACTION}" >> "${CONFIG_TMP_A}"
              # SAVE IDS FOR LATER
              [[ "${KEY}" == "lefttrigger" ]] && L_TR_AXIS="${NUM}"
              [[ "${KEY}" == "righttrigger" ]] && R_TR_AXIS="${NUM}"
          fi

      elif [[ "${TYPE}" == "b" || "${TYPE}" == "h" ]]; then
          # DIGITAL SECTION
          local FINAL_NUM=${NUM}
          [[ "${TYPE}" == "h" ]] && FINAL_NUM=${FLYCAST_D_INDEXES[${TVAL}]}

          echo "bind$((B_COUNT_D++)) = ${FINAL_NUM}:${ACTION}" >> "${CONFIG_TMP_D}"
      fi

      # NOTE(w2xg2022): 只在实体按键(b类型)时记录，摇杆方向(h/a类型)不适用组合键。
      if [[ "${TYPE}" == "b" ]]; then
          case "${KEY}" in
              back)          NUM_SELECT="${NUM}" ;;
              start)         NUM_START="${NUM}" ;;
              leftshoulder)  NUM_L1="${NUM}" ;;
              rightshoulder) NUM_R1="${NUM}" ;;
              x)             NUM_WESTX="${NUM}" ;;
              # NOTE(w2xg2022 2026-08-02): 北键也要记 —— 任天堂式印刷时「印着 X 的那颗」
              #   在北(SDL 的 y),见下方组合键那段。
              y)             NUM_NORTHY="${NUM}" ;;
          esac
      fi
  done

  echo "[analog]" > "${CONFIG}"
  cat "${CONFIG_TMP_A}" | sort >> "${CONFIG}"

  # NOTE(w2xg2022 2026-08-02): ★修 SELECT 单键同时绑到 menu 与 escape★
  #   对照表里 [back]=btn_menu、[guide]=btn_escape。但**很多山寨 Xbox 手柄没有 Guide 键**,
  #   gamecontrollerdb 里 back 与 guide 会解析到同一个按键号 —— 实机(Microsoft X-Box 360 pad)
  #   产出就是 `bind2 = 6:btn_menu` 与 `bind7 = 6:btn_escape` 并存, SELECT 单按会同时
  #   触发呼出选单与退出, 行为未定义。
  #   处置: 撞号时**丢掉 escape 那条单键**, 保留 menu(呼出选单是主要用途);
  #   退出仍然可用, 走下面的 SELECT+START 组合键。
  if [[ -n "${NUM_SELECT}" ]]; then
      sed -i "/= ${NUM_SELECT}:btn_escape\$/d" "${CONFIG_TMP_D}"
  fi

  echo -e "\n[digital]" >> "${CONFIG}"
  cat "${CONFIG_TMP_D}" | sort >> "${CONFIG}"

  # NOTE(w2xg2022): 统一热键方案(比照RA菜单)：SELECT+START退出、SELECT+右肩键
  # 存档、SELECT+左肩键读档、SELECT+西键(印X)呼出菜单。sequential=0表示「同时
  # 按住」而非「依序按下」(flycast的ButtonCombo::sequential语义)。四者都要
  # SELECT有实际按键码才写入，缺任一方就跳过避免产生无效combo。flycast原生
  # 没有FPS显示切换的可绑定动作，此项无法比照RA做到，故不在此生成。
  if [[ -n "${NUM_SELECT}" ]]; then
    echo -e "\n[combo]" >> "${CONFIG}"
    local B_COUNT_C=0
    [[ -n "${NUM_START}" ]] && echo "bind$((B_COUNT_C++)) = ${NUM_SELECT},${NUM_START}:btn_escape:0" >> "${CONFIG}"
    [[ -n "${NUM_R1}" ]]    && echo "bind$((B_COUNT_C++)) = ${NUM_SELECT},${NUM_R1}:btn_quick_save:0" >> "${CONFIG}"
    [[ -n "${NUM_L1}" ]]    && echo "bind$((B_COUNT_C++)) = ${NUM_SELECT},${NUM_L1}:btn_jump_state:0" >> "${CONFIG}"
    # NOTE(w2xg2022 2026-08-02): ★呼出选单那一组改成跟着 ES 的印刷布局走★
    #   原本写死 NUM_WESTX(位置西), 注解假设「西 = 印着 X」—— 那只在 Xbox 式印刷成立。
    #   任天堂式手柄上西键印的是 Y, 选单就变成 SELECT+Y, 与 PSP 修好之前是同一个洞。
    #   位置本身不需要透传(SDL 语意键两边都从 gamecontrollerdb 推导, 本来就对齐);
    #   唯独「印着 X 的是哪一颗」是**印刷资讯**, 只有 ES 知道 —— 读 es_settings.cfg 的
    #   InvertButtons(GuiDetectLayout 只按一次 A 写入):
    #     false = Xbox 式(A 在南) → 印刷 X 在西
    #     true  = 任天堂式(A 在东) → 印刷 X 在北
    #   ⚠️ 还没侦测过时该键不存在 → 落回西键, 与改动前同值, 行为不变。
    #   与 PSP 的 ppsspp.sh 同一套判据, 两边要一起改, 别只改一边。
    local ES_SETTINGS="/storage/.config/emulationstation/es_settings.cfg"
    local NUM_MENUKEY="${NUM_WESTX}"
    if grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null; then
        [[ -n "${NUM_NORTHY}" ]] && NUM_MENUKEY="${NUM_NORTHY}"
    fi
    [[ -n "${NUM_MENUKEY}" ]] && echo "bind$((B_COUNT_C++)) = ${NUM_SELECT},${NUM_MENUKEY}:btn_menu:0" >> "${CONFIG}"
  fi

  echo -e "\n[emulator]" >> "${CONFIG}"
  echo "mapping_name = ${JOY_NAME}" >> "${CONFIG}"
  echo "version = 4" >> "${CONFIG}"
  echo "rumble_power = ${RUMBLE}" >> "${CONFIG}"

  if [[ ! -z "${L_TR_AXIS}" && ! -z "${R_TR_AXIS}" ]]; then
      echo "triggers = ${L_TR_AXIS},${R_TR_AXIS}" >> "${CONFIG}"
  fi

  cat "${CONFIG_TMP_E}" | sort -u >> "${CONFIG}"

  rm "${CONFIG_TMP_A}" "${CONFIG_TMP_D}" "${CONFIG_TMP_E}"
}

init_config() {
  mkdir -p "/storage/.config/flycast/mappings"

  # Adjust the emulator config file to load sdl controller files.
  if [[ ! -f "${EMU_FILE}" ]]; then
    echo "[input]" >> "${EMU_FILE}"

    local SDL_JOYSTICK="maple_sdl_joystick_0 = 0\nmaple_sdl_joystick_1 = 1\nmaple_sdl_joystick_2 = 2\nmaple_sdl_joystick_3 = 3\n"
    echo -e "${SDL_JOYSTICK}" >> "${EMU_FILE}"

    for i in {1..4}; do
      echo -e "device${i} = 0\ndevice${i}.1 = 1\ndevice{$i}.2 = 1\n" >> "${EMU_FILE}"
    done

    return
  fi

  local RUMBLE=$(get_ee_setting ee_rumble_strength)
  [[ -z "${RUMBLE}" ]] && RUMBLE=0

  jc_set_record "${EMU_FILE}" "\[input\]" "VirtualGamepadVibration" "${RUMBLE}"
}


init_config

jc_get_players
