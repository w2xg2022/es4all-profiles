#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#
# Modified 2019 by Shanti Gilbert for EmuELEC/CoreELEC (https//www.coreelec.org)

# Function to find udev device name using /proc/bus/input/devices from a SDL GUID
get_udev_name_from_guid() {
    local guid="$1"

    if [[ ! "$guid" =~ ^[0-9A-Fa-f]{32}$ ]]; then
        echo "Invalid GUID format" >&2
        return 1
    fi

    guid=${guid,,}  # lowercase for safety

    # Helper: swap endian (little → big)
    swap_endian() {
        echo "$1" | sed 's/\(..\)\(..\)/\2\1/'
    }

    # Extract relevant fields (note: byte order)
    local bus_le=${guid:0:4}
    local vendor_le=${guid:8:4}
    local product_le=${guid:16:4}
    local version_le=${guid:24:4}

    local bus=$(swap_endian "$bus_le")
    local vendor=$(swap_endian "$vendor_le")
    local product=$(swap_endian "$product_le")
    local version=$(swap_endian "$version_le")

    # Find the block starting with I: that matches all three fields
    local name
    name=$(sed -n "/I:.*Bus=${bus}.*Vendor=${vendor}.*Product=${product}/,/^$/p" /proc/bus/input/devices \
        | sed -n 's/^N: Name="\([^"]*\)"/\1/p' \
        | head -n1)

    if [[ -n "$name" ]]; then
        echo "$name"
    else
    #fall back to ES name 
        echo "${DEVICE_NAME}"
    fi
}


