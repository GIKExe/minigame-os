# 🎮 MiniGame OS

> Мини-игра на NASM с собственными загрузчиками для BIOS и UEFI.
> Работает без установленной ОС: загрузчик переводит процессор в protected
> mode (x32) или long mode (x64), после чего игра напрямую управляет
> видеоадаптером и клавиатурой.

## 📖 Что изменилось

Раньше проект использовал загрузчик KolibriOS, дискету FAT12 и BIOS-прерывания
(`int 10h`, `int 16h`, `int 13h`) прямо в игровом коде. Теперь:

- добавлен **собственный BIOS-загрузчик** с проверкой CPUID и переходом в
  protected mode (x32) или long mode (x64);
- добавлен **UEFI-загрузчик** (PE32+, x86-64);
- игровой код **не вызывает BIOS-прерывания**: вывод идёт напрямую в VGA text
  `0xB8000` или в GOP framebuffer, ввод — через контроллер PS/2;
- вместо дискеты собирается **USB-образ**: MBR-загрузчик для BIOS и
  FAT16-раздел с `EFI/BOOT/BOOTX64.EFI` для UEFI;
- UEFI-загрузочный раздел — **FAT16** (`EFI/BOOT/BOOTX64.EFI`).

## ✨ Возможности

- 🚀 Два независимых пути загрузки: legacy BIOS (MBR) и UEFI.
- 🧠 Автовыбор разрядности: x86-64, если CPU поддерживает long mode, иначе i386.
- 🖥️ Два режима вывода: VGA text для BIOS и линейный framebuffer (GOP) для UEFI.
- 💾 Один USB-образ `out/usb.img` для обоих вариантов.
- 🧩 Сборка полностью локальная: NASM + mtools + binutils + Python 3.
- 🚫 Для сборки и проверки не используются QEMU и другие отладчики
  исполняемого кода.

## 🛠️ Требования

- **Windows** с Python 3;
- **WSL** (или Linux) с пакетами:

```bash
sudo apt update
sudo apt install nasm mtools binutils
```

`binutils` нужен для `ld` (линковка PE32+ для UEFI).

## ⚙️ Сборка

```bash
python build.py
```

Результат:

| Файл | Назначение |
|------|------------|
| `out/kernel32.bin` | игра для i386 protected mode |
| `out/kernel64.bin` | игра для x86-64 long mode (позиционно-независимая) |
| `out/bios.img` | BIOS payload: stage1 + kernel32 + kernel64 |
| `out/BOOTX64.EFI` | UEFI-загрузчик PE32+ со встроенным kernel64 |
| `out/efi.img` | FAT16-образ с `EFI/BOOT/BOOTX64.EFI` |
| `out/usb.img` | **итоговый образ для USB-флешки** (BIOS + UEFI) |

### 🔍 Проверка без эмулятора

```bash
python tools/verify_usb.py out/usb.img
```

Скрипт проверяет MBR и таблицу разделов, положение `usb_loader` и `bios.img`,
BPB FAT16, скрытые сектора, FAT[0]/FAT[1] и файлы раздела (сверка с `out/`).
Содержимое FAT-раздела можно посмотреть через mtools:

```bash
mdir -i out/usb.img@@1048576 ::/EFI/BOOT
```

## 💾 Загрузка с USB-флешки

`out/usb.img` — обычный MBR-образ:

| LBA | Содержимое |
|-----|------------|
| 0 | MBR: читает второй этап и передаёт управление |
| 1..8 | второй этап (`usb_loader`), грузится в `0x6000` |
| 9..116 | `bios.img` (stage1 + kernel32 + kernel64), грузится в `0x7C00` |
| 2048.. | FAT16-раздел с `EFI/BOOT/BOOTX64.EFI` для UEFI |

Запись — **побайтово (DD-режим)**, без разметки и форматирования:

* balenaEtcher или Win32DiskImager — просто выбрать `out/usb.img`;
* `dd if=out/usb.img of=/dev/sdX bs=4M status=progress` (Linux/macOS);
* Rufus → выбрать `usb.img` → подтвердить **DD-режим** (если Rufus
  предложит выбор ISO/DD). ISO-режим здесь не подходит.

Один и тот же файл грузится и в legacy BIOS (через MBR), и в UEFI (прошивка
монтирует FAT16-раздел и запускает `\EFI\BOOT\BOOTX64.EFI`).

> **Secure Boot** должен быть выключен: EFI-приложение не подписано.

## 🎮 Управление

| Клавиша | Действие |
|:-------:|:--------:|
| **W** | Движение вверх |
| **A** | Движение влево |
| **S** | Движение вниз |
| **D** | Движение вправо |

Последняя строка экрана — статус: **загрузчик** (BIOS или UEFI) и
**разрядность** (x32 или x64). Карта занимает 24 строки, 25-я отведена под неё.

## 🧱 Структура проекта

```
src/
  bios_boot.nasm    BIOS stage1: CPUID, A20, GDT, protected/long mode
  usb_mbr.nasm      MBR для USB-образа: загружает второй этап
  usb_loader.nasm   второй этап USB: читает bios.img в 0x7C00
  kernel32.nasm     игра x32: VGA text + PS/2
  kernel64.nasm     игра x64: VGA text / GOP framebuffer + PS/2
  uefi_boot.nasm    UEFI PE32+ загрузчик
  bootinfo.inc      структура bootinfo, общая для загрузчиков и ядер
  game_data.inc     карта и шрифт 8x16
  font8x16.bin      шрифт ASCII 32..126
tools/
  verify_usb.py     статическая проверка USB-образа
  verify_iso.py     проверки FAT-тома (общий модуль для verify_usb)
  mkiso.py          генератор ISO9660 + El Torito (сейчас не используется)
build.py            сборка всего
```

## ⚠️ Ограничения

- Ввод рассчитан на **PS/2-клавиатуру** (порты `0x60/0x64`). USB HID-драйвера
  нет; на некоторых UEFI-системах без PS/2 клавиатура может не работать.
- UEFI-загрузчик использует GOP. Если GOP недоступен, включается резервный
  режим VGA text, который поддерживается не всеми UEFI-прошивками.
- FAT16-раздел для UEFI имеет размер ~32 МиБ (65535 секторов по 512 байт,
  64994 кластера). FAT32 требует не менее 65525 кластеров, поэтому используется
  FAT16 — корректный том для EDK2 FatPkg, Windows и Linux.
- Игра не использует BIOS/UEFI после передачи управления ядру.

## 🤝 Вклад в проект

Если вы хотите улучшить проект, найти баги или предложить новую
функциональность, создавайте
[Issues](https://github.com/GIKExe/minigame-os/issues) или отправляйте
[Pull Requests](https://github.com/GIKExe/minigame-os/pulls)!

---

<p align="center">Сделано с ❤️ и NASM</p>
