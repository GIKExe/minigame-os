; ===========================================================================
;  kernel32.nasm - основная игра для protected mode (i386+).
;
;  Используется BIOS-загрузчиком, если процессор не поддерживает long mode.
;  BIOS-прерывания не используются: вывод идёт напрямую в VGA text 0xB8000,
;  ввод - через контроллер PS/2 (порты 0x60/0x64).
;
;  KERNEL_BASE задаётся при сборке и равен физическому адресу, по которому
;  загрузчик размещает этот бинарник.
;
;  Вход: ESI = указатель на bootinfo (см. bootinfo.inc).
; ===========================================================================
%ifndef KERNEL_BASE
%define KERNEL_BASE 0
%endif

[BITS 32]
[ORG KERNEL_BASE]

%define MAP_WIDTH   80
%define MAP_HEIGHT  24

%include "bootinfo.inc"

global _start
_start:
    cli
    cld
    ; В protected mode нулевой селектор в SS (и в DS, через который идёт
    ; вся адресация данных) вызывает #GP. GDT загрузчика: 0x10 = data.
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax

    mov     esp, stack_top

    mov     [bi_ptr], esi
    cmp     dword [esi + BI_MAGIC], BOOTINFO_MAGIC
    jne     halt

    mov     eax, [esi + BI_MODE]
    mov     [video_mode], eax

    call    init_keyboard
    call    clear_screen
    call    draw_map
    call    draw_player
    call    draw_status

.main:
    call    move_player
    jmp     .main

; ---------------------------------------------------------------------------
; clear_screen - очистить VGA text
; ---------------------------------------------------------------------------
clear_screen:
    ; спрятать аппаратный курсор VGA (без BIOS)
    mov     dx, 0x3D4
    mov     al, 0x0A
    out     dx, al
    inc     dx
    mov     al, 0x20
    out     dx, al

    mov     edi, 0xB8000
    mov     eax, 0x0720
    mov     ecx, MAP_WIDTH * (MAP_HEIGHT + 1)
    rep     stosw
    ret

; ---------------------------------------------------------------------------
; draw_char
;   EAX = x, EBX = y, ECX = символ, EDX = цвет
; ---------------------------------------------------------------------------
draw_char:
    mov     [cur_x], eax
    mov     [cur_y], ebx
    mov     [cur_ch], ecx
    mov     [cur_color], edx

    mov     edi, 0xB8000
    mov     eax, ebx
    imul    eax, MAP_WIDTH
    add     eax, [cur_x]
    shl     eax, 1
    add     edi, eax

    mov     eax, [cur_ch]
    mov     [edi], al
    mov     eax, [cur_color]
    mov     [edi + 1], al
    ret

; ---------------------------------------------------------------------------
; draw_map
; ---------------------------------------------------------------------------
draw_map:
    mov     dword [map_y], 0
.row:
    mov     dword [map_x], 0
.col:
    mov     eax, [map_y]
    imul    eax, MAP_WIDTH
    add     eax, [map_x]
    mov     esi, map_data
    movzx   ecx, byte [esi + eax]

    mov     eax, [map_x]
    mov     ebx, [map_y]
    mov     edx, 0x07
    call    draw_char

    inc     dword [map_x]
    cmp     dword [map_x], MAP_WIDTH
    jb      .col

    inc     dword [map_y]
    cmp     dword [map_y], MAP_HEIGHT
    jb      .row
    ret

; ---------------------------------------------------------------------------
; draw_player / clear_cell
; ---------------------------------------------------------------------------
draw_player:
    mov     eax, [player_x]
    mov     ebx, [player_y]
    mov     ecx, 'P'
    movzx   edx, byte [player_color]
    call    draw_char
    ret

clear_cell:
    mov     eax, [player_x]
    mov     ebx, [player_y]
    mov     ecx, ' '
    mov     edx, 0x07
    call    draw_char
    ret

; ---------------------------------------------------------------------------
; draw_status - строка "Loader: BIOS  Arch: x32" в последней строке экрана
; ---------------------------------------------------------------------------
draw_status:
    push    ebp
    push    esi
    mov     esi, status_text
    xor     ebp, ebp                    ; столбец
.loop:
    movzx   ecx, byte [esi]
    test    ecx, ecx
    jz      .done
    mov     eax, ebp
    mov     ebx, MAP_HEIGHT             ; последняя строка (25-я)
    mov     edx, 0x0F
    call    draw_char
    inc     esi
    inc     ebp
    cmp     ebp, MAP_WIDTH
    jb      .loop
