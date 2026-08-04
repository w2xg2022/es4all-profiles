#!/bin/bash
# es4all: profile 套用钩子(机制层) —— ES 每次启动、profile 同步之后调用一次。
#
# ★这支是【通用入口】★: ES 只认得 "有没有 bin/apply.sh" 这一件事, 里面做什么完全由
# 本仓库决定。于是以后要新增任何一次性设定(PSP 预设、keylayout、模拟器选择…),
# 都只需要改本仓库, **不必再动 ES、更不必重编固件**。
#
# 幂等: 每一项各自用标记档把关, 只在【第一次】套用。
# ★为什么是「预设」而不是「强制」★: 使用者在 PPSSPP 里自己改过画质/后端之后, 不该被
# 下一次开机改回去。要强制的话就是每次启动都写(像 ppsspp.sh 对 UI 语言那样), 但那是
# 「跟随 ES 设定」的语意, 与「出厂预设值」不同, 别混为一谈。

set -u

# ★必须 source /etc/profile★ —— set_ee_setting / get_ee_setting 是**定义在那里面的
# shell 函式**, 不是 /usr/bin 里的可执行档。少了这行, 下面 `command -v set_ee_setting`
# 一律不成立, 所有靠它写的设定会被**静默跳过**:选单看起来正常、标记档也照样建立,
# 但设定一个都没写进 emuelec.conf。实机踩过(2026-08-02):PSP/DC 的模拟器预设
# 从头到尾没生效, 先前看到的 psp.core=PPSSPPSDL 是韧体本来就有的值, 不是这里设的。
# 这类「守卫把自己挡掉」的失败最难发现, 因为它不报错也不留痕迹。
# ⚠️ source 前后要关掉 `set -u`:EmuELEC 的 /etc/profile.d/10-locale.conf 会引用未定义的
#    LOCPATH, 在 `set -u` 下直接让整支脚本中止(实机踩过, 表现同样是「什么都没发生」)。
set +u
[ -f /etc/profile ] && . /etc/profile
set -u

# ---------------------------------------------------------------------------
# 三边差异: 只有几个路径不同, 在这里一次吸收
# ---------------------------------------------------------------------------
# ★2026-08-03 本档提升到 common/, 三个发行版共用同一支★
#   原本只有 emuelec 有, 结果 rocknix / armbian【什么一次性设定都不会跑】——
#   PSP/DC 预设没套、selfmount 服务没人 enable、钩子的执行位没人补。
#   而 ES 呼叫的是 target 无关的 scriptPath("apply.sh"), 少了它就整段静默不执行。
#
# ★判据用「设定档在哪」而不是猜发行版名★: 那个档的位置就是 ES 自己(Paths.cpp)
#   认定的 config store, 与 ES 同源; 拿 /etc/os-release 去猜等於多养一套真相。
if [ -f /storage/.config/system/configs/system.cfg ]; then
	TARGET=rocknix
	SYS_CONF=/storage/.config/system/configs/system.cfg
	ROOT_CFG=/storage/.config
elif [ -d /storage/.config/emuelec ]; then
	TARGET=emuelec
	SYS_CONF=/storage/.config/emuelec/configs/emuelec.conf
	ROOT_CFG=/storage/.config
else
	TARGET=armbian
	ROOT_CFG="${HOME:-/storage}/.config"
	SYS_CONF="${HOME:-/storage}/.emulationstation/system.conf"
fi

# ★独立模拟器的【名字】三边不一样, 而且 emulator 与 core 两个键还可能不同值★
#   emuelec : psp.emulator=PPSSPPSDL   psp.core=PPSSPPSDL
#   rocknix : psp.emulator=ppsspp      psp.core=ppsspp-sa   (两个键不同值!)
#   armbian : 没有独立 PPSSPP, 走 libretro -> 不设这两个键
#   值取自各自 es_systems.cfg 的 <emulator name=…>/<core>。写错的表现是
#   「选单显示 A、实际跑 B」或干脆开不了, 而且**不会报错**。
case "${TARGET}" in
	rocknix)
		PSP_EMULATOR=ppsspp;    PSP_CORE=ppsspp-sa
		DC_EMULATOR=flycast;    DC_CORE=flycast-sa
		;;
	emuelec)
		PSP_EMULATOR=PPSSPPSDL; PSP_CORE=PPSSPPSDL
		DC_EMULATOR=flycastsa;  DC_CORE=flycastsa
		;;
	*)
		PSP_EMULATOR=""; PSP_CORE=""
		DC_EMULATOR=""; DC_CORE=""
		;;
