; ============================================================
; 第 01 章：寄存器全景
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l registers.lst -o registers.obj registers.asm
;   ld -o registers.exe registers.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
;
; 运行后退出码应为 63（6 项检查全部通过，位掩码 0x3F）：
;   .\registers.exe
;   $LASTEXITCODE
; ============================================================

default rel

section .text
    global _start
    extern ExitProcess

_start:
    ; Windows x64 入口：RSP % 16 == 8。
    ; sub rsp, 40 = 8 字节对齐 + 32 字节影子空间。
    sub rsp, 40

    xor r15d, r15d              ; R15D 作为 6 项检查的位掩码

    ; ---- 检查 1：写 32 位寄存器会清零高 32 位 ----
    mov rax, 0xFFFFFFFFFFFFFFFF
    mov eax, 0x12345678         ; 高 32 位自动清零
    cmp rax, 0x12345678
    jne .c1
    or r15d, 1
.c1:

    ; ---- 检查 2：8 位子寄存器只改最低字节 ----
    mov rax, 0x1122334455667788
    mov al, 0x99                ; 只改 AL
    mov rbx, 0x1122334455667799
    cmp rax, rbx
    jne .c2
    or r15d, 2
.c2:

    ; ---- 检查 3：movzx 零扩展 ----
    mov al, 0x80
    movzx ecx, al               ; 0x80，而不是 0xFFFFFF80
    cmp ecx, 0x80
    jne .c3
    or r15d, 4
.c3:

    ; ---- 检查 4：movsx 符号扩展 ----
    mov al, 0x80
    movsx edx, al               ; 0xFFFFFF80 == -128
    cmp edx, 0xFFFFFF80
    jne .c4
    or r15d, 8
.c4:

    ; ---- 检查 5：xchg 交换两个寄存器 ----
    mov eax, 0x11111111
    mov ebx, 0x22222222
    xchg eax, ebx
    cmp eax, 0x22222222
    jne .c5
    or r15d, 16
.c5:

    ; ---- 检查 6：R8 / R8D / R8W / R8B 命名 ----
    mov r8, 0x1122334455667788
    mov r8d, 0x99AABBCC         ; 高 32 位被清零
    mov r9, 0x0000000099AABBCC
    cmp r8, r9
    jne .c6
    or r15d, 32
.c6:

    ; 退出码 = 位掩码。全部通过时 1|2|4|8|16|32 = 63。
    mov ecx, r15d
    call ExitProcess            ; 不返回
