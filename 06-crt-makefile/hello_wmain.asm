; ============================================================
; 第 06 章：wmain + 宽字符 CRT + 第一套 Makefile
; 构建：make          （nasm -f win64 -l hello_wmain.obj.lst -o ...）
; 运行：.\hello_wmain.exe alpha beta
; ============================================================
default rel
%include "../common.asm"

section .rdata
    msg_args:   WSTR "wmain received %d argument(s)"
                dw 10, 0
    msg_hello:  WSTR "hello from wmain"
                dw 10, 0
    msg_tail:   WSTR "built with nasm + gcc, wide API by default"
                dw 10, 0

section .text
    global  wmain
    extern  wprintf

; int wmain(int argc, wchar_t **argv)
;   ECX = argc, RDX = argv
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP      ; 32 字节影子空间

    ; 先打印 argc：此时 ECX 还是原值，没有经过任何 call
    mov     edx, ecx
    lea     rcx, [rel msg_args]
    xor     eax, eax                ; 变参函数要求 AL = 0（无浮点参数）
    call    wprintf

    lea     rcx, [rel msg_hello]
    xor     eax, eax
    call    wprintf

    lea     rcx, [rel msg_tail]
    xor     eax, eax
    call    wprintf

    xor     eax, eax                ; wmain 的返回值就是进程退出码
    leave
    ret
