#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 AwemeLitePlus.dylib 注入抖音极速版 IPA（Windows / macOS / Linux 通用，无需任何第三方库）

用法:
    python inject.py -i 原始.ipa -d AwemeLitePlus.dylib -o 已注入.ipa

注入后必须重新签名（zsign / ldid / TrollStore 安装时自动签名），否则无法启动。
"""

import argparse
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x21


def read_header(data):
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, res = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        raise RuntimeError("不是 64 位 Mach-O（magic=%#x）" % magic)
    return {
        "cputype": cputype,
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
    }


def scan_load_commands(data, ncmds):
    """返回 (第一个 section 的文件偏移, 是否已加密, 现有 dylib 列表)"""
    first_section = None
    encrypted = False
    dylibs = []
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            so = off + 72
            for _i in range(nsects):
                sect_offset = struct.unpack_from("<I", data, so + 48)[0]
                if sect_offset and (first_section is None or sect_offset < first_section):
                    first_section = sect_offset
                so += 80
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptid = struct.unpack_from("<I", data, off + 16)[0]
            if cryptid != 0:
                encrypted = True
        elif cmd == LC_LOAD_DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            raw = data[off + name_off: data.index(b"\0", off + name_off)]
            dylibs.append(raw.decode("utf-8", "replace"))
        off += cmdsize
    return first_section, encrypted, dylibs


def add_load_dylib(path, install_name):
    """在 Mach-O 头部 padding 区写入一条 LC_LOAD_DYLIB（不改变文件布局）"""
    with open(path, "rb") as f:
        data = bytearray(f.read())

    header = read_header(data)
    ncmds = header["ncmds"]
    sizeofcmds = header["sizeofcmds"]
    first_section, encrypted, dylibs = scan_load_commands(data, ncmds)

    if install_name in dylibs:
        print("  [=] 已存在该 dylib 加载项，跳过")
        return False
    if encrypted:
        raise RuntimeError("可执行文件仍是加密状态，无法注入")

    name = install_name.encode("utf-8") + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    command = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    command += name.ljust(cmdsize - 24, b"\0")

    insert_at = 32 + sizeofcmds
    if first_section is not None and insert_at + cmdsize > first_section:
        raise RuntimeError(
            "头部 padding 不足（需要 %d 字节，仅剩 %d），无法安全注入"
            % (cmdsize, max(0, first_section - insert_at))
        )

    data[insert_at:insert_at + cmdsize] = command
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)

    with open(path, "wb") as f:
        f.write(data)
    print("  [+] 已写入 LC_LOAD_DYLIB: %s (%d bytes)" % (install_name, cmdsize))
    return True


def make_workdir():
    """Windows 下 App 内有超深目录，必须用短根目录 + 长路径前缀，否则解压会 FileNotFoundError"""
    if os.name == "nt":
        base = "C:\\awtmp"
        os.makedirs(base, exist_ok=True)
        path = tempfile.mkdtemp(prefix="aw_", dir=base)
        return "\\\\?\\" + path
    return tempfile.mkdtemp(prefix="aweme_inject_")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--ipa", required=True, help="原始解密 IPA")
    parser.add_argument("-d", "--dylib", required=True, help="编译出的 AwemeLitePlus.dylib")
    parser.add_argument("-o", "--out", required=True, help="输出 IPA 路径")
    parser.add_argument("--keep-unsigned", action="store_true", help="保留 _CodeSignature 目录（默认删除）")
    args = parser.parse_args()

    if not os.path.isfile(args.ipa):
        sys.exit("IPA 不存在: %s" % args.ipa)
    if not os.path.isfile(args.dylib):
        sys.exit("dylib 不存在: %s" % args.dylib)

    workdir = make_workdir()
    try:
        print("[1/5] 解压 IPA ...")
        with zipfile.ZipFile(args.ipa) as zf:
            zf.extractall(workdir)

        payload = os.path.join(workdir, "Payload")
        apps = [d for d in os.listdir(payload) if d.endswith(".app")]
        if len(apps) != 1:
            sys.exit("Payload 下找到 %d 个 .app，无法确定目标" % len(apps))
        app_dir = os.path.join(payload, apps[0])

        with open(os.path.join(app_dir, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
        executable = info["CFBundleExecutable"]
        bundle_id = info.get("CFBundleIdentifier", "?")

        print("[2/5] 目标: %s (%s)" % (apps[0], bundle_id))

        frameworks_dir = os.path.join(app_dir, "Frameworks")
        os.makedirs(frameworks_dir, exist_ok=True)
        target_dylib = os.path.join(frameworks_dir, os.path.basename(args.dylib))
        shutil.copy2(args.dylib, target_dylib)
        print("  [+] 已拷贝 dylib -> Frameworks/%s" % os.path.basename(args.dylib))

        print("[3/5] 注入 Mach-O 加载命令 ...")
        binary_path = os.path.join(app_dir, executable)
        add_load_dylib(binary_path, "@executable_path/Frameworks/%s" % os.path.basename(args.dylib))

        print("[4/5] 清理旧签名 ...")
        if args.keep_unsigned:
            print("  [=] 按参数保留 _CodeSignature")
        else:
            for root, dirs, _files in os.walk(app_dir):
                for d in list(dirs):
                    if d == "_CodeSignature":
                        shutil.rmtree(os.path.join(root, d), ignore_errors=True)
                        dirs.remove(d)
            print("  [+] _CodeSignature 已清理，等待重新签名")

        print("[5/5] 重新打包 ...")
        out_path = os.path.abspath(args.out)
        if os.path.exists(out_path):
            os.remove(out_path)

        with zipfile.ZipFile(args.ipa) as src, zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as dst:
            written = set()
            for item in src.infolist():
                name = item.filename
                local = os.path.join(workdir, name.replace("/", os.sep))
                if name.endswith("/"):
                    continue
                if not os.path.isfile(local):
                    continue
                dst.write(local, name)
                written.add(name)

            # 新增的 dylib
            dylib_entry = "Payload/%s/Frameworks/%s" % (apps[0], os.path.basename(args.dylib))
            if dylib_entry not in written:
                dst.write(target_dylib, dylib_entry)

        size = os.path.getsize(out_path) / (1024 * 1024)
        print("\n完成: %s (%.1f MB)" % (out_path, size))
        print("下一步：用 zsign / ldid 重新签名后再安装。")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