.done:
    pop     esi
    pop     ebp
    ret

; ---------------------------------------------------------------------------
; move_player
; ---------------------------------------------------------------------------
move_player:
    call    poll_key
    test    al, al
    jz      .ret

    cmp     al, 0x11
    je      .up
    cmp     al, 0x1E
    je      .left
    cmp     al, 0x1F
    je      .down
    cmp     al, 0x20
    je      .right

.ret:
    ret

.up:
    mov     eax, [player_x]
    mov     [new_x], eax
    mov     eax, [player_y]
    dec     eax
    mov     [new_y], eax
    jmp     .check

.left:
    mov     eax, [player_x]
    dec     eax
    mov     [new_x], eax
    mov     eax, [player_y]
    mov     [new_y], eax
    jmp     .check

.down:
    mov     eax, [player_x]
    mov     [new_x], eax
    mov     eax, [player_y]
    inc     eax
    mov     [new_y], eax
    jmp     .check

.right:
    mov     eax, [player_x]
    inc     eax
    mov     [new_x], eax
    mov     eax, [player_y]
    mov     [new_y], eax

.check:
    cmp     dword [new_x], 0
    jl      .ret
    cmp     dword [new_x], MAP_WIDTH - 1
    jg      .ret
    cmp     dword [new_y], 0
    jl      .ret
    cmp     dword [new_y], MAP_HEIGHT - 1
    jg      .ret

    mov     eax, [new_y]
    imul    eax, MAP_WIDTH
    add     eax, [new_x]
    mov     esi, map_data
    movzx   eax, byte [esi + eax]

    cmp     al, '#'
    je      .ret

    cmp     al, 'R'
    jne     .n1
    mov     byte [player_color], 0x0C
.n1:
    cmp     al, 'G'
    jne     .n2
    mov     byte [player_color], 0x0A
.n2:
    cmp     al, 'B'
    jne     .n3
    mov     byte [player_color], 0x0B
.n3:
    call    clear_cell
    mov     eax, [new_x]
    mov     [player_x], eax
    mov     eax, [new_y]
    mov     [player_y], eax
    call    draw_player
    ret

; ---------------------------------------------------------------------------
; poll_key
; ---------------------------------------------------------------------------
poll_key:
    mov     dx, 0x64
    in      al, dx
    test    al, 1
    jz      .none
    test    al, 0x20
    jnz     .flush

    mov     dx, 0x60
    in      al, dx
    cmp     al, 0xE0
    je      .none
    cmp     al, 0xE1
    je      .none
    test    al, 0x80
    jnz     .none
    ret

.flush:
    mov     dx, 0x60
    in      al, dx
.none:
    xor     al, al
    ret

; ---------------------------------------------------------------------------
; init_keyboard
; ---------------------------------------------------------------------------
init_keyboard:
    push    ebx

    mov     dx, 0x64
    in      al, dx
    test    al, 1
    jz      .no_flush
    mov     dx, 0x60
    in      al, dx
.no_flush:

    call    kbd_wait_write
    mov     al, 0x20
    out     0x64, al

    call    kbd_wait_read
    in      al, 0x60
    mov     bl, al
    or      bl, 0x40

    call    kbd_wait_write
    mov     al, 0x60
    out     0x64, al
    call    kbd_wait_write
    mov     al, bl
    out     0x60, al

    call    kbd_wait_write
    mov     al, 0xAE
    out     0x64, al

    pop     ebx
    ret

kbd_wait_write:
    mov     ecx, 0xFFFF
.loop:
    in      al, 0x64
    test    al, 2
    jz      .ok
    dec     ecx
    jnz     .loop
.ok:
    ret

kbd_wait_read:
    mov     ecx, 0xFFFF
.loop:
    in      al, 0x64
    test    al, 1
    jnz     .ok
    dec     ecx
    jnz     .loop
.ok:
    ret

; ---------------------------------------------------------------------------
halt:
    cli
.loop:
    hlt
    jmp     .loop

; ---------------------------------------------------------------------------
; Данные
; ---------------------------------------------------------------------------
%include "game_data.inc"

align 4
bi_ptr:         dd 0
video_mode:     dd 0
cur_x:          dd 0
cur_y:          dd 0
cur_ch:         dd 0
cur_color:      dd 0
player_x:       dd 2
player_y:       dd 2
player_color:   db 0x0E
new_x:          dd 0
new_y:          dd 0
map_x:          dd 0
map_y:          dd 0

status_text:    db "Loader: BIOS   Arch: x32", 0

align 16
stack_bottom:
    times 16384 db 0
stack_top:
