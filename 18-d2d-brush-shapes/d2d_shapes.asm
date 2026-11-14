; ============================================================
; 第 18 章：Direct2D 画刷与图元
; 构建：make        产物：d2d_shapes.exe（GUI 子系统，只编译不运行）
; 演示 CreateSolidColorBrush / FillRectangle / DrawRectangle / FillEllipse
; 以及“FLOAT 参数走 XMM 寄存器”这条 x64 ABI 规则
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
extern D2D1CreateFactory

global wmain

section .data
class_name:   WSTRZ "MasmLearnD2DShapes"
window_title: WSTRZ "x64 assembly - D2D shapes"

iid_d2d1factory:
    db 0x47, 0x22, 0x15, 0x06, 0x50, 0x6F, 0x5A, 0x46
    db 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07

clear_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.10
        at D2D1_COLOR_F.g, dd 0.13
        at D2D1_COLOR_F.b, dd 0.18
        at D2D1_COLOR_F.a, dd 1.0
    iend

fill_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.20
        at D2D1_COLOR_F.g, dd 0.55
        at D2D1_COLOR_F.b, dd 0.85
        at D2D1_COLOR_F.a, dd 1.0
    iend

stroke_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 1.0
        at D2D1_COLOR_F.g, dd 0.85
        at D2D1_COLOR_F.b, dd 0.30
        at D2D1_COLOR_F.a, dd 1.0
    iend

circle_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.85
        at D2D1_COLOR_F.g, dd 0.30
        at D2D1_COLOR_F.b, dd 0.35
        at D2D1_COLOR_F.a, dd 1.0
    iend

; 矩形：left/top/right/bottom 都是 FLOAT
rect_fill:
    istruc D2D1_RECT_F
        at D2D1_RECT_F.left,   dd 40.0
        at D2D1_RECT_F.top,    dd 40.0
        at D2D1_RECT_F.right,  dd 340.0
        at D2D1_RECT_F.bottom, dd 220.0
    iend

; 椭圆：中心点 + 两个半径
circle_shape:
    istruc D2D1_ELLIPSE
        at D2D1_ELLIPSE.point_x, dd 460.0
        at D2D1_ELLIPSE.point_y, dd 150.0
        at D2D1_ELLIPSE.radiusX, dd 90.0
        at D2D1_ELLIPSE.radiusY, dd 70.0
    iend

section .bss
wndclass:    resb WNDCLASSEXW_size
msg:         resb MSG_size
hwnd:        resq 1

rt_props:    resb D2D1_RENDER_TARGET_PROPERTIES_size
hwnd_props:  resb D2D1_HWND_RENDER_TARGET_PROPERTIES_size

p_factory:   resq 1
p_rt:        resq 1
p_fill:      resq 1
p_stroke:    resq 1
p_circle:    resq 1

section .text

; ------------------------------------------------------------
; 辅助函数：释放一个 COM 对象（RCX = 接口指针，可为 0）
; 只破坏 RAX/RCX，返回值无意义
; ------------------------------------------------------------
release_if_nonnull:
    test    rcx, rcx
    jz      .ret
    COM_CALL rcx, IUNKNOWN_RELEASE
.ret:
    ret

; ------------------------------------------------------------
WndProc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    cmp     edx, WM_PAINT
    je      .on_paint
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

.on_paint:
    mov     rax, [rel p_rt]
    test    rax, rax
    jz      .paint_done

    ; BeginDraw
    mov     rcx, [rel p_rt]
    COM_CALL rcx, D2D1_RT_BEGIN_DRAW

    ; Clear(&clear_color)
    mov     rcx, [rel p_rt]
    lea     rdx, [rel clear_color]
    COM_CALL rcx, D2D1_RT_CLEAR

    ; FillRectangle(&rect_fill, p_fill)
    mov     rcx, [rel p_rt]
    lea     rdx, [rel rect_fill]
    mov     r8,  [rel p_fill]
    COM_CALL rcx, D2D1_RT_FILL_RECTANGLE

    ; DrawRectangle(&rect_fill, p_stroke, 2.0f, NULL)
    ; 注意：第 4 个参数是 FLOAT，走 XMM3，不是 R9；
    ;       第 5 个参数（strokeStyle）才走 R9。
    mov     rcx, [rel p_rt]
    lea     rdx, [rel rect_fill]
    mov     r8,  [rel p_stroke]
    mov     eax, 0x40000000         ; 2.0f 的位模式
    movd    xmm3, eax
    xor     r9d, r9d
    COM_CALL rcx, D2D1_RT_DRAW_RECTANGLE

    ; FillEllipse(&circle_shape, p_circle)
    mov     rcx, [rel p_rt]
    lea     rdx, [rel circle_shape]
    mov     r8,  [rel p_circle]
    COM_CALL rcx, D2D1_RT_FILL_ELLIPSE

    ; EndDraw
    mov     rcx, [rel p_rt]
    xor     edx, edx
    xor     r8d, r8d
    COM_CALL rcx, D2D1_RT_END_DRAW

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

; ---- 释放顺序：画刷 → 渲染目标 → 工厂 ----
.on_destroy:
    mov     rcx, [rel p_fill]
    call    release_if_nonnull
    mov     qword [rel p_fill], 0

    mov     rcx, [rel p_stroke]
    call    release_if_nonnull
    mov     qword [rel p_stroke], 0

    mov     rcx, [rel p_circle]
    call    release_if_nonnull
    mov     qword [rel p_circle], 0

    mov     rcx, [rel p_rt]
    call    release_if_nonnull
    mov     qword [rel p_rt], 0

    mov     rcx, [rel p_factory]
    call    release_if_nonnull
    mov     qword [rel p_factory], 0

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
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128

    mov     qword [rbp - 8], 0
    xor     ecx, ecx
    call    GetModuleHandleW
    mov     [rbp - 8], rax

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
    mov     dword [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.pixelSize_width], 640
    mov     dword [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.pixelSize_height], 480

    mov     rcx, [rel p_factory]
    lea     rdx, [rel rt_props]
    lea     r8,  [rel hwnd_props]
    lea     r9,  [rel p_rt]
    COM_CALL rcx, D2D1_FACTORY_CREATE_HWND_RT
    test    eax, eax
    jnz     .fail_d2d

    ; ---- 三个纯色画刷：CreateSolidColorBrush(&color, NULL, &brush) ----
    mov     rcx, [rel p_rt]
    lea     rdx, [rel fill_color]
    xor     r8d, r8d                ; 不指定 opacity/transform
    lea     r9,  [rel p_fill]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH

    mov     rcx, [rel p_rt]
    lea     rdx, [rel stroke_color]
    xor     r8d, r8d
    lea     r9,  [rel p_stroke]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH

    mov     rcx, [rel p_rt]
    lea     rdx, [rel circle_color]
    xor     r8d, r8d
    lea     r9,  [rel p_circle]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH

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
