; ============================================================
; 第 10 章：UTF-16 字符串处理
; 演示：长度、ASCII 大小写转换、单词计数、逐码元打印
; 运行：.\strings.exe
; 注意：UTF-16 的一个“码元”是 2 字节；BMP 内一个汉字占 1 个码元。
; ============================================================
default rel
%include "../common.asm"

section .rdata
    sample:         WSTR "x64 assembly 汇编"
    sample_len      equ ($ - sample) / WCHAR_SIZE
                    dw 0

    sample_ascii:   WSTR "x64 assembly"
                    dw 0
    words_text:     WSTR "one two three four"
    words_len       equ ($ - words_text) / WCHAR_SIZE
                    dw 0

    fmt_len:    WSTR "length of sample = %d WCHAR units"
                dw 10, 0
    fmt_upper:  WSTR "uppercase = %ls"
                dw 10, 0
    fmt_words:  WSTR "words = %d"
                dw 10, 0
    fmt_code:   WSTRZ "U+%04X "
    fmt_nl:     dw 10, 0
    msg_codes:  WSTR "code units: "
                dw 0

section .bss
    upper_buf:  resw 64

section .text
    global  wmain
    extern  wprintf

; ------------------------------------------------------------
; size_t wlen(wchar_t *s)
;   RCX = 字符串地址；返回 EAX = 码元个数
; ------------------------------------------------------------
wlen:
    xor     eax, eax
.loop:
    cmp     word [rcx + rax*2], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

; ------------------------------------------------------------
; void ascii_upper(wchar_t *src, wchar_t *dst)
;   RCX = 源，RDX = 目标；只转换 ASCII 的 a~z
;   RSI / RDI 是非易失寄存器，必须保存
; ------------------------------------------------------------
ascii_upper:
    push    rsi
    push    rdi
    mov     rsi, rcx
    mov     rdi, rdx
.loop:
    mov     ax, word [rsi]
    test    ax, ax
    jz      .done
    cmp     ax, 'a'
    jb      .store
    cmp     ax, 'z'
    ja      .store
    sub     ax, 32
.store:
    mov     word [rdi], ax
    add     rsi, WCHAR_SIZE
    add     rdi, WCHAR_SIZE
    jmp     .loop
.done:
    mov     word [rdi], 0
    pop     rdi
    pop     rsi
    ret

; ------------------------------------------------------------
; int count_words(wchar_t *s, int len)
;   RCX = 字符串，EDX = 码元数；返回 EAX = 单词数
;   分隔符：空格、TAB、CR、LF
; ------------------------------------------------------------
count_words:
    xor     eax, eax                ; 单词数
    xor     r8d, r8d                ; in_word
    xor     r9d, r9d                ; i
.loop:
    cmp     r9d, edx
    jae     .done
    mov     r10w, word [rcx + r9*2]

    cmp     r10w, ' '
    je      .sep
    cmp     r10w, 9
    je      .sep
    cmp     r10w, 13
    je      .sep
    cmp     r10w, 10
    je      .sep

    test    r8d, r8d
    jnz     .next
    mov     r8d, 1
    inc     eax
    jmp     .next
.sep:
    xor     r8d, r8d
.next:
    inc     r9d
    jmp     .loop
.done:
    ret

; ------------------------------------------------------------
; int wmain(int argc, wchar_t **argv)
; ------------------------------------------------------------
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64

    lea     rcx, [rel sample]
    call    wlen
    mov     dword [rbp - 4], eax    ; 保存长度

    lea     rcx, [rel fmt_len]
    mov     edx, dword [rbp - 4]
    xor     eax, eax
    call    wprintf

; ---------- ASCII 大小写 ----------
    lea     rcx, [rel sample_ascii]
    lea     rdx, [rel upper_buf]
    call    ascii_upper

    lea     rcx, [rel fmt_upper]
    lea     rdx, [rel upper_buf]
    xor     eax, eax
    call    wprintf

; ---------- 单词计数 ----------
    lea     rcx, [rel words_text]
    mov     edx, words_len
    call    count_words

    lea     rcx, [rel fmt_words]
    mov     edx, eax
    xor     eax, eax
    call    wprintf

; ---------- 逐码元打印 ----------
    lea     rcx, [rel msg_codes]
    xor     eax, eax
    call    wprintf

    lea     rax, [rel sample]
    mov     qword [rbp - 16], rax   ; 基址
    mov     dword [rbp - 8], 0      ; i
.code_loop:
    mov     eax, dword [rbp - 8]
    cmp     eax, dword [rbp - 4]
    jge     .codes_done

    mov     r8, qword [rbp - 16]
    movzx   edx, word [r8 + rax*2]
    lea     rcx, [rel fmt_code]
    xor     eax, eax
    call    wprintf

    inc     dword [rbp - 8]
    jmp     .code_loop
.codes_done:
    lea     rcx, [rel fmt_nl]
    xor     eax, eax
    call    wprintf

    xor     eax, eax
    leave
    ret
