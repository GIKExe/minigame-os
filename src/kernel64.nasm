; ===========================================================================
;  kernel64.nasm - основная игра для long mode (x86-64).
;
;  Загружается BIOS-загрузчиком в низкую память либо встраивается в
;  UEFI-загрузчик. Код позиционно-независимый: все обращения к данным
;  идут через RIP-relative адресацию.
;
;  BIOS-прерывания не используются вообще:
;    * вывод  - VGA text 0xB8000 или GOP framebuffer;
;    * ввод   - контроллер PS/2 (порты 0x60/0x64).
;
;  Вход: RDI = указатель на bootinfo (см. bootinfo.inc).
; ===========================================================================
[BITS 64]
[ORG 0]
default rel

%define MAP_WIDTH   80
%define MAP_HEIGHT  24
%define FONT_WIDTH  8
%define FONT_HEIGHT 16

%include "bootinfo.inc"

global _start
_start:
    cli
    cld
    ; В long mode DS/ES/SS для адресации не используются, но SS всё равно
    ; должен содержать валидный селектор: BIOS-загрузчик и прошивка UEFI
    ; уже оставили корректные селекторы. Грузить сюда 0 нельзя - это #GP.
    ; Поэтому сегментные регистры не трогаем.

    lea     rsp, [rel stack_top]
    and     rsp, -16

    mov     [rel bi_ptr], rdi
    mov     rsi, rdi

    cmp     dword [rsi + BI_MAGIC], BOOTINFO_MAGIC
    jne     halt

    mov     eax, [rsi + BI_FIRMWARE]
    mov     [rel firmware], eax

    mov     eax, [rsi + BI_MODE]
    mov     [rel video_mode], eax
    cmp     eax, 1
    jne     .no_fb

    mov     rax, [rsi + BI_FB_BASE]
    mov     [rel fb_base], rax
    mov     eax, [rsi + BI_WIDTH]
    mov     [rel fb_width], eax
    mov     eax, [rsi + BI_HEIGHT]
    mov     [rel fb_height], eax
    mov     eax, [rsi + BI_PITCH]
    mov     [rel fb_pitch], eax
    mov     eax, [rsi + BI_BPP]
    mov     [rel fb_bpp], eax
    mov     eax, [rsi + BI_FORMAT]
    mov     [rel fb_format], eax
    call    compute_origin

.no_fb:
    call    init_keyboard
    call    clear_screen
    call    draw_map
    call    draw_player
    call    draw_status

.main:
    call    move_player
    jmp     .main

; ---------------------------------------------------------------------------
; game_x0/game_y0 - положение игрового поля 640x400 по центру экрана.
; ---------------------------------------------------------------------------
compute_origin:
    mov     eax, [rel fb_width]
    sub     eax, MAP_WIDTH * FONT_WIDTH
    jns     .x_ok
    xor     eax, eax
.x_ok:
    shr     eax, 1
    mov     [rel game_x0], eax

    mov     eax, [rel fb_height]
    sub     eax, (MAP_HEIGHT + 1) * FONT_HEIGHT
    jns     .y_ok
    xor     eax, eax
.y_ok:
    shr     eax, 1
    mov     [rel game_y0], eax
    ret

; ---------------------------------------------------------------------------
; clear_screen
; ---------------------------------------------------------------------------
clear_screen:
    cmp     dword [rel video_mode], 0
    jne     .fb

    ; спрятать аппаратный курсор VGA (без BIOS)
    mov     dx, 0x3D4
    mov     al, 0x0A
    out     dx, al
    inc     dx
    mov     al, 0x20
    out     dx, al

    mov     rdi, 0xB8000
    mov     eax, 0x0720                 ; пробел, серый на чёрном
    mov     ecx, MAP_WIDTH * (MAP_HEIGHT + 1)
    rep     stosw
    ret

