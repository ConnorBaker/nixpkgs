import struct, sys
elf = bytearray(open(sys.argv[1], "rb").read())
(shoff,) = struct.unpack_from("<Q", elf, 0x28)
shnum, shstrndx = struct.unpack_from("<HH", elf, 0x3C)
struct.pack_into("<HH", elf, 0x3C, 0, 0xFFFF)  # e_shnum, e_shstrndx (SHN_XINDEX)
struct.pack_into("<Q", elf, shoff + 0x20, shnum)  # sh_size
struct.pack_into("<I", elf, shoff + 0x28, shstrndx)  # sh_link
open(sys.argv[2], "wb").write(elf)
