#!/bin/bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2020-present Shanti Gilbert (https://github.com/shantigilbert)

# Source predefined functions and variables
. /etc/profile

# Configure ADVMAME players based on ES settings
CONFIG_DIR="/storage/.config/ppsspp/PSP/SYSTEM"
CONFIG=${CONFIG_DIR}/controls.ini
#CONFIG2=${CONFIG_DIR}/controls.ini

CONFIG_TMP=/tmp/jc/ppsspp.tmp


source joy_common.sh "ppsspp" "fixed_order"

declare -A GC_PPSSPP_VALUES=(
  [h0.1]="10-19" #Up
  [h0.4]="10-20" #Down
  [h0.8]="10-21" #Left
  [h0.2]="10-22" #Right
  # NOTE(w2xg2022): 位置对齐(参考rocknix-psp-standalone-keymap)：标准SDL按钮顺序
  # b0=南/A、b1=东/B、b2=西/X、b3=北/Y，各绑到该实体位置产生的PPSSPP device-10 NKCODE
  # (实测南A=189/东B=190/西X=191/北Y=188)。原值b0=190/b1=189/b2=188/b3=191 刚好
  # A↔B、X↔Y 对调(会造成✕○□△错位)。⚠️10-xxx码随手把SDL枚举而定，X98mini实体上机
  # 需实测✕(应在南=确定)○□△是否对齐，不对再回调。
  [b0]="10-189"
  [b1]="10-190"
  [b2]="10-191"
  [b3]="10-188"
  [b4]="10-193"
  [b5]="10-192"
  [b6]="10-196"
  [b7]="10-197"
  [b8]="10-196" # back
  [b9]="10-197" # start
  [b10]="" # usually home.
  [b11]="10-106" #leftstick
  [b12]="10-107" #rightstick
  [b13]="10-19" # up
  [b14]="10-20" # down
  [b15]="10-21" # left
  [b16]="10-22" # right
  [a0-0]="10-4001"
  [a0-1]="10-4000"
  [a1-0]="10-4003"
  [a1-1]="10-4002"
  [a2]="10-4010" #lefttrigger
	[a3]="10-4011" #righttrigger
	[a4]="10-4010" #lefttrigger
  [a5]="10-4011" #righttrigger
)

declare -A KB_PPSSPP_VALUES=(
  [h0.1]="1-19" #Up
  [h0.4]="1-20" #Down
  [h0.8]="1-21" #Left
  [h0.2]="1-22" #Right

  [b0]="1-52"
  [b1]="1-54"
  [b2]="1-47"
  [b3]="1-29"
  [b4]="1-45"
  [b5]="1-51"
  [b6]="1-66"
  [b7]="1-62"

  [a0-0]="1-38"
  [a0-1]="1-40"
  [a1-0]="1-37"
  [a1-1]="1-39"
)

# NOTE(w2xg2022): 基准为「位置对齐」——物理位置(SDL名a=南/b=东/x=西/y=北)映射到
# 该位置的PSP符号(南=✕Cross、东=○Circle、西=□Square、北=△Triangle)，配合下面
# GC_PPSSPP_VALUES的b0-b3(南189/东190/西191/北188)达成✕○□△几何对齐。
# ⚠️旧版这里是全对调状态(南→Circle等)，端到端追踪根本没对齐，本次一并修正。
# 之后由ES的InvertGameButtons/InvertXYButtons决定是否翻转(见下方)。PSP无字母标签，
# 「位置对齐」即其唯一自然基准。
declare -A GC_PPSSPP_BUTTONS=(
  [dpleft]="Left"
  [dpright]="Right"
  [dpup]="Up"
  [dpdown]="Down"
  [a]="Cross"
  [b]="Circle"
  [x]="Square"
  [y]="Triangle"
  [back]="Select"
  [start]="Start"
  [leftshoulder]="L"
  [rightshoulder]="R"
  [leftx-0]="An.Left"
  [leftx-1]="An.Right"
  [lefty-0]="An.Up"
  [lefty-1]="An.Down"
)

# NOTE(w2xg2022): 手柄三层架构定案(2026-07)——第三层「游戏内」一律「写死原厂位置对齐」，
# 不再透传、不再看任何 ES 开关(原 InvertGameButtons/InvertXYButtons 已从 ES 移除)。
# ★2026-07-12 X98mini 实机修正★:SDL 语义键 a=南/b=东/x=西/y=北 本就位置对齐,
# GC_PPSSPP_BUTTONS 默认表(a=Cross南/b=Circle东/x=Square西/y=Triangle北)即正确;
# 但 `if EE_INVERT_XY=="false"` 分支会把 x/y 错误 swap 成 x=Triangle/y=Square(反逻辑),
# 故 AB/XY 都必须设 true 跳过对应 swap 段,才是位置对齐(南✕东○西□北△,实机确认)。
EE_INVERT_AB="true"
EE_INVERT_XY="true"

if [[ "${EE_INVERT_AB}" == "false" ]]; then
  GC_PPSSPP_BUTTONS[a]="Circle"
  GC_PPSSPP_BUTTONS[b]="Cross"
