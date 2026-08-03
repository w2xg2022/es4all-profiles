#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# es4all ROCKNIX 音源输出切换 —— EmuELEC `emuelec-utils setauddev` 的 ROCKNIX 等价物。
#
# ★为什么不能照抄 EmuELEC 那套★
#   EmuELEC 是裸 ALSA：setauddev 把 /storage/.config/asound.conf 的默认 PCM 改成 hw:<card,device>。
#   ROCKNIX 走 **PipeWire**（`aplay -L` 的 default 指向 "PipeWire Media Server"），
#   写 asound.conf 完全不起作用 —— 必须改 PipeWire 的默认 sink。
#
# 用法： es4all-setauddev <card,device>      例： es4all-setauddev 0,0
#                                            或： es4all-setauddev CARD=HDMI,DEV=0
#   参数格式与 resources/audio_outputs.cfg 一致（三个 target 共用同一份映射表），
#   本脚本只取其中的 **card** 号，用它去 PipeWire 里找对应的 sink。
#
# 为什么按 ALSA card 号解析而不是记 sink id：
#   `wpctl status` 里的数字 id 每次开机都会变，不能持久化；node.name 虽稳定但各板不同。
#   PipeWire 的 ALSA sink 都带 api.alsa.pcm.card 属性，用它对应回 card 号最稳。
#
# 无参数时：读 system.cfg 的 system.audiooutput 重新套用（开机 glue 用这个路径）。

CARDDEV="$1"
SYS_CFG=/storage/.config/system/configs/system.cfg

if [ -z "${CARDDEV}" ]; then
    CARDDEV=$(sed -n 's/^system\.audiooutput=//p' "${SYS_CFG}" 2>/dev/null | head -1)
fi
[ -z "${CARDDEV}" ] && exit 0

# 取出 card 部分。支援两种写法：
#   0,0                 传统写法：card 号
#   CARD=HDMI,DEV=0     按【卡名】——MD1000 这类板子必须用这种
#
# ★为什么要支援卡名★：MD1000 上两张 simple-card 的探测顺序不固定，卡号 0/1
# 会在两次开机之间对调（2026-07-29 同一台机器实测两种排列都出现过）。写死卡号
# 等于每隔一次开机就把声音送去错的孔。与「写死 UUID 而不用 LABEL」同一类错误。
CARD="${CARDDEV%%,*}"
case "${CARD}" in
    CARD=*)
        # 卡名 -> 卡号。/proc/asound/<name> 是指向 cardN 的符号连结，
        # 例如 /proc/asound/HDMI -> card1，取结尾数字即可。
        _name="${CARD#CARD=}"
        CARD=$(readlink "/proc/asound/${_name}" 2>/dev/null | sed 's/^card//')
        [ -z "${CARD}" ] && CARD=$(awk -v n="${_name}" '$2=="["n" ]"||$0~"\\["n"[ ]*\\]"{print $1; exit}' /proc/asound/cards 2>/dev/null)
        ;;
esac
case "${CARD}" in ''|*[!0-9]*) exit 1 ;; esac

command -v wpctl >/dev/null 2>&1 || exit 1
command -v pw-dump >/dev/null 2>&1 || exit 1

# PipeWire 起来需要时间（开机时 glue 可能跑在它之前），等一下再放弃
i=0
while [ $i -lt 15 ]; do
    wpctl status >/dev/null 2>&1 && break
    i=$((i+1)); sleep 1
done

# 找出 api.alsa.pcm.card == CARD 的 Audio/Sink 节点 id
ID=$(pw-dump 2>/dev/null | jq -r --arg c "${CARD}" '
    .[] | select(.info.props["media.class"]=="Audio/Sink")
        | select((.info.props["api.alsa.pcm.card"]|tostring) == $c)
        | .id' 2>/dev/null | head -1)

[ -z "${ID}" ] && exit 1

wpctl set-default "${ID}" >/dev/null 2>&1 || exit 1
exit 0
