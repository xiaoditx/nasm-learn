; ============================================================
; 第 12 章：text.asm —— 文本统计模块
; 导出：void text_stats(wchar_t *buf, int chars, TEXT_STATS *out)
;   RCX = buf, EDX = 码元数, R8 = 结果结构体
; ============================================================
default rel
%include "../common.asm"

section .text
    global  text_stats

text_stats:
    mov     dword [r8 + TEXT_STATS.chars], edx
    mov     dword [r8 + TEXT_STATS.lines], 0
    mov     dword [r8 + TEXT_STATS.words], 0

    xor     r9d, r9d                ; i
    xor     r10d, r10d              ; in_word
.loop:
    cmp     r9d, edx
    jae     .done
    mov     r11w, word [rcx + r9*2]

    ; 行数：只数 LF，避免 CRLF 被算两次
    cmp     r11w, 10
    jne     .not_line
    inc     dword [r8 + TEXT_STATS.lines]
.not_line:
    ; 单词：分隔符之间的连续非分隔符算一个
    cmp     r11w, ' '
    je      .sep
    cmp     r11w, 9
    je      .sep
    cmp     r11w, 13
    je      .sep
    cmp     r11w, 10
    je      .sep

    test    r10d, r10d
    jnz     .next
    mov     r10d, 1
    inc     dword [r8 + TEXT_STATS.words]
    jmp     .next
.sep:
    xor     r10d, r10d
.next:
    inc     r9d
    jmp     .loop
.done:
    ret