esac

STAMP_DIR="${ROOT_CFG}/es4all"
DATA_DIR="${ROOT_CFG}/es4all"                 # 机型资料的落点
OVERRIDE_DIR="${ROOT_CFG}/es4all/override"    # /usr/bin 覆盖档(由 selfmount.sh bind-mount)
ES_CONFIG_DIR="${ROOT_CFG}/emulationstation"  # ES 的使用者设定目录(scripts/ 钩子在这底下)
PPINI="${ROOT_CFG}/ppsspp/PSP/SYSTEM/ppsspp.ini"

mkdir -p "${STAMP_DIR}"

# 写一个 key 到 ES 的 config store。等价於 EmuELEC 的 set_ee_setting, 但三边都成立。
# ★为什么不用 set_ee_setting★: 那是 EmuELEC /etc/profile 里的 shell 函式,
# rocknix / armbian 根本没有 —— 用它等於那两边永远静默跳过(而且标记档照建, 看起来像做了)。
conf_set() {
	local key="$1" val="$2"
	[ -n "${SYS_CONF}" ] || return 0
	mkdir -p "$(dirname "${SYS_CONF}")"
	[ -f "${SYS_CONF}" ] || : > "${SYS_CONF}"
	if grep -q "^${key}=" "${SYS_CONF}" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${val}|" "${SYS_CONF}"
	else
		echo "${key}=${val}" >> "${SYS_CONF}"
	fi
}

