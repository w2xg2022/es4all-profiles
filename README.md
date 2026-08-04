# es4all-profiles —— 机型专属配置文件

ES4All（armbian / emuelec / rocknix 三个 target）在**运行期**下发的机型专属配置。

目的：把「改一行数据就得重编固件、或至少发一包 ES」这件事拆掉。
本仓库的改动**不经过 ES 发版，也不经过云编译**，设备端更新后重启即生效。

## ⚠️ 能放什么、不能放什么

**能放**：纯数据表、脚本、设定档 —— 改完重启（ES 或系统）就生效的东西。
例：音源输出映射表、installtoemmc 板子表、PSP controls.ini、keylayout、asound 模板。

**不能放**：dts / dtb / 内核 config / u-boot，以及任何编进 ES 二进制的东西。
这些只能重编。**别把「开了这个仓库就不用云编译」当预期** —— AV 音频那类问题多数在 dts 层，本仓库救不了。

## 目录约定

```
<scope>/<dest-root>/<相对路径>
```

**scope（解析顺序，后者覆盖前者）**

| rank | 路径 | 意思 |
|---|---|---|
| 0 | `common/` | 三个发行版共用（目前空著，见下方「保底只留一份」） |
| 1 | `<target>/_common/` | 该发行版全机型 |
| 2 | `<target>/<DEVICE>/_common/` | 该芯片家族全机型 |
| 3 | `<target>/<DEVICE>/<SUBDEVICE>/` | 单一机型 |

`<target>` = `armbian` / `emuelec` / `rocknix`（**用发行版全名，不用 A/E/R 缩写** ——
缩写省不了几个字，却让人每次都要回想 A 是哪个；目录名是给人读的）。

`DEVICE` / `SUBDEVICE` **与建置系统同名同义**，别自己另创一套写法。现有对照
（来源＝云编译 workflow 里的 `Resolve PROJECT/DEVICE for model`）：

| SUBDEVICE | PROJECT | DEVICE |
|---|---|---|
| `MD1000` | Rockchip | `RK3566` |
| `X98mini` / `E900V22C` | Amlogic-ce | `Amlogic-no` |

### ⚠️ 两层的比对规则**不一样**，是刻意的

- **DEVICE = 全等比对**。它是建置变数，值本来就是精确字串。
  用子串会让 `RK3566` 命中 `RK356x`。
  来源是「候选集合」而非单一档：`/etc/os-release` 的
  `COREELEC_DEVICE`/`ROCKNIX_DEVICE`/`LIBREELEC_DEVICE`、`/ee_arch`、
  Armbian 的 `BOARDFAMILY`，任一对上就算命中。
  **为什么要收集成集合**：同一台机器的 DEVICE 在不同地方可能写得不一样 ——
  MD1000 的云编译用 `DEVICE=RK3566`，但本地曾用 `DEVICE=MD1000` 编过，
  於是 `/ee_arch` 里躺的是 `MD1000`。只认一个来源就会「明明是这台却不命中」，而且静默。
- **SUBDEVICE = 子串比对**。它拿 `/proc/device-tree/model` 比，那是一长串描述，
  用全等永远对不上。

> 为什么不是三个仓库：三边大部分内容相同，拆开必然漂移。
> 真正的差异只有【落点路径】和【消费脚本】，用 scope 覆盖表达就够。

### `common/` 放什么（2026-08-05 现况）

