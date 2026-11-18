#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Сборка MiniGame OS.
#
# Запускать обычным Python под Windows. В WSL должны быть установлены:
#   sudo apt install nasm mtools binutils
#
# Результат:
#   out/kernel32.bin   - ядро protected mode (i386+)
#   out/kernel64.bin   - ядро long mode (x86-64)
#   out/bios.img       - El Torito boot image для BIOS
#   out/BOOTX64.EFI    - UEFI-загрузчик (PE32+)
#   out/efi.img        - FAT16-образ с EFI/BOOT/BOOTX64.EFI
#   out/usb.img        - образ для USB-флешки (MBR: BIOS + FAT16: UEFI)

import os
import struct
import sys
import subprocess

OUT_DIR = "out"

KERNEL32_FILE = os.path.join(OUT_DIR, "kernel32.bin")
KERNEL64_FILE = os.path.join(OUT_DIR, "kernel64.bin")
BOOTLOADER_FILE = os.path.join(OUT_DIR, "bios_stage1.bin")
BIOS_IMG = os.path.join(OUT_DIR, "bios.img")
UEFI_OBJ = os.path.join(OUT_DIR, "uefi.obj")
UEFI_EFI = os.path.join(OUT_DIR, "BOOTX64.EFI")
EFI_IMG = os.path.join(OUT_DIR, "efi.img")
README_FILE = os.path.join(OUT_DIR, "README.TXT")

KERNEL32_SRC = os.path.join("src", "kernel32.nasm")
KERNEL64_SRC = os.path.join("src", "kernel64.nasm")
BIOS_SRC = os.path.join("src", "bios_boot.nasm")
UEFI_SRC = os.path.join("src", "uefi_boot.nasm")

STAGE1_RESERVE = 0x2000                 # байт под bios_stage1.bin
LOAD_BASE = 0x7C00                      # El Torito грузит boot image сюда
KERNEL32_ADDR = LOAD_BASE + STAGE1_RESERVE
KERNEL64_ALIGN = 0x1000

# FAT16-раздел для UEFI: 65535 секторов по 512 байт (~32 МиБ),
# 64994 кластера. Валидный FAT32 требует >= 65525 кластеров, поэтому
# для такого размера используется FAT16: на нём том монтируют EDK2,
# Windows и Linux.
EFI_IMG_SECTORS = 0xFFFF

ENABLE_64 = True


def wsl_path(path):
    p = os.path.abspath(path).replace("\\", "/")
    if len(p) >= 2 and p[1] == ":":
        return f"/mnt/{p[0].lower()}{p[2:]}"
    return p


def run(cmd, desc):
    print(f"[*] {desc}...")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"[!] Ошибка команды: {' '.join(cmd)}", file=sys.stderr)
        sys.exit(result.returncode)


def align_up(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def write_file(path, data):
    with open(path, "wb") as f:
        f.write(data)


def nasm(src, dst, fmt="bin", defines=None, includes=None):
    cmd = ["wsl", "nasm", "-f", fmt]
    for define in defines or []:
        cmd += ["-D", define]
    for include in includes or []:
        cmd += ["-I", include]
    cmd += [wsl_path(src), "-o", wsl_path(dst)]
    return cmd


def patch_pe_section(path, section_name, characteristics):
    """GNU ld для PE не даёт выставить CODE|WRITE одновременно через NASM.
    Патчим характеристики секции .kernel уже в готовом PE-файле."""
    data = bytearray(read_file(path))
    if data[:2] != b"MZ":
        raise RuntimeError("not a PE file")
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_off:pe_off + 4] != b"PE\x00\x00":
        raise RuntimeError("bad PE signature")
    coff = pe_off + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    sec_off = coff + 20 + opt_size
    found = False
    for i in range(num_sections):
        off = sec_off + i * 40
        name = bytes(data[off:off + 8]).rstrip(b"\x00")
        if name == section_name.encode("ascii"):
            struct.pack_into("<I", data, off + 36, characteristics)
            found = True
    if not found:
        raise RuntimeError(f"section {section_name} not found in {path}")
    write_file(path, data)


