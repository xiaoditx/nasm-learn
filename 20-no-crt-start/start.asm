; ============================================================
; 第 20 章：_start 入口 —— 摆脱 CRT 的第一步
; 构建：make        产物：start.exe（控制台子系统，实际运行）
; 内容：
;   1. 入口改为 _start（不再使用 wmainCRTStartup 提供的 wmain）
;   2. _start 没有 argc/argv，命令行要用 GetCommandLineW 自己取
;   3. 输出不再经过 CRT 的 wprintf，直接 WriteConsoleW
;   4. 结束必须显式 ExitProcess（裸 ret 会挂起，见第 05 章）
;   5. 链接：gcc -nostartfiles -Wl,-e,_start（去掉 CRT 启动文件）
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
msg_hello:    WSTR "hello from _start (no CRT startup)"
msg_hello_len equ ($ - msg_hello) / WCHAR_SIZE
msg_nl:       dw 13, 10

section .bss
written:      resd 1

section .text

; ------------------------------------------------------------
; _start：PE 入口点
; 与 wmain 的本质区别：
;   - 没有人给我们准备 argc/argv/envp，寄存器内容无约定
;   - 入口时 RSP % 16 == 8（call 我们的代码压了返回地址）
;   - 从这里 ret 出去不会正常退出，必须 ExitProcess
; ------------------------------------------------------------
_start:
    sub     rsp, ENTRY_SUB_RSP      ; 40 = 32 影子 + 8，减完 RSP%16==0

    ; rbx 存控制台句柄；_start 是入口、无人要求我们恢复非易失寄存器
    mov     ecx, STD_OUTPUT_HANDLE
    call    GetStdHandle
    mov     rbx, rax

    ; ---- WriteConsoleW(rbx, msg_cmd, msg_cmd_len, &written, NULL) ----
    mov     rcx, rbx
    lea     rdx, [msg_cmd]
    mov     r8d, msg_cmd_len
    lea     r9, [written]
    mov     qword [rsp + 32], 0     ; 第 5 参数 lpReserved = NULL
    call    WriteConsoleW

    ; ---- 自取命令行：GetCommandLineW() → LPWSTR（带程序名） ----
    call    GetCommandLineW
    mov     rsi, rax                ; rsi = 命令行字符串首地址

    ; 内联 wcslen：统计到第一个 0 码元为止
    xor     edx, edx
.len_loop:
    cmp     word [rsi + rdx*2], 0
    je      .len_done
    inc     rdx
    jmp     .len_loop
.len_done:

    ; ---- WriteConsoleW(rbx, rsi, len, &written, NULL) ----
    mov     r8, rdx                 ; r8d = 长度（码元数）
    mov     rdx, rsi                ; rdx = 缓冲区
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

    ; ---- "hello from _start" + 换行 ----
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

    ; ---- 收尾：ExitProcess(42)，退出码 42 供 $LASTEXITCODE 验证 ----
    mov     ecx, 42
    call    ExitProcess
    ; 不会返回