# ---------------------------------------------------------------------------
# PSP 预设: 独立模拟器 + 画面后端 + 内部分辨率
# ---------------------------------------------------------------------------
psp_defaults() {
	local stamp="${STAMP_DIR}/.psp-defaults-applied"

	# 全机种预设值。机型资料档可覆盖(见下), 没有资料档就用这两个。
	#   BACKEND: OPENGL | VULKAN     RESOLUTION: 内部分辨率倍数(2 = 2X)
	# ★为什么预设是 OpenGL 而不是 Vulkan★: Vulkan 要驱动真的支援才快, 在旧的
	# Mali(如 G31/450)上不是变慢就是黑屏; OpenGL 是所有机型都跑得起来的安全值。
	# 跑得动 Vulkan 的机型(如 MD1000/RK3566 的 G52)自己用机型资料档覆盖。
	local BACKEND=OPENGL
	local RESOLUTION=2

	# 机型资料(<T>/<机型>/storage-config/es4all/psp-defaults.conf), 有才覆盖。
	# 格式就是两行 KEY=VALUE, 见 E/MD1000 那份。
	local conf="${DATA_DIR}/psp-defaults.conf"
	if [ -f "${conf}" ]; then
		# 只取认得的两个键, 不 source 整个档(资料档不该有执行能力)
		local v
		v=$(sed -n 's/^[[:space:]]*BACKEND[[:space:]]*=[[:space:]]*//p' "${conf}" | head -1)
		[ -n "${v}" ] && BACKEND="${v}"
		v=$(sed -n 's/^[[:space:]]*RESOLUTION[[:space:]]*=[[:space:]]*//p' "${conf}" | head -1)
		[ -n "${v}" ] && RESOLUTION="${v}"
	fi

	# ★2026-08-02:标记档改成【记住套用了什么值】, 不再只记「做过了」★
	#   实机踩到的洞(MD1000): 标记档 08:27 生成、机型资料档 11:57 才下发 ——
	#   `[ -f stamp ] && return` 在资料到位【之前】就永久封印了这段,
	#   于是 psp-defaults.conf 写着 VULKAN, 实机却一直是 OpenGL,
	#   而且**完全静默**, 看设定档只会觉得「设了没用」。
	#   改成比对内容后, 这两种情形都能自愈:
	#     ①机型资料晚于首次开机才下发  ②我们日后调整了建议值(改 conf 就会重新套用)
	#   ⚠️ 仍**不是**每次开机强制: 值没变就不动, 使用者自己在 PPSSPP 里改过的画质会留着。
	#     只有「profile 给的建议值本身变了」才会再套一次 —— 那正是我们要它生效的时候。
	#   (旧的空标记档内容不等于任何 want, 会自动重跑一次, 不必手动清。)
	local want="BACKEND=${BACKEND} RESOLUTION=${RESOLUTION}"
	[ "$(cat "${stamp}" 2>/dev/null)" = "${want}" ] && return 0

	# ① 预设用【独立】PPSSPP 而不是 libretro 核心。
	#    psp.core / psp.emulator 优先于 es_systems.cfg 的默认值(两个键都要设,
	#    ES 的选单与实际启动路径分别读它们)。
	#    armbian 没有独立 PPSSPP(走 libretro), 那边 PSP_CORE 是空的 -> 不写这两个键。
	#    ★不能写空值★: 写了 psp.core= 会让 ES 认为使用者选了「空」的模拟器。
	if [ -n "${PSP_CORE}" ]; then
		conf_set psp.core "${PSP_CORE}"
		conf_set psp.emulator "${PSP_EMULATOR}"
	fi

	# ② 后端与分辨率写进 ppsspp.ini。
	#    ⚠️ PPSSPP 写这行的格式是 `GraphicsBackend = 3 (VULKAN)` —— 数字后面还带括号名称,
	#    只写数字虽然能读, 但下次 PPSSPP 存档时格式会被它自己改回去; 这里直接照它的格式写,
	#    比对/除错时看得懂, 也不会每次开机都被判定成「变更」。
	if [ -f "${PPINI}" ]; then
		local BE_NUM BE_NAME
		case "$(echo "${BACKEND}" | tr '[:lower:]' '[:upper:]')" in
			VULKAN) BE_NUM=3; BE_NAME=VULKAN ;;
			*)      BE_NUM=0; BE_NAME=OPENGL ;;
		esac
		sed -i "s|^GraphicsBackend = .*|GraphicsBackend = ${BE_NUM} (${BE_NAME})|" "${PPINI}"
		sed -i "s|^InternalResolution = .*|InternalResolution = ${RESOLUTION}|" "${PPINI}"
	fi

	echo "${want}" > "${stamp}"
	echo "es4all: PSP defaults applied -> ${want}"
}

# ---------------------------------------------------------------------------
# 开机自挂载服务: 让自己编的 ES 与 /usr/bin 覆盖档撑过重开机
# ---------------------------------------------------------------------------
# ★这项不用标记档、每次都跑★: enable 是幂等的, 而且刷新固件、换 /storage 之后
# 这个 enable 会消失 —— 每次开机确认一遍才不会某天默默失效。
# (失效的表现极隐蔽: ES 跑回固件自带的旧版, 版本号还很像, 会被误判成「改动没生效」。)
# ★改成扫描, 不再写死单一服务名★(2026-08-03): profile 以後会下发不只一个 unit
# (目前有 es4all-selfmount、es4all-storage)。写死名字的话, 新增一个 unit 就要同时改这里,
# 而漏改的表现是「档案下发了、服务却没人 enable」—— 又一个静默失效。
selfmount_service() {
	[ -d /storage/.config/system.d ] || return 0
	command -v systemctl >/dev/null 2>&1 || return 0

	local u name
	for u in /storage/.config/system.d/es4all-*.service; do
		[ -f "${u}" ] || continue
		name=$(basename "${u}")
		if ! systemctl is-enabled "${name}" >/dev/null 2>&1; then
			systemctl daemon-reload 2>/dev/null
			systemctl enable "${name}" >/dev/null 2>&1
		fi
	done

	# ★drop-in 不需要 enable, 但需要 daemon-reload 才会被读进来★
	# (例: emustation.service.d/10-es4all-storage.conf —— 聚合就挂在那上面)
	# 新下发的 drop-in 若没 reload, 会等到下次开机才生效, 而症状是
	# 「档案明明在、功能就是没跑」—— 又一个静默慢一拍。
	if [ -n "$(ls -d /storage/.config/system.d/*.service.d 2>/dev/null)" ]; then
		systemctl daemon-reload 2>/dev/null
	fi
}

