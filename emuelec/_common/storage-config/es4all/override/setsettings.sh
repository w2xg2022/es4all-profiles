#!/bin/bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2019-present Shanti Gilbert (https://github.com/shantigilbert)

# I use ${} for easier reading

# IMPORTANT: This script should not return (echo) anything other than the shader if its set

. /etc/profile

LOGGING=0
[[ "$(get_es_setting string LogLevel)" == "debug" ]] && LOGGING=1
LOG=/emuelec/logs/setsettings.log

RETROARCHIVEMENTS=(3do arcade atari2600 atari7800 atarilynx coleco colecovision famicom fbn fbneo fds gamegear gb gba gbc lynx mame genesis mastersystem megadrive megadrive-japan msx n64 neogeo nes ngp pcengine pcfx pokemini psx saturn sega32x segacd sfc sg-1000 snes tg16 vectrex virtualboy wonderswan)
NOREWIND=(sega32x zxspectrum odyssey2 mame n64 dreamcast atomiswave naomi neogeocd saturn psp pspminis)
NORUNAHEAD=(psp sega32x n64 dreamcast atomiswave naomi neogeocd saturn)

INDEXRATIOS=(4/3 16/9 16/10 16/15 21/9 1/1 2/1 3/2 3/4 4/1 9/16 5/4 6/5 7/9 8/3 8/7 19/12 19/14 30/17 32/9 config squarepixel core custom full)
CONF="/storage/.config/emuelec/configs/emuelec.conf"
export RA_CONF="/storage/.config/retroarch/retroarch.cfg"
RACORECONF="/storage/.config/retroarch/retroarch-core-options.cfg"

TMP_RACONF="/tmp/ra_merge_settings.cfg"
RACONF="${TMP_RACONF}"

if [ "${LOGGING}" ]; then 
echo "Setsettings Log ${RACONF}" > "${LOG}"
fi

PLATFORM=${1,,}
CORE=${3,,}
ROM="${2##*/}"
ROM="$(printf '%s' "${ROM}" | sed 's/\([][]\)/\\\1/g')"
SETF=0
SHADERSET=0
AUTOLOAD="false"

#bezels
ISBEZEL="false"
IRBEZEL="22"

#Autosave
AUTOSAVE="$@"
AUTOSAVE="${AUTOSAVE#*--autosave=*}"
AUTOSAVE="${AUTOSAVE% --*}"

#Snapshot
SNAPSHOT="$@"
SNAPSHOT="${SNAPSHOT#*--snapshot=*}"
SNAPSHOT="${SNAPSHOT% --*}"


write_log() {
	local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
	[[ "${LOGGING}" ]] && echo "${timestamp} : ${1}" >> "${LOG}"
}

# Helper function: check if array contains value
array_contains() {
    local seeking=$1; shift
    local element
    for element; do
        [[ "$element" == "$seeking" ]] && return 0
    done
    return 1
}

# Helper function: write boolean setting
write_bool() {
    local key=$1
    local value=$2
    [ "$value" == "1" ] && echo "${key} = \"true\"" >> ${RACONF} || echo "${key} = \"false\"" >> ${RACONF}
}

#Self language retroarch
EE_LANG=$(get_ee_setting system.language)

case "${EE_LANG}" in
    pt_BR|pt_PT) LANGEMUELEC="7" ;;
    en_US|en_GB) LANGEMUELEC="0" ;;
    fr_FR)       LANGEMUELEC="2" ;;
    es_ES|es_MX|eu_ES) LANGEMUELEC="3" ;;
    de_DE)       LANGEMUELEC="4" ;;
    it_IT)       LANGEMUELEC="5" ;;
    tr_TR)       LANGEMUELEC="18" ;;
    zh_CN)       LANGEMUELEC="12" ;;
    zh_TW)       LANGEMUELEC="11" ;;
    ko_KR)       LANGEMUELEC="10" ;;
    ja_JP)       LANGEMUELEC="1" ;;
    ru_RU)       LANGEMUELEC="9" ;;
    nl_NL)       LANGEMUELEC="6" ;;
    pl_PL)       LANGEMUELEC="14" ;;
    sv_SE)       LANGEMUELEC="25" ;;
    hu_HU)       LANGEMUELEC="31" ;;
    cs_CZ)       LANGEMUELEC="27" ;;
    *)           LANGEMUELEC="0" ;;
esac

echo "user_language = ${LANGEMUELEC}" >> ${TMP_RACONF}

write_log "Set Language to ${EE_LANG} Retroarch: ${LANGEMUELEC}"

# NOTE(w2xg2022): ES自己的介面語言(es_settings.cfg的Language)跟system.language是
# 兩個獨立設定，原本只同步給RetroArch，ES本身語言一直沒跟著system.language走。
# ES內部locale代碼跟system.language同樣是zh_CN/zh_TW這類標準值，直接同步即可。
ES_SETTINGS_CFG="/storage/.emulationstation/es_settings.cfg"
if [ -f "${ES_SETTINGS_CFG}" ] && [ -n "${EE_LANG}" ]; then
    if grep -q 'name="Language"' "${ES_SETTINGS_CFG}"; then
        sed -i "s/name=\"Language\" value=\"[^\"]*\"/name=\"Language\" value=\"${EE_LANG}\"/" "${ES_SETTINGS_CFG}"
    else
        sed -i "s|</config>|\t<string name=\"Language\" value=\"${EE_LANG}\" />\n</config>|" "${ES_SETTINGS_CFG}"
    fi
    write_log "Set ES UI Language to ${EE_LANG}"