function onstart_retroarch_joystick() {
    iniConfig " = " '"' "${configdir}/retroarch/retroarch.cfg"
    iniGet "input_joypad_driver"
    local input_joypad_driver="${ini_value}"
    if [[ -z "${input_joypad_driver}" ]]; then
        input_joypad_driver="udev"
    fi

    _retroarch_select_hotkey=1

    _atebitdo_hack=0
    getAutoConf "8bitdo_hack" && _atebitdo_hack=1

    # NOTE(w2xg2022 2026-08-05): ★暂存档必须【每个行程一份】, 不能用写死的共用路径★
    #
    #   键位精灵存档时, 这支脚本会被【同时】叫两次:
    #     ① ES 自己 —— es_input.cfg 里的 <inputAction type="onfinish">
    #     ② es4all 的 controls-changed 钩子(10-inputconfig.sh)
    #   两边共用 /tmp/tempconfig.cfg, 谁先跑完就把它 mv 到 /tmp/joypads/,
    #   另一边接下来的 sed/mv 全部扑空:
    #       sed: /tmp/tempconfig.cfg: No such file or directory
    #       mv: can't rename '/tmp/tempconfig.cfg': No such file or directory
    #   ★而失败的那一边【已经先把旧的 joypad 档改名成 .bak 了】★ ——
    #   於是正本没了、新的也没产出, RA 直接显示「未配置」, 手柄进游戏就失效。
    #   跑几次就叠几层 .bak(实机看到 .cfg.bak.bak.bak.bak)。
    #
    #   ⚠️ 钩子里原本的注解写「两条同时存在也没关系, 事件是同步执行的、
    #      跑完才轮到 doOnFinish」—— ★那个假设在实机上不成立★(2026-08-05 MD1000/EmuELEC)。
    #      与其去赌执行顺序, 不如让两边各用各的暂存档: $$ 是行程 PID, 天生不会撞。
    ES4ALL_TMPCFG="/tmp/tempconfig.$$.cfg"
    iniConfig " = " "\"" "${ES4ALL_TMPCFG}"

    v=${DEVICE_GUID:8:8}
    part1=$(echo ${v:6:2}${v:4:2}${v:2:2}${v:0:2})
    v=${DEVICE_GUID:16:8}
    part2=$(echo ${v:6:2}${v:4:2}${v:2:2}${v:0:2})
   
    input_vendor=$(echo $((16#${part1:4})))
    input_product=$(echo $((16#${part2:4})))

    # es4all: 面键要按【位置】写进 autoconfig, 不是按印刷字母。
    #
    # ★为什么在这里做, 而不是留给 per-core remap★
    #   RetroPad 的 A/B/X/Y 本身就是固定方位(A东 B南 X北 Y西)。以前的做法是这里照印刷
    #   字母抄, 再由 setsettings.sh 写一份 per-core remap 把 A/B 扳回位置 —— 但那是
    #   「翻转」语意: 正确与否取决于原本是哪一套, 而且它写死只翻 A/B、不翻 X/Y,
    #   于是四颗面键用了两套规则(A/B 位置对齐、X/Y 标签对齐)。实机就是这样一半对一半错。
    #   ★「一半对一半错」正是双重错误的徵兆★ —— 别只修露馅的那一半。
    #   改成这里一次写死方位, 就没有「翻了几次」可以数错, 任天堂式/Xbox 式走同一条路,
    #   per-core remap 那层整个不需要(已由 override 的 setsettings.sh 移除并清理旧档)。
    #
    # ★方位从哪来★: es_input.cfg 的 a/b/x/y 是【印刷字母 → 实体按键编号】,
    #   ES 的 InvertButtons 记的是【印刷字母在哪个方位】(布局侦测的结果, 精灵只问一次 A)。
    #
    # ★★极性: true = 任天堂式(印刷 A 在东)、false = Xbox 式(印刷 A 在南)★★
    #   这是【与系统其余部分一致】的那一套, 别自己另外推:
    #     GuiDetectLayout                : 按到 BTN_EAST(A 在东) -> 存 true
    #     set_flycast_joy.sh / ppsspp.sh : true -> 南=b 东=a 西=y 北=x (即 A 在东)
    #   ⚠️ ES 内部的 InputConfig::buttonDisplayName / buttonImage 用的是**相反**的解读
    #      (true -> 逻辑 a 显示成 SOUTH)。★那一处才是异类★, 别拿它当基准。
    #      实机 2026-08-03 我就是照它推, 把这里写反 -> 四颗面键全歪, 而同一台的 PSP/DC
    #      却是对的(它们照的是上面那套)。**同一个旗标被多处消费时, 基准是「多数 + 实机
    #      验证过的那一套」, 不是最先读到的那一处。**
    #
    #   两者一凑才得到「方位 → 实体编号」。★这是唯一可靠的来源★ ——
    #   gamecontrollerdb 对山寨手柄常按【字母】写而不是按位置, 拿它当方位用会静默错。
    ES_SETTINGS="/storage/.config/emulationstation/es_settings.cfg"
    # 需要换算的是 **Xbox 式**(印刷与 RetroPad 方位不一致), 即 InvertButtons 非 true。
    # 任天堂式(true)时印刷与方位天生一致, 直通即可。
    ES_LAYOUT_XBOX=1
    if grep -q '<bool name="InvertButtons" value="true"' "${ES_SETTINGS}" 2>/dev/null; then
        ES_LAYOUT_XBOX=0
    fi

    RA_DEVICE_NAME=$(get_udev_name_from_guid "${DEVICE_GUID}")
    iniSet "input_device" "${RA_DEVICE_NAME}"
    iniSet "input_driver" "${input_joypad_driver}"
    iniSet "input_vendor_id" "${input_vendor}"
    iniSet "input_product_id" "${input_product}"

    
}

function onstart_retroarch_keyboard() {
    iniConfig " = " '"' "${configdir}/retroarch/retroarch.cfg"

    _retroarch_select_hotkey=1

    declare -Ag retroarchkeymap
    # SDL codes from https://wiki.libsdl.org/SDLKeycodeLookup
    retroarchkeymap["1073741904"]="left"
    retroarchkeymap["1073741903"]="right"
    retroarchkeymap["1073741906"]="up"
    retroarchkeymap["1073741905"]="down"
    retroarchkeymap["13"]="enter"
    retroarchkeymap["1073741912"]="kp_enter"
    retroarchkeymap["9"]="tab"
    retroarchkeymap["1073741897"]="insert"
    retroarchkeymap["127"]="del"
    retroarchkeymap["1073741901"]="end"
    retroarchkeymap["1073741898"]="home"
    retroarchkeymap["1073742053"]="rshift"
    retroarchkeymap["1073742049"]="shift"
    retroarchkeymap["1073742048"]="ctrl"
    retroarchkeymap["1073742050"]="alt"
    retroarchkeymap["32"]="space"
    retroarchkeymap["27"]="escape"
    retroarchkeymap["43"]="add"
    retroarchkeymap["45"]="subtract"
    retroarchkeymap["1073741911"]="kp_plus"
    retroarchkeymap["1073741910"]="kp_minus"
    retroarchkeymap["1073741882"]="f1"
    retroarchkeymap["1073741883"]="f2"
    retroarchkeymap["1073741884"]="f3"
    retroarchkeymap["1073741885"]="f4"
    retroarchkeymap["1073741886"]="f5"
    retroarchkeymap["1073741887"]="f6"
    retroarchkeymap["1073741888"]="f7"
    retroarchkeymap["1073741889"]="f8"
    retroarchkeymap["1073741890"]="f9"
    retroarchkeymap["1073741891"]="f10"
    retroarchkeymap["1073741892"]="f11"
    retroarchkeymap["1073741893"]="f12"
    retroarchkeymap["48"]="num0"
    retroarchkeymap["49"]="num1"
    retroarchkeymap["50"]="num2"
    retroarchkeymap["51"]="num3"
    retroarchkeymap["52"]="num4"
    retroarchkeymap["53"]="num5"
    retroarchkeymap["54"]="num6"
    retroarchkeymap["55"]="num7"
    retroarchkeymap["56"]="num8"
    retroarchkeymap["57"]="num9"
    retroarchkeymap["1073741899"]="pageup"
    retroarchkeymap["1073741902"]="pagedown"
    retroarchkeymap["1073741922"]="keypad0"
    retroarchkeymap["1073741913"]="keypad1"
    retroarchkeymap["1073741914"]="keypad2"
    retroarchkeymap["1073741915"]="keypad3"
    retroarchkeymap["1073741916"]="keypad4"
    retroarchkeymap["1073741917"]="keypad5"
    retroarchkeymap["1073741918"]="keypad6"
    retroarchkeymap["1073741919"]="keypad7"
    retroarchkeymap["1073741920"]="keypad8"
    retroarchkeymap["1073741921"]="keypad9"
    retroarchkeymap["46"]="period"
    retroarchkeymap["1073741881"]="capslock"
    retroarchkeymap["1073741907"]="numlock"
    retroarchkeymap["8"]="backspace"
    retroarchkeymap["42"]="multiply"
    retroarchkeymap["47"]="divide"
    retroarchkeymap["1073741894"]="print_screen"
    retroarchkeymap["1073741895"]="scroll_lock"
    retroarchkeymap["96"]="backquote"
    retroarchkeymap["1073741896"]="pause"
    retroarchkeymap["39"]="quote"
    retroarchkeymap["44"]="comma"
    retroarchkeymap["45"]="minus"
    retroarchkeymap["47"]="slash"
    retroarchkeymap["59"]="semicolon"
    retroarchkeymap["61"]="equals"
    retroarchkeymap["91"]="leftbracket"
    retroarchkeymap["92"]="backslash"
    retroarchkeymap["93"]="rightbracket"
    retroarchkeymap["1073741923"]="kp_period"
    retroarchkeymap["1073741927"]="kp_equals"
    retroarchkeymap["1073742052"]="rctrl"
    retroarchkeymap["1073742054"]="ralt"
    retroarchkeymap["97"]="a"
    retroarchkeymap["98"]="b"
    retroarchkeymap["99"]="c"
    retroarchkeymap["100"]="d"
    retroarchkeymap["101"]="e"
    retroarchkeymap["102"]="f"
    retroarchkeymap["103"]="g"
    retroarchkeymap["104"]="h"
    retroarchkeymap["105"]="i"
    retroarchkeymap["106"]="j"
    retroarchkeymap["107"]="k"
    retroarchkeymap["108"]="l"
    retroarchkeymap["109"]="m"
    retroarchkeymap["110"]="n"
    retroarchkeymap["111"]="o"
    retroarchkeymap["112"]="p"
    retroarchkeymap["113"]="q"
    retroarchkeymap["114"]="r"
    retroarchkeymap["115"]="s"
    retroarchkeymap["116"]="t"
    retroarchkeymap["117"]="u"
    retroarchkeymap["118"]="v"
    retroarchkeymap["119"]="w"
    retroarchkeymap["120"]="x"
    retroarchkeymap["121"]="y"
    retroarchkeymap["122"]="z"

    # special case for disabled hotkey
    retroarchkeymap["0"]="nul"
}

# es4all: 印刷字母 -> 该按键实际所在方位对应的 RetroPad 面键。
#   Xbox 式(印刷 A 在南): 印刷A=南->RetroPad B, 印刷B=东->A, 印刷X=西->Y, 印刷Y=北->X
#   任天堂式(印刷 A 在东): 印刷与方位本来就一致 -> 原样
# ES 没有这个设定(旧机器/还没跑过精灵)时走 ES 的预设值 false = 任天堂式, 与原行为相同。
function face_key() {
    if [[ "${ES_LAYOUT_XBOX}" -eq 1 ]]; then
        case "${1}" in
            a) echo "b" ;;
            b) echo "a" ;;
            x) echo "y" ;;
            y) echo "x" ;;
        esac
    else
        echo "${1}"
    fi
}

function map_retroarch_joystick() {
    local input_name="${1}"
    local input_type="${2}"
    local input_id="${3}"
    local input_value="${4}"

    local keys
    case "${input_name}" in
        up)
            keys=("input_up" "input_volume_up")
            ;;
        down)
            keys=("input_down" "input_volume_down")
            ;;
        left)
            keys=("input_left" "input_state_slot_decrease")
            ;;
        right)
            keys=("input_right" "input_state_slot_increase")
            ;;
        # es4all: 面键分两半处理 ——
        #   input_<abxy>   = 按【位置】(face_key 换算, 见 onstart 的说明)
        #   伴生的热键组合 = 按【印刷】不动(input_reset/menu_toggle/fps_toggle)
        # 这不是不一致, 是三层架构里刻意的分工: 游戏内按位置、组合键按印刷
        # (使用者记的是手柄上印的字, 而热键提示也都写印刷字母)。
        a)
            keys=("input_$(face_key a)")
            ;;
        b)
            keys=("input_$(face_key b)" "input_reset")
            ;;
        x)
            keys=("input_$(face_key x)" "input_menu_toggle")
            ;;
        y)
            keys=("input_$(face_key y)" "input_fps_toggle")
            ;;
        leftbottom|leftshoulder)
            keys=("input_l" "input_load_state")
            ;;
        rightbottom|rightshoulder)
            keys=("input_r" "input_save_state")
            ;;
        lefttop|lefttrigger)
            keys=("input_l2" "input_rewind")
            ;;
        righttop|righttrigger)
            keys=("input_r2" "input_toggle_fast_forward")
            ;;
        leftthumb)
            keys=("input_l3")
            ;;
        rightthumb)
            keys=("input_r3")
            ;;
        start)
            keys=("input_start" "input_exit_emulator")
            ;;
        select)
            keys=("input_select")
            ;;
        leftanalogleft)
            keys=("input_l_x_minus")
            ;;
        leftanalogright)
            keys=("input_l_x_plus")
            ;;
        leftanalogup)
            keys=("input_l_y_minus")
            ;;
        leftanalogdown)
            keys=("input_l_y_plus")
            ;;
        rightanalogleft)
            keys=("input_r_x_minus")
            ;;
        rightanalogright)
            keys=("input_r_x_plus")
            ;;
        rightanalogup)
            keys=("input_r_y_minus")
            ;;
        rightanalogdown)
            keys=("input_r_y_plus")
            ;;
        hotkeyenable)
            keys=("input_enable_hotkey")
            _retroarch_select_hotkey=0
            if [[ "${input_type}" == "key" && "${input_id}" == "0" ]]; then
                return
            fi
            ;;
        *)
            return
            ;;
    esac

    local key
    local value
    local type
    for key in "${keys[@]}"; do
        case "${input_type}" in
            hat)
                type="btn"
                value="h${input_id}${input_name}"
                ;;
            axis)
                type="axis"
                if [[ "${input_value}" == "1" ]]; then
                    value="+${input_id}"
                else
                    value="-${input_id}"
                fi
                ;;
            *)
                type="btn"
                value="${input_id}"

                # workaround for mismatched controller mappings
                iniGet "input_driver"
                if [[ "${ini_value}" == "udev" ]]; then
                    case "${RA_DEVICE_NAME}" in
                        "8Bitdo FC30"*|"8Bitdo NES30"*|"8Bitdo SFC30"*|"8Bitdo SNES30"*|"8Bitdo Zero"*)
                            if [[ "$_atebitdo_hack" -eq 1 ]]; then
                                value="$((input_id+11))"
                            fi
                            ;;
                    esac
                fi
                ;;
        esac
        if [[ "${input_name}" == "select" && "$_retroarch_select_hotkey" -eq 1 ]]; then
            _retroarch_select_type="${type}"
        fi
        key+="_${type}"
        iniSet "${key}" "${value}"
    done
}

