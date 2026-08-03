#!/bin/bash
# es4all Armbian 音源输出切换 —— EmuELEC `setauddev` / ROCKNIX `es4all-setauddev` 的
# Armbian 等价物。ES 从 audio_outputs.cfg 取出 <card,device> 后呼叫本档。
#
# 用法: setaudio.sh <card,device> [标签]
#   例: setaudio.sh 0,0 "HDMI"
#       setaudio.sh CARD=HDMI,DEV=0 "HDMI"
#   (标签只用来写 log, 三个 target 的介面一致, 多的参数忽略。)
#
# ★为什么写 ~/.asoundrc 而不是 /etc/asound.conf★
#   Armbian 上 ES 是以【游戏使用者】身分跑的, 不是 root(es4all-1key 刻意这样设计:
#   给 sudo 权限过大、让 ES 跑 root 又会把设定档写进 /root)。
#   /etc/asound.conf 要 root 才写得动 —— 从 ES 呼叫必然失败, 而且是【静默】失败:
#   使用者看到选单切换成功、log 也没错, 声音却完全没变。
#   ~/.asoundrc 是 ALSA 的使用者层设定, 优先於 /etc/asound.conf, 权限天生就有。
#
# ★为什么不自动侦测 HDMI★(别再加回去)
#   es4all-1key 原本用 `aplay -l | grep HDMI` 猜卡号。那在 MD1000 上碰巧对,
#   但按名字猜必然会在别的板子上挑错孔 —— X98mini 的 HDMI 在 aplay -l 里
#   叫 "SPDIF-SPDIF"。所以卡号一律来自机型资料档 audio_outputs.cfg, 不猜。

set -u

CARDDEV="${1:-}"
LABEL="${2:-}"
[ -n "${CARDDEV}" ] || { echo "usage: setaudio.sh <card,device> [label]" >&2; exit 1; }

ASOUNDRC="${HOME:-/home/$(id -un)}/.asoundrc"

# 支援两种写法(与 audio_outputs.cfg 一致):
#   0,0              传统: card 号,device 号
#   CARD=HDMI,DEV=0  按卡名 —— 卡号会随驱动载入顺序变动的板子必须用这种
CARD="${CARDDEV%%,*}"
DEV="${CARDDEV#*,}"
CARD="${CARD#CARD=}"
DEV="${DEV#DEV=}"
[ -n "${DEV}" ] || DEV=0

# ★用 plug 包一层★: 直接 hw: 会因为取样率/格式不合而放不出声(而且报的错很难懂)。
# plug 会自动做转换, 是「切了就该有声音」的最短路径。
cat > "${ASOUNDRC}" <<EOF
# 由 es4all setaudio.sh 产生 —— 手改会在下次切换音源时被覆盖。
# 来源: es4all-profiles 的机型资料 audio_outputs.cfg (${LABEL:-未命名输出})
pcm.!default {
    type plug
    slave.pcm "hw:${CARD},${DEV}"
}
ctl.!default {
    type hw
    card ${CARD}
}
EOF

echo "es4all: audio output -> hw:${CARD},${DEV} ${LABEL:+(${LABEL})}"
exit 0