fi

EE_RUMBLE=$(get_ee_setting ee_rumble_strength)
[[ -z "${EE_RUMBLE}" ]] && EE_RUMBLE=0
EE_RUMBLE_VAL=0
[[ "${EE_RUMBLE}" -gt 0 ]] && EE_RUMBLE_VAL=1
write_bool "input_enable_vibration" "${EE_RUMBLE_VAL}"

echo "input_vibration_vibe_strength  = \"${EE_RUMBLE}\"" >> ${TMP_RACONF}
write_log "Set Input Vibration Strength to ${EE_RUMBLE}"

# For the new snapshot save state manager we need to set the path to be /storage/roms/savestates/[PLATFORM]
mkdir -p "/storage/roms/savestates/${PLATFORM}"

cat >> ${RACONF} << EOF
savestates_in_content_dir = "false"
sort_savefiles_by_content_enable = "false"
sort_savefiles_enable = "false"
sort_savestates_by_content_enable = "false"
sort_savestates_enable = "false"
savestate_directory = "/storage/roms/savestates/${PLATFORM}"
EOF

function default_settings() {
# IMPORTANT: Every setting we change should have a default value here
    cat >> ${RACONF} << EOF
video_scale_integer = "false"
video_scale_integer_overscale = "false"
video_shader = ""
video_shader_enable = "false"
video_smooth = "false"
aspect_ratio_index = "22"
rewind_enable = "false"
run_ahead_enabled = "false"
run_ahead_frames = "1"
run_ahead_secondary_instance = "false"
savestate_auto_save = "false"
savestate_auto_load = "false"
cheevos_enable = "false"
cheevos_username = ""
cheevos_password = ""
cheevos_hardcore_mode_enable = "false"
cheevos_start_active = "false"
cheevos_leaderboards_enable = "false"
cheevos_verbose_enable = "false"
cheevos_auto_screenshot = "false"
ai_service_mode = "0"
ai_service_enable = "false"
ai_service_source_lang = "0"
ai_service_url = ""
input_libretro_device_p1 = "1"
fps_show = "false"
netplay = "false"
video_oga_vertical_enable = "false"
video_ogs_vertical_enable = "false"
video_ctx_scaling = "false"
video_frame_delay_auto = "false"
EOF
}

function set_setting() {
# we set the setting on the configuration file

write_log "Called \"${1}\" with \"${2}\""

case ${1} in
    "ratio")
    if [[ -z "${2}" || "${2}" == "none" || "${2}" == "0" ]]; then
        # 22 is the "Core Provided" aspect ratio and its set by default if no other is selected
        echo 'aspect_ratio_index = "22"' >> ${RACONF}
    else
    for i in "${!INDEXRATIOS[@]}"; do
        if [[ "${INDEXRATIOS[${i}]}" = "${2}" ]]; then
            break
        fi
    done
        echo "aspect_ratio_index = \"${i}\""  >> ${RACONF}
        IRBEZEL="${i}"
    fi
    ;;
    "smooth")
        write_bool "video_smooth" "${2}"
    ;;
    "rewind")
        if array_contains "${PLATFORM}" "${NOREWIND[@]}"; then
            echo 'rewind_enable = "false"' >> ${RACONF}
        else
            write_bool "rewind_enable" "${2}"
        fi
    ;;
    "autosave")
        if [[ -z "${AUTOSAVE}" || "${AUTOSAVE}" == "0" ]]; then
            echo 'savestate_auto_save = "false"' >> ${RACONF}
            echo 'savestate_auto_load = "false"' >> ${RACONF}
        else
        write_log "Autosave ${AUTOSAVE}"
            echo 'savestate_auto_save = "true"' >> ${RACONF}
            echo 'savestate_auto_load = "true"' >> ${RACONF}
            AUTOLOAD="true"
        fi
    ;;
    "snapshot")
        if [[ ! -z "${SNAPSHOT}" ]]; then
            echo "state_slot = \"${SNAPSHOT}\"" >> ${RACONF}
        else
            if [[ "${AUTOLOAD}" == "false" ]]; then
                echo 'savestate_auto_save = "false"' >> ${RACONF}
                echo 'savestate_auto_load = "false"' >> ${RACONF}
            fi
            echo 'state_slot = "0"' >> ${RACONF}
        fi
    ;;
    "integerscale")
        write_bool "video_scale_integer" "${2}"
        [ "${2}" == "1" ] && ISBEZEL="true" || ISBEZEL="false"
    ;;
    "integerscaleoverscale")
		case "${2}" in
			"1")
				echo 'video_scale_integer_scaling = "1"' >> "${RACONF}"
				echo 'video_scale_integer_axis = "1"' >> "${RACONF}"
			;;
			"2")
				echo 'video_scale_integer_scaling = "2"' >> "${RACONF}"
				echo 'video_scale_integer_axis = "1"' >> "${RACONF}"
			;;
			*)
				echo 'video_scale_integer_overscale = "0"' >> "${RACONF}"
				echo 'video_scale_integer_axis = "0"' >> "${RACONF}"
			;;
