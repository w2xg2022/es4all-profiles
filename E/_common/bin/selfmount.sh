#!/bin/sh
# es4all: 开机自挂载(机制层) —— 由 es4all-selfmount.service 在 ES 启动【之前】执行。
#
# 解决两件事, 而且两件是同一个根:
#
# ① **自己编的 ES 撑不过重开机**
#    EmuELEC 的 /usr 是只读 squashfs, 换 ES 只能 bind-mount 盖上去。
#    但 mount 不持久 —— 手动挂的那份重开机就没了, 于是又跑回固件自带的旧版,
#    而版本号还长得很像, 极容易误判成「我的改动没生效」。
#    (实机踩过: 页脚显示 V1.1, 但 /storage 里躺着的是自己编的 V1.2pre。)
#
# ② **想覆盖 /usr/bin 里的发行版脚本, 却不想为此重编固件**
#    例: set_ppsspp_joy.sh / set_flycast_joy.sh 里那两张【写死的键位对照表】——
#    要让独立模拟器的键位跟着 ES 走, 就得换掉那两支, 而它们在只读的 /usr/bin。
#    只要把同名档放进 override 目录, 本脚本就 bind-mount 盖上去, 重编固件免了。
#
# ★为什么用 bind-mount 而不是 PATH 前置★
#   ppsspp.sh / flycast.sh 确实是用**裸名**呼叫(`set_ppsspp_joy.sh`), 看起来 PATH
#   前置就够。但那些脚本开头都 `. /etc/profile`, 而 profile 会重设 PATH ——
#   到底谁先谁后要看每支脚本怎么写, 是会随上游改动而悄悄失效的假设。
#   bind-mount 直接换掉档案本身, 不依赖任何顺序。

set -u

OVERRIDE_DIR=/storage/.config/es4all/override
ES_BIN=/storage/es4all-emulationstation
LOG=/storage/.config/es4all/selfmount.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }

# 已经挂过就跳过(本服务是 oneshot, 但重跑要安全)。
bind_over() {
	src="$1"; dst="$2"
	[ -e "${src}" ] || return 0
	[ -e "${dst}" ] || { log "跳过 ${dst}: 目标不存在"; return 0; }
	if mountpoint -q "${dst}"; then
		log "跳过 ${dst}: 已经是挂载点"
		return 0
	fi
	chmod 0755 "${src}" 2>/dev/null
	if mount --bind "${src}" "${dst}"; then
		log "已挂载 ${src} -> ${dst}"
	else
		log "★挂载失败★ ${src} -> ${dst}"
	fi
}

log "===== selfmount 开始 ====="

# ① 自己编的 ES 本体
bind_over "${ES_BIN}" /usr/bin/emulationstation

# ② /usr/bin 覆盖: override/ 里每个档都盖到 /usr/bin/<同名>
#    ★只盖【本来就存在】的档★(bind_over 里有守卫) —— 覆盖一个不存在的目标没有意义,
#    而且那通常表示档名打错了, 静默建立反而会让人以为生效了。
#
# ★这个回圈【没东西可挂】时一定要留话★ —— 实机踩过(2026-08-02):
# 开机时 override/ 还是空的(档案是 ES 起来后由 profile 同步才送下来的),
# 回圈一个档都没跑, log 就只剩开始/结束两行, 跟成功挂完长得一模一样;
# 结果 PSP/DC 用的还是固件里那份写死键位表, 而 log 看起来毫无异状。
# 无声的成功与无声的失败必须长得不一样。
n=0
if [ -d "${OVERRIDE_DIR}" ]; then
	for f in "${OVERRIDE_DIR}"/*; do
		[ -f "${f}" ] || continue
		n=$((n + 1))
		bind_over "${f}" "/usr/bin/$(basename "${f}")"
	done
	[ "${n}" -eq 0 ] && log "★注意★ ${OVERRIDE_DIR} 里没有可挂的档(profile 同步可能还没跑)"
else
	log "★注意★ ${OVERRIDE_DIR} 不存在, 本轮没有任何 /usr/bin 覆盖"
fi

log "===== selfmount 结束 ====="
exit 0
