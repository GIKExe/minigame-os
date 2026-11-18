; ===========================================================================
;  uefi_boot.nasm - UEFI-загрузчик (PE32+, x86-64).
;
;  Что делает:
;    * получает GOP (EFI_GRAPHICS_OUTPUT_PROTOCOL) и координаты framebuffer;
;    * заполняет bootinfo;
;    * выходит из Boot Services;
;    * передаёт управление встроенному 64-битному ядру.
;
;  Ядро (kernel64.bin) встроено в секцию .kernel и собирается отдельно.
;  Секция помечена executable+writable, потому что содержит и код, и стек
;  ядра. Код ядра позиционно-независимый.
;
;  Сборка:
;    nasm -f win64 -I src/ -I out/ src/uefi_boot.nasm -o out/uefi.obj
;    ld -mi386pep -e efi_main --subsystem 10 ...
; ===========================================================================
[BITS 64]
default rel

%include "bootinfo.inc"

%define EFI_SUCCESS             0
%define EFI_LOAD_ERROR          1

; EFI_SYSTEM_TABLE
%define ST_CONOUT               64
%define ST_BOOTSERVICES         96

; EFI_BOOT_SERVICES
%define BS_GETMEMORYMAP         56
%define BS_EXITBOOTSERVICES     232
%define BS_SETWATCHDOGTIMER     256
%define BS_LOCATEPROTOCOL       320

; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL
%define CONOUT_OUTPUTSTRING     8

; EFI_GRAPHICS_OUTPUT_PROTOCOL
%define GOP_MODE                24
; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE
%define GOM_INFO                8
%define GOM_FRAMEBUFFER         24
; EFI_GRAPHICS_OUTPUT_MODE_INFORMATION
%define GOMI_HORIZONTAL         4
%define GOMI_VERTICAL           8
%define GOMI_FORMAT             12
%define GOMI_PIXELSPERSCANLINE  32

section .text
global efi_main
efi_main:
    ; UEFI x64 ABI: RCX = ImageHandle, RDX = SystemTable
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r14
    push    r15
    sub     rsp, 0x180

    mov     r14, rcx                    ; ImageHandle
    mov     r15, rdx                    ; SystemTable

    ; Приветствие через ConOut (это UEFI, не BIOS)
    mov     rcx, [r15 + ST_CONOUT]
    test    rcx, rcx
    jz      .no_banner
    lea     rdx, [rel msg_boot]
    call    qword [rcx + CONOUT_OUTPUTSTRING]
.no_banner:

    ; ---- Отключить watchdog: иначе прошивка перезагрузит машину,
    ;      пока игра бесконечно опрашивает клавиатуру ----
    mov     rax, [r15 + ST_BOOTSERVICES]
    xor     ecx, ecx                    ; Timeout = 0
    xor     edx, edx                    ; WatchdogCode
    xor     r8d, r8d                    ; DataSize
    xor     r9d, r9d                    ; WatchdogData
    call    qword [rax + BS_SETWATCHDOGTIMER]

    ; ---- LocateProtocol(EFI_GRAPHICS_OUTPUT_PROTOCOL) ----
    lea     rcx, [rel gop_guid]
    xor     edx, edx
    lea     r8, [rel gop_ptr]
    mov     rax, [r15 + ST_BOOTSERVICES]
    call    qword [rax + BS_LOCATEPROTOCOL]
    test    rax, rax
    jnz     .no_gop

    mov     rbx, [rel gop_ptr]
    test    rbx, rbx
    jz      .no_gop

    mov     rsi, [rbx + GOP_MODE]       ; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *
    test    rsi, rsi
    jz      .no_gop
    mov     rdi, [rsi + GOM_INFO]       ; EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *
    test    rdi, rdi
    jz      .no_gop

    mov     eax, [rdi + GOMI_HORIZONTAL]
    mov     [rel boot_info + BI_WIDTH], eax
    mov     eax, [rdi + GOMI_VERTICAL]
    mov     [rel boot_info + BI_HEIGHT], eax
    mov     eax, [rdi + GOMI_FORMAT]
    mov     [rel boot_info + BI_FORMAT], eax

    mov     eax, [rdi + GOMI_PIXELSPERSCANLINE]
    test    eax, eax
    jnz     .pitch_ok
    mov     eax, [rdi + GOMI_HORIZONTAL]
