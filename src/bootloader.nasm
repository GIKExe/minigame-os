[BITS 16]
[ORG 0x7C00]

%define lf 0x0a
%define cr 0x0d

%define pos_read_tmp 0700h    ;position for temporary read
%define boot_program 7c00h    ;position for boot code
%define seg_read_kernel 1000h ;segment to kernel read

jmp start_program
nop

; Boot Sector and BPB Structure
BS_OEMName      db      'KOLIBRI '      ; db 8
BPB_BytsPerSec  dw      512             ; bytes per sector
BPB_SecPerClus  db      1               ; sectors per cluster
BPB_RsvdSecCnt  dw      1               ; number of reserver sectors
BPB_NumFATs     db      2               ; count of FAT data structures
BPB_RootEntCnt  dw      224             ; count of 32-byte dir. entries (224*32 = 14 sectors)
BPB_TotSec16    dw      2880            ; count of sectors on the volume (2880 for 1.44 mbytes disk)
BPB_Media       db      0xF0            ; f0 - used for removable media
BPB_FATSz16     dw      9               ; count of sectors by one copy of FAT
BPB_SecPerTrk   dw      18              ; sectors per track
BPB_NumHeads    dw      2               ; number of heads
BPB_HiddSec     dd      0               ; count of hidden sectors
BPB_TotSec32    dd      0               ; count of sectors on the volume (if > 65535)
BS_DrvNum       db      0               ; int 13h drive number
BS_Reserved     db      0               ; reserved
BS_BootSig      db      29h             ; Extended boot signature
BS_VolID        dd      0x00004F86      ; Volume serial number
BS_VolLab       db      'KOLIBRI    '   ; Volume label (db 11)
BS_FilSysType   db      'FAT12   '      ; file system type (db 8)

start_program:
	mov [BS_DrvNum], dl

; <Efremenkov S.V.>
	cld     ;clear direction flag for Phoenix BIOS, see next "lodsb"
	xor     ax, ax
	cli
	mov     ss, ax
	mov     sp, 0x7C00
	sti
; <\Efremenkov S.V.>
	push    ss
	pop     ds

; 	; print loading string
; 	mov     si, loading 
; loop_loading:
; 	lodsb
; 	or      al, al
; 	jz      read_root_directory
; 	mov     ah, 0eh
; 	mov     bx, 7
; 	int     10h
; 	jmp     loop_loading

read_root_directory:
	push    ss
	pop     es

	; calculate some disk parameters
	; - beginning sector of RootDir
	mov     ax, word [BPB_FATSz16]
	xor     cx, cx
	mov     cl, byte [BPB_NumFATs]
	mul     cx
	add     ax, word [BPB_RsvdSecCnt]
	mov     word [FirstRootDirSecNum], ax      ; 19
	mov     si, ax

	; - count of sectors in RootDir
	mov     bx, word [BPB_BytsPerSec]
	mov     cl, 5                           ; divide ax by 32
	shr     bx, cl                          ; bx = directory entries per sector
	mov     ax, word [BPB_RootEntCnt]
	xor     dx, dx
	div     bx
	mov     word [RootDirSecs], ax             ; 14

	; - data start
	add     si, ax                          ; add beginning sector of RootDir and count sectors in RootDir
	mov     word [data_start], si              ; 33
	; reading root directory
	; al=count root dir sectrors !!!! TODO: al, max 255 sectors !!!!
	mov     ah, 2                           ; read
	push    ax

	mov     ax, word [FirstRootDirSecNum]
	call    conv_abs_to_THS                 ; convert abs sector (AX) to BIOS T:H:S (track:head:sector)
	pop     ax
	mov     bx, pos_read_tmp                ; es:bx read buffer
	call    read_sector

	mov     si, bx                          ; read buffer address: es:si
	mov     ax, [RootDirSecs]
	mul     word [BPB_BytsPerSec]
	add     ax, si                          ; AX = end of root dir. in buffer pos_read_tmp

	; find kernel file in root directory
loop_find_dir_entry:
	push    si
	mov     cx, 11
	mov     di, kernel_name
	rep cmpsb                               ; compare es:si and es:di, cx bytes long
	pop     si
	je      found_kernel_file
	add     si, 32                          ; next dir. entry
	cmp     si, ax                          ; end of directory
	jb      loop_find_dir_entry

file_error_message:
	; mov     si, error_message

; loop_error_message:
; 	lodsb
; 	or      al, al
; 	jz      freeze_pc
; 	mov     ah, 0eh
; 	mov     bx, 7
; 	int     10h
; 	jmp     loop_error_message

freeze_pc:
	jmp     $                               ; endless loop

	; === KERNEL FOUND. LOADING... ===

found_kernel_file:
	mov     bp, [si+01ah]                   ; first cluster of kernel file
	mov     [cluster1st], bp   ; starting cluster of kernel file

	; reading first FAT table
	mov     ax, word [BPB_RsvdSecCnt]  ; begin first FAT abs sector number
	call    conv_abs_to_THS                 ; convert abs sector (AX) to BIOS T:H:S (track:head:sector)
	mov     bx, pos_read_tmp                ; es:bx read position
	mov     ah, 2                           ; ah=2 (read)
	mov     al, byte [BPB_FATSz16]     ; FAT size in sectors (TODO: max 255 sectors)
	call    read_sector
	jc      file_error_message              ; read error

	mov     ax, seg_read_kernel
	mov     es, ax
	xor     bx, bx                          ; es:bx = 1000h:0000h


	; reading kernel file
