#!/usr/bin/env python3
"""Статическая проверка minigame-os.iso без запуска эмулятора.

Проверяются:
  * Primary Volume Descriptor по ECMA-119 (смещения 156/190/318/...);
  * размер ISO и обе половины both-endian полей;
  * корневой каталог и все файлы;
  * El Torito boot catalog (контрольная сумма, BIOS- и UEFI-записи,
    совпадение LBA/размера с файлами ISO);
  * сигнатура BIOS-загрузчика;
  * BPB FAT16/FAT32, FAT[0]/FAT[1], FSInfo/backup boot sector;
  * каталоги и файлы внутри UEFI FAT-образа (сверка с файлами ISO).

Запуск: python tools/verify_iso.py minigame-os.iso
"""

import struct
import sys

S = 2048


def u16(b, o):
    return struct.unpack_from('<H', b, o)[0]


def u16be(b, o):
    return struct.unpack_from('>H', b, o)[0]


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def be32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def show_entry(label, e):
    """Запись boot catalog: boot indicator, media, load segment, LBA, count."""
    assert e[0] == 0x88, (label, hex(e[0]))
    print(f"{label}: bootable, media 0x{e[1]:02X}, "
          f"load segment 0x{u16(e, 2):04X}, "
          f"sectors {u16(e, 6)}, lba {u32(e, 8)}")


