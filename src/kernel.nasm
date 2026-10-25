[BITS 16]
[ORG 0x0000]

setup:
	mov ax, 0x1000
	mov ds, ax      ; DS = 0x1000 -> теперь [si] читает из 0x1000:si
	mov es, ax      ; ES = 0x1000 (для видеобуфера, если понадобится)
	; mov ss, ax      ; SS = 0x1000
	; mov sp, 0xFFFE  ; Стек растёт вниз от верха сегмента
	cld             ; Сброс флага направления (обязательно для BIOS-совместимости)

	mov ah, 0x00
	mov al, 0x03
	int 0x10

	mov ah, 01h
	mov cx, 2607h
	int 10h

	; mov ah, 0x09
	; mov al, 's'
	; mov bh, 0x00
	; mov bl, 0x05
	; mov cx, 0x01
	; int 0x10

	call draw_map

main:
	call move_player
	call draw_player
	jmp main


move_player:
	push ax
	push bx
	push cx
	push dx

	mov ah, 0x01
	int 0x16
	jz .exit

	mov ah, 0x00
	int 0x16
	mov [debug.data], al

	mov al, [debug.data]
	mov dl, [player.x]
	mov dh, [player.y]
	cmp al, 'd'
	je .move_right
	cmp al, 'a'
	je .move_left
	cmp al, 's'
	je .move_down
	cmp al, 'w'
	je .move_up

.exit:
	pop dx
	pop cx
	pop bx
	pop ax
	ret

.check:
	call set_pos
	mov ah, 0x08
	mov bh, 0x00
	int 0x10
	cmp al, '#'
	je .exit
	cmp al, 'R'
	jne .next1
	mov byte [player.color], 0x0C
.next1:
	cmp al, 'G'
	jne .next2
	mov byte [player.color], 0x0A
.next2:
	cmp al, 'B'
	jne .next3
	mov byte [player.color], 0x0B
.next3:
	call clear_pos
	mov [player.x], dl
	mov [player.y], dh
	jmp .exit

.move_right:
	inc dl
	jmp .check

.move_left:
	dec dl
	jmp .check

.move_down:
	inc dh
	jmp .check

.move_up:
	dec dh
	jmp .check


draw_map:
	push si
	push dx

	mov dx, 0
	call set_pos

	mov si, map
	call print

	pop dx
	pop si
	ret


clear_pos:
	push ax
	push bx
	push cx
	push dx

	mov dl, [player.x]
	mov dh, [player.y]
	call set_pos

	mov ah, 0x09
	mov al, ' '
	mov bh, 0x00
	mov bl, 0x07
	mov cx, 0x01
	int 0x10

	pop dx
	pop cx
	pop bx
	pop ax
	ret


draw_player:
	push si
	push dx

	mov dl, [player.x]
	mov dh, [player.y]
	call set_pos

	mov si, player
	call print

	pop dx
	pop si
	ret


set_pos:
	push ax
	push bx

	mov ah, 0x02
	mov bh, 0x00
	; Ожидает DH, DL
	int 0x10

	pop bx
	pop ax
	ret


print:
	push ax
	push bx
	push cx
	push dx
	mov ah, 0x09
	mov bh, 0x00
	mov bl, [si]
	inc si
	mov cx, 0x01
.loop:
	mov al, [si]
	cmp al, 0x00
	je .end
	inc si
	int 0x10
	call cursor
	jmp .loop
.end:
	pop dx
	pop cx
	pop bx
	pop ax
	ret


cursor:
	push ax
	push bx
	push cx
	push dx
.get_pos:
	mov ah, 03h
	mov bh, 00h
	int 10h
.c0:
	cmp dl, 79
	je .c1
	inc dl
	jmp .set_pos
.c1:
	cmp dh, 24
	je .reset
	mov dl, 00h
	inc dh
	jmp .set_pos
.reset:
	mov dx, 0000h
.set_pos:
	mov ah, 02h
	int 10h
.exit:
	pop dx
	pop cx
	pop bx
	pop ax
	ret


player:
.color db 0x0E
.symbol db 'P'
	 db 0
.x db 2
.y db 2


debug:
	db 0x05
.data db 0
	db 0


map:
	db 0x07
	db '################################################################################'
	db '#                                                                              #'
	db '#                                                                              #'
	db '#                                                                              #'
	db '#######################################@@#######################################'
	db '#                                                                              #'
	db '#                                                                              #'
	db '#                                                                              #'
	db '#      R                   G                     R           G                 #'
	db '#                                                                              #'
	db '#                                                                              #'
	db '#                G                                                  B          #'
	db '#                          B           R                                       #'
	db '#                                                               R              #'
	db '#                     G                           G                            #'
	db '#                                                              R               #'
	db '#                             B           R                                    #'
	db '#           R                                                                  #'
	db '#                        G                      B                              #'
	db '#                                                                              #'
	db '#                                                          R        G          #'
	db '#          G                      R                                            #'
	db '#                                                                              #'
	db '#                                                                              #'
	db '################################################################################'
	db 0
