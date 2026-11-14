; ============================================================
; 第 17 章：Direct2D 工厂与 HwndRenderTarget
; 构建：make        产物：d2d_target.exe（GUI 子系统，只编译不运行）
; 第一次真正调用 COM 虚表：D2D1CreateFactory + CreateHwndRenderTarget
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

; ID2D1Factory 虚表槽位（d2d1.h:1635-1652）
%define FACTORY_CREATE_HWND_RENDER_TARGET 14
; ID2D1RenderTarget 虚表槽位（d2d1.h:947-1003）
%define RT_CLEAR                          47
%define RT_BEGIN_DRAW                     48
%define RT_END_DRAW                       49
; IUnknown
%define IUNKNOWN_RELEASE                  2

section .data
class_name:   WSTRZ "MasmLearnD2DTarget"
window_title: WSTRZ "x64 assembly - D2D render target"

; IID_ID2D1Factory = {06152247-6F50-465A-9245-118BFD3B6007}
iid_d2d1factory:
    db 0x47, 0x22, 0x15, 0x06, 0x50, 0x6F, 0x5A, 0x46
    db 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07

; D2D1_COLOR_F：r/g/b/a 都是 FLOAT
clear_color:
    istruc D2D1_COLOR_F
        at D2D1_COLOR_F.r, dd 0.12
        at D2D1_COLOR_F.g, dd 0.16
        at D2D1_COLOR_F.b, dd 0.22
        at D2D1_COLOR_F.a, dd 1.0
    iend

section .bss
wndclass:   resb WNDCLASSEXW_size
msg:        resb MSG_size
hwnd:       resq 1

rt_props:   resb D2D1_RENDER_TARGET_PROPERTIES_size        ; 28
hwnd_props: resb D2D1_HWND_RENDER_TARGET_PROPERTIES_size    ; 24

p_factory:  resq 1
p_rt:       resq 1

section .text

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

; ---- WM_PAINT：BeginDraw → Clear → EndDraw ----
.on_paint:
    mov     rax, [rel p_rt]
    test    rax, rax
    jz      .paint_done

    ; BeginDraw(this)
    mov     rcx, [rel p_rt]
    COM_CALL rcx, RT_BEGIN_DRAW

    ; Clear(this, &clear_color)
    mov     rcx, [rel p_rt]
    lea     rdx, [rel clear_color]
    COM_CALL rcx, RT_CLEAR

    ; EndDraw(this, NULL, NULL) -> HRESULT
    mov     rcx, [rel p_rt]
    xor     edx, edx
    xor     r8d, r8d
    COM_CALL rcx, RT_END_DRAW

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

; ---- WM_DESTROY：先释放 COM 对象，再退出消息循环 ----
.on_destroy:
    mov     rcx, [rel p_rt]
    test    rcx, rcx
    jz      .no_rt
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_rt], 0
.no_rt:
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
    mov     qword [rax + WNDCLASSEXW.hbrBackground], 0      ; D2D 自己清屏
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

    ; ---- D2D1CreateFactory(SINGLE_THREADED, &IID, NULL, &p_factory) ----
    xor     ecx, ecx
    lea     rdx, [rel iid_d2d1factory]
    xor     r8d, r8d
    lea     r9,  [rel p_factory]
    call    D2D1CreateFactory
    test    eax, eax
    jnz     .fail_d2d

    ; ---- 两个属性结构全 0 = D2D 默认配置 ----
    lea     rdi, [rel rt_props]
    xor     eax, eax
    mov     ecx, D2D1_RENDER_TARGET_PROPERTIES_size / 4      ; 7
    rep     stosd

    lea     rdi, [rel hwnd_props]
    xor     eax, eax
    mov     ecx, D2D1_HWND_RENDER_TARGET_PROPERTIES_size / 4 ; 6
    rep     stosd

    lea     rax, [rel hwnd_props]
    mov     rcx, [rel hwnd]
    mov     [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.hwnd], rcx
    mov     dword [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.pixelSize_width], 640
    mov     dword [rax + D2D1_HWND_RENDER_TARGET_PROPERTIES.pixelSize_height], 480

    ; ---- CreateHwndRenderTarget(this, &rt_props, &hwnd_props, &p_rt) ----
    mov     rcx, [rel p_factory]
    lea     rdx, [rel rt_props]
    lea     r8,  [rel hwnd_props]
    lea     r9,  [rel p_rt]
    COM_CALL rcx, FACTORY_CREATE_HWND_RENDER_TARGET
    test    eax, eax
    jnz     .fail_d2d

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
