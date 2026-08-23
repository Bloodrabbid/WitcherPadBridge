#!/usr/bin/env python3
"""Add (or remove) an LC_LOAD_DYLIB entry in every slice of a Mach-O binary.

Steam on macOS has no way to pass DYLD_INSERT_LIBRARIES to a game (the VAR=val %command%
syntax is Linux-only), so the only way for the mod to load on a normal Steam launch is for the
executable itself to name it. The load commands sit in a region padded out to the first __TEXT
section -- megabytes of zeroes here -- so the entry is written into that padding and the file
length never changes.

  inject_loadcmd.py add    <binary> <dylib-path>
  inject_loadcmd.py remove <binary> <dylib-path>
  inject_loadcmd.py list   <binary>
"""
import struct, sys

LC_LOAD_DYLIB = 0x0C
LC_SEGMENT_64 = 0x19
FAT_MAGIC     = 0xCAFEBABE
MH_MAGIC_64   = 0xFEEDFACF


def slices(data):
    """(offset, size) for each Mach-O in the file, fat or thin."""
    magic, = struct.unpack_from('>I', data, 0)
    if magic == FAT_MAGIC:
        n, = struct.unpack_from('>I', data, 4)
        out = []
        for i in range(n):
            _, _, off, size, _ = struct.unpack_from('>5I', data, 8 + i * 20)
            out.append((off, size))
        return out
    if struct.unpack_from('<I', data, 0)[0] == MH_MAGIC_64:
        return [(0, len(data))]
    raise SystemExit('not a Mach-O file')


def walk(data, off):
    ncmds, sizeofcmds = struct.unpack_from('<II', data, off + 16)
    p = off + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, p)
        yield p, cmd, cmdsize
        p += cmdsize


def dylib_name(data, p, cmdsize):
    noff, = struct.unpack_from('<I', data, p + 8)
    return data[p + noff:p + cmdsize].rstrip(b'\0').decode(errors='replace')


def first_section_offset(data, off):
    """Where the padding after the load commands ends."""
    best = None
    for p, cmd, cmdsize in walk(data, off):
        if cmd != LC_SEGMENT_64:
            continue
        nsects, = struct.unpack_from('<I', data, p + 64)
        for i in range(nsects):
            s = p + 72 + i * 80
            fileoff, = struct.unpack_from('<I', data, s + 48)
            if fileoff and (best is None or fileoff < best):
                best = fileoff
    return best


def add(data, off, path):
    for p, cmd, cmdsize in walk(data, off):
        if cmd == LC_LOAD_DYLIB and dylib_name(data, p, cmdsize) == path:
            return data, 'already present'
    raw = path.encode() + b'\0'
    cmdsize = (24 + len(raw) + 7) & ~7
    ncmds, sizeofcmds = struct.unpack_from('<II', data, off + 16)
    end = off + 32 + sizeofcmds
    limit = first_section_offset(data, off)
    if limit is None or end - off + cmdsize > limit:
        raise SystemExit('no padding left for another load command')
    if any(data[end:end + cmdsize]):
        raise SystemExit('padding after the load commands is not free')
    cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000)
    cmd += raw + b'\0' * (cmdsize - 24 - len(raw))
    data[end:end + cmdsize] = cmd
    struct.pack_into('<II', data, off + 16, ncmds + 1, sizeofcmds + cmdsize)
    return data, 'added'


def remove(data, off, path):
    ncmds, sizeofcmds = struct.unpack_from('<II', data, off + 16)
    for p, cmd, cmdsize in walk(data, off):
        if cmd == LC_LOAD_DYLIB and dylib_name(data, p, cmdsize) == path:
            tail_end = off + 32 + sizeofcmds
            data[p:tail_end - cmdsize] = data[p + cmdsize:tail_end]
            data[tail_end - cmdsize:tail_end] = b'\0' * cmdsize
            struct.pack_into('<II', data, off + 16, ncmds - 1, sizeofcmds - cmdsize)
            return data, 'removed'
    return data, 'not present'


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    action, binary = sys.argv[1], sys.argv[2]
    data = bytearray(open(binary, 'rb').read())
    if action == 'list':
        for off, _ in slices(data):
            for p, cmd, cmdsize in walk(data, off):
                if cmd == LC_LOAD_DYLIB:
                    print(f'{off:#x}  {dylib_name(data, p, cmdsize)}')
        return
    path = sys.argv[3]
    for off, _ in slices(data):
        data, how = (add if action == 'add' else remove)(data, off, path)
        print(f'slice {off:#x}: {how}')
    open(binary, 'wb').write(data)


main()