| 档 | 为什么在 common |
|---|---|
| `bin/apply.sh` | ES 呼叫的是 target 无关的 `scriptPath("apply.sh")`。原本只有 emuelec 有，结果 rocknix / armbian **什么一次性设定都不会跑**（PSP/DC 预设没套、selfmount 没人 enable、钩子执行位没人补）。三边差异只有几个路径，脚本内 detect 掉即可 |
| `bin/installtoemmc.sh` | 写入 eMMC 的**包装层**（脱离 ES 的 cgroup、把画面交给终端机、挡 automount、成功后关机）。这些坑与分区方案无关，两边一模一样。★提升到 common 之前 ROCKNIX 没有这层★：ES 是背景呼叫的，引擎走到 `read ans` 等 YES 时读到 EOF 就 abort，输出还被 `/dev/null` 吃掉——表现是「按了完全没反应」 |
| `bin/es-input-to-retroarch.sh` | rocknix / armbian 没有 EmuELEC 那套 configscripts，用它把 `es_input.cfg` 转成 RA autoconfig。★2026-08-04 从 python 改写成 sh + awk★：python3 不是三边都保证有，少了它整条链**静默失效**（精灵跑完 RA 却完全没变），awk 是 busybox 内建 |
| `bin/es-joypad-evdev.sh` | ROCKNIX 专用的第二份 autoconfig：档名与 `input_device` 改用 **udev 名**，因为 `setsettings.sh` 是按 `/proc/bus/input/devices` 的名字找档，而 `es_input.cfg` 记的是 SDL 名——对不上就永远读不到我们这份。★内容照抄 es_input 的编号，不要去问 evdev★（理由见档头：山寨手柄 A/B 照位置报、X/Y 照字母报） |
| `bin/es-joypad-evdevmap.sh` | 上一支的辅助：从能力位取装置名。它算的编号刻意不用 |
| `bin/es-sdl-gcdb.sh` | 产一行 SDL gamecontrollerdb 对照。给**走 SDL 语意的模拟器**（PPSSPP）用——它们拿到的是 BACK/START 而不是按钮编号，哪颗实体键算 BACK 是 db 决定的，★改 controls.ini 的数字改不动★ |
| `bin/psp-hotkeys.sh` | PPSSPP 的和弦（每次启动重写，因为乾净退出会洗掉）。热键要两层查表：es_input 的实体编号 → db 的语意名 → NKCODE。与 EmuELEC 的 `ppsspp.sh` 同一套逻辑 |
| `bin/es-flycast-mapping.sh` | DC（flycast）的 `[combo]`。ROCKNIX 原本靠 gptokeyb，但**它不读 es_input.cfg**、预设热键是 Guide 键而这类手柄多半没有，於是组合键整套按不出来 |
| `bin/es4all-storage.sh` / `es4all-storage-detach.sh` / `mergerfs` | 内外盘聚合。挂在各 target 的 ES 服务 `ExecStartPre` 上，所以「重启 ES」＝「重新套用挂载」 |
| `bin/es4all-gamelist-merge.py` | 聚合时合并两侧的 gamelist |
| `storage-config/…/controls-changed/10-inputconfig.sh` | 翻译**工具**三边不同，但「什么时候翻译」是同一件事，不该各写一份钩子 |

> 键位那一整排（`es-input-to-retroarch` / `es-joypad-evdev` / `es-sdl-gcdb` / `psp-hotkeys` /
> `es-flycast-mapping`）看起来很多，其实是同一句话的五种方言：
> **键位的唯一真相是使用者在精灵里按的那一颗**，各模拟器只是吃的格式不同。

⚠️ **三边同名不同内容是设计，不是漂移**：`setaudio.sh`（裸 ALSA / PipeWire / `~/.asoundrc`）、
`installtoemmc-engine.sh`（两套分区逻辑）、selfmount unit（`essway` vs `emustation`）都必须各写一份。
（**包装层** `installtoemmc.sh` 相反——那层与分区方案无关，已提升到 `common/`。）
`gen_manifest.sh` 的一致性检查因此改成**白名单**（`SHARED_SAME`），目前只盯 `bin/selfmount.sh`
—— 那是唯一刻意维持位元组相同的复本。噪音多的检查等於没有检查。

### 共用层：真实需求是「部分 target 共用」，不是「三边共用」

`common/` 曾经一直空著，不是没人用，是**猜错了共用的维度**：当初以为会沿
「三边 vs 单边」分，实际是沿「**唯读 squashfs（emuelec/rocknix） vs 可写 rootfs（armbian）**」分。
例：`selfmount.sh` 在 emuelec 与 rocknix 位元组相同，armbian 根本不需要 bind-mount。

（**2026-08 起 `common/` 已经满了**——见上表。真正共用的东西後来自己长出来了：
键位翻译、聚合、写入 eMMC 的包装层。当初猜错的是**哪些**东西共用，不是「有没有」。）

