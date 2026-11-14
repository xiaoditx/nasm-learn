; ============================================================
; 第 23 章：无 CRT 工具库（utils 模块）
; CRT 平时悄悄给的 4 件东西，这里自己实现：
;   util_wcslen        字符串长度（替代 wcslen）
;   util_u64_to_wstr   无符号 64 位 → 十进制 UTF-16（替代 _ui64tow）
;   util_print_wstr    打印（控制台 WriteConsoleW / 管道 WriteFile）
;   util_alloc/free    堆分配包装（替代 malloc/free）
; ============================================================
%include "../common.asm"

default rel

extern GetStdHandle
extern GetConsoleMode
extern WriteConsoleW
extern WriteFile
extern WideCharToMultiByte
extern GetProcessHeap
extern HeapAlloc
extern HeapFree

global util_wcslen
global util_u64_to_wstr
global util_print_wstr
global util_alloc
global util_free

%define UTF8_BUF_SIZE  4096     ; 管道路径的 UTF-8 转换缓冲（演示程序够用了）

section .bss
h_out:        resq 1          ; 缓存的 stdout 句柄
out_kind:     resd 1          ; 0=未检测  1=真控制台  2=管道/文件
console_mode: resd 1          ; GetConsoleMode 的输出参数
written:      resd 1          ; WriteConsoleW/WriteFile 的写出计数
utf8_buf:     resb UTF8_BUF_SIZE

section .text

; ------------------------------------------------------------
; util_wcslen(PCWSTR rcx) -> rax = 长度（码元数，不含结尾 0）
; 纯计算叶子函数：不调 API，不需要栈帧
; ------------------------------------------------------------
util_wcslen:
    xor     eax, eax
.loop:
    cmp     word [rcx + rax*2], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; ------------------------------------------------------------
; util_u64_to_wstr(u64 rcx, PWSTR rdx) -> rax = 写入长度（不含结尾 0）
; 十进制。div 得到的余数是"个位在前"，先正序存栈上临时缓冲，
; 再倒序拷回调用方缓冲。调用方保证缓冲 >= 21 个码元（20 位 + NUL）。
; 本函数不调 API，栈帧只是临时缓冲，对齐无要求（仍保持 16 倍数）。
; ------------------------------------------------------------
util_u64_to_wstr:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 48                 ; [rbp-40 .. rbp-1] = 20 个码元的临时缓冲

    mov     r8, rcx                 ; r8 = 待转换值
    mov     r9, rdx                 ; r9 = 目标缓冲
    mov     r10d, 10                ; 除数
    xor     ecx, ecx                ; 已生成位数

.gen:                               ; do-while：保证 0 也能生成 '0'
    mov     rax, r8
    xor     edx, edx                ; div 用 RDX:RAX 被除数，高 64 位清零
    div     r10                     ; rax = 商，rdx = 余数（当前最低位）
    add     edx, '0'
    mov     [rbp + rcx*2 - 40], dx  ; temp[count] = 数字字符（低位在前）
    inc     rcx
    mov     r8, rax
    test    r8, r8
    jnz     .gen

    ; 倒序拷贝：dest[i] = temp[count-1-i]
    xor     eax, eax
.copy:
    mov     rsi, rcx
    dec     rsi
    sub     rsi, rax                ; rsi = count-1-i
    mov     dx, [rbp + rsi*2 - 40]
    mov     [r9 + rax*2], dx
    inc     rax
    cmp     rax, rcx
    jb      .copy

    mov     word [r9 + rcx*2], 0    ; NUL 结尾
    mov     rax, rcx                ; 返回长度
    leave
    ret

; ------------------------------------------------------------
; detect_out：填写 h_out / out_kind（惰性，只检测一次）
; GetConsoleMode 成功 → 真控制台；失败 → stdout 被重定向到管道/文件
; ------------------------------------------------------------
detect_out:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    cmp     dword [rel out_kind], 0
    jne     .done

    mov     ecx, STD_OUTPUT_HANDLE
    call    GetStdHandle
    mov     [rel h_out], rax

    mov     rcx, rax
    lea     rdx, [rel console_mode]
    call    GetConsoleMode
    test    eax, eax
    jz      .pipe
    mov     dword [rel out_kind], 1
    jmp     .done
.pipe:
    mov     dword [rel out_kind], 2
.done:
    leave
    ret

; ------------------------------------------------------------
; util_print_wstr(PCWSTR rcx)：打印一行（不带换行）
; 真控制台 → WriteConsoleW（UTF-16 直出）
; 管道/文件 → WideCharToMultiByte(CP_UTF8) + WriteFile
; 栈帧 80 = 32 影子 + 32 最大栈参（WideCharToMultiByte 后 4 参）+ 16 本地
; ------------------------------------------------------------
util_print_wstr:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 80
    mov     [rbp - 8], rcx          ; 保存字符串指针

    call    util_wcslen             ; rcx 已是参数
    mov     [rbp - 16], rax         ; 保存长度

    call    detect_out
    cmp     dword [rel out_kind], 1
    jne     .pipe

    ; ---- 真控制台：WriteConsoleW(h, s, len, &written, NULL) ----
    mov     rcx, [rel h_out]
    mov     rdx, [rbp - 8]
    mov     r8d, dword [rbp - 16]
    lea     r9, [rel written]
    mov     qword [rsp + 32], 0     ; 第 5 参 lpReserved
    call    WriteConsoleW
    jmp     .done

.pipe:
    ; ---- 管道：WideCharToMultiByte(CP_UTF8,0,s,len,buf,SIZE,NULL,NULL) ----
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, [rbp - 8]
    mov     r9d, dword [rbp - 16]
    lea     rax, [rel utf8_buf]
    mov     qword [rsp + 32], rax           ; lpMultiByteStr
    mov     qword [rsp + 40], UTF8_BUF_SIZE ; cbMultiByte
    mov     qword [rsp + 48], 0             ; lpDefaultChar
    mov     qword [rsp + 56], 0             ; lpUsedDefaultChar
    call    WideCharToMultiByte
    test    eax, eax
    jz      .done                   ; 转换失败（演示程序静默放弃）

    ; WriteFile(h, utf8_buf, eax, &written, NULL)
    mov     rcx, [rel h_out]
    lea     rdx, [rel utf8_buf]
    mov     r8d, eax
    lea     r9, [rel written]
    mov     qword [rsp + 32], 0
    call    WriteFile

.done:
    leave
    ret

; ------------------------------------------------------------
; util_alloc(SIZE_T rcx 字节数) -> rax = 指针（失败 NULL）
; 相当于 malloc；进程堆 = GetProcessHeap()
; ------------------------------------------------------------
util_alloc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    mov     r8, rcx                 ; 第 3 参 dwBytes
    call    GetProcessHeap
    mov     rcx, rax                ; 第 1 参 hHeap
    xor     edx, edx                ; 第 2 参 dwFlags = 0
    call    HeapAlloc
    leave
    ret

; ------------------------------------------------------------
; util_free(LPVOID rcx)：释放 util_alloc 拿到的内存
; ------------------------------------------------------------
util_free:
    push    rbp
    mov     rbp, rsp
    sub     rsp, FRAME_SUB_RSP

    mov     r8, rcx                 ; 第 3 参 lpMem
    call    GetProcessHeap
    mov     rcx, rax
    xor     edx, edx
    call    HeapFree
    leave
    ret
