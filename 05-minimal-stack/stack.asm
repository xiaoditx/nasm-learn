; ============================================================
; 第 05 章：栈、栈帧与 call/ret
;
; 用递归阶乘演示：
;   - 每次 call 把返回地址压栈，RSP 减 8
;   - 标准栈帧 push rbp / mov rbp,rsp / sub rsp,32
;   - ret 从栈顶弹出返回地址
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l stack.lst -o stack.obj stack.asm
;   ld -o stack.exe stack.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
;
; 运行后退出码应为 120（5! = 120）：
;   .\stack.exe
;   $LASTEXITCODE
; ============================================================

default rel

section .text
    global _start
    extern ExitProcess

_start:
    sub rsp, 40                     ; 入口 RSP%16==8 → 40 后 %16==0

    mov ecx, 5                      ; fact(5)
    call fact
    ; 此时 RAX = 120

    mov ecx, eax
    call ExitProcess                ; 退出码 120

; ------------------------------------------------------------
; fact：n!（n 在 ECX 中，结果在 EAX 中）
;
; 入口：RSP % 16 == 8（call 压入 8 字节返回地址）
; 序言：push rbp      → RSP % 16 == 0
;       mov rbp, rsp
;       sub rsp, 32   → 影子空间 + 本地槽，仍 % 16 == 0
; 这样函数体内再 call 时，call 指令执行处 RSP % 16 == 0，符合 ABI。
; ------------------------------------------------------------
fact:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    mov [rbp - 4], ecx              ; 本地槽保存 n（递归调用会覆盖 ECX）

    cmp ecx, 1
    jle .base

    lea ecx, [rcx - 1]              ; n - 1
    call fact                       ; 递归
    mov ecx, [rbp - 4]              ; 恢复 n
    imul eax, ecx                   ; (n-1)! * n
    jmp .done

.base:
    mov eax, 1

.done:
    leave                           ; mov rsp, rbp; pop rbp
    ret                             ; 弹出返回地址，回到调用点
