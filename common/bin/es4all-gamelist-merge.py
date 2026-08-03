#!/usr/bin/env python3
"""es4all: 把多颗盘的 gamelist.xml 合并成一份, 写到 overlay 的 upperdir。

============================================================================
为什么需要这支
============================================================================
overlayfs 对**目录**是联集、对**档案**不是 —— 同名档只有优先序最高的那份看得见,
其余被完全遮蔽。而 `gamelist.xml` 正是档案:

    内部盘 mame/gamelist.xml   ← 刮好的 300 笔
    外接盘 mame/gamelist.xml   ← 刮好的 500 笔
    /storage/roms/mame/        ← ROM 档两边都看得到(目录联集) ✅
    /storage/roms/mame/gamelist.xml ← **只有一份**, 另一份的刮削资料整个不见 ❌

表现会是「游戏都在, 但有一半突然变成没刮过的样子」, 而图片档其实还躺在
media/ 里(那是目录, 有合并), 只是 XML 里引用它们的 <game> 条目没了。

★把合并结果写进 upperdir 就解决★: upper 的档案优先于所有 lower,
ES 看到的就是合并版。

============================================================================
合并规则(刻意保守)
============================================================================
优先序: upper(ES 自己写的) > lower 由左到右(与 lowerdir 顺序一致)

    已存在于 upper 的 <path> —— **一律不动**
    只在 lower 出现的 <path> —— 补进来

★为什么不覆盖 upper 已有的条目★: 那份是 ES 的活档, 里面有玩过次数、最后游玩时间、
收藏标记这些**只有 ES 知道的东西**。每次开机重新合并覆盖它, 等于每次开机把使用者的
游玩纪录洗掉一次 —— 而且悄无声息。所以这支只做「补上缺的」, 不做「以 lower 为准」。

用法: es4all-gamelist-merge.py <upper_root> <lower1> [lower2 ...]
      (lower 由左到右 = 优先序由高到低, 与 mount -o lowerdir=a:b:c 一致)
"""
import os
import sys
import xml.etree.ElementTree as ET


def load(path):
    """回传 (root, {path_text: element})。档案不存在或坏掉都回空, 不抛例外。"""
    if not os.path.isfile(path):
        return None, {}
    try:
        tree = ET.parse(path)
    except Exception as e:                      # 坏掉的 XML 不该让整个开机流程失败
        print("  跳过(解析失败) %s: %s" % (path, e))
        return None, {}
    root = tree.getroot()
    index = {}
    for game in root.findall("game"):
        p = game.findtext("path")
        if p:
            index[p.strip()] = game
    return root, index


def merge_platform(upper_root, lowers, platform):
    upper_gl = os.path.join(upper_root, platform, "gamelist.xml")
    root, index = load(upper_gl)
    if root is None:
        root = ET.Element("gameList")
        index = {}

    added = 0
    for low in lowers:                          # 由左到右 = 优先序由高到低
        _, low_index = load(os.path.join(low, platform, "gamelist.xml"))
        for p, game in low_index.items():
            if p in index:                      # 已经有了(upper 或更高优先序的 lower) -> 不动
                continue
            root.append(game)
            index[p] = game
            added += 1

    if added == 0:
        return 0

    os.makedirs(os.path.dirname(upper_gl), exist_ok=True)
    ET.ElementTree(root).write(upper_gl, encoding="utf-8", xml_declaration=True)
    print("  %s: 补进 %d 笔 -> %s" % (platform, added, upper_gl))
    return added


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    upper_root, lowers = sys.argv[1], sys.argv[2:]

    # 平台清单 = 所有 lower 里「含 gamelist.xml 的目录」的联集。
    # ★不扫 upper★: upper 一开始是空的, 而且它只该被动接收合并结果。
    platforms = set()
    for low in lowers:
        if not os.path.isdir(low):
            continue
        for name in os.listdir(low):
            if os.path.isfile(os.path.join(low, name, "gamelist.xml")):
                platforms.add(name)

    total = 0
    for platform in sorted(platforms):
        total += merge_platform(upper_root, lowers, platform)
    print("gamelist 合并完成: 共补进 %d 笔, 涵盖 %d 个平台" % (total, len(platforms)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