# ---------------------------------------------------------------------------
# 开机自挂载服务: 同步之后【补跑一次】
# ---------------------------------------------------------------------------
# ★这是一个顺序死结, 不补跑就永远慢一拍★(实机踩过 2026-08-02):
#   selfmount 是 oneshot + Before=emustation.service, 一次开机只在 ES 【之前】跑一次;
#   而 override/ 里的档是 ES 起来【之后】才由 profile 同步送下来的。
#   => 新的 override 档在拿到它的那一轮开机永远挂不上, 要等下一次重开机。
#   中间那一轮的表现是「档案明明下发成功, 却完全没作用」, 而且 log 无异状。
#
# 补跑安全: bind_over 对已经是挂载点的目标会跳过, 所以重跑只会补上还没挂的那些,
# 不会去动执行中的 ES 本体(它开机时就挂好了)。
#
# ★判断「挂了没」要查 /proc/mounts, 不能用 mountpoint★(实机踩过 2026-08-02):
# busybox 的 mountpoint 只认目录, 对档案一律 exit 1 —— 拿它当条件的话, 这里会判定
# 「永远没挂」, 于是每次 ES 启动都重启一次服务, 而 selfmount 那边同样判定「还没挂」,
# 就一层一层叠上去。与 selfmount.sh 的 is_bound() 是同一条规则, 两边必须一致。
selfmount_refresh() {
	[ -d "${OVERRIDE_DIR}" ] || return 0
	command -v systemctl >/dev/null 2>&1 || return 0

	local f target need=0
	for f in "${OVERRIDE_DIR}"/*; do
		[ -f "${f}" ] || continue
		target="/usr/bin/$(basename "${f}")"
		# 只看【本来就存在】的目标 —— 与 selfmount.sh 的守卫同一条规则,
		# 否则一个打错字的档名会让这里每次开机都白白重启服务。
		[ -e "${target}" ] || continue
		awk -v p="${target}" '$2 == p { found = 1 } END { exit !found }' /proc/mounts || need=1
	done

	[ "${need}" -eq 1 ] && systemctl restart es4all-selfmount.service >/dev/null 2>&1
	return 0
}

# ---------------------------------------------------------------------------
# 键位透传的触发钩子: 补执行位
# ---------------------------------------------------------------------------
# ES 存完键位后会 fireEvent("controls-changed"), Scripting 会去跑
# scripts/controls-changed/ 里的每一支 —— 但它是【直接执行档案本身】, 没有执行位就跑不起来。
# 而 profile 同步只对落在 bin/ 的档补执行位(见 Es4allProfiles.cpp 的 needsExecBit),
# 这支钩子落在 storage-config/ 底下, 送到就是 -rw-, 不补就是「下发成功但完全没效果」。
#
# ★为什么钩子不干脆放 bin/★: 那个落点是 /storage/.config/es4all/bin, ES 的事件机制
# 只认 scripts/<事件名>/ 这个位置, 放别处它根本不会去看。
# configscripts/ 里的档同理: inputconfiguration.sh 会去执行它们, 没有执行位一样跑不起来。
input_hook() {
	local dir
	for dir in "${ES_CONFIG_DIR}/scripts/controls-changed" \
	           "${ES_CONFIG_DIR}/scripts/configscripts"; do
		[ -d "${dir}" ] || continue
		chmod 0755 "${dir}"/*.sh 2>/dev/null
	done

	# ★autostart 也要补执行位★(2026-08-04)
	#   profile 同步只对落在 bin/ 的档补执行位(见 Es4allProfiles 的 needsExecBit),
	#   而 ROCKNIX 的 /storage/.config/autostart/ 底下那些档【必须可执行】才会被跑。
	#   少了这一步的表现是「档案明明在、开机却什么都没发生」—— 与 controls-changed
	#   钩子当初那个坑一模一样, 所以顺手一起处理。
	[ -d "${ROOT_CFG}/autostart" ] && chmod 0755 "${ROOT_CFG}"/autostart/* 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# DC 预设: 用独立模拟器(Flycast-SA)而不是 libretro 核心
# ---------------------------------------------------------------------------
# 与 PSP 同一套做法: dreamcast.core / dreamcast.emulator 两个键都要设 ——
# ES 的选单与实际启动路径分别读它们, 只设一个会出现「选单显示 A、实际跑 B」。
# 值取自 es_systems.cfg 的 <emulator name="flycastsa"><core default="true">flycastsa。
# ★同样只在第一次套用★(标记档把关): 使用者后来自己改回 libretro 不该被开机流程覆盖。
# 这里的值写死在本档、没有机型资料档, 所以不会有 psp_defaults 那个「资料晚到」的洞;
# 但要是哪天 DC 也加了机型资料, 记得比照 psp_defaults 改成【比对内容】的标记档。
dc_defaults() {
	local stamp="${STAMP_DIR}/.dc-defaults-applied"
	[ -f "${stamp}" ] && return 0

	# 名字见档首的 per-target 表(emuelec=flycastsa, rocknix=flycast/flycast-sa)。
	[ -n "${DC_CORE}" ] || return 0
	conf_set dreamcast.core "${DC_CORE}"
	conf_set dreamcast.emulator "${DC_EMULATOR}"

	touch "${stamp}"
}

# ---------------------------------------------------------------------------
# 开机音量预设
# ---------------------------------------------------------------------------
# ROCKNIX 的 autostart/050-audio 在【没有】audio.volume 时用写死的 60 —— 对电视盒
# 偏小(它们透过 HDMI 推外接喇叭/电视, 与 ROCKNIX 常见的掌机不同), 而且那个 60
# 首次开机就会被写回 system.cfg, 从此变成「使用者的值」, 固件端再怎么改预设都追不回来。
#
# 所以既有机器只能从设定档这一侧改。★仅此一次★: 标记档记住我们套过的值,
# 使用者之后自己调的音量不会被开机流程覆盖(与 psp_defaults 同一套语意)。
# 日后若调整建议值, 改本档的 WANT 即可重新套用一次。
#
# 固件侧另有一条互补的路: RK3566 的 options 宣告 DEVICE_VOLUME="80"(见 w2xg2022/rocknix
# 54c2b366), 那条只对【全新刷机、还没有 audio.volume】的机器生效。两条不冲突:
# 新机走固件预设, 既有机器走这里。
audio_volume_default() {
	local want=80
	local stamp="${STAMP_DIR}/.audio-volume-applied"
	[ "$(cat "${stamp}" 2>/dev/null)" = "${want}" ] && return 0

	# 只有 ROCKNIX/EmuELEC 这类把音量记在 config store 的发行版才有这个键;
	# ARMBIAN 侧音量走 ALSA 的 ~/.asoundrc, 不适用。
	[ "${TARGET}" = "armbian" ] && return 0

	conf_set audio.volume "${want}"
	# 立刻套用一次, 免得非要重开机才听得出差别。ROCKNIX 有 /usr/bin/volume。
	[ -x /usr/bin/volume ] && /usr/bin/volume "${want}" >/dev/null 2>&1
	echo "${want}" > "${stamp}"
	echo "es4all: audio volume default applied -> ${want}"
}

psp_defaults
dc_defaults
audio_volume_default
selfmount_service
selfmount_refresh
input_hook

exit 0