esac
    ;;
    "rgascale")
        write_bool "video_ctx_scaling" "${2}"
    ;;
    "shaderset")
        if [[ -z "${2}" || "${2}" == "none" || "${2}" == "0" ]]; then
            echo 'video_shader_enable = "false"' >> ${RACONF}
            echo 'video_shader = ""' >> ${RACONF}
        else
            echo "video_shader = \"${2}\"" >> ${RACONF}
            echo 'video_shader_enable = "true"' >> ${RACONF}
            echo "--set-shader /tmp/shaders/${2}"
        fi
    ;;
    "runahead")
    if ! array_contains "${PLATFORM}" "${NORUNAHEAD[@]}"; then
        if [[ -z "${2}" || "${2}" == "none" || "${2}" == "0" ]]; then
            echo 'run_ahead_enabled = "false"' >> ${RACONF}
            echo 'run_ahead_frames = "1"' >> ${RACONF}
        else
            echo 'run_ahead_enabled = "true"' >> ${RACONF}
            echo "run_ahead_frames = \"${2}\"" >> ${RACONF}
        fi
	fi
    ;;
    "secondinstance")
        if ! array_contains "${PLATFORM}" "${NORUNAHEAD[@]}"; then
        write_bool "run_ahead_secondary_instance" "${2}"
        fi
    ;;
    "video_frame_delay_auto")
        write_bool "video_frame_delay_auto" "${2}"
    ;;
    "ai_service_enabled")
        if [[ -z "${2}" || "${2}" == "none" || "${2}" == "0" ]]; then
            echo 'ai_service_enable = "false"' >> ${RACONF}
        else
            echo 'ai_service_enable = "true"' >> ${RACONF}
            AI_LANG=$(get_setting "ai_target_lang")
            AI_URL=$(get_setting "ai_service_url")
            [[ -z "${AI_LANG}" ]] && AI_LANG="0"
            echo "ai_service_source_lang = \"${AI_LANG}\"" >> ${RACONF}
            if [[ -z "${AI_URL}" || "${AI_URL}" == "auto" || "${AI_URL}" == "none" ]]; then
                echo "ai_service_url = \"http://ztranslate.net/service?api_key=BATOCERA&mode=Fast&output=png&target_lang=${AI_LANG}\"" >> ${RACONF}
            else
                echo "ai_service_url = \"${AI_URL}&mode=Fast&output=png&target_lang=${AI_LANG}\"" >> ${RACONF}
            fi
        fi
    ;;
    "retroachievements")
        if [[ $(array_contains "${PLATFORM}" "${RETROARCHIVEMENTS[@]}") && "${2}" == "1" ]]; then
            # Batch read all retroachievements settings at once
            local RA_USER=$(get_setting "retroachievements.username")
            local RA_PASS=$(get_setting "retroachievements.password")
            local RA_HARD=$(get_setting "retroachievements.hardcore")
            local RA_ENCORE=$(get_setting "retroachievements.encore")
            local RA_LEAD=$(get_setting "retroachievements.leaderboards")
            local RA_VERB=$(get_setting "retroachievements.verbose")
            local RA_SCREEN=$(get_setting "retroachievements.screenshot")
            
            echo 'cheevos_enable = "true"' >> ${RACONF}
            echo "cheevos_username = \"${RA_USER}\""  >> ${RACONF}
            echo "cheevos_password = \"${RA_PASS}\""  >> ${RACONF}
                    # retroachievements_hardcore_mode
            write_bool "cheevos_hardcore_mode_enable" "${RA_HARD}"
                    # retroachievements_encore_mode
            write_bool "cheevos_start_active" "${RA_ENCORE}"
                    # retroachievements_leaderboards
            write_bool "cheevos_leaderboards_enable" "${RA_LEAD}"
                    # retroachievements_verbose_mode
            write_bool "cheevos_verbose_enable" "${RA_VERB}"
                    # retroachievements_automatic_screenshot
            write_bool "cheevos_auto_screenshot" "${RA_SCREEN}"
            if [ "${RA_SCREEN}" == "1" ]; then 
				echo 'cheevos_auto_screenshot = "true"' >> ${RACONF}
				echo 'screenshot_directory = "/roms/screenshots"' >> ${RACONF}
				mkdir -p "/roms/screenshots"
            else
				echo 'cheevos_auto_screenshot = "false"' >> ${RACONF}
            fi
		else
            cat >> ${RACONF} << EOF
