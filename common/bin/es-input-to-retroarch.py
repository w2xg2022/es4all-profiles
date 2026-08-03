#!/usr/bin/env python3
"""将 EmulationStation 的手柄按键映射 (es_input.cfg) 转换为
RetroArch 的 autoconfig 设定档，让 ES 设定好的手柄可直接在
RetroArch / 游戏核心中使用，不需要重新设置。"""
import os
import sys
import xml.etree.ElementTree as ET

# ES 按键名 -> RetroArch autoconfig 按键名（按钮类）
BUTTON_MAP = {
    "a": "input_a_btn",
    "b": "input_b_btn",
    "x": "input_x_btn",
    "y": "input_y_btn",
    "start": "input_start_btn",
    "select": "input_select_btn",
    "leftshoulder": "input_l_btn",
    "rightshoulder": "input_r_btn",
    "leftthumb": "input_l3_btn",
    "rightthumb": "input_r3_btn",
    "hotkeyenable": "input_enable_hotkey_btn",
}

# ES 按键名 -> RetroArch autoconfig 按键名（摇杆轴类，含正负号）
AXIS_MAP = {
    "lefttrigger": "input_l2_axis",
    "righttrigger": "input_r2_axis",
    "leftanalogleft": "input_left_x_minus_axis",
    "leftanalogright": "input_left_x_plus_axis",
    "leftanalogup": "input_left_y_minus_axis",
    "leftanalogdown": "input_left_y_plus_axis",
    "rightanalogleft": "input_right_x_minus_axis",
    "rightanalogright": "input_right_x_plus_axis",
    "rightanalogup": "input_right_y_minus_axis",
    "rightanalogdown": "input_right_y_plus_axis",
}

# ES 方向键名 -> RetroArch autoconfig 按键名（D-Pad）
DPAD_MAP = {
    "up": "input_up_btn",
    "down": "input_down_btn",
    "left": "input_left_btn",
    "right": "input_right_btn",
}

# SDL hat 方向位标记
HAT_DIR = {1: "up", 2: "right", 4: "down", 8: "left"}

# ES 按键名 -> RetroArch 热键：绑到「印刷/实体按键」，避免 retroarch.cfg 写死的
# 按钮编号在更换手柄后对应到错误的按键。意图（对齐 EmuELEC controller-guide）：
#   SELECT+R1 = 存档 / SELECT+L1 = 读档 / SELECT+X = 呼出 RA 菜单 / SELECT+Y = 切换帧率
HOTKEY_MAP = {
    "rightshoulder": "input_save_state_btn",
    "leftshoulder":  "input_load_state_btn",
    "x":             "input_menu_toggle_btn",
    "y":             "input_fps_toggle_btn",
}

# 面键（A/B/X/Y）：按【物理位置】写死，不看 es_input 记录的印刷字母。
#
# udev 驱动下 evdev 语义码是位置锚定的 —— btn0=南 btn1=东 btn2=北 btn3=西，
# 不论手柄印 A 还是 B，南键永远是 btn0。所以这里直接把 RetroPad 的固定方位
# （A=东 B=南 X=北 Y=西）对到对应的位置码，游戏内就是「一份走天下」。
#
# ★2026-08-03 修正：以前写 a→0 / b→1 / x→2 / y→3，那是【标签对齐】★
#   （把南键给了 RetroPad A），要再靠 per-core remap 翻 A/B 才会正。
#   而那个翻转只翻 A/B 不翻 X/Y，四颗面键两套规则，实机就是一半对一半错。
#   现在第一层直接写成位置对齐，第三层什么都不用做 —— 与 EmuELEC 侧
#   configscripts/retroarch.sh 的结论一致（见 es4all 352e15c）。
#
# ⚠️ 这里的前提是「evdev 码位置锚定」。若某支手柄实测不成立（山寨手柄什么都可能），
#    退路是照 EmuELEC 那套：用 es_input 的印刷字母 + ES 的 InvertButtons 反推方位。
#    两条路都只依赖已知量，别再回去用「翻几次」那种相对语意。
FACE_BTN_POSITION = {
    "a": "1",  # RetroPad A = 东
    "b": "0",  # RetroPad B = 南
    "x": "2",  # RetroPad X = 北
    "y": "3",  # RetroPad Y = 西
}


def guid_to_vendor_product(guid):
    try:
        raw = bytes.fromhex(guid)
        vendor = int.from_bytes(raw[4:6], "little")
        product = int.from_bytes(raw[8:10], "little")
        return vendor, product
    except Exception:
        return None, None


def convert_device(input_config, out_dir):
    device_name = input_config.get("deviceName", "")
    guid = input_config.get("deviceGUID", "")
    if not device_name:
        return

    lines = []
    lines.append('input_driver = "udev"')
    lines.append('input_device = "%s"' % device_name)

    vendor, product = guid_to_vendor_product(guid)
    if vendor is not None:
        lines.append('input_vendor_id = "%d"' % vendor)
        lines.append('input_product_id = "%d"' % product)

    dpad_from_hat = {}
    dpad_from_button = {}

    for inp in input_config.findall("input"):
        name = inp.get("name")
        itype = inp.get("type")
        iid = inp.get("id")
        value = inp.get("value")

        if name in BUTTON_MAP:
            # 面键按物理位置固定编号；其余按键照 ES 记录的实体按钮 id。
            btn_val = FACE_BTN_POSITION.get(name, iid)
            lines.append('%s = "%s"' % (BUTTON_MAP[name], btn_val))
            # 热键绑到「印刷/实体按键」（Layer 2 按印刷），用 ES 记录的实体 id。
            if name in HOTKEY_MAP:
                lines.append('%s = "%s"' % (HOTKEY_MAP[name], iid))
        elif name in AXIS_MAP:
            if itype == "axis":
                sign = "+" if int(value) >= 0 else "-"
                lines.append('%s = "%s%s"' % (AXIS_MAP[name], sign, iid))
            else:
                lines.append('%s = "%s"' % (AXIS_MAP[name], iid))
        elif name in DPAD_MAP:
            if itype == "hat":
                direction = HAT_DIR.get(int(value))
                if direction:
                    dpad_from_hat[name] = 'h%s%s' % (iid, direction)
            else:
                dpad_from_button[name] = iid

    for name, key in DPAD_MAP.items():
        if name in dpad_from_hat:
            lines.append('%s = "%s"' % (key, dpad_from_hat[name]))
        elif name in dpad_from_button:
            lines.append('%s = "%s"' % (key, dpad_from_button[name]))

    safe_name = "".join(c if c.isalnum() or c in " _-" else "_" for c in device_name).strip()
    out_path = os.path.join(out_dir, "%s.cfg" % safe_name)
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("写入 %s" % out_path)


def main():
    es_input_cfg = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.emulationstation/es_input.cfg")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.config/retroarch/autoconfig")

    if not os.path.isfile(es_input_cfg):
        return

    os.makedirs(out_dir, exist_ok=True)

    tree = ET.parse(es_input_cfg)
    for input_config in tree.getroot().findall("inputConfig"):
        if input_config.get("type") == "joystick":
            convert_device(input_config, out_dir)


if __name__ == "__main__":
    main()
