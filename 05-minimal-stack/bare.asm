; ============================================================
; 第 05 章附：零依赖最小程序
;
; 不链接任何导入库，入口直接 ret 回系统线程启动代码。
; 这不是正式写法：退出码由系统接管，不受我们控制。
;
; 构建（在本目录下执行）：
;   nasm -f win64 -l bare.lst -o bare.obj bare.asm
;   ld -o bare.exe bare.obj --subsystem console --entry=_start
;
; 运行：
;   .\bare.exe
;   $LASTEXITCODE
; ============================================================

default rel

section .text
    global _start

_start:
    mov eax, 7              ; 只是把 7 留在 RAX；它不保证成为退出码
    ret                     ; 返回到 KERNEL32!BaseThreadInitThunk+20
