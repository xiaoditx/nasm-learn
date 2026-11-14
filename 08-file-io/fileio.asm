; ============================================================
; 第 08 章：文件 I/O —— CreateFileW / WriteFile / ReadFile / CloseHandle
; 流程：创建文件 → 写入 UTF-16 文本 → 关闭 → 重新打开 → 读回 → 打印
; 运行：.\fileio.exe
; ============================================================
default rel
%include "../common.asm"

section .rdata
    filename:   WSTRZ "demo_file.txt"

; 要写入文件的 UTF-16LE 文本（3 行）
    content:
        WSTR "line one"
        dw 13, 10
        WSTR "line two"
        dw 13, 10
        WSTR "line three"
        dw 13, 10
    content_chars equ ($ - content) / WCHAR_SIZE
    content_bytes equ content_chars * WCHAR_SIZE

    msg_written:  WSTR "WriteFile  : %lu bytes"
                  dw 10, 0
    msg_read:     WSTR "ReadFile   : %lu bytes"
                  dw 10, 0
    msg_readback: WSTR "--- read back from disk ---"
                  dw 10, 0
    msg_content:  WSTR "%ls"
                  dw 10, 0
    msg_open_fail:  WSTR "CreateFileW failed, error=%lu"
                    dw 10, 0
    msg_write_fail: WSTR "WriteFile failed, error=%lu"
                    dw 10, 0
    msg_read_fail:  WSTR "ReadFile failed, error=%lu"
                    dw 10, 0

section .bss
    read_buf:   resb 512            ; 256 个 UTF-16 码元

section .text
    global  wmain
    extern  wprintf
    extern  CreateFileW
    extern  WriteFile
    extern  ReadFile
    extern  CloseHandle
    extern  GetLastError

; int wmain(int argc, wchar_t **argv)
wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128                ; 32 影子 + 3 个栈参数 + 本地槽

; ---------- 1. 创建/覆盖文件 ----------
    lea     rcx, [rel filename]
    mov     edx, GENERIC_READ | GENERIC_WRITE
    xor     r8d, r8d                ; dwShareMode = 0
    xor     r9d, r9d                ; lpSecurityAttributes = NULL
    mov     qword [rsp + 32], CREATE_ALWAYS
    mov     qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov     qword [rsp + 48], NULL  ; hTemplateFile
    call    CreateFileW
    mov     qword [rbp - 8], rax
    cmp     rax, INVALID_HANDLE_VALUE
    je      .fail_open

; ---------- 2. 写入 UTF-16 文本 ----------
    mov     rcx, qword [rbp - 8]
    lea     rdx, [rel content]
    mov     r8d, content_bytes
    lea     r9, [rbp - 16]          ; &bytesWritten
    mov     qword [rsp + 32], NULL  ; lpOverlapped
    call    WriteFile
    test    eax, eax
    jz      .fail_write

    lea     rcx, [rel msg_written]
    mov     edx, dword [rbp - 16]
    xor     eax, eax
    call    wprintf

; ---------- 3. 关闭 ----------
    mov     rcx, qword [rbp - 8]
    call    CloseHandle

; ---------- 4. 重新以只读方式打开 ----------
    lea     rcx, [rel filename]
    mov     edx, GENERIC_READ
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword [rsp + 32], OPEN_EXISTING
    mov     qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov     qword [rsp + 48], NULL
    call    CreateFileW
    mov     qword [rbp - 8], rax
    cmp     rax, INVALID_HANDLE_VALUE
    je      .fail_open

; ---------- 5. 读回 ----------
    mov     rcx, qword [rbp - 8]
    lea     rdx, [rel read_buf]
    mov     r8d, 512                ; 缓冲区容量（字节）
    lea     r9, [rbp - 24]          ; &bytesRead
    mov     qword [rsp + 32], NULL
    call    ReadFile
    test    eax, eax
    jz      .fail_read

    mov     rcx, qword [rbp - 8]
    call    CloseHandle

; ---------- 6. 打印读回结果 ----------
    lea     rcx, [rel msg_read]
    mov     edx, dword [rbp - 24]
    xor     eax, eax
    call    wprintf

    lea     rcx, [rel msg_readback]
    xor     eax, eax
    call    wprintf

    lea     rcx, [rel msg_content]
    lea     rdx, [rel read_buf]
    xor     eax, eax
    call    wprintf

    xor     eax, eax
    leave
    ret

; ---------- 失败路径 ----------
.fail_open:
    call    GetLastError
    mov     dword [rbp - 28], eax
    lea     rcx, [rel msg_open_fail]
    mov     edx, dword [rbp - 28]
    xor     eax, eax
    call    wprintf
    mov     eax, 1
    leave
    ret

.fail_write:
    call    GetLastError
    mov     dword [rbp - 28], eax
    mov     rcx, qword [rbp - 8]
    call    CloseHandle
    lea     rcx, [rel msg_write_fail]
    mov     edx, dword [rbp - 28]
    xor     eax, eax
    call    wprintf
    mov     eax, 2
    leave
    ret

.fail_read:
    call    GetLastError
    mov     dword [rbp - 28], eax
    mov     rcx, qword [rbp - 8]
    call    CloseHandle
    lea     rcx, [rel msg_read_fail]
    mov     edx, dword [rbp - 28]
    xor     eax, eax
    call    wprintf
    mov     eax, 3
    leave
    ret