loop_obtains_kernel_data:
	; read one cluster of file
	call    obtain_cluster
	jc      file_error_message              ; read error

	; add one cluster length to segment:offset
	push    bx
	mov     bx, es
	mov     ax, word [BPB_BytsPerSec]               ;\
	movsx   cx, byte [BPB_SecPerClus]               ; | !!! TODO: !!!
	mul     cx                                      ; | out this from loop !!!
	shr     ax, 4                                   ;/
	add     bx, ax
	mov     es, bx
	pop     bx

	mov     di, bp
	shr     di, 1
	pushf
	add     di, bp                          ; di = bp * 1.5
	add     di, pos_read_tmp
	mov     ax, [di]                        ; read next entry from FAT-chain
	popf
	jc      move_4_right
	and     ax, 0fffh
	jmp     verify_end_sector
move_4_right:
	mov     cl, 4
	shr     ax, cl
verify_end_sector:
	cmp     ax, 0ff8h                       ; last cluster
	jae     execute_kernel
	mov     bp, ax
	jmp     loop_obtains_kernel_data

execute_kernel:
	mov     ax, 'KL'
	push    0
	pop     ds
	mov     si, loader_block
	push    word seg_read_kernel
	push    word 0
	retf                                    ; jmp far 1000:0000


;------------------------------------------
	; loading cluster from file to es:bx
obtain_cluster:
	; bp - cluster number to read
	; carry = 0 -> read OK
	; carry = 1 -> read ERROR

	; print one dot
	push    bx
	mov     ax, 0e2eh                       ; ah=0eh (teletype), al='.'
	xor     bh, bh
	int     10h
	pop     bx

writesec:
	; convert cluster number to sector number
	mov     ax, bp                          ; data cluster to read
	sub     ax, 2
	xor     dx, dx
	mov     dl, byte [BPB_SecPerClus]
	mul     dx
	add     ax, word [data_start]

	call    conv_abs_to_THS                 ; convert abs sector (AX) to BIOS T:H:S (track:head:sector)
patchhere:
	mov     ah, 2                           ; ah=2 (read)
	mov     al, byte [BPB_SecPerClus]  ; al=(one cluster)
	call    read_sector
	retn
;------------------------------------------

;------------------------------------------
	; read sector from disk
read_sector:
	push    bp
	mov     bp, 20                                  ; try 20 times
newread:
	dec     bp
	jnz     .next
	cmp     ah, 02h                                 ; if read sectors
	jz      file_error_message
	mov     byte[write_err], 1         ; if write sectors
	jmp     .ret
.next:
	push ax
	push bx
	push cx
	push dx
	mov al, 18 ; МАКСИМУМ 9 КиБ !!!
	int 0x13
	pop dx
	pop cx
	pop bx
	pop ax
	jc newread
.ret:
	pop     bp
	retn

;------------------------------------------
	; convert abs. sector number (AX) to BIOS T:H:S
	; sector number = (abs.sector%BPB_SecPerTrk)+1
	; pre.track number = (abs.sector/BPB_SecPerTrk)
	; head number = pre.track number%BPB_NumHeads
	; track number = pre.track number/BPB_NumHeads
	; Return: cl - sector number
	;         ch - track number
	;         dl - drive number (0 = a:)
	;         dh - head number
conv_abs_to_THS:
	push    bx
	mov     bx, word [BPB_SecPerTrk]
	xor     dx, dx
	div     bx
	inc     dx
	mov     cl, dl                          ; cl = sector number
	mov     bx, word [BPB_NumHeads]
	xor     dx, dx
	div     bx
	; !!!!!!! ax = track number, dx = head number
	mov     ch, al                          ; ch=track number
	xchg    dh, dl                          ; dh=head number
	mov dl, [BS_DrvNum]                    ; dl=? (drive ? (a:))
	pop     bx
	retn
;------------------------------------------

; loading         db      cr,lf,'Starting system ',0
; error_message   db      13,10
kernel_name     db      'KERNEL  BIN',0

FirstRootDirSecNum      dw      0
RootDirSecs     dw      0
data_start      dw      0

write1st:
	push    cs
	pop     ds
	mov     byte [patchhere+1], 3      ; change ah=2 to ah=3
	mov     bp, [cluster1st]
	push    1000h
	pop     es
	xor     bx, bx
	call    writesec
	mov     byte [patchhere+1], 2      ; change back ah=3 to ah=2
	retf
cluster1st      dw      0
loader_block:
		db      1                       ; +0
		dw      0                       ; +1
		dw      write1st                ; +3
		dw      0                       ; +5
write_err db 0                      ; +7

times 0x1BE - ($ - $$) db 0
; Partition 1:
db 0x80 ; 0x1BE: Boot flag (активный)
times 15 db 0
; Partition 2-4:
times 48 db 0
; Boot Signature
db 0x55, 0xAA