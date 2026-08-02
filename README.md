# es4all-profiles —— 机型专属配置文件

ES4All（A / E / R 三个 target）在**运行期**下发的机型专属配置。

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

1. `common/` —— 三个 target 共用（目前是空的，见下方「保底只留一份」）
2. `<T>/_common/` —— 该 target 全机型共用（T = `A` / `E` / `R`）
3. `<T>/<机型>/` —— 该 target 的单一机型

机型键 = `/proc/device-tree/model` 的**子串**，与 `audio_outputs.cfg` 同一套写法
（如 `MD1000`、`E900V22C`、`X98mini`、`P6`）。

> 为什么不是三个仓库：A/E/R 大部分内容相同，拆开必然漂移。
> 三边真正的差异只有【落点路径】和【消费脚本】，用 scope 覆盖表达就够。

**只有这三层，不再多。** 曾考虑在 target 与机型之间加一层芯片家族
（`_family/Amlogic/`），结论是暂不加：现在只有三台机器，加了只是多一个
「该放哪层」要想；等真的出现两台以上重复同一份资料，再按当时看到的
实际分家依据（可能是芯片、也可能是 codec 或 u-boot）来加。

## 机制 vs 资料：什么放哪一层

这不是第四层，是**摆放约定**：

| 放哪 | 放什么 | 例子 |
|---|---|---|
| `<T>/_common/bin/` | **机制**——怎么做 | `setaudio.sh` 的切换流程 |
| `<T>/<机型>/` | **资料**——这台是什么 | `audio_outputs.cfg`、`asound.conf`、`emmc-layout.conf` |

机制放在 target 层而不是 `common/`，是因为做法本来就分家：
EmuELEC 裸 ALSA 改 asound.conf，ROCKNIX 走 PipeWire 改默认 sink。

**逃生门**：若某台的流程真的不同（不只是参数不同，例如 MD1000 是重分区、
X98mini 是重用原厂分区），在 `<T>/<机型>/bin/` 放一支同名脚本即可盖掉
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

把同名档放进 `<T>/_common/storage-config/es4all/override/`，
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

### 键位精灵的触发钩子（controls-changed）

`<T>/_common/storage-config/emulationstation/scripts/controls-changed/10-inputconfig.sh`
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
| `installtoemmc.sh` | `storage-config/es4all/emmc-layout.conf` |

**dest-root（落点根，各 target 实际路径不同，由客户端解析）**

| dest-root | A (Armbian) | E (EmuELEC) | R (ROCKNIX) |
|---|---|---|---|
| `es-resources/` | ES 用户 resources 目录 | 同左 | 同左 |
| `storage-config/` | `~/.config/` | `/storage/.config/` | `/storage/.config/` |
| `bin/` | `~/.config/es4all/bin/` | `/storage/.config/es4all/bin/` | 同 E |

`bin/` 放**可执行脚本**，客户端会自动补上执行位（`chmod 0755`）。
与 `storage-config/` 分开是刻意的：补执行位这件事只该发生在这个落点，
混在一起会误伤一般设定档。

⚠️ 落在 `bin/` 的脚本同时是**选单可见性的开关**：ES 用
`Es4allProfiles::scriptPath("<名字>")` 判断「这台机器有没有这个功能」，
有脚本才显示对应入口。目前有两个约定名字：

| 脚本 | 作用 |
|---|---|
| `setaudio.sh <card,device> <标签>` | 音源输出切换。有它就取代 ES 内建实作 |
| `installtoemmc.sh` | 写入 eMMC 的**流程**（放 `_common`，每台都有） |

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

## 首刷

固件里仍要打包一份 baseline（= 现况）。本仓库只做**叠加更新**，
不能是唯一来源，否则没网络的新机器会拿不到任何配置。
