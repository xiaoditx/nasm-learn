; ============================================================
; 第 03 章：常用指令、循环与自检
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l instructions.lst -o instructions.obj instructions.asm
;   ld -o instructions.exe instructions.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
;
; 退出码 0 表示 6 项自检全部通过；非 0 是失败项的位掩码。
;   .\instructions.exe
;   $LASTEXITCODE
; ============================================================

default rel

section .data
    arr       dq  1, 2, 3, 4, 5, 6, 7, 8, 9, 10
    ARR_LEN   equ 10
    text      db  'hello', 0

section .text
    global _start
    extern ExitProcess

_start:
    sub rsp, 40

    xor r15d, r15d                  ; 位掩码：哪一项失败就置对应位

    ; ---- 自检 1：循环求和（rdx 作下标，rax 作累加器）----
    lea rsi, [rel arr]
    mov ecx, ARR_LEN
    xor eax, eax
    xor edx, edx
.sum_loop:
    add rax, [rsi + rdx*8]
    inc rdx
    cmp rdx, rcx
    jb .sum_loop
    cmp rax, 55
    je .c1
    or r15d, 1
.c1:

    ; ---- 自检 2：扫描字符串求长度 ----
    lea rsi, [rel text]
    xor eax, eax
.len_loop:
    cmp byte [rsi + rax], 0
    je .len_done
    inc eax
    jmp .len_loop
.len_done:
    cmp eax, 5
    je .c2
    or r15d, 2
.c2:

    ; ---- 自检 3：imul 三操作数形式 7 * 6 ----
    mov eax, 7
    imul eax, eax, 6
    cmp eax, 42
    je .c3
    or r15d, 4
.c3:

    ; ---- 自检 4：div 无符号除法 42 / 6 ----
    mov eax, 42
    xor edx, edx                    ; 被除数高 32 位必须清零
    mov ecx, 6
    div ecx                         ; eax = 商, edx = 余数
    cmp eax, 7
    jne .fail4
    cmp edx, 0
    je .c4
.fail4:
    or r15d, 8
.c4:

    ; ---- 自检 5：test + jcc 判奇偶 ----
    mov eax, 42
    test eax, 1                     ; 只影响标志位，不改 eax
    jz .c5                          ; 偶数才通过；奇数置失败位
    or r15d, 16
.c5:

    ; ---- 自检 6：call / ret 调用本地函数 ----
    lea rcx, [rel arr]
    mov edx, ARR_LEN
    call sum_qwords
    cmp rax, 55
    je .c6
    or r15d, 32
.c6:

    mov ecx, r15d
    call ExitProcess                ; 全部通过时退出码 0

; ------------------------------------------------------------
; sum_qwords：求 qword 数组之和
;   入口：RCX = 数组首地址，RDX = 元素个数
;   返回：RAX = 总和
; 入口 RSP % 16 == 8；序言后 RSP % 16 == 0。
; 本函数不再调用其它函数，32 字节空间同时作为影子空间与本地存储。
; ------------------------------------------------------------
sum_qwords:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    xor eax, eax
    xor r8d, r8d
.loop:
    add rax, [rcx + r8*8]
    inc r8
    cmp r8, rdx
    jb .loop

    leave                           ; mov rsp, rbp; pop rbp
    ret
