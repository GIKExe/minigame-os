#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Минимальный генератор ISO9660 + El Torito (BIOS + UEFI).

Зачем свой генератор: в окружении сборки нет xorriso/mkisofs, а для
поставленной задачи достаточно ISO9660 level 1 + El Torito. Генератор
не зависит от ОС и запускается обычным Python.

ISO содержит:
  * El Torito boot catalog с двумя записями:
      - BIOS, no emulation, образ bios.img;
      - UEFI, platform ID 0xEF, образ efi.img (FAT16);
  * файлы в корне ISO: README.TXT, KERNEL32.BIN, KERNEL64.BIN,
    BIOS.IMG, EFI.IMG, BOOTX64.EFI.
"""

import math
import os
import struct
import sys

SECTOR = 2048

# LBA служебных структур
LBA_PVD = 16
LBA_BOOT_RECORD = 17
LBA_TERMINATOR = 18
LBA_BOOT_CATALOG = 19
LBA_PATH_L = 20
LBA_PATH_M = 21
LBA_ROOT_DIR = 22
LBA_FIRST_FILE = 23


def _le16(v):
    return struct.pack("<H", v & 0xFFFF)


def _be16(v):
    return struct.pack(">H", v & 0xFFFF)


def _le32(v):
    return struct.pack("<I", v & 0xFFFFFFFF)


def _be32(v):
    return struct.pack(">I", v & 0xFFFFFFFF)


def _both16(v):
    return _le16(v) + _be16(v)


def _both32(v):
    return _le32(v) + _be32(v)


def _pad(text, size):
    data = text.encode("ascii", "replace")[:size]
    return data.ljust(size, b" ")


def _date7(year=2026, month=1, day=1):
    return bytes([(year - 1900) & 0xFF, month, day, 0, 0, 0, 0])


def _date17():
    # YYYYMMDDHHMMSS + hundredths + GMT offset
    return b"2026010100000000" + b"\x00"


def _dir_record(name, extent, size, flags=0):
    name_b = name.encode("ascii")
    nlen = len(name_b)
    rec_len = 33 + nlen
    if nlen % 2 == 0:
        rec_len += 1

    rec = bytearray()
    rec += bytes([rec_len, 0])
    rec += _both32(extent)
    rec += _both32(size)
    rec += _date7()
    rec += bytes([flags, 0, 0])
    rec += _both16(1)
    rec += bytes([nlen])
    rec += name_b
    if rec_len > len(rec):
        rec += b"\x00"
    assert len(rec) == rec_len, (name, len(rec), rec_len)
    return bytes(rec)


def _path_table(big_endian=False):
    e16 = _be16 if big_endian else _le16
    e32 = _be32 if big_endian else _le32
    # root: len_di=1, ext_attr=0, extent, parent=1, name=0, padding
    rec = bytes([1, 0]) + e32(LBA_ROOT_DIR) + e16(1) + b"\x00\x00"
    assert len(rec) == 10
    return rec


def _boot_catalog(bios_sectors, bios_lba, efi_sectors, efi_lba):
    # Validation entry
    val = bytearray(32)
    val[0] = 1                       # header id
    val[1] = 0                       # platform: x86
    val[4:28] = b"MINIGAME OS BOOT CATALOG"
    val[30] = 0x55
    val[31] = 0xAA
    # checksum: сумма всех 16-битных слов должна быть 0
    words = struct.unpack("<16H", bytes(val))
    val[28:30] = _le16((-sum(words)) & 0xFFFF)

    # Default (BIOS) entry
    bios = bytearray(32)
    bios[0] = 0x88                   # bootable
    bios[1] = 0x00                   # no emulation
    bios[2:4] = _le16(0)             # load segment
    bios[4] = 0                      # system type
    bios[6:8] = _le16(bios_sectors)
    bios[8:12] = _le32(bios_lba)

    # Section header for UEFI
    sec = bytearray(32)
    sec[0] = 0x91                    # final section header
    sec[1] = 0xEF                    # UEFI platform
    sec[2:4] = _le16(1)              # one entry
    sec[4:32] = b"UEFI".ljust(28, b"\x00")

    # UEFI entry
    uefi = bytearray(32)
    uefi[0] = 0x88
    uefi[1] = 0x00
    uefi[2:4] = _le16(0)
    uefi[4] = 0
    uefi[6:8] = _le16(efi_sectors)
    uefi[8:12] = _le32(efi_lba)

    catalog = bytes(val + bios + sec + uefi)
    assert len(catalog) == 128
    # Проверка контрольной суммы validation entry
    assert sum(struct.unpack("<16H", catalog[:32])) & 0xFFFF == 0
    return catalog


def _pvd(volume_id, total_sectors, root_record):
    """Primary Volume Descriptor, ECMA-119 8.4.

    Раскладка полей после объемного размера:
      72   unused2 (8)
      80   volume space size (both32)
      88   unused3 (32)
      120  volume set size (both16)
      124  volume sequence number (both16)
      128  logical block size (both16)
      132  path table size (both32)
      140  type L path table (LE32)
      144  optional L (LE32)
      148  type M path table (BE32)
      152  optional M (BE32)
      156  root directory record (34)
      190  volume set id (128)
      318  publisher (128)
      446  data preparer (128)
      574  application id (128)
      702  copyright file id (37)
      739  abstract file id (37)
      776  bibliographic file id (37)
      813  creation / modification / expiration / effective dates (17 each)
      881  file structure version
      882  reserved
      883  application use (512)
      1395 reserved (653)
    """
    pvd = bytearray(SECTOR)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = _pad("", 32)         # system id
    pvd[40:72] = _pad(volume_id, 32) # volume id
    pvd[72:80] = b"\x00" * 8         # unused2
    pvd[80:88] = _both32(total_sectors)  # volume space size
    pvd[88:120] = b"\x00" * 32       # unused3 (reserved)
    pvd[120:124] = _both16(1)        # volume set size
    pvd[124:128] = _both16(1)        # volume sequence number
    pvd[128:132] = _both16(SECTOR)   # logical block size
    pvd[132:140] = _both32(len(_path_table(False)))  # path table size
    pvd[140:144] = _le32(LBA_PATH_L)
    pvd[144:148] = _le32(0)          # optional type L
    pvd[148:152] = _be32(LBA_PATH_M)
    pvd[152:156] = _be32(0)          # optional type M
    pvd[156:190] = root_record
    pvd[190:318] = _pad("", 128)     # volume set id
    pvd[318:446] = _pad("", 128)     # publisher
    pvd[446:574] = _pad("", 128)     # data preparer
    pvd[574:702] = _pad("MINIGAME OS", 128)  # application id
    pvd[702:739] = _pad("", 37)      # copyright file id
    pvd[739:776] = _pad("", 37)      # abstract file id
    pvd[776:813] = _pad("", 37)      # bibliographic file id
    pvd[813:830] = _date17()         # creation
    pvd[830:847] = _date17()         # modification
    pvd[847:864] = _date17()         # expiration
    pvd[864:881] = _date17()         # effective
    pvd[881] = 1                     # file structure version
    # 882 reserved, 883..1394 application use, 1395..2047 reserved
    return bytes(pvd)


def _boot_record(catalog_lba):
    rec = bytearray(SECTOR)
    rec[0] = 0
    rec[1:6] = b"CD001"
    rec[6] = 1
    rec[7:39] = b"EL TORITO SPECIFICATION".ljust(32, b"\x00")
    rec[71:75] = _le32(catalog_lba)
    return bytes(rec)


def build_iso(path, files, volume_id="MINIGAME_OS"):
    """files: list of (iso_name, bytes). BIOS.IMG/EFI.IMG ищутся по имени."""
    files = [(name.upper(), data) for name, data in files]

    # Раскладка файлов
    entries = []
    next_lba = LBA_FIRST_FILE
    for name, data in files:
        sectors = max(1, math.ceil(len(data) / SECTOR))
        entries.append({"name": name, "data": data, "lba": next_lba, "sectors": sectors})
        next_lba += sectors
    total_sectors = next_lba

    by_name = {e["name"]: e for e in entries}
    if "BIOS.IMG" not in by_name or "EFI.IMG" not in by_name:
        raise ValueError("files must contain BIOS.IMG and EFI.IMG")

    bios = by_name["BIOS.IMG"]
    efi = by_name["EFI.IMG"]
    bios_sectors = math.ceil(len(bios["data"]) / 512)
    efi_sectors = math.ceil(len(efi["data"]) / 512)
    if bios_sectors > 0xFFFF or efi_sectors > 0xFFFF:
        raise ValueError("El Torito sector count overflow (max 65535 * 512 bytes)")
    if efi_sectors == 0:
        raise ValueError("empty EFI image")

    # Корневой каталог
    root = bytearray()
    root += _dir_record("\x00", LBA_ROOT_DIR, SECTOR, flags=2)   # "."
    root += _dir_record("\x01", LBA_ROOT_DIR, SECTOR, flags=2)   # ".."
    for e in entries:
        # ISO level 1: 8.3 + ;1
        name = e["name"]
        if "." in name:
            base, ext = name.split(".", 1)
            iso_name = f"{base[:8]}.{ext[:3]};1"
        else:
            iso_name = f"{name[:8]};1"
        root += _dir_record(iso_name, e["lba"], len(e["data"]), flags=0)
    if len(root) > SECTOR:
        raise ValueError(f"root directory too large: {len(root)} bytes")

    root_record = _dir_record("\x00", LBA_ROOT_DIR, SECTOR, flags=2)

    catalog = _boot_catalog(bios_sectors, bios["lba"], efi_sectors, efi["lba"])

    iso = bytearray(total_sectors * SECTOR)
    iso[LBA_PVD * SECTOR:(LBA_PVD + 1) * SECTOR] = _pvd(volume_id, total_sectors, root_record)
    iso[LBA_BOOT_RECORD * SECTOR:(LBA_BOOT_RECORD + 1) * SECTOR] = _boot_record(LBA_BOOT_CATALOG)
    term = bytearray(SECTOR)
    term[0] = 255
    term[1:6] = b"CD001"
    term[6] = 1
    iso[LBA_TERMINATOR * SECTOR:(LBA_TERMINATOR + 1) * SECTOR] = bytes(term)
    iso[LBA_BOOT_CATALOG * SECTOR:LBA_BOOT_CATALOG * SECTOR + len(catalog)] = catalog
    iso[LBA_PATH_L * SECTOR:LBA_PATH_L * SECTOR + 10] = _path_table(False)
    iso[LBA_PATH_M * SECTOR:LBA_PATH_M * SECTOR + 10] = _path_table(True)
    iso[LBA_ROOT_DIR * SECTOR:LBA_ROOT_DIR * SECTOR + len(root)] = root

    for e in entries:
        off = e["lba"] * SECTOR
        iso[off:off + len(e["data"])] = e["data"]

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(iso)

    return {
        "path": path,
        "size": len(iso),
        "sectors": total_sectors,
        "bios_lba": bios["lba"],
        "efi_lba": efi["lba"],
        "bios_sectors": bios_sectors,
        "efi_sectors": efi_sectors,
    }


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def main(argv):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--bios", required=True)
    p.add_argument("--efi", required=True)
    p.add_argument("--bootx64", required=True)
    p.add_argument("--kernel32", required=True)
    p.add_argument("--kernel64", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--readme", default=None)
    args = p.parse_args(argv)

    files = [
        ("BIOS.IMG", _read(args.bios)),
        ("EFI.IMG", _read(args.efi)),
        ("BOOTX64.EFI", _read(args.bootx64)),
        ("KERNEL32.BIN", _read(args.kernel32)),
        ("KERNEL64.BIN", _read(args.kernel64)),
    ]
    if args.readme:
        files.append(("README.TXT", _read(args.readme)))

    info = build_iso(args.output, files)
    print(f"[+] ISO: {info['path']} ({info['size']} bytes, {info['sectors']} sectors)")
    print(f"    BIOS LBA {info['bios_lba']} ({info['bios_sectors']} x 512)")
    print(f"    UEFI LBA {info['efi_lba']} ({info['efi_sectors']} x 512)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