.fb:
    mov     rdi, [rel fb_base]
    mov     eax, [rel fb_pitch]
    imul    eax, [rel fb_height]
    test    eax, eax
    jz      .done
    mov     ecx, eax
    xor     eax, eax
    rep     stosb
.done:
    ret

; ---------------------------------------------------------------------------
; draw_char
;   EAX = x (столбец 0..79)
;   EBX = y (строка 0..24)
;   ECX = символ
;   EDX = цвет EGA (0..15)
; ---------------------------------------------------------------------------
draw_char:
    push    rbx
    push    rsi
    push    rdi
    push    rbp
    push    r12
    push    r13

    mov     r12d, eax                   ; x
    mov     r13d, ebx                   ; y
    mov     ebp, ecx                    ; символ
    mov     [rel cur_color], edx

    mov     eax, edx
    and     eax, 15
    lea     rsi, [rel ega_palette]
    mov     ebx, [rsi + rax * 4]        ; 0x00RRGGBB

    ; В памяти пиксель хранится как младший байт первым. EGA-палитра задана
    ; в порядке 0x00RRGGBB, т.е. байты B,G,R - это формат GOP 1
    ; (PixelBlueGreenRed). Для формата 0 (PixelRedGreenBlue) нужен 0x00BBGGRR.
    cmp     dword [rel video_mode], 0
    je      .color_ok
    cmp     dword [rel fb_format], 0
    jne     .color_ok
    bswap   ebx
    shr     ebx, 8
.color_ok:

    cmp     ebp, 32
    jae     .ch_ok
    mov     ebp, 32
.ch_ok:
    cmp     ebp, 126
    jbe     .ch_done
    mov     ebp, '?'
.ch_done:

    cmp     dword [rel video_mode], 0
    jne     .fb

    ; ---- VGA text ----
    mov     edi, 0xB8000
    mov     eax, r13d
    imul    eax, MAP_WIDTH
    add     eax, r12d
    shl     eax, 1
    add     edi, eax
    mov     eax, ebp
    mov     [rdi], al
    mov     eax, [rel cur_color]
    mov     [rdi + 1], al
    jmp     .done

.fb:
    ; px = game_x0 + x*8, py = game_y0 + y*16
    mov     eax, r12d
    shl     eax, 3
    add     eax, [rel game_x0]
    mov     [rel cur_px], eax
    mov     eax, r13d
    shl     eax, 4
    add     eax, [rel game_y0]
    mov     [rel cur_py], eax

    ; --- Залить клетку фоном ---
    ; В VGA text пробел сам очищает знакоместо, а в GOP-режиме глиф
    ; пробела не содержит ни одного установленного бита, поэтому без
    ; этой заливки старый символ остаётся на экране, а новый рисуется
    ; поверх него. Фон у всех клеток чёрный.
    mov     rdi, [rel fb_base]
    mov     eax, [rel cur_py]
    imul    eax, [rel fb_pitch]
    mov     edx, [rel cur_px]
    shl     edx, 2
    add     eax, edx
    add     rdi, rax                    ; &fb[cell_x, cell_y]

    mov     r11d, [rel fb_pitch]
    sub     r11d, FONT_WIDTH * 4        ; добивка до начала следующей строки
    mov     r8d, FONT_HEIGHT
    xor     eax, eax
.bg_row:
    mov     ecx, FONT_WIDTH
    rep     stosd
    add     rdi, r11
    dec     r8d
    jnz     .bg_row

    ; rsi = &font8x16[(ch - 32) * 16]
    lea     rsi, [rel font8x16]
    mov     eax, ebp
    sub     eax, 32
    shl     eax, 4
    mov     ecx, eax
    add     rsi, rcx

    xor     r13d, r13d                  ; строка глифа
.row:
    movzx   ebp, byte [rsi + r13]
    xor     r12d, r12d                  ; бит в строке