cheevos_enable = "false"
cheevos_username = ""
cheevos_password = ""
cheevos_hardcore_mode_enable = "false"
cheevos_start_active = "false"
cheevos_leaderboards_enable = "false"
cheevos_verbose_enable = "false"
cheevos_auto_screenshot = "false"
EOF
        fi
    ;;
    "netplay")
        if [[ -z "${2}" || "${2}" == "none" || "${2}" == "0" ]]; then
            echo 'netplay = "false"' >> ${RACONF}
        else
            echo 'netplay = "true"' >> ${RACONF}
            
            # Batch read netplay settings
            local NP_MODE=$(get_setting "netplay.mode")
            local NP_PORT=$(get_setting "netplay.port")
            local NP_IP=$(get_setting "netplay.server.ip")
            local NP_SPORT=$(get_setting "netplay.server.port")
            local NP_PASS=$(get_setting "netplay.password")
            local NP_SPASS=$(get_setting "netplay.spectatepassword")
            local NP_PUBLIC=$(get_setting "netplay_public_announce")
            local NP_RELAY=$(get_setting "netplay.relay")
            local NP_FRAMES=$(get_setting "netplay.frames")
            local NP_NICK=$(get_setting "netplay.nickname")

        # Security : hardcore mode disables save states, which would kill netplay
	# double check if this is not a duplicated entry when it 
            echo 'cheevos_hardcore_mode_enable = "false"' >> ${RACONF}

            if [[ "${NP_MODE}" == "host" ]]; then
        # Quite strangely, host mode requires netplay_mode to be set to false when launched from command line
                echo 'netplay_mode = "false"' >> ${RACONF}
                echo 'netplay_client_swap_input = "false"' >> ${RACONF}
                echo "netplay_ip_port = \"${NP_PORT}\"" >> ${RACONF}
            elif [[ "${NP_MODE}" == "client" || "${NP_MODE}" == "spectator" ]]; then
        # But client needs netplay_mode = true ... bug ?
                echo 'netplay_mode = "true"' >> ${RACONF}
                echo "netplay_ip_address = \"${NP_IP}\"" >> ${RACONF}
                echo "netplay_ip_port = \"${NP_SPORT}\"" >> ${RACONF}
                echo 'netplay_client_swap_input = "true"' >> ${RACONF}
            fi

            [[ "${NP_MODE}" == "spectator" ]] && echo 'netplay_start_as_spectator = "true"' >> ${RACONF}

            if [[ -n "${NP_PASS}" && "${NP_PASS}" != "none" && "${NP_PASS}" != "false" ]]; then
                echo "netplay_password = \"${NP_PASS}\"" >> ${RACONF}
            fi

            if [[ -n "${NP_SPASS}" && "${NP_SPASS}" != "none" && "${NP_SPASS}" != "false" ]]; then
                echo "netplay_spectate_password = \"${NP_SPASS}\"" >> ${RACONF}
            fi

        # Netplay hide the gameplay
            if [[ -n "${NP_PUBLIC}" && "${NP_PUBLIC}" != "none" && "${NP_PUBLIC}" != "false" ]]; then
                echo 'netplay_public_announce = "true"' >> ${RACONF}
            else
                echo 'netplay_public_announce = "false"' >> ${RACONF}
            fi

            if [[ -n "${NP_RELAY}" && "${NP_RELAY}" != "none" && "${NP_RELAY}" != "false" ]]; then
                echo 'netplay_use_mitm_server = "true"'  >> ${RACONF}
                echo "netplay_mitm_server = \"${NP_RELAY}\"" >> ${RACONF}
            else
                echo 'netplay_use_mitm_server = "false"' >> ${RACONF}
            fi

            echo "netplay_delay_frames = \"${NP_FRAMES}\"" >> ${RACONF}
            echo "netplay_nickname = \"${NP_NICK}\"" >> ${RACONF}
        fi
    ;;
    "fps")
    # Display FPS in Retroarch
        local SHOWFPS=$(get_setting "showFPS")
        write_bool "fps_show" "${SHOWFPS}"
    ;;
    "vertical")
    # Vertical orientation game
    if [ "${2}" == "1" ]; then
        echo 'video_oga_vertical_enable = "true"' >> ${RACONF}
   
            local VERT_ASP=$(get_setting "vert_aspect")
            if [[ -z "${VERT_ASP}"  || "${VERT_ASP}" == "none" || "${VERT_ASP}" == "0" || "${VERT_ASP}" == "1" ]]; then
                echo 'aspect_ratio_index = "1"' >> ${RACONF}
                IRBEZEL="1"
            else
                echo "aspect_ratio_index = \"${VERT_ASP}\"" >> ${RACONF}
                IRBEZEL="${VERT_ASP}"
            fi
            
            case "$(oga_ver)" in
                "OGA")
                    [ -f "/tmp/joypads/GO-Advance Gamepad_vertical.cfg" ] && {
                        mv "/tmp/joypads/GO-Advance Gamepad.cfg" "/tmp/joypads/GO-Advance Gamepad_horizontal.cfg"
                        mv "/tmp/joypads/GO-Advance Gamepad_vertical.cfg" "/tmp/joypads/GO-Advance Gamepad.cfg"
                    }
                ;;
                "OGABE")
                    [ -f "/tmp/joypads/GO-Advance Gamepad (rev 1.1)_vertical.cfg" ] && {
                        mv "/tmp/joypads/GO-Advance Gamepad (rev 1.1).cfg" "/tmp/joypads/GO-Advance Gamepad (rev 1.1)_horizontal.cfg"
                        mv "/tmp/joypads/GO-Advance Gamepad (rev 1.1)_vertical.cfg" "/tmp/joypads/GO-Advance Gamepad (rev 1.1).cfg"
                    }
                ;;
                "OGS")
                    echo 'video_ogs_vertical_enable = "true"' >> ${RACONF}
                    [ -f "/tmp/joypads/GO-Super Gamepad_vertical.cfg" ] && {
                        mv "/tmp/joypads/GO-Super Gamepad.cfg" "/tmp/joypads/GO-Super Gamepad_horizontal.cfg"
                        mv "/tmp/joypads/GO-Super Gamepad_vertical.cfg" "/tmp/joypads/GO-Super Gamepad.cfg"
                    }
                ;;
            esac
        else
            echo 'video_oga_vertical_enable = "false"' >> ${RACONF}
            echo 'video_ogs_vertical_enable = "false"' >> ${RACONF}

            case "$(oga_ver)" in
                "OGA")
                    [ -f "/tmp/joypads/GO-Advance Gamepad_horizontal.cfg" ] && {
                        mv "/tmp/joypads/GO-Advance Gamepad.cfg" "/tmp/joypads/GO-Advance Gamepad_vertical.cfg"
                        mv "/tmp/joypads/GO-Advance Gamepad_horizontal.cfg" "/tmp/joypads/GO-Advance Gamepad.cfg"
                    }
                ;;
                "OGABE")
                    [ -f "/tmp/joypads/GO-Advance Gamepad (rev 1.1)_horizontal.cfg" ] && {
                        mv "/tmp/joypads/GO-Advance Gamepad (rev 1.1).cfg" "/tmp/joypads/GO-Advance Gamepad (rev 1.1)_vertical.cfg"
                        mv "/tmp/joypads/GO-Advance Gamepad (rev 1.1)_horizontal.cfg" "/tmp/joypads/GO-Advance Gamepad (rev 1.1).cfg"
                    }
                ;;
                "OGS")
                    [ -f "/tmp/joypads/GO-Super Gamepad_horizontal.cfg" ] && {
                        mv "/tmp/joypads/GO-Super Gamepad.cfg" "/tmp/joypads/GO-Super Gamepad_vertical.cfg"
                        mv "/tmp/joypads/GO-Super Gamepad_horizontal.cfg" "/tmp/joypads/GO-Super Gamepad.cfg"
                    }
                ;;
            esac
        fi
    ;;
