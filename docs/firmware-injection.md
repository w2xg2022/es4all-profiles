# 把 profiles 烤进固件（构建期注入）

> 适用 **EmuELEC** 与 **ROCKNIX** 两个固件树。本档是**唯一正本**，两边的 workflow 都连回这里，
> 不要各自复制一份说明 —— 复制出来的两份必然漂移，而漂移是静默的。

## 1. 要解决的问题

profiles 现在是**运行期下发**：ES 起来后读 `manifest.json`、下载、校验 md5、按 scope 解析、
落到各 dest-root，最后在 `es4all-profiles.version` 记下版本。

这条链很好，但它有一个前提：**设备已经开机、已经联网、ES 已经跑过一轮**。
於是刚刷完机的第一次开机是「裸的」：

| 依赖 profiles 的东西 | 首开没有它会怎样 |
|---|---|
| `010-es4all-defaults`（音量 80、音源输出、Vulkan、RA 两项矫正） | 音量回到出厂 60、AV/HDMI 走 PipeWire 自己挑的 |
| `10-inputconfig.sh` + 转换器 | 跑完键位精灵**没有任何东西**被翻译给 RA/PSP/DC |
| `es4all-storage.sh` + `mergerfs` | 内外盘聚合整个不存在（`ExecStartPre` 指向不存在的档） |
| `installtoemmc.sh` + `emmc-layout.conf` | 「写入 eMMC」选单不出现 |

★而且这些**全都是静默的**★ —— 不会有错误讯息，只是行为跟文件写的不一样。
使用者第一印象就是「这固件不对劲」，而真相只是「还没连上网」。

**注入 = 把一份 baseline 烤进映像，让首开就已经是对的；运行期同步退化成「更新」而不是「取得」。**

## 2. 为什么是构建**后**注入，不是构建期当成一个套件

| | 当成套件（`package.mk`，随 build 一起编） | 构建后注入（本方案） |
|---|---|---|
| 改一行 profile | **要跑一次完整云编译**（数小时） | 重跑注入 lane，约 5 分钟 |
| 与既有 lane 的关系 | 会让 ES/内核的 lane 一起被 invalidate | 独立，谁都不影响 |
| 出错的影响面 | 整包 build 挂掉 | 只影响那一张映像，base 还在 |
| 想换 profiles 版本重出一张图 | 不行，得重编 | 换个 ref 再跑一次 |

profiles 的**全部意义**就是「改配置不必重编」。把它塞回编译期等於把这个好处退回去。

ROCKNIX 已经有 Lane C（`build-inject-image.yml`）在做同类的事（解开 SYSTEM → 改 → 重新打包），
注入 profiles 就是同一条路上多一个 payload，**不必发明新机制**。

## 3. ★核心设计决定：CI 不重写落点解析★

最容易想到的做法是：在 workflow 里把 scope 解析（`common` → `<target>/_common` →
`<target>/<DEVICE>/_common` → `<target>/<DEVICE>/<SUBDEVICE>`）与 dest-root 映射用 shell 重写一遍，
直接把档案摊到映像的对应位置。

**不要这样做。** 那等於让「落点规则」有两份实作：设备端 `apply.sh` 一份、CI 一份。
两份规则的分岔不会报错，只会让「同一个档在首开与联网后落在不同地方」——
这类 bug 我们这个专案已经踩过太多次（写死的 joypad cfg、A/B 翻转 remap、两层 bind-mount），
每一次的共同点都是**同一件事有两个真相**。

正确做法：

```
映像里放的是【未解析的 payload】
首次开机由 ES 自己解析、自己落点 —— 与联网同步走【完全同一段程式码】
```

CI 只负责三件**与规则无关**的事：把 payload 放进去、把版本戳记放进去、验证放对了。

### ⚠️ 落点解析在哪里（写这份设计时查错过一次，记下来）

我一度以为「解析 + 落点」是 `common/bin/apply.sh` 做的，於是设计成「首开呼叫 apply.sh 离线套用」。
**不对**：`apply.sh` 是**档案就位【之后】的钩子**（补执行位、enable 服务、写一次性预设），
真正把档案摊到 dest-root 的是 **ES 里的 `Es4allProfiles`（C++）**。

所以离线 baseline 需要 ES 侧加一个入口，而不是在 shell 里再写一份：

```cpp
// 与线上同步共用 scope 解析与 dest-root 映射, 只差【档案从哪来】:
//   线上: 下载到 tmp 后套用
//   离线: 直接拿映像里的 /usr/config/es4all-profiles
bool Es4allProfiles::applyFromLocal(const std::string& dir);
```

判断何时用它：`es4all-profiles.version` 不存在（= 从没套用过）且映像带了 baseline。
之后仍照旧比对线上 manifest，新的才下载。