.bit:
    test    ebp, 0x80
    jz      .skip

    ; put_pixel(cur_px + bit, cur_py + row, ebx)
    mov     eax, [rel cur_px]
    add     eax, r12d
    shl     eax, 2                      ; 4 байта на пиксель (32 bpp)
    mov     ecx, [rel cur_py]
    add     ecx, r13d
    imul    ecx, [rel fb_pitch]

    mov     rdi, [rel fb_base]
    mov     edx, eax
    add     rdi, rdx
    mov     edx, ecx
    add     rdi, rdx
    mov     [rdi], ebx

.skip:
    shl     ebp, 1
    inc     r12d
    cmp     r12d, FONT_WIDTH
    jb      .bit

    inc     r13d
    cmp     r13d, FONT_HEIGHT
    jb      .row

.done:
    pop     r13
    pop     r12
    pop     rbp
    pop     rdi
    pop     rsi
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; draw_map
; ---------------------------------------------------------------------------
draw_map:
    mov     dword [rel map_y], 0
.row:
    mov     dword [rel map_x], 0
.col:
    mov     eax, [rel map_y]
    imul    eax, MAP_WIDTH
    add     eax, [rel map_x]
    lea     rsi, [rel map_data]
    movzx   ecx, byte [rsi + rax]

    mov     eax, [rel map_x]
    mov     ebx, [rel map_y]
    mov     edx, 0x07
    call    draw_char

    inc     dword [rel map_x]
    cmp     dword [rel map_x], MAP_WIDTH
    jb      .col

    inc     dword [rel map_y]
    cmp     dword [rel map_y], MAP_HEIGHT
    jb      .row
    ret

; ---------------------------------------------------------------------------
; draw_player
; ---------------------------------------------------------------------------
draw_player:
    mov     eax, [rel player_x]
    mov     ebx, [rel player_y]
    mov     ecx, 'P'
    movzx   edx, byte [rel player_color]
    call    draw_char
    ret

; ---------------------------------------------------------------------------
; clear_cell - стереть клетку, где стоял игрок
; ---------------------------------------------------------------------------
clear_cell:
    mov     eax, [rel player_x]
    mov     ebx, [rel player_y]
    mov     ecx, ' '
    mov     edx, 0x07
    call    draw_char
    ret

; ---------------------------------------------------------------------------
; draw_status - строка "Loader: BIOS/UEFI  Arch: x64" в последней строке
; ---------------------------------------------------------------------------
draw_status:
    push    rsi
    push    r14

    lea     rsi, [rel status_bios]
    cmp     dword [rel firmware], 0
    je      .selected
    lea     rsi, [rel status_uefi]
.selected:
    xor     r14d, r14d                  ; столбец
.loop:
    movzx   ecx, byte [rsi]
    test    ecx, ecx
    jz      .done
    mov     eax, r14d
    mov     ebx, MAP_HEIGHT             ; последняя строка (25-я)
    mov     edx, 0x0F
    call    draw_char
    inc     rsi
    inc     r14d
    cmp     r14d, MAP_WIDTH
    jb      .loop
.done:
    pop     r14
    pop     rsi
    ret

; ---------------------------------------------------------------------------
; move_player - опрос PS/2 и один шаг игры
; ---------------------------------------------------------------------------
move_player:
    call    poll_key
    test    al, al
    jz      .ret

    cmp     al, 0x11                    ; W
    je      .up
    cmp     al, 0x1E                    ; A
    je      .left
    cmp     al, 0x1F                    ; S
    je      .down
    cmp     al, 0x20                    ; D
    je      .right

.ret:
    ret

.up:
    mov     eax, [rel player_x]
    mov     [rel new_x], eax
    mov     eax, [rel player_y]
    dec     eax
    mov     [rel new_y], eax
    jmp     .check

.left:
    mov     eax, [rel player_x]
    dec     eax
    mov     [rel new_x], eax
    mov     eax, [rel player_y]
    mov     [rel new_y], eax
    jmp     .check