function map_retroarch_keyboard() {
    local input_name="${1}"
    local input_type="${2}"
    local input_id="${3}"
    local input_value="${4}"

    local key
    case "${input_name}" in
        up)
            keys=("input_player1_up")
            ;;
        down)
            keys=("input_player1_down")
            ;;
        left)
            keys=("input_player1_left" "input_state_slot_decrease")
            ;;
        right)
            keys=("input_player1_right" "input_state_slot_increase")
            ;;
        a)
            keys=("input_player1_a")
            ;;
        b)
            keys=("input_player1_b" "input_reset")
            ;;
        x)
            keys=("input_player1_x" "input_menu_toggle")
            ;;
        y)
            keys=("input_player1_y")
            ;;
        leftbottom|leftshoulder)
            keys=("input_player1_l")
            ;;
        rightbottom|rightshoulder)
            keys=("input_player1_r")
            ;;
        lefttop|lefttrigger)
            keys=("input_player1_l2")
            ;;
        righttop|righttrigger)
            keys=("input_player1_r2")
            ;;
        leftthumb)
            keys=("input_player1_l3")
            ;;
        rightthumb)
            keys=("input_player1_r3")
            ;;
        start)
            keys=("input_player1_start" "input_exit_emulator")
            ;;
        select)
            keys=("input_player1_select")
            ;;
        hotkeyenable)
            keys=("input_enable_hotkey")
            _retroarch_select_hotkey=0
            ;;
        *)
            return
            ;;
    esac

    for key in "${keys[@]}"; do
        iniSet "${key}" "${retroarchkeymap[${input_id}]}"
    done
}

