; ============================================================
; 第 22 章：无 CRT 的 GUI 窗口
; 构建：make        产物：win_nocrt.exe（GUI 子系统，只编译不运行）
; 入口 _start，ld 直连：-e _start --subsystem windows -luser32 -lkernel32
; ============================================================
%include "../common.asm"

default rel

extern GetModuleHandleW
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
extern ExitProcess

global _start

section .data
class_name:   WSTRZ "MasmLearnNoCrtWindow"
window_title: WSTRZ "x64 assembly - no CRT window"

section .bss
wndclass: resb WNDCLASSEXW_size
msg:      resb MSG_size
hwnd:     resq 1
hinst:    resq 1

section .text

; ------------------------------------------------------------
; WndProc(HWND rcx, UINT edx, WPARAM r8, LPARAM r9) -> LRESULT rax
; 被 DispatchMessageW 间接 call：入口 RSP%16==8
; push rbp 后 ==0；再减 32（16 的倍数）保持 ==0
; ------------------------------------------------------------
WndProc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP      ; 32 字节影子空间

    cmp     edx, WM_KEYDOWN
    je      .on_keydown
    cmp     edx, WM_DESTROY
    je      .on_destroy

    ; 其余消息一律交给系统默认处理
    call    DefWindowProcW
    leave
    ret

.on_keydown:
    cmp     r8d, VK_ESCAPE          ; ESC → 关窗口
    jne     .key_other
    mov     rcx, [rel hwnd]
    call    DestroyWindow
.key_other:
    xor     eax, eax
    leave
    ret

.on_destroy:
    xor     ecx, ecx                ; PostQuitMessage(0)
    call    PostQuitMessage
    xor     eax, eax
    leave
    ret

; ------------------------------------------------------------
; _start：进程真正入口，不是"被调用的函数"：
;   - RSP%16==8（如 CRT 时代的 main 一样，但这里没有 CRT 替我们对齐）
;   - RCX/RDX/R8/R9 没有任何参数约定（不是 WinMain 的 4 个参数！）
;   - 没有调用者，不能 ret，只能 ExitProcess
;
; 栈帧推导：CreateWindowExW 有 12 个参数，后 8 个走栈（[rsp+32]..[rsp+88]），
; 需要 32 影子 + 64 栈参 = 96 字节；入口 %16==8，再补 8 → sub rsp, 104。
; 104 % 16 == 8，所以减完后 RSP % 16 == 0，之后每个 call 点都对齐。
; ------------------------------------------------------------
_start:
    sub     rsp, 104                ; 32 影子 + 64 传出栈参 + 8 对齐

    ; hInstance = GetModuleHandleW(NULL)
    ; 没有 CRT 替我们保存"实例句柄"，自己拿、自己存
    xor     ecx, ecx
    call    GetModuleHandleW
    mov     [rel hinst], rax

    ; hCursor = LoadCursorW(NULL, IDC_ARROW)
    ; 第 13 章没设光标也能跑，但进入客户区会变回默认箭头前的"忙"态；
    ; 显式加载系统箭头光标是正规做法
    xor     ecx, ecx
    mov     edx, IDC_ARROW
    call    LoadCursorW
    mov     rbx, rax                ; _start 无调用者，RBX 随便用

    ; ---- wndclass 的 80 字节清零 ----
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
    mov     rcx, [rel hinst]
    mov     [rax + WNDCLASSEXW.hInstance], rcx
    mov     [rax + WNDCLASSEXW.hCursor], rbx
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
    mov     rax, [rel hinst]
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

    ; ---- 没有 CRT 替你"return 0"，进程只能由 ExitProcess 终结 ----
.done:
    xor     ecx, ecx                ; ExitProcess(0)
    call    ExitProcess

.fail_register:
    mov     ecx, 1                  ; ExitProcess(1)：注册窗口类失败
    call    ExitProcess

.fail_create:
    mov     ecx, 2                  ; ExitProcess(2)：创建窗口失败
    call    ExitProcess
