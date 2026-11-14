; ============================================================
; 第 02 章：数据定义与内存布局
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l layout.lst -o layout.obj layout.asm
;   ld -o layout.exe layout.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
;
; 运行后退出码为校验和（见 README 的逐项计算，应为 220）：
;   .\layout.exe
;   $LASTEXITCODE
; ============================================================

default rel

section .data
    val8      db  0x56                  ; 1 字节
    val16     dw  0x1234                ; 2 字节
    val32     dd  0xDEADBEEF            ; 4 字节
    align 8
    val64     dq  0x1122334455667788    ; 8 字节
    msg       db  'NASM', 0             ; 5 字节：4 个字符 + 结束符
    MSG_LEN   equ 4                     ; equ 不占空间，编译期常量
    times 3   db  0xAA                  ; 填充 3 字节，验证 times

section .bss
    bss8      resb 1                    ; 保留 1 字节
    bss16     resw 1                    ; 保留 1 字（2 字节）
    bss32     resd 1                    ; 保留 1 双字（4 字节）
    bss64     resq 1                    ; 保留 1 四字（8 字节）

section .text
    global _start
    extern ExitProcess

_start:
    sub rsp, 40

    ; ---- 按各自宽度读取，累加成校验和 ----
    movzx eax, byte [rel val8]      ; 0x56
    movzx ecx, word [rel val16]     ; 0x1234
    add eax, ecx                    ; 0x128A

    mov ecx, [rel val32]            ; 0xDEADBEEF
    xor eax, ecx                    ; 0xDEADAC65

    xor eax, [rel val64]            ; 低 32 位 0x55667788
                                    ; 0x8BCBDBED

    movzx ecx, byte [rel val32]     ; 小端：最低字节是 0xEF
    add eax, ecx                    ; 0x8BCBDCDC

    mov ecx, [rel bss32]            ; .bss 加载时清零
    add eax, ecx                    ; 不变

    and eax, 0xFF                   ; 只留低 8 位 → 0xDC
    mov ecx, eax
    call ExitProcess                ; 退出码 220
