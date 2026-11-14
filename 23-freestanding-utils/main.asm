; ============================================================
; 第 23 章：无 CRT 工具库（main 模块）
; 演示：打印字符串、u64 转十进制、wcslen、堆分配
; 构建：make    产物：freestanding.exe（console 子系统）
; 运行：.\freestanding.exe    —— 管道重定向下也能看到输出！
; ============================================================
%include "../common.asm"

default rel

extern ExitProcess

; ---- 跨文件引用：utils.asm 里的全局符号 ----
extern util_wcslen
extern util_u64_to_wstr
extern util_print_wstr
extern util_alloc
extern util_free

global _start

section .data
str_hello:
    WSTR "freestanding utils demo (no CRT)"
    dw 13, 10, 0
str_lbl_zero:  WSTRZ "u64 0        = "
str_lbl_max:   WSTRZ "u64 max      = "
str_lbl_len:   WSTRZ "wcslen(count)= "
str_lbl_heap:  WSTRZ "heap 2^40    = "
str_countme:   WSTRZ "0123456789"
str_crlf:      dw 13, 10, 0

section .bss
numbuf:     resw 32             ; 数字转换缓冲（21 个码元够用，给 32）

section .text

; ------------------------------------------------------------
; _start：RSP%16==8 → sub rsp,40 后 ==0
; 只调用本模块外的 util_* 与 ExitProcess，最大栈参 0 → 40 字节帧足够
; ------------------------------------------------------------
_start:
    sub     rsp, 40

    ; ---- 1. 直接打印字符串 ----
    lea     rcx, [rel str_hello]
    call    util_print_wstr

    ; ---- 2. u64 = 0（验证 do-while 能生成 '0'） ----
    lea     rcx, [rel str_lbl_zero]
    call    util_print_wstr
    xor     ecx, ecx
    lea     rdx, [rel numbuf]
    call    util_u64_to_wstr
    lea     rcx, [rel numbuf]
    call    util_print_wstr
    lea     rcx, [rel str_crlf]
    call    util_print_wstr

    ; ---- 3. u64 最大值 18446744073709551615（20 位，压力测试） ----
    lea     rcx, [rel str_lbl_max]
    call    util_print_wstr
    mov     rcx, -1                     ; 0xFFFFFFFFFFFFFFFF
    lea     rdx, [rel numbuf]
    call    util_u64_to_wstr
    lea     rcx, [rel numbuf]
    call    util_print_wstr
    lea     rcx, [rel str_crlf]
    call    util_print_wstr

    ; ---- 4. wcslen("0123456789") = 10，结果也走 u64→wstr 打印 ----
    lea     rcx, [rel str_lbl_len]
    call    util_print_wstr
    lea     rcx, [rel str_countme]
    call    util_wcslen
    mov     rcx, rax
    lea     rdx, [rel numbuf]
    call    util_u64_to_wstr
    lea     rcx, [rel numbuf]
    call    util_print_wstr
    lea     rcx, [rel str_crlf]
    call    util_print_wstr

    ; ---- 5. 堆演示：申请 64 字节，把 2^40 写进去再打印 ----
    mov     ecx, 64
    call    util_alloc
    test    rax, rax
    jz      .no_heap
    mov     rbx, rax                    ; _start 无调用者，RBX 随便用

    mov     rcx, 0x10000000000          ; 2^40 = 1099511627776
    mov     rdx, rbx
    call    util_u64_to_wstr

    lea     rcx, [rel str_lbl_heap]
    call    util_print_wstr
    mov     rcx, rbx
    call    util_print_wstr
    lea     rcx, [rel str_crlf]
    call    util_print_wstr

    mov     rcx, rbx
    call    util_free
.no_heap:

    ; ---- 退出码 0 ----
    xor     ecx, ecx
    call    ExitProcess
