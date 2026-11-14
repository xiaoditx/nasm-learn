; ============================================================
; 第 21 章：ld 直接链接 —— 连 gcc 驱动也拿掉
; 构建：make        产物：lddirect.exe（控制台子系统，实际运行）
; 内容：
;   1. 功能与第 20 章相同：_start + GetCommandLineW + WriteConsoleW
;   2. 链接不再经过 gcc 驱动，直接调用 ld：
;        ld -e _start --subsystem console -o lddirect.exe lddirect.obj \
;           -L C:/msys64/ucrt64/lib -lkernel32
;   3. 观察 gcc 驱动原来替我们拼了多少参数（gcc -###）
;   4. objdump -p 看 PE 头：入口点 / 子系统 / 导入表
; ============================================================
%include "../common.asm"

default rel

extern GetStdHandle
extern GetCommandLineW
extern WriteConsoleW
extern ExitProcess

global _start

section .data
msg_cmd:      WSTR "cmdline: "
msg_cmd_len   equ ($ - msg_cmd) / WCHAR_SIZE
msg_hello:    WSTR "hello from _start (linked by ld directly)"
msg_hello_len equ ($ - msg_hello) / WCHAR_SIZE
msg_nl:       dw 13, 10

section .bss
written:      resd 1

section .text

_start:
    sub     rsp, ENTRY_SUB_RSP      ; 40 = 32 影子 + 8，减完 RSP%16==0

    mov     ecx, STD_OUTPUT_HANDLE
    call    GetStdHandle
    mov     rbx, rax

    ; ---- "cmdline: " ----
    mov     rcx, rbx
    lea     rdx, [msg_cmd]
    mov     r8d, msg_cmd_len
    lea     r9, [written]
    mov     qword [rsp + 32], 0
    call    WriteConsoleW

    ; ---- GetCommandLineW + 内联 wcslen ----
    call    GetCommandLineW
    mov     rsi, rax
    xor     edx, edx
.len_loop:
    cmp     word [rsi + rdx*2], 0
    je      .len_done
    inc     rdx
    jmp     .len_loop
.len_done:

    mov     r8, rdx
    mov     rdx, rsi
    mov     rcx, rbx
    lea     r9, [written]
    mov     qword [rsp + 32], 0
    call    WriteConsoleW

    ; ---- 换行 ----
    mov     rcx, rbx
    lea     rdx, [msg_nl]
    mov     r8d, 2
    lea     r9, [written]
    mov     qword [rsp + 32], 0
    call    WriteConsoleW

    ; ---- "hello from _start (linked by ld directly)" + 换行 ----
    mov     rcx, rbx
    lea     rdx, [msg_hello]
    mov     r8d, msg_hello_len
    lea     r9, [written]
    mov     qword [rsp + 32], 0
    call    WriteConsoleW

    mov     rcx, rbx
    lea     rdx, [msg_nl]
    mov     r8d, 2
    lea     r9, [written]
    mov     qword [rsp + 32], 0
    call    WriteConsoleW

    ; ---- ExitProcess(21) ----
    mov     ecx, 21
    call    ExitProcess