fi
if [[ "${EE_INVERT_XY}" == "false" ]]; then
  GC_PPSSPP_BUTTONS[x]="Triangle"
  GC_PPSSPP_BUTTONS[y]="Square"
fi

# Cleans all the inputs for the gamepad with name ${GAMEPAD} and player ${1}
clean_pad() {
  [[ "${1}" != "1" ]] && return
  [[ -f "${CONFIG_TMP}" ]] && rm "${CONFIG_TMP}"
  [[ ! -f "${CONFIG}" ]] && return
	grep -m 1 "Analog limiter =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "RapidFire =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Unthrottle =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "SpeedToggle =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Pause =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Pause (no menu) =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Rewind =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Toggle Debugger =" ${CONFIG} >> ${CONFIG_TMP}
	# NOTE(w2xg2022): 保留统一热键组合键行(SELECT+START退出/SELECT+R1存档/SELECT+L1读档)，
	# 否则auto_gamepad每次重建controls.ini会把controls.ini模板里预置的这几行洗掉。
	grep -m 1 "Exit App =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Save State =" ${CONFIG} >> ${CONFIG_TMP}
	grep -m 1 "Load State =" ${CONFIG} >> ${CONFIG_TMP}
	rm ${CONFIG}
}

# Sets pad depending on parameters.
# ${1} = Player Number
# ${2} = js[0-7]
# ${3} = Device GUID
# ${4} = Device Name

set_pad() {
  [[ "${1}" != "1" ]] && return

  local DEVICE_GUID=${3}

  echo "DEVICE_GUID=${DEVICE_GUID}"

  local GC_CONFIG="${5}"
  echo "GC_CONFIG=${GC_CONFIG}"
  [[ -z ${GC_CONFIG} ]] && return

  local GC_MAP=$(echo ${GC_CONFIG} | cut -d',' -f3-)

  local L_VAL=
  local R_VAL=

  set -f
  local GC_ARRAY=(${GC_MAP//,/ })
  for index in "${!GC_ARRAY[@]}"
  do
      local REC=${GC_ARRAY[${index}]}
      local BUTTON_INDEX=$(echo ${REC} | cut -d ":" -f 1)
      local TVAL=$(echo ${REC} | cut -d ":" -f 2)
      local BUTTON_VAL=${TVAL:1}
      local GC_INDEX="${GC_PPSSPP_BUTTONS[${BUTTON_INDEX}]}"
      local BTN_TYPE=${TVAL:0:1}
      local VAL="${GC_PPSSPP_VALUES[${TVAL}]}"
      local KBVAL="${KB_PPSSPP_VALUES[${TVAL}]}"

      local RECORD
      # CREATE BUTTON MAPS (inlcuding hats).
      if [[ ! -z "${GC_INDEX}" ]]; then
        if [[ "${BTN_TYPE}" == "b"  || "${BTN_TYPE}" == "h" ]]; then
          if [[ ! -z "${VAL}" ]]; then
            [[ ! -z "${KBVAL}" ]] && echo "${GC_INDEX} = ${KBVAL},${VAL}" >> ${CONFIG_TMP}
            [[ -z "${KBVAL}" ]] && echo "${GC_INDEX} = ${VAL}" >> ${CONFIG_TMP}
          fi
        fi
      fi
#      if [[ "${BTN_TYPE}" == "a" ]]; then
#        echo "BINDEX=${BUTTON_INDEX}"
#        [[ "${BUTTON_INDEX}" == "lefttrigger" ]] && L_VAL=${VAL} && echo "LVAL=${VAL}"
#        [[ "${BUTTON_INDEX}" == "righttrigger" ]] && R_VAL=${VAL} && echo "RVAL=${VAL}"
#      fi

      # Create Axis Maps
      case ${BUTTON_INDEX} in
        leftx|lefty)
          GC_INDEX="${GC_PPSSPP_BUTTONS[${BUTTON_INDEX}-0]}"
          VAL="${GC_PPSSPP_VALUES[${TVAL}-0]}"
          KBVAL="${KB_PPSSPP_VALUES[${TVAL}-0]}"
          echo "${GC_INDEX} = ${KBVAL},${VAL}" >> ${CONFIG_TMP}

          GC_INDEX="${GC_PPSSPP_BUTTONS[${BUTTON_INDEX}-1]}"
          VAL="${GC_PPSSPP_VALUES[${TVAL}-1]}"
          KBVAL="${KB_PPSSPP_VALUES[${TVAL}-1]}"
          echo "${GC_INDEX} = ${KBVAL},${VAL}" >> ${CONFIG_TMP}
          ;;
      esac
  done

#  [[ ! -z "${L_VAL}" ]] && sed -i -r "s|L = (.*)|L = \1,${L_VAL}|g" "${CONFIG_TMP}"
#  [[ ! -z "${R_VAL}" ]] && sed -i -r "s|R = (.*)|R = \1,${R_VAL}|g" "${CONFIG_TMP}"

  echo "[ControlMapping]" > ${CONFIG}
  cat "${CONFIG_TMP}" | sort >> ${CONFIG}
  rm "${CONFIG_TMP}"
}

jc_get_players