esac
}

function get_setting() {
   ees -e -r "${1}" -p "${PLATFORM}" -m "${ROM}"
}

for s in ratio smooth shaderset rewind autosave integerscale integerscaleoverscale runahead secondinstance video_frame_delay_auto retroachievements ai_service_enabled netplay fps vertical rgascale snapshot; do
EES=$(get_setting ${s})
set_setting "${s}" "${EES}"
[ -z "${EES}" ] || SETF=1
done

# If no setting was changed, set all options to default on the configuration files
[ ${SETF} == 0 ] && default_settings

# Core-specific configurations, these settings should probably be moved to other file or script
# TODO: Need to check if file exists first, it may contain other settings that we do not want to remove.
if [ "${CORE}" == "atari800" ]; then
ATARICONF="/storage/.config/emuelec/configs/atari800.cfg"
ATARI800CONF="/storage/.config/retroarch/config/Atari800/Atari800.opt"

    if [ "${PLATFORM}" == "atari5200" ]; then
        cat > "${ATARI800CONF}" << EOF
atari800_system = "5200"
EOF
        cat > "${ATARICONF}" << EOF
RAM_SIZE=16
STEREO_POKEY=0
BUILTIN_BASIC=0
EOF
        echo 'atari800_system = "5200"' >> ${RACORECONF}
    else
        cat > "${ATARI800CONF}" << EOF
atari800_system = "800XL (64K)"
EOF
        cat > "${ATARICONF}" << EOF
RAM_SIZE=64
STEREO_POKEY=1
BUILTIN_BASIC=1
EOF
        echo 'atari800_system = "800XL (64K)"' >> ${RACORECONF}
    fi
fi

if [ "${PLATFORM}" == "amstradgx4000" ]; then
# Make sure cap32_model is set to "6128+ (experimental)"
CAP32CONF="/storage/.config/retroarch/config/cap32/cap32.opt"
    cat > "${CAP32CONF}" << EOF
cap32_model = "6128+ (experimental)"
cap32_gfx_colors = "24bit"
EOF
fi

if [ "${PLATFORM}" == "amstradcpc" ]; then
# But amstradcpc wants cap32_model set to "6128"
CAP32CONF="/storage/.config/retroarch/config/cap32/cap32.opt"
   cat > "${CAP32CONF}" << EOF
cap32_model = "6128"
cap32_gfx_colors = "16bit"
EOF
fi

