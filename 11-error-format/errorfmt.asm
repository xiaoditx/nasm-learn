; ============================================================
; 第 11 章：错误码与格式化 —— GetLastError + FormatMessageW
; 演示：打开一个不存在的文件 → 取错误码 → 取系统错误文本 → UTF-8 输出
; 运行：.\errorfmt.exe
; 重点：FormatMessageW 有 7 个参数，后 3 个必须放在栈上。
; ============================================================
default rel
%include "../common.asm"

section .rdata
    filename:   WSTRZ "no_such_file.txt"

    fmt_handle: WSTR "CreateFileW returned %p"
                dw 10, 0
    fmt_err:    WSTR "GetLastError() = %lu"
                dw 10, 0
    fmt_chars:  WSTR "FormatMessageW() = %lu chars"
                dw 10, 0
    fmt_fail:   WSTR "FormatMessageW failed, error=%lu"
                dw 10, 0
    fmt_nl:     dw 10, 0
    msg_text:   WSTR "system message: "
                dw 0

section .bss
    msg_buf:    resw 512            ; 系统错误文本（UTF-16）
    utf8_buf:   resb 1024           ; 转成 UTF-8 后写标准输出

section .text
    global  wmain
    extern  wprintf
    extern  CreateFileW
    extern  GetLastError
    extern  FormatMessageW
    extern  WideCharToMultiByte
    extern  GetStdHandle
    extern  WriteFile
    extern  fflush

; ------------------------------------------------------------
; void print_utf8(wchar_t *s, int chars)
;   RCX = 宽字符串，EDX = 码元数
;   用 WideCharToMultiByte(CP_UTF8) 转码后，直接 WriteFile 到 stdout。
;   （PowerShell 管道不是控制台句柄，WriteConsoleW 会失败；WriteFile 可靠。）
; ------------------------------------------------------------
print_utf8:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 96                 ; 32 影子 + 4 个栈参数 + 本地槽

    mov     qword [rbp - 8], rcx    ; 宽字符串
    mov     dword [rbp - 16], edx   ; 码元数

    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, qword [rbp - 8]
    mov     r9d, dword [rbp - 16]
    lea     rax, [rel utf8_buf]
    mov     qword [rsp + 32], rax   ; lpMultiByteStr
    mov     qword [rsp + 40], 1024  ; cbMultiByte
    mov     qword [rsp + 48], NULL  ; lpDefaultChar
    mov     qword [rsp + 56], NULL  ; lpUsedDefaultChar
    call    WideCharToMultiByte
    test    eax, eax
    jz      .done
    mov     dword [rbp - 24], eax   ; UTF-8 字节数

    mov     ecx, STD_OUTPUT_HANDLE
    call    GetStdHandle
    mov     qword [rbp - 32], rax

    mov     rcx, qword [rbp - 32]
    lea     rdx, [rel utf8_buf]
    mov     r8d, dword [rbp - 24]
    lea     r9, [rbp - 36]          ; &written
    mov     qword [rsp + 32], NULL  ; lpOverlapped
    call    WriteFile
.done:
    leave
    ret

; ------------------------------------------------------------
; int wmain(int argc, wchar_t **argv)
; ------------------------------------------------------------
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128

; ---------- 1. 打开不存在的文件 ----------
    lea     rcx, [rel filename]
    mov     edx, GENERIC_READ
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword [rsp + 32], OPEN_EXISTING
    mov     qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov     qword [rsp + 48], NULL
    call    CreateFileW
    mov     qword [rbp - 8], rax

    lea     rcx, [rel fmt_handle]
    mov     rdx, rax
    xor     eax, eax
    call    wprintf

; ---------- 2. 立刻取错误码 ----------
    call    GetLastError
    mov     dword [rbp - 12], eax

    lea     rcx, [rel fmt_err]
    mov     edx, dword [rbp - 12]
    xor     eax, eax
    call    wprintf

; ---------- 3. 取系统错误文本（7 参数，后 3 个在栈上） ----------
    mov     ecx, 0x1200             ; FROM_SYSTEM | IGNORE_INSERTS
    xor     edx, edx                ; lpSource = NULL
    mov     r8d, dword [rbp - 12]   ; dwMessageId
    xor     r9d, r9d                ; dwLanguageId = 0
    lea     rax, [rel msg_buf]
    mov     qword [rsp + 32], rax   ; lpBuffer
    mov     qword [rsp + 40], 512   ; nSize（码元数）
    mov     qword [rsp + 48], NULL  ; Arguments = NULL
    call    FormatMessageW

    test    eax, eax
    jz      .format_failed
    mov     dword [rbp - 16], eax   ; 返回的码元数

    lea     rcx, [rel fmt_chars]
    mov     edx, dword [rbp - 16]
    xor     eax, eax
    call    wprintf

    lea     rcx, [rel msg_text]
    xor     eax, eax
    call    wprintf

    ; wprintf 有缓冲，WriteFile 没有；先 flush，保证输出顺序
    xor     ecx, ecx
    call    fflush

    lea     rcx, [rel msg_buf]
    mov     edx, dword [rbp - 16]
    call    print_utf8

    lea     rcx, [rel fmt_nl]
    xor     eax, eax
    call    wprintf

    xor     eax, eax
    leave
    ret

; ---------- 失败路径 ----------
.format_failed:
    call    GetLastError
    mov     dword [rbp - 20], eax
    lea     rcx, [rel fmt_fail]
    mov     edx, dword [rbp - 20]
    xor     eax, eax
    call    wprintf
    mov     eax, 1
    leave
    ret
