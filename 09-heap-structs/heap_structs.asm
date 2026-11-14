; ============================================================
; 第 09 章：堆内存与结构体 —— HeapAlloc + struc/endstruc + 链表
; 运行：.\heap_structs.exe
; 说明：ITEM 由 NASM 的 struc 定义，堆上分配 3 个节点并串成链表。
; ============================================================
default rel
%include "../common.asm"

; ---------- 结构体定义（只产生偏移常量，不占内存） ----------
struc ITEM
    .id:    resd 1      ; +0
    .value: resd 1      ; +4
    .next:  resq 1      ; +8
endstruc               ; NASM 自动产生 ITEM_size = 16

section .data
    static_item:
        istruc ITEM
            at ITEM.id,    dd 99
            at ITEM.value, dd 1234
            at ITEM.next,  dq 0
        iend

section .rdata
    fmt_alloc:  WSTR "allocated %d bytes for %d items (ITEM_size=%d)"
                dw 10, 0
    fmt_item:   WSTR "item id=%d value=%d"
                dw 10, 0
    fmt_sum:    WSTR "sum of values = %d"
                dw 10, 0
    fmt_static: WSTR "static item: id=%d value=%d"
                dw 10, 0
    msg_free:   WSTR "HeapFree done"
                dw 10, 0

section .bss
    stats:      resd 1              ; 仅作占位，保持 .bss 非空

section .text
    global  wmain
    extern  wprintf
    extern  GetProcessHeap
    extern  HeapAlloc
    extern  HeapFree

wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64                 ; 32 影子 + 32 本地槽

; ---------- 1. 取进程堆 ----------
    call    GetProcessHeap
    mov     qword [rbp - 16], rax

; ---------- 2. 分配 3 个 ITEM ----------
    mov     rcx, rax
    mov     edx, HEAP_ZERO_MEMORY
    mov     r8d, 3 * ITEM_size
    call    HeapAlloc
    test    rax, rax
    jz      .fail
    mov     qword [rbp - 8], rax    ; base

; ---------- 3. 填充并串联 ----------
    xor     ecx, ecx                ; i = 0
.fill:
    cmp     ecx, 3
    jge     .fill_done

    mov     rax, rcx
    shl     rax, 4                  ; i * 16 = i * ITEM_size
    add     rax, qword [rbp - 8]

    mov     dword [rax + ITEM.id], ecx
    mov     edx, ecx
    imul    edx, ecx                ; value = i * i
    mov     dword [rax + ITEM.value], edx

    cmp     ecx, 2
    jge     .last
    lea     rdx, [rax + ITEM_size]
    mov     qword [rax + ITEM.next], rdx
    jmp     .linked
.last:
    mov     qword [rax + ITEM.next], NULL
.linked:
    inc     ecx
    jmp     .fill
.fill_done:

; ---------- 4. 打印分配信息 ----------
    lea     rcx, [rel fmt_alloc]
    mov     edx, 3 * ITEM_size
    mov     r8d, 3
    mov     r9d, ITEM_size
    xor     eax, eax
    call    wprintf

; ---------- 5. 遍历链表 ----------
    mov     rax, qword [rbp - 8]
    mov     qword [rbp - 24], rax   ; 当前节点
    mov     dword [rbp - 32], 0     ; sum
.walk:
    mov     rax, qword [rbp - 24]
    test    rax, rax
    jz      .walk_done

    mov     edx, dword [rax + ITEM.id]
    mov     r8d, dword [rax + ITEM.value]
    mov     r9, qword [rax + ITEM.next]
    mov     qword [rbp - 24], r9    ; 先前进，避免被 call 覆盖

    mov     ecx, r8d
    add     dword [rbp - 32], ecx

    lea     rcx, [rel fmt_item]
    xor     eax, eax
    call    wprintf
    jmp     .walk
.walk_done:

    lea     rcx, [rel fmt_sum]
    mov     edx, dword [rbp - 32]
    xor     eax, eax
    call    wprintf

; ---------- 6. 打印静态结构体 ----------
    lea     rcx, [rel fmt_static]
    mov     edx, dword [rel static_item + ITEM.id]
    mov     r8d, dword [rel static_item + ITEM.value]
    xor     eax, eax
    call    wprintf

; ---------- 7. 释放 ----------
    mov     rcx, qword [rbp - 16]
    xor     edx, edx
    mov     r8, qword [rbp - 8]
    call    HeapFree

    lea     rcx, [rel msg_free]
    xor     eax, eax
    call    wprintf

    xor     eax, eax
    leave
    ret

.fail:
    mov     eax, 1
    leave
    ret
