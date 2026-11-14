; ============================================================
; 第 19 章：Direct2D 综合窗口
; 构建：make        产物：d2d_capstone.exe（GUI 子系统，只编译不运行）
; 内容：WM_SIZE 里 Resize、WM_TIMER 驱动动画、EndDraw 检测
;       D2DERR_RECREATE_TARGET、完整释放顺序
; ============================================================
%include "../common.asm"

default rel

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
extern GetModuleHandleW
extern LoadCursorW
extern LoadIconW
extern InvalidateRect
extern SetTimer
extern KillTimer
extern D2D1CreateFactory

global wmain

section .data
class_name:   WSTRZ "MasmLearnD2DCapstone"
window_title: WSTRZ "x64 assembly - D2D capstone"

iid_d2d1factory:
    db 0x47, 0x22, 0x15, 0x06, 0x50, 0x6F, 0x5A, 0x46
    db 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07

clear_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.08
        at D2D1_COLOR_F.g, dd 0.09
        at D2D1_COLOR_F.b, dd 0.12
        at D2D1_COLOR_F.a, dd 1.0
    iend

box_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.25
        at D2D1_COLOR_F.g, dd 0.60
        at D2D1_COLOR_F.b, dd 0.90
        at D2D1_COLOR_F.a, dd 1.0
    iend

dot_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.95
        at D2D1_COLOR_F.g, dd 0.55
        at D2D1_COLOR_F.b, dd 0.20
        at D2D1_COLOR_F.a, dd 1.0
    iend

section .bss
wndclass:    resb WNDCLASSEXW_size
msg:         resb MSG_size
hwnd:        resq 1

rt_props:    resb D2D1_RENDER_TARGET_PROPERTIES_size
hwnd_props:  resb D2D1_HWND_RENDER_TARGET_PROPERTIES_size
size_u:      resb D2D1_SIZE_U_size

p_factory:   resq 1
p_rt:        resq 1
p_box:       resq 1
p_dot:       resq 1

g_width:     resd 1
g_height:    resd 1
g_tick:      resd 1
anim_rect:   resb D2D1_RECT_F_size
anim_dot:    resb D2D1_ELLIPSE_size

section .text

; ------------------------------------------------------------
; release_scene：释放画刷与渲染目标（不释放工厂）
; ------------------------------------------------------------
release_scene:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    mov     rcx, [rel p_box]
    test    rcx, rcx
    jz      .no_box
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_box], 0
.no_box:
    mov     rcx, [rel p_dot]
    test    rcx, rcx
    jz      .no_dot
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_dot], 0
.no_dot:
    mov     rcx, [rel p_rt]
    test    rcx, rcx
    jz      .no_rt
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_rt], 0
.no_rt:
    leave
    ret

; ------------------------------------------------------------
; create_render_target：创建 RT + 两个画刷
; 返回 EAX = 0 成功；1 没有工厂；2/3 创建失败
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
    lea     rdx, [rel box_color]
    xor     r8d, r8d
    lea     r9,  [rel p_box]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH
    test    eax, eax
    jnz     .fail_brush

    mov     rcx, [rel p_rt]
    lea     rdx, [rel dot_color]
    xor     r8d, r8d
    lea     r9,  [rel p_dot]
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
    cmp     edx, WM_CLOSE
    je      .on_close
    cmp     edx, WM_DESTROY
    je      .on_destroy
    cmp     edx, WM_ERASEBKGND
    je      .on_erase

    call    DefWindowProcW
    leave
    ret

; ---- WM_SIZE：记录尺寸并把渲染目标 Resize ----
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
    call    release_scene          ; Resize 失败：下一帧重建

.size_done:
    mov     rcx, [rel hwnd]
    xor     edx, edx
    mov     r8d, FALSE
    call    InvalidateRect
    xor     eax, eax
    leave
    ret

