; ============================================================
; 第 12 章：main.asm —— 多文件控制台综合
; 流程：写文件 → 读回 → 统计字符/行/单词 → 打印并自检
; 运行：.\capstone.exe
; ============================================================
default rel
%include "../common.asm"

section .rdata
    path:   WSTRZ "capstone.txt"

    content:
        WSTR "first line"
        dw 13, 10
        WSTR "second line"
        dw 13, 10
        WSTR "third line"
        dw 13, 10
    content_chars equ ($ - content) / WCHAR_SIZE
    content_bytes equ content_chars * WCHAR_SIZE

    fmt_write:  WSTR "io_write_file: %d bytes"
                dw 10, 0
    fmt_read:   WSTR "io_read_file : %d bytes"
                dw 10, 0
    fmt_stats:  WSTR "text_stats   : chars=%d lines=%d words=%d"
                dw 10, 0
    fmt_fail:   WSTR "operation failed"
                dw 10, 0
    fmt_bad:    WSTR "self-check FAILED"
                dw 10, 0
    fmt_ok:     WSTR "self-check OK"
                dw 10, 0

section .bss
    read_buf:   resb 512
    stats:      resb TEXT_STATS_size

section .text
    global  wmain
    extern  wprintf
    extern  io_write_file
    extern  io_read_file
    extern  text_stats

wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128

; ---------- 1. 写文件 ----------
    lea     rcx, [rel path]
    lea     rdx, [rel content]
    mov     r8d, content_bytes
    call    io_write_file
    test    eax, eax
    jz      .fail
    mov     dword [rbp - 8], eax

    lea     rcx, [rel fmt_write]
    mov     edx, content_bytes
    xor     eax, eax
    call    wprintf

; ---------- 2. 读回 ----------
    lea     rcx, [rel path]
    lea     rdx, [rel read_buf]
    mov     r8d, 512
    call    io_read_file
    test    eax, eax
    jle     .fail
    mov     dword [rbp - 12], eax

    lea     rcx, [rel fmt_read]
    mov     edx, dword [rbp - 12]
    xor     eax, eax
    call    wprintf

; ---------- 3. 统计 ----------
    mov     eax, dword [rbp - 12]
    shr     eax, 1                  ; 字节数 → UTF-16 码元数
    mov     dword [rbp - 16], eax

    lea     rcx, [rel read_buf]
    mov     edx, eax
    lea     r8, [rel stats]
    call    text_stats

    lea     rcx, [rel fmt_stats]
    mov     edx, dword [rel stats + TEXT_STATS.chars]
    mov     r8d, dword [rel stats + TEXT_STATS.lines]
    mov     r9d, dword [rel stats + TEXT_STATS.words]
    xor     eax, eax
    call    wprintf

; ---------- 4. 自检 ----------
    cmp     dword [rel stats + TEXT_STATS.chars], 37
    jne     .bad
    cmp     dword [rel stats + TEXT_STATS.lines], 3
    jne     .bad
    cmp     dword [rel stats + TEXT_STATS.words], 6
    jne     .bad

    lea     rcx, [rel fmt_ok]
    xor     eax, eax
    call    wprintf
    xor     eax, eax
    leave
    ret

.bad:
    lea     rcx, [rel fmt_bad]
    xor     eax, eax
    call    wprintf
    mov     eax, 1
    leave
    ret

.fail:
    lea     rcx, [rel fmt_fail]
    xor     eax, eax
    call    wprintf
    mov     eax, 2
    leave
    ret