**结论是不为此加组合 scope**（`ER/` 这种；下次可能又是别的组合，解析规则会越长越乱），
改用工具挡住会实际发生的事 —— 忘记同步。`tools/gen_manifest.sh` 会比对
**各 target 的 `_common/` 底下相同相对路径**的档，内容不同就警告。
机型资料档不在比对范围（`audio_outputs.cfg` 每台本来就不同，那是设计不是漂移；
噪音多的检查等於没有检查）。

## 机制 vs 资料：什么放哪一层

这不是第四层，是**摆放约定**：

| 放哪 | 放什么 | 例子 |
|---|---|---|
| `<target>/_common/bin/` | **机制**——怎么做 | `setaudio.sh` 的切换流程 |
| `<target>/<DEVICE>/<SUBDEVICE>/` | **资料**——这台是什么 | `audio_outputs.cfg`、`asound.conf`、`emmc-layout.conf` |

机制放在 target 层而不是 `common/`，是因为做法本来就分家：
EmuELEC 裸 ALSA 改 asound.conf，ROCKNIX 走 PipeWire 改默认 sink。

**逃生门**：若某台的流程真的不同（不只是参数不同，例如 MD1000 是重分区、
X98mini 是重用原厂分区），在 `<target>/<DEVICE>/<SUBDEVICE>/bin/` 放一支同名脚本即可盖掉
`_common` 那份 —— 覆盖规则本来就是机型层赢，客户端不必改。

### ⚠️ 机型档是「整份取代」，不是叠加

同一个落点路径上，机型层的档案会**整份取代**上层同名档。所以：

- 机型档只需要写自己这台（对 `audio_outputs.cfg` 就是一行），不必带别的机型
- **档名必须与上层完全相同**才会取代。取成 `audio_outputs_md1000.cfg`
  会变成两个档并存，而 ES 只读得懂它认得的那个名字 —— 静默失效

### 保底只留一份，就是韧体内建那份

`audio_outputs.cfg` 的保底放在 **es4all 仓库的 `resources/audio_outputs.cfg`**，
本仓库**刻意不再保留 `common/` 版本**。

理由是可达性：保底唯一有意义的时机是「还没连上网」，而那时候本仓库的
`common/` 根本拿不到；等拿得到了，机型档也一并拿得到了。两个地方各放一份
同样的东西，只会漂移。

韧体那份**只列 HDMI**，不带任何已验证的 AV / 光纤结果。它的用途不是选单，
而是让 ES 启动时能取到 HDMI 的 `card,device` 去种开机默认值 —— 少了它，
EmuELEC 无值时会退回 `hw:0,0`，那在 X98mini 是死路无声。
（选单在少于两项时不显示，所以没下载 profile 的机器看不到这一项，但输出是对的。）

要改某台的输出 → 改本仓库的机型档，不要动韧体那份。

### 覆盖 /usr/bin 里的发行版脚本(不必重编固件)

把同名档放进 `<target>/_common/storage-config/es4all/override/`，
落到设备的 `/storage/.config/es4all/override/`，
开机时由 `es4all-selfmount.service` → `bin/selfmount.sh` **bind-mount 盖到 `/usr/bin/<同名>`**。

这是「膠水不再需要住在只读分区」的关键：改一支发行版脚本从此只要改本仓库。
`selfmount.sh` 会自己补执行位，所以放 `storage-config/` 就够，不必另立落点。

**为什么是 bind-mount 而不是 PATH 前置**：`ppsspp.sh` / `flycast.sh` 确实是用**裸名**
呼叫（`set_ppsspp_joy.sh`），看起来 PATH 前置就够；但那些脚本开头都 `. /etc/profile`，
而 profile 会重设 PATH —— 谁先谁后要看每支脚本怎么写，是会随上游改动悄悄失效的假设。
bind-mount 直接换掉档案本身，不依赖任何顺序。

