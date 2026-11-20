#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定位 ObjC 方法 IMP 并可选反汇编"""
import sys, mmap, struct, subprocess, os

class M:
    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        self.d = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        magic, cputype, cpusub, ft, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IiiIIIII', self.d, 0)
        self.ncmds = ncmds
        self.segs = []
        self.secs = {}
        off = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from('<II', self.d, off)
            if cmd == 0x19:
                seg = self.d[off+8:off+24].split(b'\0')[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', self.d, off+24)
                nsects = struct.unpack_from('<I', self.d, off+64)[0]
                self.segs.append((seg, vmaddr, vmsize, fileoff, filesize))
                so = off + 72
                for _i in range(nsects):
                    sect = self.d[so:so+16].split(b'\0')[0].decode()
                    sg = self.d[so+16:so+32].split(b'\0')[0].decode()
                    addr, size = struct.unpack_from('<QQ', self.d, so+32)
                    offset = struct.unpack_from('<I', self.d, so+48)[0]
                    self.secs[(sg, sect)] = (addr, size, offset)
                    so += 80
            off += cmdsize

    def va2off(self, va):
        for seg, vmaddr, vmsize, fileoff, filesize in self.segs:
            if vmaddr <= va < vmaddr + vmsize:
                delta = va - vmaddr
                return fileoff + delta if delta < filesize else None
        return None

    def u64(self, o): return struct.unpack_from('<Q', self.d, o)[0]
    def u32(self, o): return struct.unpack_from('<I', self.d, o)[0]
    def i32(self, o): return struct.unpack_from('<i', self.d, o)[0]
    def cstr(self, o):
        if o is None: return None
        e = self.d.find(b'\0', o)
        return self.d[o:e].decode('utf-8', 'replace')


def find_class(m, clsname):
    cl = m.secs[('__DATA_CONST', '__objc_classlist')]
    for i in range(cl[1] // 8):
        ptr = m.u64(cl[2] + i * 8)
        coff = m.va2off(ptr)
        if not coff: continue
        data = m.u64(coff + 32) & ~7
        doff = m.va2off(data)
        if not doff: continue
        if m.cstr(m.va2off(m.u64(doff + 24))) == clsname:
            return ptr, data
    return None, None


def methods(m, clsname):
    ptr, data = find_class(m, clsname)
    if not ptr: return []
    ro = m.va2off(data)
    base = m.u64(ro + 32)
    if not base: return []
    ml = m.va2off(base)
    flags = m.u32(ml); count = m.u32(ml + 4)
    entsize = (flags & 0xfffc) or 12
    out = []
    for i in range(count):
        field = base + 8 + i * entsize
        fo = m.va2off(field)
        noff = m.i32(fo); toff = m.i32(fo + 4); ioff = m.i32(fo + 8)
        so = m.va2off(field + noff)
        if not so: continue
        name = m.cstr(m.va2off(m.u64(so))) or ''
        to = m.va2off(field + toff)
        types = ''
        if to:
            for shift in range(0, 8):
                ch = m.d[to+shift:to+shift+1]
                if ch and ch.decode('latin1') in 'v@ifdBsSqcCIQ#*^{(':
                    types = m.cstr(to + shift) or ''
                    break
        imp = (field + ioff) & 0xffffffffffff
        out.append((name, types, imp))
    return out


def disasm(m, addr, count):
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_REG
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    off = m.va2off(addr)
    if off is None:
        return '(地址无法映射)'
    code = m.d[off:off + count * 4]
    lines = []
    pending_adrp = {}
    for ins in md.disasm(code, addr):
        note = ''
        mnem = ins.mnemonic
        ops = ins.op_str
        regs = ins.reg_name if hasattr(ins, 'reg_name') else ''
        if mnem == 'adrp' and ins.operands:
            try:
                dst = ins.reg_name(ins.operands[0].reg)
                pending_adrp[dst] = ins.operands[1].imm
            except Exception:
                pass
        elif mnem == 'add' and len(ins.operands) >= 3:
            try:
                dst = ins.reg_name(ins.operands[0].reg)
                src = ins.reg_name(ins.operands[1].reg)
                imm = ins.operands[2].imm
                if src in pending_adrp:
                    target = pending_adrp[src] + imm
                    so = m.va2off(target)
                    if so:
                        s = m.cstr(so)
                        if s and all(31 < ord(c) < 127 or c in '\u4e00' for c in s[:40]):
                            note = '  ; "%s"' % s.replace('\n', ' ')
                        else:
                            note = '  ; %#x' % target
                    else:
                        note = '  ; %#x' % target
                    if dst:
                        pending_adrp[dst] = target
            except Exception:
                pass
        elif mnem in ('bl', 'b') and ins.operands and ins.operands[0].type == ARM64_OP_IMM:
            note = '  ; -> %#x' % ins.operands[0].imm
        elif mnem.startswith('ldr') and ins.operands:
            try:
                if len(ins.operands) >= 2 and ins.operands[1].type == 3:  # MEM
                    mem = ins.operands[1].mem
                    base = ins.reg_name(mem.base)
                    if base in pending_adrp:
                        target = pending_adrp[base] + mem.disp
                        so = m.va2off(target)
                        if so:
                            ptr = m.u64(so)
                            po = m.va2off(ptr)
                            if po:
                                s = m.cstr(po)
                                if s and len(s) < 80:
                                    note = '  ; -> "%s"' % s
            except Exception:
                pass
        lines.append('%#010x:  %-8s %s%s' % (ins.address, mnem, ops, note))
    return '\n'.join(lines)


def main():
    cmd = sys.argv[1]
    path = os.environ.get('BIN', '/tmp/aw2/AwemeLiteCore')
    m = M(path)
    if cmd == 'list':
        for name, types, imp in methods(m, sys.argv[2]):
            print('%-60s %-30s %#x' % (name, types, imp))
    elif cmd == 'addr':
        cls, sel = sys.argv[2], sys.argv[3]
        for name, types, imp in methods(m, cls):
            if name == sel:
                print('%#x %s' % (imp, types))
                return
        print('not found')
    elif cmd == 'dis':
        cls, sel, cnt = sys.argv[2], sys.argv[3], int(sys.argv[4])
        for name, types, imp in methods(m, cls):
            if name == sel:
                print(disasm(m, imp, cnt))
                return
        print('not found')

if __name__ == '__main__':
    main()