if [ "${CORE}" == "gambatte" ]; then
GAMBATTECONF="/storage/.config/retroarch/config/Gambatte/Gambatte.opt"
    COLORIZE=$(get_setting "renderer.colorization")
    
    write_log "Gambatte Colorization: ${COLORIZE}"
    
    if [[ -z "${COLORIZE}" || "${COLORIZE}" == "auto"  ||  "${COLORIZE}" == "none" ]]; then
        cat > "${GAMBATTECONF}" << EOF
gambatte_gb_colorization = "disabled"
gambatte_gb_internal_palette = ""
EOF
        cat >> ${RACORECONF} << EOF
gambatte_gb_colorization = "disabled"
gambatte_gb_internal_palette = ""
EOF
    elif [ "${COLORIZE}" == "GBC" ]; then
        cat > "${GAMBATTECONF}" << EOF
gambatte_gb_colorization = "GBC"
gambatte_gb_internal_palette = ""
EOF
        cat >> ${RACORECONF} << EOF
gambatte_gb_colorization = "GBC"
gambatte_gb_internal_palette = ""
EOF
    elif [ "${COLORIZE}" == "SGB" ]; then
        cat > "${GAMBATTECONF}" << EOF
gambatte_gb_colorization = "SGB"
gambatte_gb_internal_palette = ""
EOF
        cat >> ${RACORECONF} << EOF
gambatte_gb_colorization = "SGB"
gambatte_gb_internal_palette = ""
EOF
    elif [ "${COLORIZE}" == "Best Guess" ]; then
        cat > "${GAMBATTECONF}" << EOF
gambatte_gb_colorization = "auto"
gambatte_gb_internal_palette = ""
EOF
        cat >> ${RACORECONF} << EOF
gambatte_gb_colorization = "auto"
gambatte_gb_internal_palette = ""
EOF
    else
        cat > "${GAMBATTECONF}" << EOF
gambatte_gb_colorization = "internal"
gambatte_gb_internal_palette = "${COLORIZE}"
EOF
        cat >> ${RACORECONF} << EOF
gambatte_gb_colorization = "internal"
gambatte_gb_internal_palette = "${COLORIZE}"
EOF
    fi
fi

# We set up the controller index
CONTROLLERS="$@"
CONTROLLERS="${CONTROLLERS#*--controllers=*}"
CONTROLLERS="${CONTROLLERS%% --autosave*}"  # until --autosave is found

for i in 1 2 3 4 5; do
if [[ "${CONTROLLERS}" == *p${i}* ]]; then
PINDEX="${CONTROLLERS#*-p${i}index }"
PINDEX="${PINDEX%% -p${i}guid*}"
PINDEX_UDEV=$(sdl_ra_joystick_map "${PINDEX}")
[[ -n "${PINDEX_UDEV}" ]] && PINDEX=${PINDEX_UDEV}
echo "input_player${i}_joypad_index = \"${PINDEX}\"" >> ${RACONF}

# Setting controller type for different cores
        [ "${PLATFORM}" == "atari5200" ] && echo "input_libretro_device_p${i} = \"513\"" >> ${RACONF}
    fi
done

# EE Device detection
read -r EE_DEVICE < /ee_arch
MENU_DRV=$(get_setting "retroarch.menu_driver")

write_log "Menu driver ${MENU_DRV} for ${EE_DEVICE}"

if [[ -z "${MENU_DRV}"  ||  "${MENU_DRV}" == "auto"  ||  "${MENU_DRV}" == "none"  ||  "${MENU_DRV}" == "0" ]]; then
    if [ "${EE_DEVICE}" == "OdroidGoAdvance" ] || [ "${EE_DEVICE}" == "GameForce" ]; then
        MENU_DRV="xmb"
    else
        MENU_DRV="ozone"
    fi
fi

[[ -z "${MENU_DRV}" ]] && MENU_DRV="ozone"

echo "menu_driver = \"${MENU_DRV}\"" >> ${RACONF}

# Show bezel if enabled
BEZEL_SET=$(get_setting "bezel")
if [[ -z "${BEZEL_SET}" || "${BEZEL_SET}" == "none"  ||  "${BEZEL_SET}" == "0" ]]; then
    ${TBASH} bezels.sh "none" "default" "${ISBEZEL}" "${IRBEZEL}"
else
    ${TBASH} bezels.sh "${PLATFORM}" "${ROM}" "${ISBEZEL}" "${IRBEZEL}"
fi

# NOTE(w2xg2022 2026-08-03): ★这里要取【反】, 原本直接等於 InvertButtons 是错的★
#
# RA 选单的确认键 = (autoconfig 把 RetroPad A 绑到哪一颗) × (swap)。
# 自从面键改成【方位对齐】(configscripts/retroarch.sh), RetroPad A **恒等於东那颗**,
# 於是要让「确认 = 印刷 A」就变成:
#     任天堂式(InvertButtons=true , 印刷A在东) -> 确认落 RetroPad A -> swap=false
#     Xbox 式 (InvertButtons=false, 印刷A在南) -> 确认落 RetroPad B -> swap=true
#   => swap = !InvertButtons
#
# ★原本 swap=InvertButtons 为什么长期没被发现★: 旧的 autoconfig 是标签对齐
# (RetroPad A 恒等於印刷 A), 那时的正确解是「永远不 swap」——
# 而 Xbox 式手柄的 InvertButtons 刚好是 false, 於是**碰巧对**;
# 任天堂式手柄(true)则一直是错的(确认落在印刷 B)。市面上绝大多数是 Xbox 式,
# 所以这个错被遮了很久, 直到拿一支印刷 A 在东的手柄测才照出来。
#
# ⚠️ 这两件事是**相依**的: 改了 autoconfig 的语意就必须同时改这里,
# 只改一个就是「一半对一半错」。
inverted_ok_cancel=$(get_es_setting bool InvertButtons)
if [[ "${inverted_ok_cancel}" == "true" ]]; then
    menu_swap="false"   # 任天堂式: 印刷A在东 = RetroPad A, 不换