def verify_fat(fat, size, expected):
    """Проверка BPB и содержимого FAT12/FAT16/FAT32-образа для UEFI.

    Тип FAT определяется так же, как в EDK2 FatPkg и Windows: по
    FatSz16/FatSz32 и числу кластеров. Меньше 4085 кластеров при
    FatSz16 != 0 - FAT12, 4085..65524 - FAT16. FAT32 обязан иметь не
    менее 65525 кластеров (0xFFF5), иначе EDK2 возвращает
    EFI_VOLUME_CORRUPTED.
    """
    assert len(fat) == size
    bps = u16(fat, 11)
    assert bps >= 512 and bps & (bps - 1) == 0, 'bad bytes per sector'
    spc = fat[13]
    assert spc != 0 and spc & (spc - 1) == 0, 'bad sectors per cluster'
    reserved = u16(fat, 14)
    numfats = fat[16]
    assert reserved != 0 and numfats != 0, 'bad reserved/FAT count'
    root_entries = u16(fat, 17)
    tot16 = u16(fat, 19)
    tot32 = u32(fat, 32)
    tot = tot32 if tot32 else tot16
    assert tot != 0, 'volume has no sectors'
    assert tot * bps == size, f'volume size {tot * bps} != image {size}'
    fatsz16 = u16(fat, 22)
    fatsz32 = u32(fat, 36)
    assert fat[21] in (0xF0, 0xF8), 'bad media descriptor'
    assert fat[510:512] == b'\x55\xAA', 'bad boot sector signature'

    fatsz = fatsz16 if fatsz16 else fatsz32
    root_secs = (root_entries * 32 + bps - 1) // bps
    first_data = reserved + numfats * fatsz + root_secs
    clusters = (tot - first_data) // spc
    assert clusters > 0, 'no data clusters'

    if fatsz16:
        assert root_entries != 0, 'FAT16/FAT12 root entry count must be non-zero'
        fat32 = False
        if clusters < 4085:
            fat_bits, fat_type = 12, 'FAT12'
        else:
            assert clusters < 65525, f'{clusters} clusters is not FAT16'
            fat_bits, fat_type = 16, 'FAT16'
    else:
        assert fatsz32 != 0, 'no FAT size'
        assert root_entries == 0, 'FAT32 root entry count must be 0'
        fat32 = True
        # EDK2 FatPkg: меньше 65525 кластеров — EFI_VOLUME_CORRUPTED.
        assert clusters >= 65525, \
            f'FAT32 needs >= 65525 clusters, got {clusters}'
        fat_bits = 32
        fat_type = 'FAT32'

    assert fat[54:62].rstrip(b'\x00 ') == fat_type.encode(), \
        f'BPB says {fat[54:62]!r}, expected {fat_type}'

    fat_start = reserved * bps

    if fat32:
        fat0 = u32(fat, fat_start) & 0x0FFFFFFF
        fat1 = u32(fat, fat_start + 4) & 0x0FFFFFFF
        assert fat0 == 0x0FFFFFF8, hex(fat0)
        assert fat1 == 0x0FFFFFFF, hex(fat1)
        fsinfo_sec = u16(fat, 48)
        fsinfo = fat[fsinfo_sec * bps:(fsinfo_sec + 1) * bps]
        assert u32(fsinfo, 0) == 0x41615252
        assert u32(fsinfo, 484) == 0x61417272
        assert u32(fsinfo, 488) <= clusters, 'FSInfo free count too large'
        backup_sec = u16(fat, 50)
        backup = fat[backup_sec * bps:(backup_sec + 1) * bps]
        assert backup[:11] == fat[:11], 'bad backup boot sector'
    else:
        fat0 = u16(fat, fat_start)
        fat1 = u16(fat, fat_start + 2)
        assert fat0 >> 8 == 0xFF and fat0 & 0xFF == fat[21], hex(fat0)
        assert fat1 == 0xFFFF, hex(fat1)

    def fat_next(cluster):
        """Следующий кластер цепочки или None в конце."""
        if fat32:
            value = u32(fat, fat_start + cluster * 4) & 0x0FFFFFFF
            return None if value >= 0x0FFFFFF8 else value
        if fat_bits == 12:
            offset = fat_start + cluster + cluster // 2
            value = u16(fat, offset)
            value = (value >> 4) if (cluster & 1) else (value & 0x0FFF)
            return None if value >= 0xFF8 else value
        value = u16(fat, fat_start + cluster * 2)
        return None if value >= 0xFFF8 else value

    def read_chain(cluster, limit):
        out = bytearray()
        seen = set()
        while cluster is not None and len(out) < limit:
            assert 2 <= cluster < clusters + 2, \
                f'cluster {cluster} outside volume'
            assert cluster not in seen, 'loop in cluster chain'
            seen.add(cluster)
            offset = (first_data + (cluster - 2) * spc) * bps
            out += fat[offset:offset + spc * bps]
            cluster = fat_next(cluster)
        return bytes(out[:limit])

    def parse_dir(data):
        entries = []
        for offset in range(0, len(data), 32):
            e = data[offset:offset + 32]
            if len(e) < 32 or e[0] == 0:
                break
            if e[0] == 0xE5:
                continue
            attr = e[11]
            if attr == 0x0F or attr & 0x08:      # LFN / volume label
                continue
            base = e[0:8].decode('latin-1').rstrip()
            ext = e[8:11].decode('latin-1').rstrip()
            if base in ('.', '..'):
                continue
            name = (base + ('.' + ext if ext else '')).upper()
            cluster = u16(e, 26)
            if fat32:
                cluster |= u16(e, 20) << 16
            entries.append((name, attr, cluster, u32(e, 28)))
        return entries

    def find(entries, name):
        for entry in entries:
            if entry[0] == name:
                return entry
        return None

    def subdir(entry):
        assert entry[1] & 0x10, f'{entry[0]} is not a directory'
        return parse_dir(read_chain(entry[2], 1 << 20))

    # Корневой каталог: FAT16 — фиксированная область, FAT32 — цепочка.
    if fat32:
        root = parse_dir(read_chain(u32(fat, 44), 1 << 20))
    else:
        root_off = (reserved + numfats * fatsz) * bps
        root = parse_dir(fat[root_off:root_off + root_entries * 32])

    print(f'{fat_type} ok: {tot} sectors, {spc} sec/cluster, '
          f'{clusters} clusters, {fat_bits}-bit FAT x {numfats}')

    # Сверяем содержимое FAT-образа с теми же файлами в корне ISO.
    for name in ('KERNEL32.BIN', 'KERNEL64.BIN', 'README.TXT'):
        entry = find(root, name)
        assert entry is not None, f'{name} missing in FAT root'
        data = read_chain(entry[2], entry[3]) if entry[3] else b''
        assert data == expected[name], f'{name} content mismatch'

    efi = find(root, 'EFI')
    assert efi is not None, 'EFI directory missing'
    boot = find(subdir(efi), 'BOOT')
    assert boot is not None, 'EFI/BOOT directory missing'
    loader = find(subdir(boot), 'BOOTX64.EFI')
    assert loader is not None, 'EFI/BOOT/BOOTX64.EFI missing'
    data = read_chain(loader[2], loader[3])
    assert data == expected['BOOTX64.EFI'], 'BOOTX64.EFI content mismatch'
    print('FAT files ok: EFI/BOOT/BOOTX64.EFI, KERNEL32.BIN, '
          'KERNEL64.BIN, README.TXT')
    return clusters


