; ============================================================
; 第 12 章：io.asm —— 文件读写模块
; 导出：
;   int  io_write_file(wchar_t *path, void *buf, int bytes)   1=成功 0=失败
;   int  io_read_file (wchar_t *path, void *buf, int cap)     >=0 字节数 -1 失败
; ============================================================
default rel
%include "../common.asm"

section .text
    global  io_write_file
    global  io_read_file
    extern  CreateFileW
    extern  WriteFile
    extern  ReadFile
    extern  CloseHandle

; ------------------------------------------------------------
; int io_write_file(wchar_t *path, void *buf, int bytes)
;   RCX = path, RDX = buf, R8D = bytes
; ------------------------------------------------------------
io_write_file:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 96                 ; 32 影子 + 3 个栈参数 + 本地槽

    mov     qword [rbp - 8],  rcx   ; path
    mov     qword [rbp - 16], rdx   ; buf
    mov     dword [rbp - 24], r8d   ; bytes

    mov     edx, GENERIC_WRITE
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword [rsp + 32], CREATE_ALWAYS
    mov     qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov     qword [rsp + 48], NULL
    call    CreateFileW
    cmp     rax, INVALID_HANDLE_VALUE
    je      .fail

    mov     qword [rbp - 32], rax   ; handle

    mov     rcx, rax
    mov     rdx, qword [rbp - 16]
    mov     r8d, dword [rbp - 24]
    lea     r9, [rbp - 40]          ; &written
    mov     qword [rsp + 32], NULL
    call    WriteFile
    test    eax, eax
    jz      .close_fail

    mov     eax, dword [rbp - 40]
    cmp     eax, dword [rbp - 24]
    jne     .close_fail

    mov     rcx, qword [rbp - 32]
    call    CloseHandle
    mov     eax, 1
    leave
    ret

.close_fail:
    mov     rcx, qword [rbp - 32]
    call    CloseHandle
.fail:
    xor     eax, eax
    leave
    ret

; ------------------------------------------------------------
; int io_read_file(wchar_t *path, void *buf, int cap)
;   RCX = path, RDX = buf, R8D = cap（字节）
; ------------------------------------------------------------
io_read_file:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 96

    mov     qword [rbp - 8],  rcx
    mov     qword [rbp - 16], rdx
    mov     dword [rbp - 24], r8d

    mov     edx, GENERIC_READ
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword [rsp + 32], OPEN_EXISTING
    mov     qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov     qword [rsp + 48], NULL
    call    CreateFileW
    cmp     rax, INVALID_HANDLE_VALUE
    je      .fail

    mov     qword [rbp - 32], rax

    mov     rcx, rax
    mov     rdx, qword [rbp - 16]
    mov     r8d, dword [rbp - 24]
    lea     r9, [rbp - 40]          ; &bytesRead
    mov     qword [rsp + 32], NULL
    call    ReadFile
    test    eax, eax
    jz      .close_fail

    mov     eax, dword [rbp - 40]
    mov     dword [rbp - 44], eax   ; 先保存，再 CloseHandle

    mov     rcx, qword [rbp - 32]
    call    CloseHandle
    mov     eax, dword [rbp - 44]
    leave
    ret

.close_fail:
    mov     rcx, qword [rbp - 32]
    call    CloseHandle
.fail:
    mov     eax, -1
    leave
    ret
