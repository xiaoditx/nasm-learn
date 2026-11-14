; ============================================================
; 第 14 章：窗口过程与消息分发
; 构建：make        产物：winproc.exe（GUI 子系统，只编译不运行）
; 演示 WM_CREATE / WM_SIZE / WM_KEYDOWN / WM_CLOSE / WM_DESTROY / WM_PAINT
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
extern SetWindowTextW
extern wsprintfW
extern BeginPaint
extern EndPaint

global wmain

section .data
class_name:   WSTRZ "MasmLearnWinProc"
window_title: WSTRZ "x64 assembly - window procedure"
fmt_key:      WSTRZ "last key: 0x%04X"
fmt_size:     WSTRZ "client: %d x %d"

section .bss
wndclass:  resb WNDCLASSEXW_size
msg:       resb MSG_size
ps:        resb PAINTSTRUCT_size
hwnd:      resq 1
title_buf: resb 128                 ; SetWindowTextW 用的缓冲区
g_width:   resd 1
g_height:  resd 1
g_keys:    resd 1

section .text

; ------------------------------------------------------------
; WndProc(HWND rcx, UINT edx, WPARAM r8, LPARAM r9) -> LRESULT rax
;
; ABI 四件套在这里全部出现：
;   1) 参数 RCX/RDX/R8/R9
;   2) 32 字节影子空间
;   3) 入口 8、call 点 0 的 16 字节对齐
;   4) 非易失寄存器（本章改用全局变量，不占用 RBX/RDI/RSI）
; ------------------------------------------------------------
WndProc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP      ; 32 字节影子空间

    cmp     edx, WM_CREATE
    je      .on_create
    cmp     edx, WM_SIZE
    je      .on_size
    cmp     edx, WM_KEYDOWN
    je      .on_keydown
    cmp     edx, WM_CLOSE
    je      .on_close
    cmp     edx, WM_DESTROY
    je      .on_destroy
    cmp     edx, WM_PAINT
    je      .on_paint
    cmp     edx, WM_ERASEBKGND
    je      .on_erase

    call    DefWindowProcW
    leave
    ret

; ---- WM_CREATE：lParam 是 CREATESTRUCT*，本例只做计数 ----
.on_create:
    xor     eax, eax
    leave
    ret

; ---- WM_SIZE：lParam 低 16 位 = 宽，高 16 位 = 高 ----
.on_size:
    mov     eax, r9d
    movzx   ecx, ax                 ; LOWORD(lParam)
    mov     [rel g_width], ecx
    shr     eax, 16
    movzx   ecx, ax                 ; HIWORD(lParam)
    mov     [rel g_height], ecx
    xor     eax, eax
    leave
    ret

; ---- WM_KEYDOWN：wParam 是虚拟键码 ----
.on_keydown:
    cmp     r8d, VK_ESCAPE
    je      .escape

    inc     dword [rel g_keys]

    ; wsprintfW(buf, "last key: 0x%04X", wParam)：变参函数，AL 必须为 0
    lea     rcx, [rel title_buf]
    lea     rdx, [rel fmt_key]
    mov     r8d, r8d                ; wParam 已在 R8，这里只是强调来源
    xor     eax, eax
    call    wsprintfW

    ; SetWindowTextW(hwnd, buf)
    mov     rcx, [rel hwnd]
    lea     rdx, [rel title_buf]
    call    SetWindowTextW

    xor     eax, eax
    leave
    ret

.escape:
    ; 直接销毁窗口：系统随后发送 WM_DESTROY
    mov     rcx, [rel hwnd]
    call    DestroyWindow
    xor     eax, eax
    leave
    ret

; ---- WM_CLOSE：默认处理就是 DestroyWindow，这里显式写出来 ----
.on_close:
    mov     rcx, [rel hwnd]
    call    DestroyWindow
    xor     eax, eax
    leave
    ret

; ---- WM_DESTROY：投递 WM_QUIT，让 GetMessageW 返回 0 ----
.on_destroy:
    xor     ecx, ecx
    call    PostQuitMessage
    xor     eax, eax
    leave
    ret

; ---- WM_PAINT：本章只做 BeginPaint/EndPaint，把窗口标记为有效 ----
.on_paint:
    mov     rcx, [rel hwnd]
    lea     rdx, [rel ps]
    call    BeginPaint             ; 返回 HDC，本章不用

    mov     rcx, [rel hwnd]
    lea     rdx, [rel ps]
    call    EndPaint

    xor     eax, eax
    leave
    ret

; ---- WM_ERASEBKGND：返回 1 表示“背景我自己擦”，减少闪烁 ----
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
    mov     qword [rax + WNDCLASSEXW.hbrBackground], COLOR_WINDOW + 1
    lea     rcx, [rel class_name]
    mov     [rax + WNDCLASSEXW.lpszClassName], rcx

    ; LoadIconW(NULL, IDI_APPLICATION) / LoadCursorW(NULL, IDC_ARROW)
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