def main(path):
    with open(path, 'rb') as f:
        d = f.read()

    # ---- PVD (offset 16 * 2048) ----
    pvd = d[16 * S:17 * S]
    assert pvd[0] == 1 and pvd[1:6] == b'CD001', pvd[:8]
    assert pvd[6] == 1, 'PVD version must be 1'
    print('PVD ok, volume id', pvd[40:72].decode('ascii').strip())

    total = u32(pvd, 80)
    assert total == be32(pvd, 84), 'volume space size endian mismatch'
    print('volume sectors', total, 'size', len(d), 'expected', total * S)
    assert total * S == len(d), 'ISO size does not match PVD'

    # both-endian поля
    assert u16(pvd, 120) == u16be(pvd, 122), 'volume set size endian'
    assert u16(pvd, 124) == u16be(pvd, 126), 'volume sequence endian'
    assert u16(pvd, 128) == u16be(pvd, 130), 'logical block size endian'
    assert u32(pvd, 132) == be32(pvd, 136), 'path table size endian'
    assert u16(pvd, 128) == S, 'logical block size must be 2048'
    assert pvd[881] == 1, 'file structure version must be 1'

    root = pvd[156:190]              # ECMA-119: root record at offset 156
    root_lba = u32(root, 2)
    root_size = u32(root, 10)
    assert root[0] == 34, root[0]
    assert root[32] == 1 and root[33] == 0, 'root record name must be 0x00'
    assert root_lba == be32(root, 6), 'root extent endian'
    assert root_size == be32(root, 14), 'root size endian'
    print('root dir lba', root_lba, 'size', root_size)

    path_size = u32(pvd, 132)
    path_l = u32(pvd, 140)
    path_m = be32(pvd, 148)
    print('path table size', path_size, 'L', path_l, 'M', path_m)
    assert path_size == 10, path_size
    assert path_l == 20 and path_m == 21

    # ---- Boot Record ----
    br = d[17 * S:18 * S]
    assert br[0] == 0 and br[1:6] == b'CD001', br[:8]
    assert br[7:39].rstrip(b'\x00') == b'EL TORITO SPECIFICATION'
    cat_lba = u32(br, 71)
    print('boot catalog lba', cat_lba)

    cat = d[cat_lba * S:cat_lba * S + 128]
    checksum = sum(struct.unpack_from('<16H', cat, 0)) & 0xFFFF
    print('validation checksum', hex(checksum))
    assert checksum == 0, 'bad El Torito validation checksum'
    print('validation id', cat[4:28].rstrip(b'\x00').decode('ascii', 'replace'))
    assert cat[30:32] == b'\x55\xAA', cat[30:32]

    show_entry('BIOS', cat[32:64])

    sec = cat[64:96]
    assert sec[0] in (0x90, 0x91), hex(sec[0])
    assert sec[1] == 0xEF, 'UEFI platform id expected'
    print('UEFI header: indicator', hex(sec[0]), 'platform 0xEF',
          'entries', u16(sec, 2), 'id',
          sec[4:32].rstrip(b'\x00').decode('ascii', 'replace'))

    show_entry('UEFI', cat[96:128])

    # ---- Root directory ----
    rd = d[root_lba * S:root_lba * S + root_size]
    o = 0
    files = {}
    while o < root_size and rd[o] != 0:
        l = rd[o]
        extent = u32(rd, o + 2)
        size = u32(rd, o + 10)
        flags = rd[o + 25]
        nlen = rd[o + 32]
        name = rd[o + 33:o + 33 + nlen]
        if nlen == 1 and name in (b'\x00', b'\x01'):
            print('dir entry', name, 'lba', extent, 'size', size,
                  'flags', flags)
        else:
            files[name.decode('ascii')] = (extent, size)
            print('file', name.decode('ascii'), 'lba', extent, 'size', size)
        assert extent == be32(rd, o + 6), 'file extent endian'
        assert size == be32(rd, o + 14), 'file size endian'
        o += l

    for name in ['BIOS.IMG;1', 'EFI.IMG;1', 'BOOTX64.EFI;1',
                 'KERNEL32.BIN;1', 'KERNEL64.BIN;1', 'README.TXT;1']:
        assert name in files, name
        lba, size = files[name]
        end = lba * S + size
        assert end <= len(d), f'{name}: extent outside ISO'
        data = d[lba * S:end]
        print('check', name, 'first bytes', data[:8].hex(),
              'actual size', size)

    # El Torito LBA/размер должны совпадать с файлами ISO.
    for label, entry, name in (('BIOS', cat[32:64], 'BIOS.IMG;1'),
                               ('UEFI', cat[96:128], 'EFI.IMG;1')):
        lba, size = files[name]
        assert u32(entry, 8) == lba, f'{label}: catalog LBA mismatch'
        assert u16(entry, 6) * 512 == size, f'{label}: catalog size mismatch'

    # ---- BIOS-загрузчик ----
    lba, size = files['BIOS.IMG;1']
    bios = d[lba * S:lba * S + size]
    assert bios[0] == 0xE9, hex(bios[0])
    assert bios[510:512] == b'\x55\xAA', bios[510:512]
    print('BIOS boot signature ok')

    # ---- FAT-образ UEFI ----
    lba, size = files['EFI.IMG;1']
    fat = d[lba * S:lba * S + size]
    expected = {
        name.split(';')[0]: d[extent * S:extent * S + fsize]
        for name, (extent, fsize) in files.items()
        if name not in ('BIOS.IMG;1', 'EFI.IMG;1')
    }
    print('EFI.IMG size', size, 'OEM', fat[3:11])
    verify_fat(fat, size, expected)

    print('ALL OK')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'minigame-os.iso'))
