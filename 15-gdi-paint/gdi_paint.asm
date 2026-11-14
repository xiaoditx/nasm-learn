; ============================================================
; 第 15 章：GDI 绘制与 WM_PAINT
; 构建：make        产物：gdi_paint.exe（GUI 子系统，只编译不运行）
; 重点：BeginPaint/EndPaint 配对、CreateSolidBrush/DeleteObject 配对、
;       RBX 作为非易失寄存器必须保存与恢复
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
extern BeginPaint
extern EndPaint
extern SetBkMode
extern SetTextColor
extern TextOutW
extern CreateSolidBrush
extern DeleteObject
extern FillRect
extern FrameRect
extern GetClientRect
extern wsprintfW

global wmain

section .data
class_name:   WSTRZ "MasmLearnGdiPaint"
window_title: WSTRZ "x64 assembly - GDI paint"

banner:       WSTRZ "x64 assembly + GDI"
banner_len    equ ($ - banner) / 2 - 1        ; 去掉结尾的 0

hint:         WSTRZ "WM_PAINT -> BeginPaint -> TextOutW -> EndPaint"
hint_len      equ ($ - hint) / 2 - 1

nextline:     WSTRZ "Direct2D starts at chapter 17"
nextline_len  equ ($ - nextline) / 2 - 1

fmt_size:     WSTRZ "client: %d x %d"

section .bss
wndclass:    resb WNDCLASSEXW_size
msg:         resb MSG_size
ps:          resb PAINTSTRUCT_size
client_rect: resb RECT_size
info_buf:    resb 128
hwnd:        resq 1
g_width:     resd 1
g_height:    resd 1

section .text

; ------------------------------------------------------------
; WndProc(HWND rcx, UINT edx, WPARAM r8, LPARAM r9) -> LRESULT rax
;
; 本章序言用了 RBX，所以必须成对保存/恢复（非易失寄存器）：
;   入口 RSP%16==8
;   push rbp        -> %16==0
;   push rbx        -> %16==8
;   sub rsp,56      -> 8-56 = -48，%16==0   ← call 点对齐
; 56 = 32 影子 + 8 个栈参数 + 16 余量
; ------------------------------------------------------------
WndProc:
    push    rbp
    mov     rbp, rsp
    push    rbx                     ; 保存非易失寄存器
    sub     rsp, 56

    cmp     edx, WM_PAINT
    je      .on_paint
    cmp     edx, WM_SIZE
    je      .on_size
    cmp     edx, WM_KEYDOWN
    je      .on_keydown
    cmp     edx, WM_CLOSE
    je      .on_close
    cmp     edx, WM_DESTROY
    je      .on_destroy
    cmp     edx, WM_ERASEBKGND
    je      .on_erase

    call    DefWindowProcW
    jmp     .done

; ---- WM_SIZE：记录尺寸并请求重画 ----
.on_size:
    mov     eax, r9d
    movzx   ecx, ax
    mov     [rel g_width], ecx
    shr     eax, 16
    movzx   ecx, ax
    mov     [rel g_height], ecx

    mov     rcx, [rel hwnd]
    xor     edx, edx                ; 整个客户区
    mov     r8d, TRUE               ; 擦除背景后再画
    call    InvalidateRect
    xor     eax, eax
    jmp     .done

; ---- WM_KEYDOWN：ESC 退出 ----
.on_keydown:
    cmp     r8d, VK_ESCAPE
    jne     .key_other
    mov     rcx, [rel hwnd]
    call    DestroyWindow
.key_other:
    xor     eax, eax
    jmp     .done

.on_close:
    mov     rcx, [rel hwnd]
    call    DestroyWindow
    xor     eax, eax
    jmp     .done

.on_destroy:
    xor     ecx, ecx
    call    PostQuitMessage
    xor     eax, eax
    jmp     .done

.on_erase:
    mov     eax, 1                  ; 背景由 WM_PAINT 自己擦
    jmp     .done

; ---- WM_PAINT：GDI 绘制的主要战场 ----
.on_paint:
    ; HDC = BeginPaint(hwnd, &ps)
    mov     rcx, [rel hwnd]
    lea     rdx, [rel ps]
    call    BeginPaint
    mov     rbx, rax                ; HDC 放进 RBX（调用结束前必须还原 RBX）

    ; SetBkMode(hdc, TRANSPARENT)：文字背景透明
    mov     rcx, rbx
    mov     edx, TRANSPARENT
    call    SetBkMode

    ; SetTextColor(hdc, COLORREF)：COLORREF = 0x00BBGGRR
    mov     rcx, rbx
    mov     edx, 0x00C06020
    call    SetTextColor

    ; TextOutW(hdc, 24, 32, banner, banner_len)
    mov     rcx, rbx
    mov     edx, 24
    mov     r8d, 32
    lea     r9,  [rel banner]
    mov     qword [rsp + 32], banner_len
    call    TextOutW

    ; TextOutW(hdc, 24, 64, hint, hint_len)
    mov     rcx, rbx
    mov     edx, 24
    mov     r8d, 64
    lea     r9,  [rel hint]
    mov     qword [rsp + 32], hint_len
    call    TextOutW

    ; TextOutW(hdc, 24, 88, nextline, nextline_len)
    mov     rcx, rbx
    mov     edx, 24
    mov     r8d, 88
    lea     r9,  [rel nextline]
    mov     qword [rsp + 32], nextline_len
    call    TextOutW

    ; GetClientRect(hwnd, &client_rect)
    mov     rcx, [rel hwnd]
    lea     rdx, [rel client_rect]
    call    GetClientRect

    ; wsprintfW(info_buf, "client: %d x %d", right, bottom)
    lea     rcx, [rel info_buf]
    lea     rdx, [rel fmt_size]
    mov     r8d, [rel client_rect + RECT.right]
    mov     r9d, [rel client_rect + RECT.bottom]
    xor     eax, eax                ; 变参函数：AL = 0
    call    wsprintfW
    mov     [rbp - 24], eax         ; 返回的字符数

    ; TextOutW(hdc, 24, 120, info_buf, count)
    mov     rcx, rbx
    mov     edx, 24
    mov     r8d, 120
    lea     r9,  [rel info_buf]
    mov     eax, [rbp - 24]
    mov     qword [rsp + 32], rax
    call    TextOutW

    ; ---- 画笔矩形：CreateSolidBrush 必须 DeleteObject ----
    mov     ecx, 0x00D0E8F0         ; 浅色底
    call    CreateSolidBrush
    mov     [rbp - 16], rax         ; HBRUSH 放进本地槽

    mov     dword [rel client_rect + RECT.left],   24
    mov     dword [rel client_rect + RECT.top],    150
    mov     dword [rel client_rect + RECT.right],  324
    mov     dword [rel client_rect + RECT.bottom], 230

    ; FillRect(hdc, &rect, brush)
    mov     rcx, rbx
    lea     rdx, [rel client_rect]
    mov     r8, [rbp - 16]
    call    FillRect

    ; FrameRect(hdc, &rect, brush)
    mov     rcx, rbx
    lea     rdx, [rel client_rect]
    mov     r8, [rbp - 16]
    call    FrameRect

    ; DeleteObject(brush)
    mov     rcx, [rbp - 16]
    call    DeleteObject

    ; EndPaint(hwnd, &ps)：和 BeginPaint 必须成对
    mov     rcx, [rel hwnd]
    lea     rdx, [rel ps]
    call    EndPaint

    xor     eax, eax

.done:
    add     rsp, 56
    pop     rbx                     ; 恢复非易失寄存器
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