def verify_pe(path):
    data = read_file(path)
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe_off + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    sec_off = coff + 20 + opt_size
    sections = {}
    for i in range(num_sections):
        off = sec_off + i * 40
        name = bytes(data[off:off + 8]).rstrip(b"\x00").decode("ascii", "replace")
        flags = struct.unpack_from("<I", data, off + 36)[0]
        sections[name] = flags
    print("[*] PE sections:")
    for name, flags in sections.items():
        print(f"      {name}: 0x{flags:08X}")
    if ".reloc" not in sections:
        print("[!] В PE нет .reloc: UEFI может не суметь загрузить образ по другому адресу.",
              file=sys.stderr)
    if ".kernel" not in sections:
        print("[!] В PE нет .kernel: ядро не встроено.", file=sys.stderr)
        sys.exit(1)
    if not (sections[".kernel"] & 0x80000000):
        print("[!] .kernel не writable: стек ядра упадёт.", file=sys.stderr)
        sys.exit(1)
    if not (sections[".kernel"] & 0x20000000):
        print("[!] .kernel не executable.", file=sys.stderr)
        sys.exit(1)


# ----------------------------
# Подготовка и компиляция
# ----------------------------

os.makedirs(OUT_DIR, exist_ok=True)

# 1. 64-битное ядро (позиционно-независимое, ORG 0)
run(nasm(KERNEL64_SRC, KERNEL64_FILE, includes=[wsl_path("src") + "/"]),
    "Компиляция kernel64")

# 2. 32-битное ядро: сначала узнаём размер при ORG 0.
tmp32 = os.path.join(OUT_DIR, "kernel32.size.bin")
run(nasm(KERNEL32_SRC, tmp32, defines=["KERNEL_BASE=0"],
         includes=[wsl_path("src") + "/"]),
    "Компиляция kernel32 (измерение размера)")
size32 = len(read_file(tmp32))

# 3. Раскладка boot image
k64_off = align_up(STAGE1_RESERVE + size32, KERNEL64_ALIGN)
k64_addr = LOAD_BASE + k64_off

# 4. Пересобираем 32-битное ядро по реальному адресу
run(nasm(KERNEL32_SRC, KERNEL32_FILE,
         defines=[f"KERNEL_BASE=0x{KERNEL32_ADDR:X}"],
         includes=[wsl_path("src") + "/"]),
    "Компиляция kernel32")
size32 = len(read_file(KERNEL32_FILE))

k64_off = align_up(STAGE1_RESERVE + size32, KERNEL64_ALIGN)
k64_addr = LOAD_BASE + k64_off
print(f"[*] kernel32 @ 0x{KERNEL32_ADDR:X} ({size32} bytes)")
print(f"[*] kernel64 @ 0x{k64_addr:X}")

# 5. BIOS stage1
run(nasm(BIOS_SRC, BOOTLOADER_FILE,
         defines=[f"K32_ADDR=0x{KERNEL32_ADDR:X}", f"K64_ADDR=0x{k64_addr:X}"],
         includes=[wsl_path("src") + "/"]),
    "Компиляция BIOS-загрузчика")

stage1 = read_file(BOOTLOADER_FILE)
if len(stage1) > STAGE1_RESERVE:
    print(f"[!] bios_stage1.bin больше 0x{STAGE1_RESERVE:X} байт", file=sys.stderr)
    sys.exit(1)

# 6. Boot image = stage1 + kernel32 + padding + kernel64
kernel32 = read_file(KERNEL32_FILE)
kernel64 = read_file(KERNEL64_FILE)
bios = bytearray(stage1.ljust(STAGE1_RESERVE, b"\x00"))
bios += kernel32
if len(bios) > k64_off:
    print("[!] kernel32 перекрывает адрес kernel64", file=sys.stderr)
    sys.exit(1)
bios += b"\x00" * (k64_off - len(bios))
bios += kernel64
# El Torito считает размер в 512-байтных секторах, а BIOS читает CD
# блоками по 2048 байт. Выравниваем образ по 2048, чтобы ни одна
# прошивка не обрезала хвост при округлении.
if len(bios) % 2048:
    bios += b"\x00" * (2048 - len(bios) % 2048)
