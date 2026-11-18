#!/usr/bin/env python3
"""Статическая проверка out/usb.img без запуска эмулятора.

Проверяются:
  * MBR: сигнатура, один активный раздел, его LBA/размер;
  * второй этап загрузчика и bios.img на своих LBA;
  * BPB FAT16 раздела, FAT[0]/FAT[1], скрытые сектора;
  * файлы внутри FAT-раздела (сверка с out/).

Запуск: python tools/verify_usb.py out/usb.img
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_iso import verify_fat

S = 512
LOADER_LBA = 1
PAYLOAD_LBA = 9
FAT_LBA = 2048


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def main(path):
    with open(path, 'rb') as f:
        d = f.read()

    # ---- MBR ----
    mbr = d[:S]
    assert mbr[510:512] == b'\x55\xAA', 'bad MBR signature'
    entry = mbr[0x1BE:0x1CE]
    assert entry[0] == 0x80, 'partition 1 must be active'
    ptype = entry[4]
    start = u32(entry, 8)
    count = u32(entry, 12)
    print(f'MBR ok: active partition type 0x{ptype:02X}, '
          f'LBA {start}, {count} sectors')
    assert ptype == 0xEF, f'unexpected partition type 0x{ptype:02X}'
    assert start == FAT_LBA, f'partition starts at {start}, expected {FAT_LBA}'
    assert (start + count) * S == len(d), 'partition does not fill the image'

    # ---- загрузчик и BIOS payload ----
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'out')

    with open(os.path.join(out, 'usb_loader.bin'), 'rb') as f:
        loader = f.read()
    assert d[LOADER_LBA * S:LOADER_LBA * S + len(loader)] == loader, \
        'usb_loader mismatch'
    print(f'usb_loader ok: LBA {LOADER_LBA}, {len(loader)} bytes')

    with open(os.path.join(out, 'bios.img'), 'rb') as f:
        bios = f.read()
    assert d[PAYLOAD_LBA * S:PAYLOAD_LBA * S + len(bios)] == bios, \
        'bios.img mismatch'
    print(f'bios.img ok: LBA {PAYLOAD_LBA}, {len(bios)} bytes')

    # ---- FAT16 раздел ----
    fat = d[start * S:(start + count) * S]
    assert u32(fat, 28) == start, 'BPB hidden sectors must equal partition LBA'

    expected = {}
    for name in ('BOOTX64.EFI', 'KERNEL32.BIN', 'KERNEL64.BIN', 'README.TXT'):
        with open(os.path.join(out, name), 'rb') as f:
            expected[name] = f.read()

    verify_fat(fat, len(fat), expected)
    print('USB IMAGE OK')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join('out', 'usb.img')))