.pitch_ok:
    shl     eax, 2                      ; 32 bpp
    mov     [rel boot_info + BI_PITCH], eax

    mov     rax, [rsi + GOM_FRAMEBUFFER]
    test    rax, rax
    jz      .no_gop
    mov     [rel boot_info + BI_FB_BASE], rax

    ; Нам нужен хотя бы режим 640x400 и формат RGBX/BGRX.
    cmp     dword [rel boot_info + BI_WIDTH], 640
    jb      .no_gop
    cmp     dword [rel boot_info + BI_HEIGHT], 400
    jb      .no_gop
    cmp     dword [rel boot_info + BI_FORMAT], 1
    ja      .no_gop

    mov     dword [rel boot_info + BI_MODE], 1
    mov     dword [rel boot_info + BI_BPP], 32
    jmp     .gop_done

.no_gop:
    ; Fallback: VGA text (не все UEFI-системы его показывают, но GOP
    ; есть практически везде; этот путь нужен для совместимости).
    mov     dword [rel boot_info + BI_MODE], 0
    mov     dword [rel boot_info + BI_WIDTH], 80
    mov     dword [rel boot_info + BI_HEIGHT], 25
    mov     dword [rel boot_info + BI_PITCH], 160
    mov     dword [rel boot_info + BI_BPP], 16
    mov     dword [rel boot_info + BI_FORMAT], 0
    mov     qword [rel boot_info + BI_FB_BASE], 0

.gop_done:
    mov     dword [rel boot_info + BI_MAGIC], BOOTINFO_MAGIC

    ; ---- Выход из Boot Services ----
    mov     dword [rel retry_count], 8
.retry:
    mov     qword [rel map_size], 128 * 1024
    lea     rax, [rel desc_ver]
    mov     [rsp + 32], rax
    lea     rcx, [rel map_size]
    lea     rdx, [rel map_buf]
    lea     r8, [rel map_key]
    lea     r9, [rel desc_size]
    mov     rax, [r15 + ST_BOOTSERVICES]
    call    qword [rax + BS_GETMEMORYMAP]
    test    rax, rax
    jnz     .exit_failed

    mov     rcx, r14
    mov     rdx, [rel map_key]
    mov     rax, [r15 + ST_BOOTSERVICES]
    call    qword [rax + BS_EXITBOOTSERVICES]
    test    rax, rax
    jz      .exited

    ; Карта памяти изменилась - повторяем.
    dec     dword [rel retry_count]
    jnz     .retry

.exit_failed:
    mov     eax, EFI_LOAD_ERROR
    lea     rsp, [rbp - 48]
    pop     r15
    pop     r14
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

.exited:
    cli
    lea     rdi, [rel boot_info]
    lea     rax, [rel kernel_image_start]
    jmp     rax

; ---------------------------------------------------------------------------
; Данные
; ---------------------------------------------------------------------------
section .data
align 8
gop_guid:
    dd      0x9042A9DE
    dw      0x23DC
    dw      0x4A38
    db      0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A

gop_ptr:        dq 0
retry_count:    dd 0
map_size:       dq 0
map_key:        dq 0
desc_size:      dq 0
desc_ver:       dd 0

align 8
boot_info:
    dd      BOOTINFO_MAGIC
    dd      0
    dq      0
    dd      80
    dd      25
    dd      160
    dd      16
    dd      0
    dd      1                           ; firmware: 1 = UEFI

; Фиктивная абсолютная ссылка: заставляет линкер создать .reloc,
; чтобы UEFI мог загрузить образ по любому адресу.
force_reloc:
    dq      efi_main

msg_boot:
    dw      'M','i','n','i','G','a','m','e',' ','O','S',' ','U','E','F','I',13,10,0

section .bss
align 16
map_buf:
    resb    128 * 1024

; ---------------------------------------------------------------------------
; Встроенное 64-битное ядро.
; Секция RWX: ядро использует её и как код, и как данные/стек.
; ---------------------------------------------------------------------------
section .kernel progbits alloc exec write align=16
global kernel_image_start
kernel_image_start:
    incbin "kernel64.bin"
kernel_image_end:
