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

1. `common/` —— 三个 target 共用
2. `<T>/_common/` —— 该 target 全机型共用（T = `A` / `E` / `R`）
3. `<T>/<机型>/` —— 该 target 的单一机型

机型键 = `/proc/device-tree/model` 的**子串**，与 `audio_outputs.cfg` 同一套写法
（如 `MD1000`、`E900V22C`、`X98mini`、`P6`）。

> 为什么不是三个仓库：A/E/R 大部分内容相同，拆开必然漂移。
> 三边真正的差异只有【落点路径】和【消费脚本】，用 scope 覆盖表达就够。

**dest-root（落点根，各 target 实际路径不同，由客户端解析）**

| dest-root | A (Armbian) | E (EmuELEC) | R (ROCKNIX) |
|---|---|---|---|
| `es-resources/` | ES 用户 resources 目录 | 同左 | 同左 |
| `storage-config/` | `~/.config/` | `/storage/.config/` | `/storage/.config/` |

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