; ---- WM_TIMER：推进动画帧，请求重画 ----
.on_timer:
    inc     dword [rel g_tick]
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
    mov     rcx, [rel p_rt]
    COM_CALL rcx, D2D1_RT_BEGIN_DRAW

    mov     rcx, [rel p_rt]
    lea     rdx, [rel clear_color]
    COM_CALL rcx, D2D1_RT_CLEAR

    ; ---- 用 tick 计算矩形位置：x = (tick & 63) * 7 ----
    mov     eax, [rel g_tick]
    and     eax, 63
    imul    eax, eax, 7                 ; 0..441
    cvtsi2ss xmm0, eax
    movss   [rel anim_rect + D2D1_RECT_F.left], xmm0
    add     eax, 120
    cvtsi2ss xmm0, eax
    movss   [rel anim_rect + D2D1_RECT_F.right], xmm0

    mov     eax, [rel g_tick]
    and     eax, 15
    imul    eax, eax, 12                ; 0..180
    add     eax, 40
    cvtsi2ss xmm0, eax
    movss   [rel anim_rect + D2D1_RECT_F.top], xmm0
    add     eax, 90
    cvtsi2ss xmm0, eax
    movss   [rel anim_rect + D2D1_RECT_F.bottom], xmm0

    ; FillRectangle(&anim_rect, p_box)
    mov     rcx, [rel p_rt]
    lea     rdx, [rel anim_rect]
    mov     r8,  [rel p_box]
    COM_CALL rcx, D2D1_RT_FILL_RECTANGLE

    ; 圆：中心跟随矩形左侧，半径 40
    mov     eax, [rel g_tick]
    and     eax, 63
    imul    eax, eax, 7
    add     eax, 60
    cvtsi2ss xmm0, eax
    movss   [rel anim_dot + D2D1_ELLIPSE.point_x], xmm0
    mov     eax, 320
    cvtsi2ss xmm0, eax
    movss   [rel anim_dot + D2D1_ELLIPSE.point_y], xmm0
    mov     eax, 40
    cvtsi2ss xmm0, eax
    movss   [rel anim_dot + D2D1_ELLIPSE.radiusX], xmm0
    movss   [rel anim_dot + D2D1_ELLIPSE.radiusY], xmm0

    ; FillEllipse(&anim_dot, p_dot)
    mov     rcx, [rel p_rt]
    lea     rdx, [rel anim_dot]
    mov     r8,  [rel p_dot]
    COM_CALL rcx, D2D1_RT_FILL_ELLIPSE

    ; EndDraw：D2DERR_RECREATE_TARGET 表示设备丢失，需要重建
    mov     rcx, [rel p_rt]
    xor     edx, edx
    xor     r8d, r8d
    COM_CALL rcx, D2D1_RT_END_DRAW
    cmp     eax, D2DERR_RECREATE_TARGET
    jne     .paint_done
    call    release_scene

.paint_done:
    xor     eax, eax
    leave
    ret

.on_keydown:
    cmp     r8d, VK_ESCAPE
    jne     .key_other
    mov     rcx, [rel hwnd]
    call    DestroyWindow
.key_other:
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
    mov     eax, 1
    leave
    ret

; ------------------------------------------------------------
; wmain
; ------------------------------------------------------------
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128

    mov     qword [rbp - 8], 0
    xor     ecx, ecx
    call    GetModuleHandleW
    mov     [rbp - 8], rax

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
    mov     rcx, [rbp - 8]
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
    mov     rax, [rbp - 8]
    mov     qword [rsp + 80], rax
    mov     qword [rsp + 88], 0
    call    CreateWindowExW
    test    rax, rax
    jz      .fail_create
    mov     [rel hwnd], rax

    xor     ecx, ecx
    lea     rdx, [rel iid_d2d1factory]
    xor     r8d, r8d
    lea     r9,  [rel p_factory]
    call    D2D1CreateFactory
    test    eax, eax
    jnz     .fail_d2d

    call    create_render_target
    test    eax, eax
    jnz     .fail_d2d

    ; SetTimer(hwnd, 1, 16, NULL)：约 60 帧/秒
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
    xor     eax, eax
    leave
    ret

.fail_register:
    mov     eax, 1
    leave
    ret

.fail_create:
    mov     eax, 2
    leave
    ret

.fail_d2d:
    mov     eax, 3
    leave
    ret
