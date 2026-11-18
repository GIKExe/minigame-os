; ===========================================================================
;  usb_loader.nasm - второй этап USB-загрузчика (загружается в 0x6000).
;
;  Читает bios.img (stage1 + kernel32 + kernel64) в 0x7C00 и передаёт
;  управление stage1. Чтение идёт через INT 13h AH=42h блоками не больше
;  32 секторов: так передача никогда не пересекает границу 64 КиБ.
;
;  PAYLOAD_LBA/PAYLOAD_SECTORS задаются в build.py.
; ===========================================================================
[BITS 16]
[ORG 0x6000]

%ifndef PAYLOAD_LBA
%define PAYLOAD_LBA 9
%endif
%ifndef PAYLOAD_SECTORS
%define PAYLOAD_SECTORS 108
%endif

%define PAYLOAD_SEG     0x07C0           ; linear 0x7C00
%define CHUNK_SECTORS   32               ; 32 * 512 = 16 КиБ

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
    mov     word [remaining], PAYLOAD_SECTORS
    mov     dword [dap_lba], PAYLOAD_LBA
    mov     word [dap_seg], PAYLOAD_SEG

.next:
    mov     ax, [remaining]
    test    ax, ax
    jz      .jump
    cmp     ax, CHUNK_SECTORS
    jbe     .size_ok
    mov     ax, CHUNK_SECTORS
.size_ok:
    mov     [dap_count], ax

    mov     cx, 3
.attempt:
    push    cx
    mov     si, dap
    mov     dl, [boot_drive]
    mov     ah, 0x42
    int     0x13
    pop     cx
    jnc     .ok

    xor     ah, ah
    mov     dl, [boot_drive]
    int     0x13                        ; сброс диска
    loop    .attempt
    jmp     .fail

.ok:
    movzx   eax, word [dap_count]
    sub     word [remaining], ax
    add     dword [dap_lba], eax

    mov     bx, ax
    shl     bx, 5                       ; сектор = 32 параграфа
    add     [dap_seg], bx
    jmp     .next

.jump:
    mov     dl, [boot_drive]
    jmp     0x0000:0x7C00

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
remaining:  dw 0

align 4
dap:
    db      0x10
    db      0
dap_count:
    dw      0
    dw      0
dap_seg:
    dw      0
dap_lba:
    dq      0

msg_fail: db "USB read error", 13, 10, 0