★同一个机制也让 ES 本体撑过重开机★：`/storage/es4all-emulationstation` 会被盖到
`/usr/bin/emulationstation`。手动 mount 不持久 —— 重开机就跑回固件自带的旧版，
而版本号长得很像，极容易误判成「我的改动没生效」（实机踩过）。

⚠️ **顺序死结（已修，别再拿掉）**：`selfmount` 是 oneshot + `Before=emustation.service`，
一次开机只在 ES **之前**跑一次；而 override 里的档是 ES 起来**之后**才由 profile 同步送下来的。
=> 新档在拿到它的那一轮开机永远挂不上，要等下一次重开机，中间那一轮的表现是
「档案明明下发成功却完全没作用」且 log 无异状。
所以 `bin/apply.sh` 的 `selfmount_refresh()` 会在同步之后**补跑一次**
（`bind_over` 对已挂载的目标会跳过，重跑安全）。
`selfmount.sh` 也会在**没有任何档可挂**时留一行 log —— 无声的成功与无声的失败不该长得一样。

**目前 override 里有什么**

| 档案 | 来源 | 为什么搬进来 |
|---|---|---|
| `set_ppsspp_joy.sh` | EmuELEC `packages/sx05re/emulators/PPSSPPSDL/scripts/` | 独立模拟器键位的**写死对照表**在这里；要让键位跟着 ES 走就得改它 |
| `set_flycast_joy.sh` | EmuELEC `packages/sx05re/emulators/flycastsa/scripts/` | 同上（DC） |

⚠️ 两支**当前与固件树位元组相同**（纯搬家，还没改行为）——这样才验得出 bind-mount
链路本身是对的。之后的修改都在本仓库进行。

### ⚠️ 档名可以有空格，但要知道它踩过什么

`Microsoft X-Box 360 pad.cfg` 是第一个带空格的档（RetroArch 的 autoconfig 按手柄名
命名，手柄名本来就带空格）。它一进来就踩爆两处，都不是会报错的那种：

- `tools/gen_manifest.sh` 原本用 `for f in $files`，按空白拆开 →
  一个档名变四个不存在的路径，manifest 里默默多出垃圾条目。已全面改成 `while read`。
- 客户端下载 URL 要**逐段** urlencode。`HttpReq::urlEncode` 会连 `/` 一起编成 `%2F`，
  整条丢进去会变成一个巨大的档名；不编则 GitHub raw 直接 404 →
  「这一档失败 → 整批放弃」，而其他档看起来都好好的。

### 固件 baseline：少数档两边都要有

一般来说本仓库的东西固件不必带（设备自己拉）。例外是**「还没拉到 profile 的那一刻
就必须存在」**的档，目前只有一个：

| 档 | 为什么固件也要有 |
|---|---|
| `configscripts/retroarch.sh` | 刷完机第一次开机会**强制跑键位精灵**（刻意的保底设计），精灵存完的**当下**就要有人把 `es_input.cfg` 翻译成 RetroArch 设定 —— 而那一刻通常还没连上网 |

**正本永远是本仓库，es4all 的 `dist/` 那份是产物。**
改完跑 `./tools/sync_baseline.sh` 同步过去；`gen_manifest.sh` 会顺手 `--check` 并警告。
两边各自维护必然漂移，而且**漂移了不会有人发现**——两份都能跑，只是行为不同。

### 内外部盘聚合（mergerfs）

`common/bin/mergerfs` —— **仓库里唯一的二进制档**（v2.42.0，官方 static aarch64 build，
strip 后 2.4 MB，ISC 授权，sha256 `93557dfb…`）。

⚠️ **为什么要收一个二进制进来**：这是本仓库第一次放非脚本的东西，值得说清楚。
把它放进固件（EmuELEC package）当然也行，但那样每次要动它就得跑一次云编译；
而它是个**静态、零依赖、不随机型变**的单一执行档，走 profile 下发完全够用，
也让「改聚合行为不必重编固件」这条原则保持完整。

⚠️ **假设 aarch64**：本仓库没有架构维度，而目前三个 target 的机器全是 aarch64。
哪天有 x86 机器，得先决定架构怎么表达（多一层 scope？还是按 target 分？）再放第二份。

