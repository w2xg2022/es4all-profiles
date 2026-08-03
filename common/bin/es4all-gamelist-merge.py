#!/usr/bin/env python3
"""es4all: 只在【两边都有 gamelist.xml】的平台上做合并。

============================================================================
为什么需要这支
============================================================================
不管是 overlayfs 还是 mergerfs, 目录会合并、**同名档案不会** —— 同一个路径只会
呈现其中一份。而 `gamelist.xml` 正是档案:

    内盘 psp/gamelist.xml   刮好的 N 笔
    外盘 psp/gamelist.xml   刮好的 M 笔
    合并视图 psp/           两边的 ROM 都看得到(目录合并) ✅
    合并视图 psp/gamelist.xml  只有一份, 另一份的刮削资料整个被遮蔽 ❌

表现是「游戏都在, 但有一半突然变成没刮过」, 而图片其实还躺在 media/ 里
(那是目录, 有合并), 只是 XML 里引用它们的 <game> 条目没了。

============================================================================
★只处理「两边都有 gamelist.xml」的平台★
============================================================================
其余三种情形【完全不需要动作】, 因为合并视图呈现的本来就是唯一那一份:
    只有内盘有该平台        -> 看到内盘的
    只有外盘有该平台        -> 看到外盘的
    两边都有平台但只有一份 gamelist -> 看到那一份

★这不只是省事, 是省【时间】★: 旧版本无差别扫过所有平台(实机 152 个),
逐一开档解析 XML, 还要穿过 FUSE 与 vfat —— 慢到把 ES 的启动卡死
(实机 2026-08-03: 挂在 ExecStartPre 上, systemd 等到超时, ES 根本没被执行到)。
改成只处理真正冲突的平台后, 通常是 0~3 个, 毫秒级。

============================================================================
合并规则(刻意保守)
============================================================================
把外盘那份里【目标没有的】<game> 补进目标, **绝不改动已有条目**。
目标 = 可写那一侧(mergerfs 的 RW 分支 = 内盘), 也就是合并视图呈现的那一份。

★为什么不覆盖已有条目★: 那份是 ES 的活档, 里面有 playcount / lastplayed /
收藏这些**只有 ES 知道**的东西。每次开机重新合并覆盖它, 等於每次开机把使用者的
游玩纪录洗掉一次 —— 而且悄无声息。

用法: es4all-gamelist-merge.py <目标(可写)根目录> <来源根目录> [来源2 ...]
"""
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

GAMELIST = "gamelist.xml"


def load(path):
    """回传 (root, {path_text: element})。档案不存在或坏掉都回空, 不抛例外 ——
    一份坏掉的 XML 不该让整个开机流程失败。"""
    if not os.path.isfile(path):
        return None, {}

    # ★别只用 ET.parse★: 实机遇到过外接盘上的 gamelist.xml 内容是 **GBK**,
    # 而 XML 宣告没写 encoding(预设 UTF-8) -> 一碰到中文就 "not well-formed"。
    # 那种档多半是 Windows 上的工具或旧版程序写的, 中文使用者的碟很常见。
    # 直接放弃等於白白丢掉整份刮削资料, 所以 UTF-8 失败就退回常见的中文编码再试一次;
    # 合并后一律以 UTF-8 写出, 顺便把它修好。
    root = None
    try:
        root = ET.parse(path).getroot()
    except Exception as e_utf8:
        # ★退回用 iconv 转码, 不要用 Python 的 codec★
        # EmuELEC 映像里的 Python 少了 CJK codec 的 C 扩充模组 ——
        # encodings/gb18030.pyc 明明在, raw.decode("gb18030") 却抛
        # `LookupError: unknown encoding`(实机 2026-08-03)。
        # 而 /usr/bin/iconv 是好的, 所以借它转。
        for enc in ("GBK", "BIG5"):            # GBK 涵盖 GB2312
            try:
                out = subprocess.run(["iconv", "-f", enc, "-t", "UTF-8", path],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     timeout=20)
            except Exception:
                break                          # 没有 iconv 就别再试了
            if out.returncode != 0 or not out.stdout:
                continue
            try:
                root = ET.fromstring(out.stdout.decode("utf-8"))
                print("  %s: 不是 UTF-8, 以 %s 解读成功" % (path, enc))
                break
            except Exception:
                root = None
        if root is None:
            print("  跳过(解析失败) %s: %s" % (path, e_utf8))
            return None, {}

    index = {}
    for game in root.findall("game"):
        p = game.findtext("path")
        if p:
            index[p.strip()] = game
    return root, index


def conflicting_platforms(target_root, source_roots):
    """找出【目标与某个来源都有 gamelist.xml】的平台名。

    以目标那一侧的目录清单为准去比对 —— 只有目标有 gamelist 的平台才可能发生
    「来源那份被遮蔽」的问题。"""
    out = []
    if not os.path.isdir(target_root):
        return out
    for name in os.listdir(target_root):
        tgt = os.path.join(target_root, name, GAMELIST)
        if not os.path.isfile(tgt):
            continue                       # 目标没有 gamelist -> 呈现的就是来源那份, 不必合并
        for src in source_roots:
            if os.path.isfile(os.path.join(src, name, GAMELIST)):
                out.append(name)
                break
    return out


def merge_platform(target_root, source_roots, platform):
    tgt_path = os.path.join(target_root, platform, GAMELIST)
    root, index = load(tgt_path)
    if root is None:
        return 0

    added = 0
    for src in source_roots:
        _, src_index = load(os.path.join(src, platform, GAMELIST))
        for p, game in src_index.items():
            if p in index:                 # 目标已经有这一笔 -> 不动
                continue
            root.append(game)
            index[p] = game
            added += 1

    if added == 0:
        return 0

    # ★先写暂存再换名★: 直接覆写时若中途断电/被杀, 使用者的 gamelist 就毁了。
    tmp = tgt_path + ".es4all-tmp"
    ET.ElementTree(root).write(tmp, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, tgt_path)
    print("  %s: 补进 %d 笔" % (platform, added))
    return added


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    target_root, source_roots = sys.argv[1], sys.argv[2:]

    platforms = conflicting_platforms(target_root, source_roots)
    if not platforms:
        print("gamelist: 没有两边都有 gamelist.xml 的平台, 不需要合并")
        return 0

    total = 0
    for platform in sorted(platforms):
        total += merge_platform(target_root, source_roots, platform)
    print("gamelist 合并完成: %d 个平台需要处理, 共补进 %d 笔" % (len(platforms), total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