if LOAD_BASE + len(bios) >= 0x70000:
    print("[!] BIOS boot image задевает page tables (0x70000)", file=sys.stderr)
    sys.exit(1)
write_file(BIOS_IMG, bios)
print(f"[*] BIOS boot image: {len(bios)} bytes")

# 7. UEFI-загрузчик
run(nasm(UEFI_SRC, UEFI_OBJ, fmt="win64",
         includes=[wsl_path("src") + "/", wsl_path(OUT_DIR) + "/"]),
    "Компиляция UEFI-загрузчика")
run([
    "wsl", "ld", "-mi386pep",
    "-e", "efi_main",
    "--subsystem", "10",
    "--image-base", "0x10000000",
    "--file-alignment", "0x200",
    "--section-alignment", "0x1000",
    "-o", wsl_path(UEFI_EFI),
    wsl_path(UEFI_OBJ),
], "Линковка BOOTX64.EFI")

# .kernel должна быть RWX: в ней код, данные и стек ядра.
patch_pe_section(UEFI_EFI, ".kernel", 0xE0500020)
verify_pe(UEFI_EFI)

# 8. FAT16-образ для UEFI
#
# -F (FAT32) здесь использовать нельзя: при 65535 секторах по 512 байт
# получается 64994 кластера, а FAT32 по спецификации начинается с 65525.
# EDK2 FatPkg в таком случае возвращает EFI_VOLUME_CORRUPTED, Windows
# определяет тип по числу кластеров и тоже не монтирует том. FAT16 с
# 64994 кластерами (< 65525) — валидный том для всех трёх реализаций.
efi_size = EFI_IMG_SECTORS * 512
print(f"[*] Создание FAT16 ({efi_size} bytes)...")
write_file(EFI_IMG, b"\x00" * efi_size)
run([
    "wsl", "mformat", "-i", wsl_path(EFI_IMG),
    "-T", str(EFI_IMG_SECTORS), "-h", "64", "-s", "32", "-c", "1",
    "-v", "EFIBOOT", "::",
], "Форматирование FAT16")

run(["wsl", "mmd", "-i", wsl_path(EFI_IMG), "::/EFI", "::/EFI/BOOT"],
    "Создание EFI/BOOT")
run(["wsl", "mcopy", "-o", "-i", wsl_path(EFI_IMG), wsl_path(UEFI_EFI),
     "::/EFI/BOOT/BOOTX64.EFI"], "Копирование BOOTX64.EFI")
run(["wsl", "mcopy", "-o", "-i", wsl_path(EFI_IMG), wsl_path(KERNEL32_FILE),
     "::/KERNEL32.BIN"], "Копирование KERNEL32.BIN")
run(["wsl", "mcopy", "-o", "-i", wsl_path(EFI_IMG), wsl_path(KERNEL64_FILE),
     "::/KERNEL64.BIN"], "Копирование KERNEL64.BIN")

# 9. README на образе
readme = """MiniGame OS
===========

USB image: MBR (BIOS) + FAT16 partition (UEFI).
BIOS: MBR loads stage1/kernel32/kernel64.
UEFI: FAT16, EFI/BOOT/BOOTX64.EFI.

Controls: W A S D
Architecture: x86-64 (long mode) if supported by CPU,
              otherwise i386 protected mode.
No BIOS calls in the game: direct VGA/GOP output and PS/2 input.
"""
write_file(README_FILE, readme.encode("ascii"))
run(["wsl", "mcopy", "-o", "-i", wsl_path(EFI_IMG), wsl_path(README_FILE),
     "::/README.TXT"], "Копирование README.TXT")

