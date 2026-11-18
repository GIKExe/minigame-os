; ===========================================================================
;  bios_boot.nasm - BIOS-загрузчик (El Torito, no emulation).
;
;  Загружается BIOS'ом по адресу 0x7C00. Код ядер уже находится в
;  загрузочном образе сразу после первого сектора, поэтому после старта
;  НИ ОДНО НЕ вызывается BIOS-прерывание: нет int 10h/13h/16h.
;
;  Задача:
;    * проверить CPUID и поддержку long mode;
;    * выбрать 64-битное (long mode) или 32-битное (protected mode) ядро;
;    * включить A20, загрузить GDT, при необходимости построить page tables;
;    * передать ядру указатель на bootinfo (ESI для 32, RDI для 64).
;
;  Адреса ядер передаются при сборке через -DK32_ADDR/-DK64_ADDR.
; ===========================================================================
[BITS 16]
[ORG 0x7C00]

%include "bootinfo.inc"

%ifndef K32_ADDR
%define K32_ADDR 0x9C00
%endif
%ifndef K64_ADDR
%define K64_ADDR 0x19C00
%endif

; ---------------------------------------------------------------------------
; Первый сектор: переход на stage2 + сигнатура загрузочного сектора.
; ---------------------------------------------------------------------------
start:
    jmp     stage2

    times   0x1FE - ($ - $$) db 0
    dw      0xAA55

; ---------------------------------------------------------------------------
; stage2
; ---------------------------------------------------------------------------
stage2:
    cli
    cld
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00

    ; ---- A20 (fast gate) ----
    in      al, 0x92
    or      al, 0x02
    and     al, 0xFE
    out     0x92, al

    ; ---- Есть ли CPUID? ----
    pushfd
    pop     eax
    mov     ecx, eax
    xor     eax, 0x00200000
    push    eax
    popfd
    pushfd
    pop     eax
    xor     eax, ecx
    and     eax, 0x00200000
    jz      .use32

    ; ---- CPUID.0: максимальный базовый лист ----
    xor     eax, eax
    cpuid
    cmp     eax, 1
    jb      .use32

    ; ---- CPUID.1: PAE обязателен для long mode ----
    mov     eax, 1
    cpuid
    test    edx, 1 << 6
    jz      .use32

    ; ---- CPUID.80000000h: максимальный расширенный лист ----
    mov     eax, 0x80000000
    cpuid
    cmp     eax, 0x80000001
    jb      .use32

    ; ---- CPUID.80000001h:EDX.LM[29] ----
    mov     eax, 0x80000001
    cpuid
    test    edx, 1 << 29
    jz      .use32

    jmp     .use64

; ---------------------------------------------------------------------------
; 32-битный protected mode
; ---------------------------------------------------------------------------
.use32:
    cli
    lgdt    [gdt_ptr]

    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax

    jmp     dword 0x08:pm32_entry

; ---------------------------------------------------------------------------
; long mode + 64-битное ядро
; ---------------------------------------------------------------------------
.use64:
    cli
    call    setup_paging
    lgdt    [gdt_ptr]

    ; CR4.PAE
    mov     eax, cr4
    or      eax, 1 << 5
    mov     cr4, eax

    ; EFER.LME
    mov     ecx, 0xC0000080
    rdmsr
    or      eax, 1 << 8
    wrmsr

    ; CR3 = PML4
    mov     eax, 0x70000
    mov     cr3, eax

    ; CR0.PG | CR0.PE
    mov     eax, cr0
    or      eax, 0x80000001
    mov     cr0, eax

    jmp     dword 0x18:lm64_entry

; ---------------------------------------------------------------------------
; setup_paging - identity map первых 1 GiB через 2-MiB страницы.
;   PML4 @ 0x70000, PDPT @ 0x71000, PD @ 0x72000
; ---------------------------------------------------------------------------
setup_paging:
    pushad

    mov     edi, 0x70000
    xor     eax, eax
    mov     ecx, 0x3000 / 4
    a32 rep stosd                       ; EDI, а не DI: иначе чистится 0x0000

    ; PML4[0] -> PDPT
    mov     edi, 0x70000
    mov     eax, 0x71003
    mov     [edi], eax
    mov     dword [edi + 4], 0

    ; PDPT[0] -> PD
    mov     edi, 0x71000
    mov     eax, 0x72003
    mov     [edi], eax
    mov     dword [edi + 4], 0

    ; PD[0..511] = 2 MiB pages, present + writable + huge
    mov     edi, 0x72000
    mov     eax, 0x83
    mov     ecx, 512
.pd_loop:
    mov     dword [edi], eax
    mov     dword [edi + 4], 0
    add     edi, 8
    add     eax, 0x200000
    dec     ecx
    jnz     .pd_loop

    popad
    ret

; ---------------------------------------------------------------------------
; 32-битная точка входа после far jump
; ---------------------------------------------------------------------------
[BITS 32]
pm32_entry:
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, 0x7C00

    mov     esi, boot_info
    jmp     K32_ADDR

; ---------------------------------------------------------------------------
; 64-битная точка входа после far jump
; ---------------------------------------------------------------------------
[BITS 64]
lm64_entry:
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     rsp, 0x7C00

    mov     rdi, boot_info
    mov     rax, K64_ADDR
    jmp     rax

; ---------------------------------------------------------------------------
; GDT
; ---------------------------------------------------------------------------
align 8
gdt_start:
    dq      0
gdt_code32:
    dq      0x00CF9A000000FFFF          ; base=0, limit=4G, code32, DPL0
gdt_data:
    dq      0x00CF92000000FFFF          ; base=0, limit=4G, data, DPL0
gdt_code64:
    dq      0x00AF9A000000FFFF          ; long mode code
gdt_end:

gdt_ptr:
    dw      gdt_end - gdt_start - 1
    dd      gdt_start

; ---------------------------------------------------------------------------
; bootinfo для ядра (режим VGA text)
; ---------------------------------------------------------------------------
align 8
boot_info:
    dd      BOOTINFO_MAGIC
    dd      0                           ; mode = VGA text
    dq      0                           ; framebuffer base
    dd      80                          ; width
    dd      25                          ; height
    dd      160                         ; pitch (80*2)
    dd      16                          ; bpp (text attribute)
    dd      0                           ; format
    dd      0                           ; firmware: 0 = BIOS