**为什么不是 overlayfs**（2026-08-03 实机坐实，别再走回头路）：
overlayfs **无法用于 FAT/exFAT/NTFS，连当 lowerdir 都不行** ——
内核 `ovl_dentry_weird()` 会拒绝任何有自订 dentry 比对函式（`d_hash`/`d_compare`）的
档案系统，而那正是**大小写不敏感**档案系统的特徵。
多数人的 ROM 碟就是 FAT/exFAT（要在 Windows 上拷贝），所以那条路对多数使用者根本不可用。
mergerfs 是 FUSE 层的 union，**分支是什么档案系统都无所谓**；FUSE 本来就在映像里
（ntfs-3g 在用），无新增依赖。

实机验证（MD1000/EmuELEC）：内盘 ext4 + 外盘 vfat → 平台数 112 → 152，
psp 目录同时看到两边的 ISO，中文档名正常，聚合全程 1 秒。

### 键位精灵的触发钩子（controls-changed）

`<target>/_common/storage-config/emulationstation/scripts/controls-changed/10-inputconfig.sh`
→ 落到 `/storage/.config/emulationstation/scripts/controls-changed/`。

ES 存完键位会发 `controls-changed` 事件，`Scripting::fireEvent` 会把
`scripts/<事件名>/` 底下的每一支都跑一遍；这支就去调 `inputconfiguration.sh`，
由它把 `es_input.cfg` 翻译成 RetroArch / PSP / DC 的设定。

★为什么不沿用发行版原本那条路★：原本的触发写在 `es_input.cfg` 里的
`<inputAction type="onfinish">`。那个档在使用者可写的 `/storage`，会被 ES 自己覆写、
也常被部署或还原**整份取代** —— 那五行一掉，「精灵 → RA/PSP/DC」整条链就**无声断掉**：
精灵照跑、`es_input.cfg` 照更新，但没人去产生 `/tmp/joypads/*.cfg`，
RetroArch 继续用旧键位，且毫无错误讯息。
（实机踩过 2026-08-02：MD1000/EmuELEC，RA 那份停在几分钟前的旧档，select/start 刚好对调。）

事件这条路的触发条件在**档案摆放位置**，不在任何可被覆写的内容里，所以拿它当正路。
两条并存无妨：`controls-changed` 不在 `_asyncEvents` 里，是**同步**执行完才轮到
`doOnFinish`，不会两支同时写 `/tmp/joypads`；重复跑一次结果也一样。

⚠️ 这支需要**执行位**（ES 是直接执行档案本身），但补执行位只发生在 `bin/` 落点，
所以由 `bin/apply.sh` 的 `input_hook()` 补。钩子本身不能改放 `bin/` ——
ES 的事件机制只认 `scripts/<事件名>/` 这个位置。

### 机制与资料之间的契约

两者分开之后，**契约就是真正的接口**：机制去哪里读配方、格式长什么样。
这个定了就不该随意改，否则旧机器下载到新机制会读不到配方，而且多半是静默失败。

| 机制 | 读的资料 |
|---|---|
| `setaudio.sh <card,device> <标签>` | 参数由 ES 从 `audio_outputs.cfg` 取出后传入 |
| `installtoemmc.sh`（包装层，`common/`）→ `installtoemmc-engine.sh`（引擎，各 target 一份） | `storage-config/es4all/emmc-layout.conf` |

**dest-root（落点根，各 target 实际路径不同，由客户端解析）**

| dest-root | armbian | emuelec | rocknix |
|---|---|---|---|
| `es-resources/` | ES 用户 resources 目录 | 同左 | 同左 |
| `storage-config/` | `~/.config/` | `/storage/.config/` | `/storage/.config/` |
| `bin/` | `~/.config/es4all/bin/` | `/storage/.config/es4all/bin/` | 同 emuelec |
| `storage/` | `~/` | `/storage/` | 同 emuelec |

`storage/` 是**使用者资料根本身**，给不在 `.config` 底下的落点用。
目前唯一的用户是 ROCKNIX 的 RA autoconfig 出厂档 → `/storage/joypads/`
（那是 `/tmp/joypads` 这个 overlay 的 upper，写入即持久）。
硬塞进 `storage-config/` 会变成 `/storage/.config/joypads`，RA 根本不看那里 —— 静默失效。