else
    menu_swap="true"    # Xbox 式: 印刷A在南 = RetroPad B, 要换
fi
echo "menu_swap_ok_cancel_buttons = \"${menu_swap}\"" >> ${RACONF}

# NOTE(w2xg2022): InvertGameButtons ES設定(跟InvertButtons同一個設定畫面) ->
# 動態產生/移除對應core的per-core remap，讓遊戲內A/B、X/Y對調(位置對齊，
# PS/PSP等幾何符號系統手感正確，實機驗證過)可以隨ES開關切換，而不是寫死。
# 用BEGIN/END標記包住新增的4行，每次啟動都先移除舊標記區塊再視設定決定要不要
# 重新加入，避免重複啟動遊戲後remap檔案內容一直疊加；標記以外的既有內容
# (例如N64 Mupen64Plus-Next.rmp原本就有的input_playerN_analog_dpad_mode)保留不動。
# NOTE(w2xg2022): ★改为自动推导，不再维护写死白名单★
# 旧版用一张手写的 EE_GAMEBTN_CORENAME 表(核心内部名→RA corename)当白名单，
# 只列了十几个核心，漏一个该核心就完全不生效——实测 mame2010/mame2016/mame/
# fbalpha2012*/fbneo_neogeo/hbmame 等一大票 arcade 核心全没收录，游戏内AB/XY对调
# 对它们通通失效。改成直接从核心自己的 .info 读 corename(RetroArch 的 per-core
# remap 文件夹名就是这个)，任何 libretro 核心都自动生效、永不漏。
# 前提：emuelecRunEmu.sh 传进来的是未截断的完整核心名(见该处 SS_CORE)。
# 找不到 .info(例如 ppsspp/flycast 独立模拟器走各自 joy 脚本、不经这里)就跳过。
EE_GAMEBTN_CORENAME_VAL=""
for _inf in "/tmp/cores/${CORE}_libretro.info" "/usr/lib/libretro/${CORE}_libretro.info"; do
    if [[ -f "${_inf}" ]]; then
        EE_GAMEBTN_CORENAME_VAL=$(sed -n 's/^corename *= *"\([^"]*\)".*/\1/p' "${_inf}" | head -1)
        break
    fi
done
# NOTE(w2xg2022): 个别核心 .info 的 corename 与 RA 运行时 library_name(=per-core remap
# 文件夹名)大小写/拼写不一致→自动推导会写错文件夹→RA 加载不到→游戏内退回标签对齐=乱。
# 这里对已知例外做修正。目前仅 applewin(.info=applewin 小写、library_name=AppleWin 大写,
# 2026-07-12 X98mini 实机确认);其余13个默认核心 corename==library_name,无需修正。
case "${EE_GAMEBTN_CORENAME_VAL}" in
    applewin) EE_GAMEBTN_CORENAME_VAL="AppleWin" ;;
