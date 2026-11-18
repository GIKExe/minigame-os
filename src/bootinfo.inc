; ---------------------------------------------------------------------------
; bootinfo.inc - структура, которую загрузчик передаёт ядру.
;
; Указатель на эту структуру передаётся:
;   * в 32-битное ядро  - в регистре ESI;
;   * в 64-битное ядро  - в регистре RDI.
;
; Все поля little-endian.
; ---------------------------------------------------------------------------

%define BOOTINFO_MAGIC      0x534F474D      ; 'MGOS'

%define BI_MAGIC            0               ; dd
%define BI_MODE             4               ; dd: 0 = VGA text, 1 = linear framebuffer
%define BI_FB_BASE          8               ; dq: физический адрес видеопамяти
%define BI_WIDTH            16              ; dd: ширина в пикселях (или 80 для VGA)
%define BI_HEIGHT           20              ; dd: высота в пикселях (или 25 для VGA)
%define BI_PITCH            24              ; dd: байт на строку
%define BI_BPP              28              ; dd: бит на пиксель
%define BI_FORMAT           32              ; dd: 0 = RGBX/BGRX, 1 = BGR, 2 = bitmask
%define BI_FIRMWARE         36              ; dd: 0 = BIOS, 1 = UEFI
%define BI_SIZE             40