.down:
    mov     eax, [rel player_x]
    mov     [rel new_x], eax
    mov     eax, [rel player_y]
    inc     eax
    mov     [rel new_y], eax
    jmp     .check

.right:
    mov     eax, [rel player_x]
    inc     eax
    mov     [rel new_x], eax
    mov     eax, [rel player_y]
    mov     [rel new_y], eax

.check:
    cmp     dword [rel new_x], 0
    jl      .ret
    cmp     dword [rel new_x], MAP_WIDTH - 1
    jg      .ret
    cmp     dword [rel new_y], 0
    jl      .ret
    cmp     dword [rel new_y], MAP_HEIGHT - 1
    jg      .ret

    mov     eax, [rel new_y]
    imul    eax, MAP_WIDTH
    add     eax, [rel new_x]
    lea     rsi, [rel map_data]
    movzx   eax, byte [rsi + rax]

    cmp     al, '#'
    je      .ret

    cmp     al, 'R'
    jne     .n1
    mov     byte [rel player_color], 0x0C
.n1:
    cmp     al, 'G'
    jne     .n2
    mov     byte [rel player_color], 0x0A
.n2:
    cmp     al, 'B'
    jne     .n3
    mov     byte [rel player_color], 0x0B
.n3:
    call    clear_cell
    mov     eax, [rel new_x]
    mov     [rel player_x], eax
    mov     eax, [rel new_y]
    mov     [rel player_y], eax
    call    draw_player
    ret

; ---------------------------------------------------------------------------
; poll_key - неблокирующее чтение PS/2, возвращает AL=scan code или 0
; ---------------------------------------------------------------------------
poll_key:
    mov     dx, 0x64
    in      al, dx
    test    al, 1
    jz      .none
    test    al, 0x20                    ; данные мыши?
    jnz     .flush

    mov     dx, 0x60
    in      al, dx
    cmp     al, 0xE0
    je      .none
    cmp     al, 0xE1
    je      .none
    test    al, 0x80                    ; break code
    jnz     .none
    ret

.flush:
    mov     dx, 0x60
    in      al, dx
.none:
    xor     al, al
    ret

; ---------------------------------------------------------------------------
; init_keyboard - включить трансляцию в scan code set 1
; ---------------------------------------------------------------------------
init_keyboard:
    push    rbx

    ; очистить выходной буфер
    mov     dx, 0x64
    in      al, dx
    test    al, 1
    jz      .no_flush
    mov     dx, 0x60
    in      al, dx
.no_flush:

    call    kbd_wait_write
    mov     al, 0x20                    ; прочитать configuration byte
    out     0x64, al

    call    kbd_wait_read
    in      al, 0x60
    mov     bl, al
    or      bl, 0x40                    ; включить трансляцию set2 -> set1

    call    kbd_wait_write
    mov     al, 0x60                    ; записать configuration byte
    out     0x64, al
    call    kbd_wait_write
    mov     al, bl
    out     0x60, al

    call    kbd_wait_write
    mov     al, 0xAE                    ; включить клавиатурный интерфейс
    out     0x64, al

    pop     rbx
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

align 8
bi_ptr:         dq 0
fb_base:        dq 0

video_mode:     dd 0
fb_width:       dd 0
fb_height:      dd 0
fb_pitch:       dd 0
fb_bpp:         dd 0
fb_format:      dd 0
firmware:       dd 0
game_x0:        dd 0
game_y0:        dd 0
cur_px:         dd 0
cur_py:         dd 0
cur_color:      dd 0

player_x:       dd 2
player_y:       dd 2
player_color:   db 0x0E

new_x:          dd 0
new_y:          dd 0
map_x:          dd 0
map_y:          dd 0

status_bios:    db "Loader: BIOS   Arch: x64", 0
status_uefi:    db "Loader: UEFI   Arch: x64", 0

align 16
ega_palette:
    dd 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA
    dd 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA
    dd 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF
    dd 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF

align 16
stack_bottom:
    times 16384 db 0
stack_top:
