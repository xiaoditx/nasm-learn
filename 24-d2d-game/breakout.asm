; ============================================================
; 第 24 章：纯汇编 Direct2D 小游戏 —— 弹球打砖块（零 CRT）
; 构建：make    产物：breakout.exe（GUI 子系统，只编译不运行）
; 入口 _start；ld 直连：-luser32 -lkernel32 -ld2d1
; 玩法：← → 移动挡板，ESC 退出；3 条命（左上角圆点），
;       球落到底丢一命，命用完整局重置；清光砖块立即刷新下一局。
; ============================================================
%include "../common.asm"

default rel

extern GetModuleHandleW
extern LoadIconW
extern LoadCursorW
extern RegisterClassExW
extern CreateWindowExW
extern ShowWindow
extern UpdateWindow
extern GetMessageW
extern TranslateMessage
extern DispatchMessageW
extern DefWindowProcW
extern PostQuitMessage
extern DestroyWindow
extern InvalidateRect
extern SetTimer
extern KillTimer
extern D2D1CreateFactory
extern ExitProcess

global _start

; ---------- 游戏常量（逻辑坐标 = 像素，场地固定 640x480） ----------
%define BRICK_COUNT   32          ; 8 列 x 4 行

section .data
class_name:   WSTRZ "MasmLearnD2DBreakout"
window_title: WSTRZ "x64 assembly - D2D breakout (no CRT)"

iid_d2d1factory:
    db 0x47, 0x22, 0x15, 0x06, 0x50, 0x6F, 0x5A, 0x46
    db 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07

; ---- 颜色 ----
clear_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.08
        at D2D1_COLOR_F.g, dd 0.09
        at D2D1_COLOR_F.b, dd 0.12
        at D2D1_COLOR_F.a, dd 1.0
    iend
brick_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.85
        at D2D1_COLOR_F.g, dd 0.45
        at D2D1_COLOR_F.b, dd 0.15
        at D2D1_COLOR_F.a, dd 1.0
    iend
paddle_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.25
        at D2D1_COLOR_F.g, dd 0.60
        at D2D1_COLOR_F.b, dd 0.90
        at D2D1_COLOR_F.a, dd 1.0
    iend
ball_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.95
        at D2D1_COLOR_F.g, dd 0.85
        at D2D1_COLOR_F.b, dd 0.30
        at D2D1_COLOR_F.a, dd 1.0
    iend

; ---- 浮点常量（dd 立即数由 NASM 转成 IEEE754 单精度位型） ----
c_zero:       dd 0.0
c_neg1:       dd -1.0             ; 乘 -1 = 速度反向
c_ball_r:     dd 8.0
c_ball_maxx:  dd 632.0            ; 640 - r
c_ball_dead:  dd 488.0            ; 球心越过这条线 = 丢命
c_ball_x0:    dd 320.0
c_ball_y0:    dd 240.0
c_ball_vx0:   dd 3.0
c_ball_vy0:   dd -4.0
c_paddle_y:   dd 450.0
c_paddle_w:   dd 100.0
c_paddle_h:   dd 12.0
c_paddle_max: dd 540.0            ; 640 - 100
c_paddle_spd: dd 8.0              ; 每帧像素
c_paddle_x0:  dd 270.0            ; (640-100)/2
c_brick_w:    dd 72.0
c_brick_h:    dd 20.0
c_life_r:     dd 6.0

section .bss
wndclass:   resb WNDCLASSEXW_size
msg:        resb MSG_size
hwnd:       resq 1
hinst:      resq 1

rt_props:   resb D2D1_RENDER_TARGET_PROPERTIES_size
hwnd_props: resb D2D1_HWND_RENDER_TARGET_PROPERTIES_size
size_u:     resb D2D1_SIZE_U_size

p_factory:  resq 1
p_rt:       resq 1
p_brick:    resq 1
p_paddle:   resq 1
p_ball:     resq 1

g_width:    resd 1
g_height:   resd 1

draw_rect:    resb D2D1_RECT_F_size
draw_ellipse: resb D2D1_ELLIPSE_size

; ---- 游戏状态 ----
ball_x:     resd 1                ; 全部是 float
ball_y:     resd 1
ball_vx:    resd 1
ball_vy:    resd 1
paddle_x:   resd 1
lives:      resd 1
key_left:   resd 1                ; WM_KEYDOWN/UP 维护的按键状态
key_right:  resd 1
bricks:     resd BRICK_COUNT      ; 1 = 存活，0 = 已击碎

section .text

; ------------------------------------------------------------
; reset_ball：球回中场，初速 (3, -4)。叶子函数，只用易失寄存器。
; ------------------------------------------------------------
reset_ball:
    movss   xmm0, [rel c_ball_x0]
    movss   [rel ball_x], xmm0
    movss   xmm0, [rel c_ball_y0]
    movss   [rel ball_y], xmm0
    movss   xmm0, [rel c_ball_vx0]
    movss   [rel ball_vx], xmm0
    movss   xmm0, [rel c_ball_vy0]
    movss   [rel ball_vy], xmm0
    ret

; ------------------------------------------------------------
; reset_bricks：32 块砖全部置 1。叶子函数。
; 注意：[rel bricks + rcx*4] 非法——RIP 相对寻址不能带变址寄存器，
; 必须先 lea 取绝对地址再 [rdx + rcx*4]。
; ------------------------------------------------------------
reset_bricks:
    lea     rdx, [rel bricks]
    xor     ecx, ecx
    mov     eax, 1
.loop:
    mov     [rdx + rcx*4], eax
    inc     ecx
    cmp     ecx, BRICK_COUNT
    jb      .loop
    ret

; ------------------------------------------------------------
; reset_game：整局重置（命 = 3，挡板居中，砖与球复位）
; ------------------------------------------------------------
reset_game:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    mov     dword [rel lives], 3
    movss   xmm0, [rel c_paddle_x0]
    movss   [rel paddle_x], xmm0
    call    reset_bricks
    call    reset_ball

    leave
    ret

; ------------------------------------------------------------
; release_scene：释放 3 个画刷与渲染目标（不释放工厂）
; ------------------------------------------------------------
release_scene:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    mov     rcx, [rel p_brick]
    test    rcx, rcx
    jz      .no_brick
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_brick], 0
.no_brick:
    mov     rcx, [rel p_paddle]
    test    rcx, rcx
    jz      .no_paddle
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_paddle], 0
.no_paddle:
    mov     rcx, [rel p_ball]
    test    rcx, rcx
    jz      .no_ball
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_ball], 0
.no_ball:
    mov     rcx, [rel p_rt]
    test    rcx, rcx
    jz      .no_rt
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_rt], 0
.no_rt:
    leave
    ret

; ------------------------------------------------------------
; create_render_target：创建 RT + 3 个画刷
; 返回 EAX = 0 成功；1 没有工厂；2 画刷失败；3 RT 失败
; ------------------------------------------------------------
create_render_target:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64

    mov     rax, [rel p_factory]
    test    rax, rax
    jz      .no_factory

    lea     rdi, [rel rt_props]
    xor     eax, eax
    mov     ecx, D2D1_RENDER_TARGET_PROPERTIES_size / 4
    rep     stosd

    lea     rdi, [rel hwnd_props]
    xor     eax, eax
    mov     ecx, D2D1_HWND_RENDER_TARGET_PROPERTIES_size / 4
    rep     stosd

    lea     rax, [rel hwnd_props]
    mov     rcx, [rel hwnd]
    mov     [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.hwnd], rcx
    mov     ecx, [rel g_width]
    mov     [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.pixelSize_width], ecx
    mov     ecx, [rel g_height]
    mov     [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.pixelSize_height], ecx

    mov     rcx, [rel p_factory]
    lea     rdx, [rel rt_props]
    lea     r8,  [rel hwnd_props]
    lea     r9,  [rel p_rt]
    COM_CALL rcx, D2D1_FACTORY_CREATE_HWND_RT
    test    eax, eax
    jnz     .fail_create

    mov     rcx, [rel p_rt]
    lea     rdx, [rel brick_color]
    xor     r8d, r8d
    lea     r9,  [rel p_brick]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH
    test    eax, eax
    jnz     .fail_brush

    mov     rcx, [rel p_rt]
    lea     rdx, [rel paddle_color]
    xor     r8d, r8d
    lea     r9,  [rel p_paddle]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH
    test    eax, eax
    jnz     .fail_brush

    mov     rcx, [rel p_rt]
    lea     rdx, [rel ball_color]
    xor     r8d, r8d
    lea     r9,  [rel p_ball]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH
    test    eax, eax
    jnz     .fail_brush

    xor     eax, eax
    leave
    ret

.fail_brush:
    call    release_scene
    mov     eax, 2
    leave
    ret

.fail_create:
    mov     eax, 3
    leave
    ret

.no_factory:
    mov     eax, 1
    leave
    ret

; ------------------------------------------------------------
; update_game：每帧（WM_TIMER, 16ms）推进一步游戏逻辑
; 帧布局：push rbp → push rbx → sub 40；入口%16==8 → 对齐
; ------------------------------------------------------------
update_game:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40

    ; ---- 挡板：按住 ←/→ 连续移动（按键状态而非单次消息） ----
    cmp     dword [rel key_left], 0
    je      .no_left
    movss   xmm0, [rel paddle_x]
    subss   xmm0, [rel c_paddle_spd]
    comiss  xmm0, [rel c_zero]          ; 左边界 clamp：xmm0 < 0 → CF=1
    jae     .store_left
    xorps   xmm0, xmm0
.store_left:
    movss   [rel paddle_x], xmm0
.no_left:
    cmp     dword [rel key_right], 0
    je      .no_right
    movss   xmm0, [rel paddle_x]
    addss   xmm0, [rel c_paddle_spd]
    comiss  xmm0, [rel c_paddle_max]
    jbe     .store_right
    movss   xmm0, [rel c_paddle_max]
.store_right:
    movss   [rel paddle_x], xmm0
.no_right:

    ; ---- 球：位置积分 ----
    movss   xmm0, [rel ball_x]
    addss   xmm0, [rel ball_vx]
    movss   [rel ball_x], xmm0
    movss   xmm0, [rel ball_y]
    addss   xmm0, [rel ball_vy]
    movss   [rel ball_y], xmm0

    ; ---- 左墙 ----
    movss   xmm0, [rel ball_x]
    comiss  xmm0, [rel c_ball_r]
    jae     .no_wall_l
    movss   xmm0, [rel c_ball_r]
    movss   [rel ball_x], xmm0
    movss   xmm0, [rel ball_vx]
    mulss   xmm0, [rel c_neg1]
    movss   [rel ball_vx], xmm0
.no_wall_l:
    ; ---- 右墙 ----
    movss   xmm0, [rel ball_x]
    comiss  xmm0, [rel c_ball_maxx]
    jbe     .no_wall_r
    movss   xmm0, [rel c_ball_maxx]
    movss   [rel ball_x], xmm0
    movss   xmm0, [rel ball_vx]
    mulss   xmm0, [rel c_neg1]
    movss   [rel ball_vx], xmm0
.no_wall_r:
    ; ---- 顶墙 ----
    movss   xmm0, [rel ball_y]
    comiss  xmm0, [rel c_ball_r]
    jae     .no_wall_t
    movss   xmm0, [rel c_ball_r]
    movss   [rel ball_y], xmm0
    movss   xmm0, [rel ball_vy]
    mulss   xmm0, [rel c_neg1]
    movss   [rel ball_vy], xmm0
.no_wall_t:

    ; ---- 挡板碰撞（仅下落时 vy > 0 才检测） ----
    movss   xmm0, [rel ball_vy]
    comiss  xmm0, [rel c_zero]
    jbe     .no_paddle
    movss   xmm0, [rel ball_y]
    addss   xmm0, [rel c_ball_r]
    comiss  xmm0, [rel c_paddle_y]      ; 球底 < 挡板顶 → 跳过
    jb      .no_paddle
    movss   xmm0, [rel ball_y]
    subss   xmm0, [rel c_ball_r]
    movss   xmm1, [rel c_paddle_y]
    addss   xmm1, [rel c_paddle_h]
    comiss  xmm0, xmm1                  ; 球顶 > 挡板底 → 跳过
    ja      .no_paddle
    movss   xmm0, [rel ball_x]
    addss   xmm0, [rel c_ball_r]
    comiss  xmm0, [rel paddle_x]        ; 球右缘 < 挡板左缘 → 跳过
    jb      .no_paddle
    movss   xmm0, [rel ball_x]
    subss   xmm0, [rel c_ball_r]
    movss   xmm1, [rel paddle_x]
    addss   xmm1, [rel c_paddle_w]
    comiss  xmm0, xmm1                  ; 球左缘 > 挡板右缘 → 跳过
    ja      .no_paddle
    ; 命中：球贴回挡板顶，vy 反向
    movss   xmm0, [rel c_paddle_y]
    subss   xmm0, [rel c_ball_r]
    movss   [rel ball_y], xmm0
    movss   xmm0, [rel ball_vy]
    mulss   xmm0, [rel c_neg1]
    movss   [rel ball_vy], xmm0
.no_paddle:

    ; ---- 砖块碰撞：球的 AABB 与砖的 AABB 重叠检测 ----
    ; 砖 i：col = i & 7，row = i >> 3
    ; left = 18 + col*76，top = 40 + row*24（76=72+4 缝隙，24=20+4）
    lea     r10, [rel bricks]
    xor     ebx, ebx
.brick_loop:
    cmp     ebx, BRICK_COUNT
    jae     .brick_done
    cmp     dword [r10 + rbx*4], 0
    je      .brick_next

    mov     eax, ebx
    and     eax, 7
    imul    eax, eax, 76
    add     eax, 18
    cvtsi2ss xmm1, eax                  ; xmm1 = brick_left
    mov     eax, ebx
    shr     eax, 3
    imul    eax, eax, 24
    add     eax, 40
    cvtsi2ss xmm2, eax                  ; xmm2 = brick_top

    movss   xmm0, [rel ball_x]
    addss   xmm0, [rel c_ball_r]        ; 球右缘 <= 砖左缘 → 无碰撞
    comiss  xmm0, xmm1
    jbe     .brick_next
    movss   xmm0, [rel ball_x]
    subss   xmm0, [rel c_ball_r]        ; 球左缘 >= 砖右缘 → 无碰撞
    movss   xmm3, xmm1
    addss   xmm3, [rel c_brick_w]
    comiss  xmm0, xmm3
    jae     .brick_next
    movss   xmm0, [rel ball_y]
    addss   xmm0, [rel c_ball_r]        ; 球底缘 <= 砖顶缘 → 无碰撞
    comiss  xmm0, xmm2
    jbe     .brick_next
    movss   xmm0, [rel ball_y]
    subss   xmm0, [rel c_ball_r]        ; 球顶缘 >= 砖底缘 → 无碰撞
    movss   xmm3, xmm2
    addss   xmm3, [rel c_brick_h]
    comiss  xmm0, xmm3
    jae     .brick_next

    ; 命中：砖碎、vy 反向、本帧不再检测其他砖
    mov     dword [r10 + rbx*4], 0
    movss   xmm0, [rel ball_vy]
    mulss   xmm0, [rel c_neg1]
    movss   [rel ball_vy], xmm0
    jmp     .brick_done
.brick_next:
    inc     ebx
    jmp     .brick_loop
.brick_done:

    ; ---- 球落底：丢命 ----
    movss   xmm0, [rel ball_y]
    comiss  xmm0, [rel c_ball_dead]
    jbe     .no_lose
    dec     dword [rel lives]
    jz      .game_over
    call    reset_ball                  ; 还有命：只重置球
    jmp     .no_lose
.game_over:
    call    reset_game                  ; 命用完：整局重置
.no_lose:

    ; ---- 通关检测：32 块砖全碎则刷新下一局 ----
    lea     r10, [rel bricks]
    xor     ebx, ebx
    xor     eax, eax
.win_scan:
    cmp     ebx, BRICK_COUNT
    jae     .win_scan_done
    or      eax, [r10 + rbx*4]          ; 有任何一块存活，eax != 0
    inc     ebx
    jmp     .win_scan
.win_scan_done:
    test    eax, eax
    jnz     .not_won
    call    reset_bricks
    call    reset_ball
.not_won:

    add     rsp, 40
    pop     rbx
    pop     rbp
    ret

; ------------------------------------------------------------
; draw_scene：画一帧。返回 EAX = EndDraw 的 HRESULT
; 帧布局：push rbp → push rbx → push rsi → sub 48
; ------------------------------------------------------------
draw_scene:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    sub     rsp, 48

    mov     rcx, [rel p_rt]
    COM_CALL rcx, D2D1_RT_BEGIN_DRAW

    mov     rcx, [rel p_rt]
    lea     rdx, [rel clear_color]
    COM_CALL rcx, D2D1_RT_CLEAR

    ; ---- 砖块：遍历存活砖，逐个 FillRectangle ----
    lea     rsi, [rel bricks]           ; rsi 非易失，COM 调用后仍有效
    xor     ebx, ebx
.brick_loop:
    cmp     ebx, BRICK_COUNT
    jae     .bricks_done
    cmp     dword [rsi + rbx*4], 0
    je      .brick_next

    mov     eax, ebx
    and     eax, 7
    imul    eax, eax, 76
    add     eax, 18                     ; left
    cvtsi2ss xmm0, eax
    movss   [rel draw_rect + D2D1_RECT_F.left], xmm0
    add     eax, 72                     ; right = left + 72
    cvtsi2ss xmm0, eax
    movss   [rel draw_rect + D2D1_RECT_F.right], xmm0
    mov     eax, ebx
    shr     eax, 3
    imul    eax, eax, 24
    add     eax, 40                     ; top
    cvtsi2ss xmm0, eax
    movss   [rel draw_rect + D2D1_RECT_F.top], xmm0
    add     eax, 20                     ; bottom = top + 20
    cvtsi2ss xmm0, eax
    movss   [rel draw_rect + D2D1_RECT_F.bottom], xmm0

    mov     rcx, [rel p_rt]
    lea     rdx, [rel draw_rect]
    mov     r8,  [rel p_brick]
    COM_CALL rcx, D2D1_RT_FILL_RECTANGLE
.brick_next:
    inc     ebx
    jmp     .brick_loop
.bricks_done:

    ; ---- 挡板 ----
    movss   xmm0, [rel paddle_x]
    movss   [rel draw_rect + D2D1_RECT_F.left], xmm0
    addss   xmm0, [rel c_paddle_w]
    movss   [rel draw_rect + D2D1_RECT_F.right], xmm0
    movss   xmm0, [rel c_paddle_y]
    movss   [rel draw_rect + D2D1_RECT_F.top], xmm0
    addss   xmm0, [rel c_paddle_h]
    movss   [rel draw_rect + D2D1_RECT_F.bottom], xmm0
    mov     rcx, [rel p_rt]
    lea     rdx, [rel draw_rect]
    mov     r8,  [rel p_paddle]
    COM_CALL rcx, D2D1_RT_FILL_RECTANGLE

    ; ---- 球 ----
    movss   xmm0, [rel ball_x]
    movss   [rel draw_ellipse + D2D1_ELLIPSE.point_x], xmm0
    movss   xmm0, [rel ball_y]
    movss   [rel draw_ellipse + D2D1_ELLIPSE.point_y], xmm0
    movss   xmm0, [rel c_ball_r]
    movss   [rel draw_ellipse + D2D1_ELLIPSE.radiusX], xmm0
    movss   [rel draw_ellipse + D2D1_ELLIPSE.radiusY], xmm0
    mov     rcx, [rel p_rt]
    lea     rdx, [rel draw_ellipse]
    mov     r8,  [rel p_ball]
    COM_CALL rcx, D2D1_RT_FILL_ELLIPSE

    ; ---- 命数：左上角 lives 个小圆，圆心 x = 20 + i*24, y = 20 ----
    xor     ebx, ebx
.life_loop:
    cmp     ebx, dword [rel lives]
    jae     .lives_done
    mov     eax, ebx
    imul    eax, eax, 24
    add     eax, 20
    cvtsi2ss xmm0, eax
    movss   [rel draw_ellipse + D2D1_ELLIPSE.point_x], xmm0
    mov     eax, 20
    cvtsi2ss xmm0, eax
    movss   [rel draw_ellipse + D2D1_ELLIPSE.point_y], xmm0
    movss   xmm0, [rel c_life_r]
    movss   [rel draw_ellipse + D2D1_ELLIPSE.radiusX], xmm0
    movss   [rel draw_ellipse + D2D1_ELLIPSE.radiusY], xmm0
    mov     rcx, [rel p_rt]
    lea     rdx, [rel draw_ellipse]
    mov     r8,  [rel p_ball]
    COM_CALL rcx, D2D1_RT_FILL_ELLIPSE
    inc     ebx
    jmp     .life_loop
.lives_done:

    ; EndDraw：HRESULT 经 EAX 返回给调用者（检测 D2DERR_RECREATE_TARGET）
    mov     rcx, [rel p_rt]
    xor     edx, edx
    xor     r8d, r8d
    COM_CALL rcx, D2D1_RT_END_DRAW

    add     rsp, 48
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ------------------------------------------------------------
; WndProc
; ------------------------------------------------------------
WndProc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    cmp     edx, WM_PAINT
    je      .on_paint
    cmp     edx, WM_SIZE
    je      .on_size
    cmp     edx, WM_TIMER
    je      .on_timer
    cmp     edx, WM_KEYDOWN
    je      .on_keydown
    cmp     edx, WM_KEYUP
    je      .on_keyup
    cmp     edx, WM_CLOSE
    je      .on_close
    cmp     edx, WM_DESTROY
    je      .on_destroy
    cmp     edx, WM_ERASEBKGND
    je      .on_erase

    call    DefWindowProcW
    leave
    ret

; ---- WM_SIZE：记录尺寸并把渲染目标 Resize（与第 19 章相同） ----
.on_size:
    mov     eax, r9d
    movzx   ecx, ax
    mov     [rel g_width], ecx
    shr     eax, 16
    movzx   ecx, ax
    mov     [rel g_height], ecx

    mov     rax, [rel p_rt]
    test    rax, rax
    jz      .size_done

    lea     rax, [rel size_u]
    mov     ecx, [rel g_width]
    mov     [rax + D2D1_SIZE_U.width], ecx
    mov     ecx, [rel g_height]
    mov     [rax + D2D1_SIZE_U.height], ecx

    mov     rcx, [rel p_rt]
    lea     rdx, [rel size_u]
    COM_CALL rcx, D2D1_HWND_RT_RESIZE
    test    eax, eax
    jz      .size_done
    call    release_scene               ; Resize 失败：下一帧重建

.size_done:
    mov     rcx, [rel hwnd]
    xor     edx, edx
    mov     r8d, FALSE
    call    InvalidateRect
    xor     eax, eax
    leave
    ret

; ---- WM_TIMER：游戏循环的心跳 ----
.on_timer:
    call    update_game
    mov     rcx, [rel hwnd]
    xor     edx, edx
    mov     r8d, FALSE
    call    InvalidateRect
    xor     eax, eax
    leave
    ret

; ---- WM_PAINT ----
.on_paint:
    mov     rax, [rel p_rt]
    test    rax, rax
    jnz     .have_rt
    call    create_render_target
    test    eax, eax
    jnz     .paint_done
.have_rt:
    call    draw_scene
    cmp     eax, D2DERR_RECREATE_TARGET
    jne     .paint_done
    call    release_scene               ; 设备丢失：下一帧重建
.paint_done:
    xor     eax, eax
    leave
    ret

; ---- WM_KEYDOWN：←/→ 置位，ESC 退出 ----
.on_keydown:
    cmp     r8d, VK_LEFT
    je      .kd_left
    cmp     r8d, VK_RIGHT
    je      .kd_right
    cmp     r8d, VK_ESCAPE
    jne     .kd_done
    mov     rcx, [rel hwnd]
    call    DestroyWindow
    jmp     .kd_done
.kd_left:
    mov     dword [rel key_left], 1
    jmp     .kd_done
.kd_right:
    mov     dword [rel key_right], 1
.kd_done:
    xor     eax, eax
    leave
    ret

; ---- WM_KEYUP：松开即停 ----
.on_keyup:
    cmp     r8d, VK_LEFT
    jne     .ku_not_left
    mov     dword [rel key_left], 0
.ku_not_left:
    cmp     r8d, VK_RIGHT
    jne     .ku_done
    mov     dword [rel key_right], 0
.ku_done:
    xor     eax, eax
    leave
    ret

.on_close:
    mov     rcx, [rel hwnd]
    call    DestroyWindow
    xor     eax, eax
    leave
    ret

.on_destroy:
    mov     rcx, [rel hwnd]
    mov     edx, 1
    call    KillTimer
    call    release_scene

    mov     rcx, [rel p_factory]
    test    rcx, rcx
    jz      .no_factory
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_factory], 0
.no_factory:
    xor     ecx, ecx
    call    PostQuitMessage
    xor     eax, eax
    leave
    ret

.on_erase:
    mov     eax, 1                      ; 背景由 D2D Clear 负责
    leave
    ret