esac
if [[ -n "${EE_GAMEBTN_CORENAME_VAL}" ]]; then
    # NOTE(w2xg2022): 配合es4all的ES把「遊戲內按鍵對調」拆成兩個獨立設定，膠水
    # 也拆開分別套用(以前只有InvertGameButtons、一開就AB+XY一起翻，那其實是bug：
    # XY不該預設跟著翻)：
    #   InvertGameButtons -> 只翻 A/B (RetroPad: A=8,B=0，翻成 a=0,b=8)，預設true
    #     (跟es4all Settings一致；偵測後=!mABInverted，位置對齊修正PS/PSP手感)
    #   InvertXYButtons   -> 只翻 X/Y (RetroPad: X=9,Y=1，翻成 x=1,y=9)，預設false
    #     (跟es4all Settings一致；偵測後=mXYInverted)
    # 不翻的那組就不寫對應行(RA預設本來就是A=8/B=0/X=9/Y=1，正身)。兩組共用同一個
    # BEGIN/END InvertGameButtons標記包住(方便一次移除舊區塊，跨新舊版本都相容)。
    # NOTE(w2xg2022 2026-08-02): ★这层不再产生任何面键 remap★
    #
    # 原本这里写死「翻 A/B、不翻 X/Y」, 用来把 autoconfig 的标签对齐扳成位置对齐。
    # 问题是「翻转」是相对语意 —— 对不对取决于 autoconfig 原本是哪一套, 而且只翻一半:
    # 实机结果就是 A/B 位置对齐、X/Y 却还是标签对齐, 四颗面键两套规则。
    # ★一半对一半错正是双重错误的徵兆, 不能只补 X/Y 那一半★。
    #
    # 定案: 面键的方位改由【第一层】一次写死 —— configscripts/retroarch.sh 用
    # es_input.cfg(印刷字母→实体编号) + ES 的 InvertButtons(印刷字母在哪个方位)
    # 直接把 input_a/b/x/y_btn 写成方位对应的那一颗。RetroPad 的 A/B/X/Y 本来就是
    # 固定方位(A东 B南 X北 Y西), 所以第一层写对之后, 这层什么都不用做。
    # 好处: 没有「翻了几次」可以数错, 任天堂式与 Xbox 式手柄走同一条路。
    #
    # 这里保留的是【清理】: 把过去写下去的那四行拔掉, 否则会跟新的第一层叠加成再翻一次。
    # ★不能只靠 BEGIN/END 标记删★ —— RetroArch 自己存回 .rmp 时会把注释洗掉并重排,
    # 标记一旦没了, 旧的 sed 区间删除就永远删不到, 而那四行会留在档案里继续生效
    # (实机 2026-08-02: Snes9x.rmp / MAME 2003-Plus.rmp 都是没有标记的裸行)。
    # 所以标记式与裸行式两种都清, 裸行只清我们写过的那四个确切值, 不动使用者自己的 remap。
    EE_RMP_DIR="/storage/.config/retroarch/config/remappings/${EE_GAMEBTN_CORENAME_VAL}"
    EE_RMP_FILE="${EE_RMP_DIR}/${EE_GAMEBTN_CORENAME_VAL}.rmp"
    if [[ -f "${EE_RMP_FILE}" ]]; then
        sed -i '/^# BEGIN InvertGameButtons$/,/^# END InvertGameButtons$/d' "${EE_RMP_FILE}"
        sed -i -e '/^input_player1_btn_a = "0"$/d' \
               -e '/^input_player1_btn_b = "8"$/d' \
               -e '/^input_player1_btn_x = "1"$/d' \
               -e '/^input_player1_btn_y = "9"$/d' "${EE_RMP_FILE}"
    fi
    # ★唯一的例外: Apple II(AppleWin) 刻意把 A/B 对调回去★
    #
    # 三层架构的通则是「游戏内按位置」, 但 apple2 是**习惯特例**(架构定案时就保留的):
    # 使用者按的是长年养成的手感, 不是几何位置, 所以这台机器上 A/B 要维持印刷对齐。
    # ★做成【一个核心的具名例外】, 而不是把全域翻转改回来★ —— 全域翻转正是刚修掉的
    # 「翻转语意 + 只翻一半」那个坑, 例外要小、要指名道姓、要写清楚为什么。
    #
    # 值就是上面刚清掉的那两行(RetroPad A=8/B=0 -> a=0,b=8), 顺序上先清后写:
    # 于是就算 RetroArch 把注释标记洗掉了, 下次启动也只会剩一份, 不会越叠越多。
    #
    # ★资料夹名必须是 library_name 不是 .info 的 corename★:
    # applewin 的 .info 写小写 applewin, RA 运行时的 library_name 是大写 AppleWin,
    # 写错资料夹 RA 就读不到, 表现是「明明设了却没作用」——
    # 上面的 case 已经把它修正成 AppleWin, 这里直接比对修正后的值。
    if [[ "${EE_GAMEBTN_CORENAME_VAL}" == "AppleWin" ]]; then
        mkdir -p "${EE_RMP_DIR}"
        {
            echo "# BEGIN InvertGameButtons"
            echo 'input_player1_btn_a = "0"'
            echo 'input_player1_btn_b = "8"'
            echo "# END InvertGameButtons"
        } >> "${EE_RMP_FILE}"
    fi

    # 移除標記後若檔案變成全空(該core原本沒有其他remap內容)，直接刪掉整個檔案/
    # 資料夾，避免RA讀到一個空remap檔案殘留在磁碟上
    if [[ -f "${EE_RMP_FILE}" ]] && ! grep -q '[^[:space:]]' "${EE_RMP_FILE}"; then
        rm -f "${EE_RMP_FILE}"
        rmdir "${EE_RMP_DIR}" 2>/dev/null
    fi
fi

echo "cheevos_unsupported_notification = \"false\"" >> ${RACONF}

# Merge the changes to: /storage/.config/retroarch/retroarch.cfg 
ees -i ${RACONF}

if [[ "${LOGGING}" == "1" ]]; then
write_log "- merged settings to retroarch.cfg -"
cat "${RACONF}" >> "${LOG}"
fi
 
rm ${RACONF}

RA_CONF_OVERRIDES="/storage/.config/retroarch/retroarch_overrides.cfg"
if [[ -f "${RA_CONF_OVERRIDES}" ]]; then
	ees -i ${RA_CONF_OVERRIDES}
	if [[ "${LOGGING}" == "1" ]]; then
		write_log "- merged ${RA_CONF_OVERRIDES} settings to retroarch.cfg -"
		cat "${RA_CONF_OVERRIDES}" >> "${LOG}"
	fi
fi
