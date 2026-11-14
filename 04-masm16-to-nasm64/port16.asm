; ============================================================
; 第 04 章：从 16 位 MASM 迁移到 NASM x64
;
; 本章程序把“16 位时代算 VGA 文本缓冲区地址”的写法，
; 原样翻译成 64 位 NASM，用退出码验证结果。
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l port16.lst -o port16.obj port16.asm
;   ld -o port16.exe port16.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
;
; 运行后退出码应为 234：
;   .\port16.exe
;   $LASTEXITCODE
; ============================================================

default rel

section .text
    global _start
    extern ExitProcess

_start:
    sub rsp, 40

    ; 16 位 MASM 常写成：mov ax, 0B800h
    ; NASM 十六进制写作 0xB800；但 64 位下段基址不再自动加，
    ; 所以这里直接使用线性地址 0xB8000。
    mov eax, 0xB8000

    ; 16 位：mov cx, 3 / mov ax, 80 / mul cx
    ; 64 位：三操作数 imul 更直接
    mov ecx, 3
    imul ecx, ecx, 80               ; 行号 * 每行 80 列
    add ecx, 5                      ; 列号 5
    shl ecx, 1                      ; 每个字符单元 2 字节

    ; 相加得到 0xB8000 + (3*80+5)*2 = 0xB81EA
    add eax, ecx

    ; 16 位时代常用 and al, 0Fh 之类的截断；
    ; 这里只保留低 8 位 → 0xEA
    and eax, 0xFF

    mov ecx, eax
    call ExitProcess                ; 退出码 234