`bin/` 放**可执行脚本**，客户端会自动补上执行位（`chmod 0755`）。
与 `storage-config/` 分开是刻意的：补执行位这件事只该发生在这个落点，
混在一起会误伤一般设定档。

⚠️ 落在 `bin/` 的脚本同时是**选单可见性的开关**：ES 用
`Es4allProfiles::scriptPath("<名字>")` 判断「这台机器有没有这个功能」，
有脚本才显示对应入口。目前有两个约定名字：

| 脚本 | 作用 |
|---|---|
| `setaudio.sh <card,device> <标签>` | 音源输出切换。有它就取代 ES 内建实作 |
| `installtoemmc-engine.sh` | 写入 eMMC 的**分区流程**（各 target 一份，每台都有） |

⚠️ 「退出选单要不要显示写入 eMMC」看的**不是**这支脚本，而是机型目录里有没有
`storage-config/es4all/emmc-layout.conf`（见上面「机制 vs 资料」）。
流程每台都有，配方才代表这台真的做过、验证过。

`es-resources/` 落在 ES 的**用户** resources 目录，不是系统那份。
`ResourceManager` 的搜索顺序是用户目录优先于系统目录，所以：

- 覆盖立即生效，不必动只读镜像（E/R 是 squashfs）
- **ES 自我更新（OTA）不会洗掉它** —— OTA 覆盖的是系统那份

新增 dest-root 要同时改这张表和客户端解析逻辑，别只加目录。

## manifest.json

由 `tools/gen_manifest.sh` 生成，**不要手改**。

```
./tools/gen_manifest.sh          # 重算 md5 与 size，写回 manifest.json
```

字段：

- `schema` —— manifest 格式版本，客户端不认得就整包跳过
- `version` —— 内容版本，客户端用它判断要不要更新
- `min_es4all_version` —— 低于此版的 ES 不套用（防旧 ES 拿到不认得的字段）
- `files[]` —— `path` / `md5` / `size`

**每次改动内容都要重跑一次并连同 manifest.json 一起 commit**，否则设备端算出的 md5
对不上，会整批拒绝套用。

## 客户端契约（ES4All 侧）

1. 抓 `manifest.json`，比对 `version`；无变化就结束
2. 检查 `min_es4all_version`
3. 逐档下载到暂存区，**逐档校验 md5**；任一档不符 → 整批放弃，不做部分套用
4. 现有落点整份备份到 `<storage>/.profiles.bak`
5. 套用；失败可从备份还原

安全性：仓库地址**写死在 ES 里，不开放使用者自订 URL**。
本仓库内容包含可执行脚本，等同远程代码 —— 可设定 URL 就是把机器交出去。

## 首刷（烤进固件的 baseline）

固件里仍要打包一份 baseline。本仓库只做**叠加更新**，不能是唯一来源，
否则没网络的新机器会拿不到任何配置——而且**全都是静默的**：
音量回出厂值、跑完键位精灵没有任何东西被翻译给 RA/PSP/DC、聚合的 `ExecStartPre`
指向不存在的档、「写入 eMMC」选单不出现。使用者只会觉得「这固件不对劲」。

构建期注入的完整设计（两个固件树共用的**唯一正本**）：
**[`docs/firmware-injection.md`](docs/firmware-injection.md)**

两个固件树各有一条注入 lane（`inject-profiles.yml`），都只连回那份文件、不复述。
核心决定是 **CI 不重写落点解析**——那会让落点规则有两份实作，分岔不报错，
只会让同一个档在首开与联网後落在不同地方。

> ⚠️ **尚未接线**：离线套用还需要 ES 侧一个 `Es4allProfiles::applyFromLocal()` 入口
> （落点解析在 ES 的 C++ 里，不在 `apply.sh`——`apply.sh` 是档案就位**之後**的钩子）。
> 在那之前，注入 lane 只会把 payload 放进映像，不会自动生效。