★这一条是整份设计里最关键的一点★：宁可在 ES 里加一个十几行的函式，
也不要在 CI 或 shell 里复制一份落点规则。

## 4. 落点与流程

### 4.1 映像里的位置

```
/usr/config/es4all-profiles/          <- payload 原样（含 manifest.json）
/usr/config/es4all-profiles.version   <- 注入时的 profiles commit（baseline 版本戳）
```

选 `/usr/config` 是因为**两个发行版都会把它播种到 `/storage/.config`**：

- ROCKNIX：`chksysconfig verify` 在设定档缺失时 `rsync -a /usr/config/ /storage/.config`
- EmuELEC：同类机制（首开填 `/storage/.config`）

放 `/storage` 是错的：那个分区在首开时才建立/扩展，映像里放什么都不算数。

### 4.2 首开的套用

由 ES 在启动时做（`Es4allProfiles` 现有的同步流程里加一个前置分支）：

```
若 es4all-profiles.version 不存在 且 /storage/.config/es4all-profiles/ 存在
    -> applyFromLocal()  （离线套用 baseline，走同一套 scope/dest-root 解析）
    -> 把 baseline 的 manifest version 写进 es4all-profiles.version
然后照旧: 取线上 manifest, version 比 baseline 新才下载
```

★版本戳记必须一起写★，否则 ES 每次开机都会认为「本机没有 profiles」而重新下载整包 ——
不会出错，但每次开机白跑一趟网路，而且看起来像是同步机制坏了。

放在 ES 而不是 autostart 脚本的理由同上：**落点规则只有 ES 知道**，
在脚本里做就必须把规则抄一份出来。

### 4.3 与运行期同步的关系

```
首开：  baseline（映像里的，离线）      -> 立刻可用
之后：  ES 比对 manifest 的 version     -> 比 baseline 新才下载
```

版本比较用的是 profiles 仓库的 `manifest.json` 里的 `version` 字段（`YYYY.MM.DD.N`），
**不是 commit SHA** —— SHA 无法比大小。注入时把当次的 `version` 写进 baseline 戳记档。

## 5. workflow 该做的检查（这些比注入本身更重要）

注入这类操作最典型的失败不是「炸掉」，是**默默什么都没做**，然后所有人以为烤进去了。
所以每一步都要有能证伪的输出：

1. **manifest 与档案一致**：跑 `tools/gen_manifest.sh` 后 `git diff --exit-code manifest.json`。
   不一致代表有人改了档没重产 manifest —— 那样烤进去的 baseline 校验必然失败。
   ★这是历史上真的发生过的事★（profiles push 后设备端「看不到更新」，就是 manifest 没重产）。
2. **payload 真的进了 squashfs**：重新打包后 `unsquashfs -l` 抓一次，档案数写进 job summary。
   没有这一步，`cp` 打错路径与成功长得一模一样。
3. **执行位**：payload 里 `bin/` 底下的档必须保有 `+x`。用 `tar` 搬，不要经过 zip 或 SMB
   （Z: 盘编辑会掉执行位，这个坑踩过）。
4. **不覆盖映像自己的东西**：只新增 `/usr/config/es4all-profiles*`，不动 `/usr/config` 底下既有档。
5. **pin 的是明确的 ref**：`workflow_dispatch` 的 `PROFILES_REF` 预设 `main`，但**产出的映像里要记下
   解析后的 commit SHA**，否则事后无法回答「这张图里的 profiles 是哪一版」。

## 6. 建议的触发方式

| 情境 | 做法 |
|---|---|
| 只改了 profiles，想出一张新图 | 单独跑注入 lane，base 用最近一次成功的映像 |
| 改了 ES / 内核 / 套件 | 先跑原本的 build lane，**完成后自动接注入 lane**（`workflow_run` 触发） |
| 想验证「没有 profiles 的裸机行为」 | 跳过注入 —— 这也是注入必须是独立 lane 的理由之一 |

★不要把注入塞进 build lane 的最后一步★：那样「重跑注入」就等於「重跑整个 build」，
而注入正是最需要反覆重跑的那一段。

## 7. 已知的边界

- **注入不能取代云编译**：dts / dtb / 内核 config / u-boot / 编进 ES 二进制的东西都不在 payload 里。
  「开了 profiles 就不用云编译」是错的认知，AV 音频那类问题多数在 dts 层。
- **首开 bootstrap 只跑一次**：使用者若手动删掉 `es4all-profiles.version`，下次开机会用 baseline
  盖回去。这是刻意的（那等於「还原出厂 profiles」），但要在文件里讲明，否则会被当成 bug。
- **base 映像与 payload 的版本要一起记**：Release notes 里两个 SHA 都写（固件树 + profiles），
  少写一个，事后就无法重现那张图。
