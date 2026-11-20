#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""快速提取 ObjC 类名 / 指定类的方法名"""
import sys, mmap, struct, json

class M:
    def __init__(self, path):
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
                if delta < filesize:
                    return fileoff + delta
                return None
        return None

    def u64(self, o):
        return struct.unpack_from('<Q', self.d, o)[0]

    def u32(self, o):
        return struct.unpack_from('<I', self.d, o)[0]

    def i32(self, o):
        return struct.unpack_from('<i', self.d, o)[0]

    def cstr(self, o):
        if o is None:
            return None
        e = self.d.find(b'\0', o)
        try:
            return self.d[o:e].decode('utf-8')
        except UnicodeDecodeError:
            return self.d[o:e].decode('utf-8', 'replace')


def methods_of(m, class_ptr, class_data):
    """class_data 是 class_ro 的地址(VA)"""
    ro = m.va2off(class_data)
    if not ro:
        return []
    base = m.u64(ro + 32)
    if not base:
        return []
    ml = m.va2off(base)
    if not ml:
        return []
    flags_entsize = m.u32(ml)
    count = m.u32(ml + 4)
    if count > 20000:
        return []
    relative = bool(flags_entsize & 0x80000000)
    entsize = flags_entsize & 0xfffc
    res = []
    if not relative:
        # 绝对指针: name(8) types(8) imp(8)
        for i in range(count):
            fo = ml + 8 + i * max(entsize, 24)
            nptr = m.u64(fo)
            no = m.va2off(nptr)
            res.append(m.cstr(no) or '')
        return res
    if entsize == 0:
        entsize = 12
    for i in range(count):
        field = base + 8 + i * entsize
        fo = m.va2off(field)
        if not fo:
            return res
        noff = m.i32(fo)
        if noff == 0:
            res.append('')
            continue
        so = m.va2off(field + noff)
        if not so:
            res.append('')
            continue
        sva = m.u64(so)
        sto = m.va2off(sva)
        res.append(m.cstr(sto) or '' if sto else '')
    return res


def main():
    path = sys.argv[1]
    outpath = sys.argv[2]
    targets = set(sys.argv[3:]) if len(sys.argv) > 3 else set()

    m = M(path)
    cl = m.secs[('__DATA_CONST', '__objc_classlist')]
    total = cl[1] // 8

    all_names = []
    detail = {}
    for i in range(total):
        ptr = m.u64(cl[2] + i * 8)
        coff = m.va2off(ptr)
        if not coff:
            continue
        data = m.u64(coff + 32) & ~7
        doff = m.va2off(data)
        if not doff:
            continue
        name_va = m.u64(doff + 24)
        noff = m.va2off(name_va)
        if not noff:
            continue
        name = m.cstr(noff)
        if not name:
            continue
        all_names.append(name)
        if name in targets:
            sup_ptr = m.u64(coff + 8)
            sup_name = None
            if sup_ptr:
                sc = m.va2off(sup_ptr)
                if sc:
                    sd = m.u64(sc + 32) & ~7
                    sdo = m.va2off(sd)
                    if sdo:
                        sup_name = m.cstr(m.va2off(m.u64(sdo + 24)))
            detail[name] = {
                'super': sup_name,
                'methods': [x for x in methods_of(m, ptr, data) if x],
            }

    with open(outpath, 'w', encoding='utf-8') as f:
        json.dump({'count': len(all_names), 'names': all_names, 'detail': detail}, f, ensure_ascii=False)
    print('classes:', len(all_names), 'matched:', len(detail))
    for k, v in detail.items():
        print('  %-45s super=%-35s methods=%d' % (k, v['super'], len(v['methods'])))


if __name__ == '__main__':
    main()
