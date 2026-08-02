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
  # NOTE(w2xg2022 2026-08-02 第三版): ★[back]="btn_menu" 已移除 —— 它是所有组合键失效的元凶★
  #   flycast 在**按键按下的当下就比对一次**(gamepad_device.cpp:168 一按下就
  #   get_button_id(currentInputs))。单键绑定与组合键存在**同一张表**
  #   (mapping.h:211 把单键包成「只有一个元素的 ButtonCombo」)。
  #   于是「SELECT 单按 = 开选单」一成立, 按下 SELECT 的瞬间选单就跳出来,
  #   第二颗键被选单介面吃掉 -> 退出/存档/读档三组**永远凑不成**。
  #   ★「单按开选单」与「当组合键的第一颗」在机制上互斥, 没有两全★, 故取后者:
  #   改成 热键+X 开选单, 与 RA / PSP 完全一致(三边同一套心智模型),
  #   代价只是开选单多按一颗, 换回存档/读档/退出三个功能。
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
#
# ★2026-08-02 复审结论:维持 AB 位置对齐, 别再改回标签对齐(已评估并否决)★
#   现象:flycast 选单要按**印着 B**(物理东)那颗才能确认, 与 ES/RA/PSP 相反。
#   机制:**flycast 选单没有独立的导航绑定**, 直接把 DC 的 A 当「确认」——
#     core/ui/gui.cpp:419  io.AddKeyEvent(ImGuiKey_GamepadFaceDown, kcode[0] & DC_BTN_A)
#   Dreamcast 原厂 A 在**东**, 位置对齐后物理东(印刷 B)→DC A, 所以是本设定的直接结果。
#   因为选单与游戏内共用同一份映射, **改选单必然连游戏内一起改, 没有两全** ——
#   用户裁定:游戏手感优先, 接受 DC 选单用东(印刷 B)确认。
#
#   PSP / RA 不受影响(三边情况各不相同, 别照抄):
#     RA  : 有选单专用开关 menu_swap_ok_cancel_buttons(=false), 确认已是物理南=印刷 A。
#     PSP : 与 DC 同样「选单吃游戏键」, 但 PPSSPP 用「✕」当确认, ✕ 本来就在南 = 印刷 A,
#           碰巧一致 —— DC 是唯一「原厂 A 不在南」的主机, 所以只有它会撞。
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

  # ★2026-08-02 真因:档名要用【SDL 映射名】, 不是核心名★
  #   flycast 组档名是 api_name() + "_" + name()(gamepad_device.cpp:552),
  #   而 SDL 对已识别手柄回传的 name() 是 **gamecontrollerdb 里的映射名**
  #   (本机: "Xbox 360 Controller"), 不是核心名(SDL_JoystickName: "Microsoft X-Box 360 pad")。
  #   原本写成核心名 -> flycast 找不到 -> 一路使用**内建预设映射**,
  #   我们产的整份设定(含 [combo])**从来没被读过**。
  #   ★这个洞极难发现★: 内建预设的游戏内按键刚好是对的、Back 又刚好开选单,
  #   看起来「设定有生效」, 只有组合键这种预设没有的东西才会暴露。
  #   实机验证: 同内容另存成 SDL_Xbox 360 Controller.cfg 后, SELECT+X 立刻能开选单。
  #   映射名 = gamecontrollerdb 那行的第 2 栏(第 1 栏是 GUID, 第 3 栏起是键位)。
  local GC_CONFIG="${5}"
  [[ -z ${GC_CONFIG} ]] && return
  local GC_NAME=$(echo "${GC_CONFIG}" | cut -d',' -f2)
  [[ -z "${GC_NAME}" ]] && GC_NAME="${JOY_NAME}"

  local CONFIG="${MAPPING_DIR}/SDL_${GC_NAME}.cfg"
  # 顺手清掉旧版留下的「核心名」那份, 免得目录里两个档看起来像都有效。
  [[ -f "${MAPPING_DIR}/SDL_${JOY_NAME}.cfg" ]] && rm -f "${MAPPING_DIR}/SDL_${JOY_NAME}.cfg"
  [[ -f "${CONFIG}" ]] && rm "${CONFIG}"

  > "${CONFIG_TMP_A}"; > "${CONFIG_TMP_D}"; > "${CONFIG_TMP_E}"

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
      # NOTE(w2xg2022): 只在实体按键(b类型)时记录，摇杆方向(h/a类型)不适用组合键。
      # ★2026-08-02 第三版:这段必须放在 `[[ -z "${ACTION}" ]] && continue` 【之前】★
      #   拿掉 [back]="btn_menu" 之后 back 在对照表里没有动作, 会被那行 continue 跳过,
      #   于是 NUM_SELECT 永远是空 -> NUM_HOTKEY 空 -> **整个 [combo] 区块被跳过**。
      #   实机踩过:产出只有 [digital]、没有 [combo]。记录按键码与「有没有 digital 动作」
      #   是两件事, 别绑在一起。
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

  done

  echo "[analog]" > "${CONFIG}"
  cat "${CONFIG_TMP_A}" | sort >> "${CONFIG}"

  # NOTE(w2xg2022 2026-08-02 第三版): ★热键(组合键的修饰键)一律从 ES 透传, 不写死★
  #   来源 = es_input.cfg 的 hotkeyenable(实体按键编号)。使用者在 ES 里改热键, 这里跟着改。
  #   读不到才退回 SDL 的 back —— 那只是保底, 不是预期路径。
  #   ★按【装置名】比对, 不能按 GUID★: SDL 2.26+ 在 GUID 里塞了 CRC-16,
  #   执行期取到 030081b85e04...、ES 记的是 030000005e04..., 按 GUID 必然【静默】落空。
  local ES_INPUT="/storage/.config/emulationstation/es_input.cfg"
  local NUM_HOTKEY="${NUM_SELECT}"
  if [[ -f "${ES_INPUT}" && -n "${JOY_NAME:-}" ]]; then
      local HK
      HK=$(awk -v nm="deviceName=\"${JOY_NAME}\"" '
          index($0, nm) { inblock=1 }
          inblock && /name="hotkeyenable"/ && /type="button"/ {
              if (match($0, /id="[0-9]+"/)) { print substr($0, RSTART+4, RLENGTH-5); exit }
          }
          inblock && /<\/inputConfig>/ { inblock=0 }
      ' "${ES_INPUT}")
      if [[ -n "${HK}" ]]; then
          NUM_HOTKEY="${HK}"
          echo "es4all: hotkey from ES = button ${HK}"
      fi
  fi

  # ★热键那颗绝不能留任何单键绑定★(原理见档案上方 [back] 那段注解):
  #   只要它单独一颗就有作用, flycast 在按下的瞬间就触发, 组合键永远凑不成。
  #   [back]=btn_menu 已从对照表移除; [guide]=btn_escape 在**没有独立 Guide 键**的手柄上
  #   会与 back 撞号(实机 X-Box 360 pad 两者都解析成 6), 产出单键 escape —— 一并删掉。
  if [[ -n "${NUM_HOTKEY}" ]]; then
      sed -i "/= ${NUM_HOTKEY}:btn_escape\$/d" "${CONFIG_TMP_D}"
      sed -i "/= ${NUM_HOTKEY}:btn_menu\$/d" "${CONFIG_TMP_D}"
  fi

  # NOTE(w2xg2022 2026-08-02): ★删完必须重新编号★
  #   上面两处 sed -d(拿掉撞号的 escape 单键、把选单移到 ES 热键)会在 bindN 留下
  #   **编号空洞** —— 实测产出过 bind0..bind6 + bind8..bind12(bind7 不见了)。
  #   flycast 若是从 bind0 逐一往下读、遇缺号就停, 后面那几个(L1/R1/START/X/Y)会全失效。
  #   没去确认它容不容忍空洞 —— 但留着毫无好处, 这里按原顺序重排成连续编号。
  awk -F' = ' '{ print "bind" (n++) " = " $2 }' "${CONFIG_TMP_D}" > "${CONFIG_TMP_D}.renum" \
      && mv -f "${CONFIG_TMP_D}.renum" "${CONFIG_TMP_D}"

  echo -e "\n[digital]" >> "${CONFIG}"
  cat "${CONFIG_TMP_D}" | sort >> "${CONFIG}"

  # NOTE(w2xg2022): 统一热键方案(比照RA菜单)：SELECT+START退出、SELECT+右肩键
  # 存档、SELECT+左肩键读档、SELECT+西键(印X)呼出菜单。sequential=0表示「同时
  # 按住」而非「依序按下」(flycast的ButtonCombo::sequential语义)。四者都要
  # SELECT有实际按键码才写入，缺任一方就跳过避免产生无效combo。flycast原生
  # 没有FPS显示切换的可绑定动作，此项无法比照RA做到，故不在此生成。
  # NOTE(w2xg2022 2026-08-02 第三版): 四组组合键, ★修饰键与选单键都从 ES 透传, 一个都不写死★
  #   修饰键 = NUM_HOTKEY(上面从 es_input.cfg 的 hotkeyenable 取得; 读不到才退回 back)
  #   选单键 = 「印着 X 的那颗」。位置资讯两边本来就对齐(都从 gamecontrollerdb 推导),
  #            但**印刷资讯只有 ES 知道**, 故读 es_settings.cfg 的 InvertButtons:
  #              false = Xbox 式(A 在南) → 印刷 X 在西
  #              true  = 任天堂式(A 在东) → 印刷 X 在北
  #   sequential=0 = 「同时按住」而非「依序按下」(flycast ButtonCombo::sequential)。
  #   缺任一颗就跳过该组, 避免产生无效 combo。
  #   ⚠️ flycast 原生没有 FPS 显示切换的可绑定动作, 这项无法比照 RA 做到。
  if [[ -n "${NUM_HOTKEY}" ]]; then
    echo -e "
[combo]" >> "${CONFIG}"
    local B_COUNT_C=0
    [[ -n "${NUM_START}" ]] && echo "bind$((B_COUNT_C++)) = ${NUM_HOTKEY},${NUM_START}:btn_escape:0" >> "${CONFIG}"
    [[ -n "${NUM_R1}" ]]    && echo "bind$((B_COUNT_C++)) = ${NUM_HOTKEY},${NUM_R1}:btn_quick_save:0" >> "${CONFIG}"
    [[ -n "${NUM_L1}" ]]    && echo "bind$((B_COUNT_C++)) = ${NUM_HOTKEY},${NUM_L1}:btn_jump_state:0" >> "${CONFIG}"

    local ES_SETTINGS="/storage/.config/emulationstation/es_settings.cfg"
    local NUM_MENUKEY="${NUM_WESTX}"
    if grep -q '"InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null; then
        [[ -n "${NUM_NORTHY}" ]] && NUM_MENUKEY="${NUM_NORTHY}"
    fi
    [[ -n "${NUM_MENUKEY}" ]] && echo "bind$((B_COUNT_C++)) = ${NUM_HOTKEY},${NUM_MENUKEY}:btn_menu:0" >> "${CONFIG}"
  fi

  echo -e "\n[emulator]" >> "${CONFIG}"
  echo "mapping_name = ${GC_NAME}" >> "${CONFIG}"
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
