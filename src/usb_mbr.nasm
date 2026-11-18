; ===========================================================================
;  usb_mbr.nasm - MBR для USB-образа MiniGame OS.
;
;  BIOS загружает этот сектор в 0x7C00 как обычный MBR винчестера.
;  Задача сектора - прочитать второй этап (usb_loader) по фиксированному
;  LBA и передать ему управление. Второй этап загружается в 0x6000,
;  поэтому он не перетирается, когда bios.img читается в 0x7C00.
;
;  Таблица разделов заполняется в build.py (один активный FAT16-раздел
;  с EFI/BOOT/BOOTX64.EFI для UEFI).
; ===========================================================================
[BITS 16]
[ORG 0x7C00]

%ifndef LOADER_LBA
%define LOADER_LBA 1
%endif
%ifndef LOADER_SECTORS
%define LOADER_SECTORS 8
%endif
%define LOADER_SEG 0x0600               ; linear 0x6000

start:
    cli
    cld
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00
    sti

    mov     [boot_drive], dl

    mov     si, dap
    mov     dl, [boot_drive]
    mov     ah, 0x42
    int     0x13
    jnc     .ok

    ; одна повторная попытка после сброса диска
    xor     ah, ah
    mov     dl, [boot_drive]
    int     0x13
    mov     si, dap
    mov     dl, [boot_drive]
    mov     ah, 0x42
    int     0x13
    jc      .fail

.ok:
    mov     dl, [boot_drive]
    jmp     LOADER_SEG:0x0000

.fail:
    mov     si, msg_fail
.print:
    lodsb
    test    al, al
    jz      .hang
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    jmp     .print
.hang:
    cli
    hlt
    jmp     .hang

boot_drive: db 0

align 4
dap:
    db      0x10                        ; размер DAP
    db      0
    dw      LOADER_SECTORS
    dw      0x0000                      ; offset
    dw      LOADER_SEG                  ; segment
    dq      LOADER_LBA

msg_fail: db "USB boot error", 13, 10, 0

; ---------------------------------------------------------------------------
; Таблица разделов и сигнатура. Сами записи пишет build.py.
; ---------------------------------------------------------------------------
    times   0x1BE - ($ - $$) db 0
    times   0x1FE - ($ - $$) db 0
    dw      0xAA55
