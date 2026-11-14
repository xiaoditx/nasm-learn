; ============================================================
; 第 00 章：NASM 源码骨架与第一个裸 PE
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l hello.lst -o hello.obj hello.asm
;   ld -o hello.exe hello.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
;
; 运行后退出码应为 42：
;   .\hello.exe
;   $LASTEXITCODE
; ============================================================

; 默认使用 RIP 相对寻址：x64 中写 [magic] 比 [rel magic] 更安全，
; 避免链接器生成 32 位绝对地址重定位。
default rel

section .data
    ; 已初始化的数据段：8 字节常量
    magic dq 0x1122334455667788

section .bss
    ; 未初始化的数据段：1 个 8 字节槽位，加载时清零
    slot resq 1

section .text
    ; 把 _start 导出为链接器可见的入口符号
    global _start

    ; 从 kernel32.dll 导入 ExitProcess（函数跳板由 libkernel32.a 提供）
    extern ExitProcess

_start:
    ; Windows x64 进程入口：RSP % 16 == 8，栈顶是系统返回地址。
    ; 调用外部函数前，先留出：
    ;   8 字节  —— 把入口的 8 对齐到 16
    ;   32 字节 —— Windows x64 的影子空间
    ; 合计 40 字节。
    sub rsp, 40

    ; 演示 .data -> 寄存器 -> .bss 的读写
    mov rax, [rel magic]        ; 从 .data 读 8 字节
    mov [rel slot], rax         ; 写入 .bss

    ; ExitProcess(UINT uExitCode)
    ; 第 1 个参数走 ECX；写 ECX 会自动把 RCX 高 32 位清零。
    mov ecx, 42
    call ExitProcess            ; 不返回

    ; ExitProcess 正常不会返回；这里只是防御性收尾。
    add rsp, 40
    xor eax, eax
    ret