# 10. USB-образ (BIOS + UEFI с флешки)
#
# ISO9660/El Torito рассчитан на CD: с USB-флешки legacy BIOS его, как
# правило, не грузит (El Torito - спецификация CD, а флешка видна как
# винчестер). Поэтому для флешки собирается обычный MBR-образ:
#
#   LBA 0        - MBR, читает второй этап по фиксированному LBA;
#   LBA 1..8     - второй этап (usb_loader), грузится в 0x6000;
#   LBA 9..116   - bios.img (stage1 + kernel32 + kernel64) в 0x7C00;
#   LBA 2048..   - FAT16-раздел с EFI/BOOT/BOOTX64.EFI для UEFI.
#
# Один и тот же файл грузится и в legacy BIOS (через MBR), и в UEFI
# (прошивка монтирует FAT16-раздел).
USB_MBR_FILE = os.path.join(OUT_DIR, "usb_mbr.bin")
USB_LOADER_FILE = os.path.join(OUT_DIR, "usb_loader.bin")
USB_IMG = os.path.join(OUT_DIR, "usb.img")
USB_LOADER_LBA = 1
USB_LOADER_SECTORS = 8
USB_PAYLOAD_LBA = USB_LOADER_LBA + USB_LOADER_SECTORS
USB_FAT_LBA = 2048

run(nasm(os.path.join("src", "usb_mbr.nasm"), USB_MBR_FILE,
         defines=[f"LOADER_LBA={USB_LOADER_LBA}",
                  f"LOADER_SECTORS={USB_LOADER_SECTORS}"]),
    "Компиляция USB MBR")
run(nasm(os.path.join("src", "usb_loader.nasm"), USB_LOADER_FILE,
         defines=[f"PAYLOAD_LBA={USB_PAYLOAD_LBA}",
                  f"PAYLOAD_SECTORS={len(bios) // 512}"]),
    "Компиляция USB-загрузчика")

mbr = bytearray(read_file(USB_MBR_FILE))
if len(mbr) != 512 or mbr[0x1FE:0x200] != b"\x55\xAA":
    print("[!] USB MBR: неверный размер или сигнатура", file=sys.stderr)
    sys.exit(1)

loader = read_file(USB_LOADER_FILE)
if len(loader) > USB_LOADER_SECTORS * 512:
    print("[!] usb_loader не влезает в отведённые сектора", file=sys.stderr)
    sys.exit(1)

fat = bytearray(read_file(EFI_IMG))
if fat[54:59] != b"FAT16":
    print("[!] EFI.IMG: ожидался FAT16", file=sys.stderr)
    sys.exit(1)
# Скрытые сектора должны указывать на начало раздела - иначе часть
# прошивок/утилит считает BPB несоответствующим разделу.
struct.pack_into("<I", fat, 28, USB_FAT_LBA)

# Один активный раздел (EFI System) с FAT16 для UEFI.
# CHS посчитан для геометрии 255 головок / 63 сектора (LBA 2048..67582);
# прошивки и утилиты используют LBA, CHS нужен только старым проверкам.
struct.pack_into("<B3sB3sII", mbr, 0x1BE,
                 0x80, b"\x20\x21\x00", 0xEF, b"\x34\x2F\x04",
                 USB_FAT_LBA, EFI_IMG_SECTORS)

usb = bytearray((USB_FAT_LBA + EFI_IMG_SECTORS) * 512)
usb[0:512] = mbr
usb[USB_LOADER_LBA * 512:USB_LOADER_LBA * 512 + len(loader)] = loader
usb[USB_PAYLOAD_LBA * 512:USB_PAYLOAD_LBA * 512 + len(bios)] = bytes(bios)
usb[USB_FAT_LBA * 512:] = fat
write_file(USB_IMG, usb)
print(f"[*] USB-образ: {len(usb)} байт, payload @ LBA {USB_PAYLOAD_LBA}, "
      f"FAT16 @ LBA {USB_FAT_LBA}")

# 11. Итог
print(f"[+] Готово: {USB_IMG} ({len(usb)} байт)")
print(f"    BIOS: LBA 0 (MBR) -> payload @ LBA {USB_PAYLOAD_LBA}")
print(f"    UEFI: FAT16 @ LBA {USB_FAT_LBA}")
print(f"    запись: dd if={USB_IMG} of=/dev/sdX bs=4M  (или Rufus DD / Etcher)")
