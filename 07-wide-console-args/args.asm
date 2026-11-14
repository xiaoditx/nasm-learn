; ============================================================
; 第 07 章：wmain 的 argc / argv（宽字符参数表）
; 运行：.\args.exe alpha beta "two words"
; 说明：argv 是 wchar_t* 数组，每个元素指向一个 UTF-16 字符串。
; ============================================================
default rel
%include "../common.asm"

section .rdata
    fmt_argc:   WSTR "argc = %d"
                dw 10, 0
    fmt_argv:   WSTR "argv[%d] @ %p = %ls"
                dw 10, 0

section .text
    global  wmain
    extern  wprintf

; int wmain(int argc, wchar_t **argv)
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64                 ; 32 影子空间 + 32 字节本地槽

    mov     dword [rbp - 4], ecx    ; argc
    mov     qword [rbp - 16], rdx   ; argv
    mov     dword [rbp - 20], 0     ; i

    lea     rcx, [rel fmt_argc]
    mov     edx, dword [rbp - 4]
    xor     eax, eax
    call    wprintf

.loop:
    mov     eax, dword [rbp - 20]   ; i
    cmp     eax, dword [rbp - 4]    ; i >= argc ?
    jge     .done

    mov     r8, qword [rbp - 16]    ; r8 = argv
    mov     r8, qword [r8 + rax*8]  ; r8 = argv[i]
    mov     r9, r8                  ; r9 = argv[i]（作为 %ls 的字符串）

    mov     edx, eax                ; %d = i
    lea     rcx, [rel fmt_argv]
    xor     eax, eax
    call    wprintf

    inc     dword [rbp - 20]
    jmp     .loop

.done:
    xor     eax, eax                ; 退出码 0
    leave
    ret
