; ============================================================
; 第 13 章：最小 Win32 窗口
; 构建：make        产物：firstwindow.exe（GUI 子系统）
; 本章只编译，不运行；运行会弹出窗口并阻塞在消息循环里。
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
extern GetModuleHandleW

global wmain

section .data
class_name:   WSTRZ "MasmLearnFirstWindow"
window_title: WSTRZ "x64 assembly - first window"

section .bss
wndclass: resb WNDCLASSEXW_size
msg:      resb MSG_size
hwnd:     resq 1

section .text

; ------------------------------------------------------------
; WndProc(HWND rcx, UINT edx, WPARAM r8, LPARAM r9) -> LRESULT rax
; 入口 RSP%16==8；push rbp 后 0；sub rsp,32 后仍是 0（32 是 16 的倍数）
; ------------------------------------------------------------
WndProc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP      ; 32 字节影子空间

    cmp     edx, WM_DESTROY
    je      .on_destroy

    ; 其余消息一律交给系统默认处理
    call    DefWindowProcW
    leave
    ret

.on_destroy:
    xor     ecx, ecx                ; PostQuitMessage(0)
    call    PostQuitMessage
    xor     eax, eax                ; WM_DESTROY 处理完返回 0
    leave
    ret

; ------------------------------------------------------------
; wmain：注册窗口类 → 创建窗口 → 显示 → 消息循环
; ------------------------------------------------------------
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128                ; 32 影子 + 64 传出栈参 + 32 本地槽

    mov     qword [rbp - 8], 0      ; [rbp-8] = hInstance

    ; hInstance = GetModuleHandleW(NULL)
    xor     ecx, ecx
    call    GetModuleHandleW
    mov     [rbp - 8], rax

    ; ---- 把 wndclass 的 80 字节清零 ----
    lea     rdi, [rel wndclass]
    xor     eax, eax
    mov     ecx, WNDCLASSEXW_size / 4    ; 20 个 dword
    rep     stosd

    ; ---- 填 WNDCLASSEXW ----
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

    ; ---- RegisterClassExW(&wndclass) ----
    lea     rcx, [rel wndclass]
    call    RegisterClassExW
    test    eax, eax
    jz      .fail_register

    ; ---- CreateWindowExW：12 个参数，后 8 个走栈 ----
    xor     ecx, ecx                    ; dwExStyle
    lea     rdx, [rel class_name]       ; lpClassName
    lea     r8,  [rel window_title]     ; lpWindowName
    mov     r9d, WS_OVERLAPPEDWINDOW    ; dwStyle

    mov     eax, CW_USEDEFAULT
    mov     qword [rsp + 32], rax       ; X
    mov     qword [rsp + 40], rax       ; Y
    mov     qword [rsp + 48], 640       ; nWidth
    mov     qword [rsp + 56], 480       ; nHeight
    mov     qword [rsp + 64], 0         ; hWndParent
    mov     qword [rsp + 72], 0         ; hMenu
    mov     rax, [rbp - 8]
    mov     qword [rsp + 80], rax       ; hInstance
    mov     qword [rsp + 88], 0         ; lpParam
    call    CreateWindowExW
    test    rax, rax
    jz      .fail_create
    mov     [rel hwnd], rax

    ; ---- ShowWindow + UpdateWindow ----
    mov     rcx, [rel hwnd]
    mov     edx, SW_SHOWNORMAL
    call    ShowWindow

    mov     rcx, [rel hwnd]
    call    UpdateWindow

    ; ---- 消息循环 ----
.msg_loop:
    lea     rcx, [rel msg]
    xor     edx, edx                ; hWnd = NULL：取本线程所有消息
    xor     r8d, r8d                ; wMsgFilterMin
    xor     r9d, r9d                ; wMsgFilterMax
    call    GetMessageW
    test    eax, eax
    jz      .done                   ; 0 = WM_QUIT
    js      .done                   ; 负数 = -1，出错也退出

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
