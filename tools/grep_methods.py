#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全量扫描方法名，找出包含指定关键字的类与方法"""
import sys, mmap, struct

class M:
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.d = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        magic, cputype, cpusub, ft, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IiiIIIII', self.d, 0)
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


def main():
    path = sys.argv[1]
    keywords = [k.lower() for k in sys.argv[2:]]
    m = M(path)
    cl = m.secs[('__DATA_CONST', '__objc_classlist')]
    total = cl[1] // 8
    hits = {}
    for i in range(total):
        ptr = m.u64(cl[2] + i * 8)
        coff = m.va2off(ptr)
        if not coff: continue
        data = m.u64(coff + 32) & ~7
        doff = m.va2off(data)
        if not doff: continue
        name = m.cstr(m.va2off(m.u64(doff + 24)))
        if not name: continue
        base = m.u64(doff + 32)
        if not base: continue
        ml = m.va2off(base)
        if not ml: continue
        flags = m.u32(ml); count = m.u32(ml + 4)
        if count > 30000: continue
        entsize = (flags & 0xfffc) or 12
        found = []
        for j in range(count):
            field = base + 8 + j * entsize
            fo = m.va2off(field)
            if not fo: break
            noff = m.i32(fo)
            if noff == 0: continue
            so = m.va2off(field + noff)
            if not so: continue
            sva = m.u64(so)
            sto = m.va2off(sva)
            if not sto: continue
            sel = m.cstr(sto)
            if not sel: continue
            low = sel.lower()
            if any(k in low for k in keywords):
                found.append(sel)
        if found:
            hits[name] = found
    for c, sels in sorted(hits.items()):
        print('###', c)
        for s in sels[:20]:
            print('   ', s)


if __name__ == '__main__':
    main()
