#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Запускать из обычного Python под Windows.
# В используемом дистрибутиве WSL должны быть установлены:
#   sudo apt install nasm mtools

import os
import sys
import subprocess

# ----------------------------
# Настройки
# ----------------------------

OUT_DIR = "out"

BOOTLOADER_FILE = os.path.join(OUT_DIR, "bootloader.bin")
KERNEL_FILE = os.path.join(OUT_DIR, "KERNEL.BIN")

NASM_SRC = os.path.join("src", "bootloader.nasm")
KERNEL_SRC = os.path.join("src", "kernel.nasm")

IMAGE_NAME = "floppy.img"
IMAGE_SIZE = 1440 * 1024  # 1.44 МБ

VOLUME_LABEL = "MYOS_DISK"

# ----------------------------
# Функции
# ----------------------------

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

# ----------------------------
# Сборка
# ----------------------------

os.makedirs(OUT_DIR, exist_ok=True)

# 1. Компиляция загрузчика через WSL nasm
run(
	[
		"wsl",
		"nasm",
		"-f", "bin",
		wsl_path(NASM_SRC),
		"-o", wsl_path(BOOTLOADER_FILE),
	],
	"Компиляция bootloader"
)

# 2. Компиляция ядра через WSL nasm
run(
	[
		"wsl",
		"nasm",
		"-f", "bin",
		wsl_path(KERNEL_SRC),
		"-o", wsl_path(KERNEL_FILE),
	],
	"Компиляция kernel"
)

# 3. Создание пустого образа
with open(IMAGE_NAME, "wb") as f:
	f.write(b"\x00" * IMAGE_SIZE)

# 4. Форматирование образа в FAT12 через WSL mtools
run(
	[
		"wsl",
		"mformat",
		"-i", wsl_path(IMAGE_NAME),
		"-f", "1440",
		"-v", VOLUME_LABEL,
	],
	"Форматирование FAT12"
)

# 5. Запись загрузчика в сектор 0
with open(BOOTLOADER_FILE, "rb") as f:
	boot_code = f.read()

boot_code = boot_code[:512].ljust(512, b"\x00")

with open(IMAGE_NAME, "r+b") as img:
	img.seek(0)
	img.write(boot_code)

print("[*] Запись загрузчика в сектор 0...")

# 6. Копирование ядра на образ через WSL mtools
run(
	[
		"wsl",
		"mcopy",
		"-i", wsl_path(IMAGE_NAME),
		wsl_path(KERNEL_FILE),
		"::/",
	],
	"Копирование ядра"
)

print(f"[+] Готово: {IMAGE_NAME}")