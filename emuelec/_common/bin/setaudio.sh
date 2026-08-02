#!/bin/bash
# es4all: EmuELEC 音源输出切换(通用版) —— 由 ES 的 AUDIO OUTPUT 选单调用。
#
# 用法: setaudio.sh <card,device> [标签]   例: setaudio.sh 0,2 HDMI
#                                          或: setaudio.sh CARD=RK809,DEV=0 AV
#       两个参数都直接取自 audio_outputs.cfg 的同一行, 由 ES 传入。
#
#       ★标签不可省略★(第 3 步要用): Amlogic 上 HDMI=0,2 与 AV=0,1 是【同一张卡】,
#       光看 <card,device> 分不出使用者选的是哪个孔 —— 只有标签能分。
#       省略时一律不做静音处理(保守: 宁可两边都有声, 也不要把选中的输出静音)。
#
# ★为什么不能用内建的 emuelec-utils setauddev★
#   那支只做一行 sed, 只改 dmix 的 slave:
#       sed -i "s|pcm \"hw:.*|pcm \"hw:${AUDIO_DEVICE}\"|" asound.conf
#   在 Amlogic(E900V22C / X98mini)上够用, 因为 HDMI 与 AV 是【同一张卡】的两个 device,
#   softvol 的 control.card 和 ctl.!default 的 card 本来就不用动。
#   但 MD1000(RK3566)是【两张独立的卡】(card HDMI / card RK809, 各自一个 i2s 控制器),
#   只改 dmix 会变成「声音去了 AV、音量却还挂在 HDMI 卡上」——
#   音量键失效、静音状态也套错卡。
#
# 本脚本的通用规则: **卡号跟着走** —— 把目标的卡填进 asound.conf 里所有提到卡的地方。
#   在 Amlogic 上算出来的结果与现况完全相同(两个 device 同卡, card 值不变),
#   所以一支脚本同时涵盖两种拓扑, 不必每台机器写一份。

set -u

ASOUND=/storage/.config/asound.conf
DEV="${1:-}"
LABEL="${2:-}"

[ -z "${DEV}" ] && { echo "用法: $(basename "$0") <card,device> [标签]" >&2; exit 1; }
[ -f "${ASOUND}" ] || { echo "找不到 ${ASOUND}" >&2; exit 1; }

# 从 <card,device> 取出【卡】的部分:
#   "CARD=RK809,DEV=0" -> RK809      (按卡名定址)
#   "0,2"              -> 0          (按卡号定址)
case "${DEV}" in
	CARD=*) CARD="${DEV#CARD=}"; CARD="${CARD%%,*}" ;;
	*)      CARD="${DEV%%,*}" ;;
esac

[ -z "${CARD}" ] && { echo "无法从 '${DEV}' 解析出卡" >&2; exit 1; }

# 1) dmix 的 slave pcm —— 实际出声的装置。
#    ⚠️ 必须排除注解行(`/^[[:space:]]*#/!`): 本档的注解里就写着 `pcm "hw:CARD=HDMI,DEV=0"`
#    当例子, 不排除的话每切一次音源就把说明文字一起改掉, 久了注解会与事实不符、误导下一个人。
#    (内建的 emuelec-utils setauddev 没做这个排除, 是它的老毛病, 别照抄。)
sed -i "/^[[:space:]]*#/! s|pcm \"hw:.*|pcm \"hw:${DEV}\"|" "${ASOUND}"

# 2) 所有 `card <x>` 行 —— softvol 的 control.card 与 ctl.!default 的 card。
#    这两处在本档里是仅有的两个 `card ` 开头行, 一起换掉即可。
#    ⚠️ 之所以敢一网打尽: asound.conf 由我们自己维护(见 md1000-boot-fixes),
#    结构固定。若将来模板里新增了不该跟着换的 card 行, 要改成分区块处理。
sed -i "/^[[:space:]]*#/! s|^\([[:space:]]*\)card .*|\1card ${CARD}|" "${ASOUND}"

# 3) 硬件层: 有些机型(E900V22C)HDMI 与 AV 共用同一个控制器, 光改路由不够 ——
#    选了 AV 之后 HDMI 仍在同时出声, 得额外把 HDMI 那条输出路径静音。
#    ★用控制项名称定址、且先确认它存在★: numid 会随内核/机型变动;
#    没有这个控制项的机型(MD1000 是两张独立的卡, 切换本身就是真切换)直接跳过。
if [ -n "${LABEL}" ] && amixer -c "${CARD}" controls 2>/dev/null | grep -q "Audio hdmi-out mute"; then
	# 选 HDMI -> 不静音; 选其它输出(AV / 光纤) -> 把 HDMI 静音, 让选中的输出独占。
	if [ "$(echo "${LABEL}" | tr '[:lower:]' '[:upper:]')" = "HDMI" ]; then
		MUTE=off
	else
		MUTE=on
	fi
	amixer -c "${CARD}" cset name='Audio hdmi-out mute' "${MUTE}" >/dev/null 2>&1
fi

exit 0