; ------------------------------------------------------------
; _start：RSP%16==8 → sub rsp,104 后 ==0
; （32 影子 + CreateWindowExW 的 64 栈参 + 8 对齐，推导见第 22 章）
; ------------------------------------------------------------
_start:
    sub     rsp, 104

    xor     ecx, ecx
    call    GetModuleHandleW
    mov     [rel hinst], rax

    mov     dword [rel g_width], 640
    mov     dword [rel g_height], 480

    lea     rdi, [rel wndclass]
    xor     eax, eax
    mov     ecx, WNDCLASSEXW_size / 4
    rep     stosd

    lea     rax, [rel wndclass]
    mov     dword [rax + WNDCLASSEXW.cbSize], WNDCLASSEXW_size
    mov     dword [rax + WNDCLASSEXW.style], CS_HREDRAW | CS_VREDRAW
    lea     rcx, [rel WndProc]
    mov     [rax + WNDCLASSEXW.lpfnWndProc], rcx
    mov     rcx, [rel hinst]
    mov     [rax + WNDCLASSEXW.hInstance], rcx
    mov     qword [rax + WNDCLASSEXW.hbrBackground], 0
    lea     rcx, [rel class_name]
    mov     [rax + WNDCLASSEXW.lpszClassName], rcx

    xor     ecx, ecx
    mov     edx, IDI_APPLICATION
    call    LoadIconW
    lea     rcx, [rel wndclass]
    mov     [rcx + WNDCLASSEXW.hIcon], rax
    mov     [rcx + WNDCLASSEXW.hIconSm], rax

    xor     ecx, ecx
    mov     edx, IDC_ARROW
    call    LoadCursorW
    lea     rcx, [rel wndclass]
    mov     [rcx + WNDCLASSEXW.hCursor], rax

    lea     rcx, [rel wndclass]
    call    RegisterClassExW
    test    eax, eax
    jz      .fail_register

    ; ---- CreateWindowExW：12 参，后 8 走栈 ----
    xor     ecx, ecx
    lea     rdx, [rel class_name]
    lea     r8,  [rel window_title]
    mov     r9d, WS_OVERLAPPEDWINDOW
    mov     eax, CW_USEDEFAULT
    mov     qword [rsp + 32], rax
    mov     qword [rsp + 40], rax
    mov     qword [rsp + 48], 640
    mov     qword [rsp + 56], 480
    mov     qword [rsp + 64], 0
    mov     qword [rsp + 72], 0
    mov     rax, [rel hinst]
    mov     qword [rsp + 80], rax
    mov     qword [rsp + 88], 0
    call    CreateWindowExW
    test    rax, rax
    jz      .fail_create
    mov     [rel hwnd], rax

    ; ---- D2D 工厂 ----
    xor     ecx, ecx                    ; D2D1_FACTORY_TYPE_SINGLE_THREADED
    lea     rdx, [rel iid_d2d1factory]
    xor     r8d, r8d                    ; pFactoryOptions = NULL
    lea     r9,  [rel p_factory]
    call    D2D1CreateFactory
    test    eax, eax
    jnz     .fail_d2d

    call    create_render_target
    test    eax, eax
    jnz     .fail_d2d

    ; ---- 初始化游戏状态 ----
    call    reset_game

    ; ---- SetTimer(hwnd, 1, 16ms, NULL)：约 60 帧/秒 ----
    mov     rcx, [rel hwnd]
    mov     edx, 1
    mov     r8d, 16
    xor     r9d, r9d
    call    SetTimer

    mov     rcx, [rel hwnd]
    mov     edx, SW_SHOWNORMAL
    call    ShowWindow

    mov     rcx, [rel hwnd]
    call    UpdateWindow

.msg_loop:
    lea     rcx, [rel msg]
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    call    GetMessageW
    test    eax, eax
    jz      .done
    js      .done

    lea     rcx, [rel msg]
    call    TranslateMessage

    lea     rcx, [rel msg]
    call    DispatchMessageW
    jmp     .msg_loop

.done:
    xor     ecx, ecx                    ; ExitProcess(0)
    call    ExitProcess

.fail_register:
    mov     ecx, 1
    call    ExitProcess

.fail_create:
    mov     ecx, 2
    call    ExitProcess

.fail_d2d:
    mov     ecx, 3
    call    ExitProcess
