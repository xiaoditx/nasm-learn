; ============================================================
; 第 16 章：COM 基础 —— IUnknown、CoCreateInstance 与虚表调用
; 构建：make        产物：comdemo.exe（控制台，可运行）
; 本章不创建窗口，只创建 CLSID_ShellLink 对象并调用 vtable。
; ============================================================
%include "../common.asm"

default rel

extern CoInitializeEx
extern CoCreateInstance
extern CoUninitialize
extern wprintf

global wmain

%define COINIT_APARTMENTTHREADED 2
%define CLSCTX_INPROC_SERVER     1

; IUnknown 的虚表槽位（所有 COM 接口都一样）
%define IUNKNOWN_QUERY_INTERFACE 0
%define IUNKNOWN_ADD_REF         1
%define IUNKNOWN_RELEASE         2

section .data
; CLSID_ShellLink = {00021401-0000-0000-C000-000000000046}
; GUID 的内存布局：Data1(u32 LE) Data2(u16 LE) Data3(u16 LE) Data4(8 字节原样)
clsid_shelllink:
    db 0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00
    db 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46

; IID_IShellLinkW = {000214F9-0000-0000-C000-000000000046}
iid_ishelllinkw:
    db 0xF9, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00
    db 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46

; IID_IUnknown = {00000000-0000-0000-C000-000000000046}
iid_iunknown:
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    db 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46

fmt_init:   WSTRZ `CoInitializeEx               = 0x%08X\n`
fmt_create: WSTRZ `CoCreateInstance(ShellLink)  = 0x%08X\n`
fmt_null:   WSTRZ `  -> object pointer is NULL\n`
fmt_qi:     WSTRZ `QueryInterface(IID_IUnknown) = 0x%08X\n`
fmt_rel1:   WSTRZ `Release(IUnknown)            -> %u\n`
fmt_rel2:   WSTRZ `Release(IShellLinkW)         -> %u\n`
fmt_uninit: WSTRZ `CoUninitialize               done\n`

section .bss
p_link: resq 1
p_unk:  resq 1

section .text

wmain:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 96                 ; 32 影子 + 32 栈参 + 32 本地槽

    mov     qword [rbp - 8],  0     ; [rbp-8]  = pLink
    mov     qword [rbp - 16], 0     ; [rbp-16] = pUnk
    mov     qword [rbp - 24], 0     ; [rbp-24] = 临时 HRESULT

    ; ---- CoInitializeEx(NULL, COINIT_APARTMENTTHREADED) ----
    xor     ecx, ecx
    mov     edx, COINIT_APARTMENTTHREADED
    call    CoInitializeEx
    mov     [rbp - 24], eax

    lea     rcx, [rel fmt_init]
    mov     edx, [rbp - 24]
    xor     eax, eax                ; 变参函数 AL = 0
    call    wprintf

    ; ---- CoCreateInstance：5 个参数，第 5 个走栈 ----
    ; rcx = &CLSID, rdx = pUnkOuter(NULL), r8d = CLSCTX_INPROC_SERVER,
    ; r9 = &IID_IShellLinkW, [rsp+32] = &pLink
    lea     rcx, [rel clsid_shelllink]
    xor     edx, edx
    mov     r8d, CLSCTX_INPROC_SERVER
    lea     r9,  [rel iid_ishelllinkw]
    lea     rax, [rbp - 8]
    mov     qword [rsp + 32], rax
    call    CoCreateInstance
    mov     [rbp - 24], eax

    lea     rcx, [rel fmt_create]
    mov     edx, [rbp - 24]
    xor     eax, eax
    call    wprintf

    mov     rax, [rbp - 8]
    test    rax, rax
    jnz     .have_object

    lea     rcx, [rel fmt_null]
    xor     edx, edx
    xor     eax, eax
    call    wprintf
    jmp     .uninit

.have_object:
    ; ---- QueryInterface：虚表槽位 0 ----
    ; 接口指针的 [0] 就是 lpVtbl；方法地址在 [lpVtbl + slot*8]
    mov     rcx, [rbp - 8]          ; this
    mov     rax, [rcx]              ; rax = lpVtbl
    lea     rdx, [rel iid_iunknown] ; riid
    lea     r8,  [rbp - 16]         ; ppvObject
    call    qword [rax + IUNKNOWN_QUERY_INTERFACE * 8]
    mov     [rbp - 24], eax

    lea     rcx, [rel fmt_qi]
    mov     edx, [rbp - 24]
    xor     eax, eax
    call    wprintf

    mov     rax, [rbp - 16]
    test    rax, rax
    jz      .release_link

    ; ---- Release 查询到的 IUnknown：槽位 2 ----
    mov     rcx, [rbp - 16]
    mov     rax, [rcx]
    call    qword [rax + IUNKNOWN_RELEASE * 8]
    mov     edx, eax
    lea     rcx, [rel fmt_rel1]
    xor     eax, eax
    call    wprintf

.release_link:
    ; ---- Release 原始接口 ----
    mov     rcx, [rbp - 8]
    mov     rax, [rcx]
    call    qword [rax + IUNKNOWN_RELEASE * 8]
    mov     edx, eax
    lea     rcx, [rel fmt_rel2]
    xor     eax, eax
    call    wprintf

.uninit:
    call    CoUninitialize
    lea     rcx, [rel fmt_uninit]
    xor     edx, edx
    xor     eax, eax
    call    wprintf

    xor     eax, eax
    leave
    ret