function onend_retroarch_joystick() {
    # if $_retroarch_select_hotkey is set here, then there was no hotkeyenable button
    # in the configuration, so we should use the select button as hotkey enable if set
    if [[ "$_retroarch_select_hotkey" -eq 1 ]]; then
        iniGet "input_select_${_retroarch_select_type}"
        [[ -n "${ini_value}" ]] && iniSet "input_enable_hotkey_${_retroarch_select_type}" "${ini_value}"
    fi

    # hotkey sanity check
    # remove hotkeys if there is no hotkey enable button
    if ! grep -q "input_enable_hotkey" "${ES4ALL_TMPCFG}"; then
        local key
        for key in input_toggle_fast_forward input_rewind input_fps_toggle input_volume_up input_volume_down input_state_slot_decrease input_state_slot_increase input_reset input_menu_toggle input_load_state input_save_state input_exit_emulator; do
            sed -i "/${key}/d" "${ES4ALL_TMPCFG}"
        done
    fi

    # disable any auto configs for the same device to avoid duplicates
    local file
    local dir="/tmp/joypads"
    while read -r file; do
        mv "${file}" "${file}.bak" > /dev/null 2>&1
    done < <(grep -Fl "\"${RA_DEVICE_NAME}\"" "${dir}/"*.cfg 2>/dev/null)

		for file in /tmp/joypads/*.*; do
			txt=$( cat "$file" | grep -E -c "^input_vendor_id = \"${input_vendor}\"$|^input_product_id = \"${input_product}\"$" )
			[[ "${txt}" == "2" ]] && mv "${file}" "${file}.bak" > /dev/null 2>&1
		done

    # sanitise filename
    file="${RA_DEVICE_NAME//[\?\<\>\\\/:\*\|]/}.cfg"

    if [[ -f "${dir}/${file}" ]]; then
        mv "${dir}/${file}" "${dir}/${file}.bak"
    fi
    sed -i '/^[[:space:]]*$/d' "${ES4ALL_TMPCFG}"
    mv "${ES4ALL_TMPCFG}" "${dir}/${file}"
}

function onend_retroarch_keyboard() {
    if [[ "$_retroarch_select_hotkey" -eq 1 ]]; then
        iniGet "input_player1_select"
        iniSet "input_enable_hotkey" "${ini_value}"
    fi

    # hotkey sanity check
    # remove hotkeys if there is no hotkey enable button
    iniGet "input_enable_hotkey"
    if [[ -z "${ini_value}" || "${ini_value}" == "nul" ]]; then
        iniSet "input_state_slot_decrease" ""
        iniSet "input_state_slot_increase" ""
        iniSet "input_reset" ""
        iniSet "input_menu_toggle" "f1"
        iniSet "input_load_state" ""
        iniSet "input_save_state" ""
        iniSet "input_exit_emulator" "escape"
        iniSet "input_shader_next" ""
        iniSet "input_shader_prev" ""
        iniSet "input_rewind" ""
        iniSet "input_toggle_fast_forward" ""
        iniSet "input_rewind" ""
        iniSet "input_fps_toggle" ""
        iniSet "input_volume_up" ""
        iniSet "input_volume_down" ""
    fi
}
