# 第 16 章：COM 基础 —— IUnknown、CoCreateInstance 与虚表调用

> Direct2D 本质上是一组 COM 接口。学 D2D 之前，先把"接口指针怎么调用方法"搞明白。
> 本章源码：[comdemo.asm](comdemo.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[comdemo.obj.lst](comdemo.obj.lst)

## 1. 本章目标

- 理解接口指针的**第一格**是 `lpVtbl`；
- 用 `CoInitializeEx` / `CoUninitialize` 管理 COM 库；
- 用 `CoCreateInstance` 创建 `CLSID_ShellLink`（5 个参数，第 5 个走栈）；
- 手动用槽位调用 `QueryInterface`（槽 0）与 `Release`（槽 2）；
- 用真实输出验证引用计数。

跑通后你应该能回答：

- `pLink` 指向的内存里，前 8 个字节是什么？
- GUID 的 `Data1/Data2/Data3` 为什么要按小端写？
- `QueryInterface` 失败时 `ppvObject` 会不会被写成 0？
- `Release` 的返回值是什么？为什么第二次调用返回 0？

## 2. 前置 / 项目结构

```text
masm-learn/
├── common.asm                COM_CALL 宏、IUnknown 槽位常量
└── 16-com-iunknown/
    ├── Makefile
    ├── comdemo.asm
    ├── README.md
    └── comdemo.obj.lst       make 后生成
```

只有 `.asm` 源码。链接 `ole32`（COM 库）与 `shell32`（ShellLink 的 CLSID 实现）。本章是**控制台程序**，原 README 含真实运行输出（已验证），这里原样保留作为实证。

## 3. 知识点讲解

### 3.1 COM 接口指针的内存布局

COM 接口指针指向一块内存，**第一格（前 8 字节）是虚表指针 `lpVtbl`**。虚表是一个函数指针数组，数组下标就是"槽位"。

```text
pLink ──► [ lpVtbl ] ──► [ QueryInterface ]  ← 槽 0
                        [ AddRef         ]  ← 槽 1
                        [ Release        ]  ← 槽 2
                        [ GetPath        ]  ← 槽 3（IShellLinkW 自己的方法）
```

所以"调用第 N 个方法"的通用模式是：

```asm
mov  rax, [rcx]                 ; rax = lpVtbl（接口指针的第一格）
call qword [rax + N * 8]        ; 调用第 N 个槽
```

`common.asm` 把它封装成宏 `COM_CALL`，只破坏 `RAX`（易失寄存器），参数必须提前放进 `RCX/RDX/R8/R9` 和栈。

### 3.2 IUnknown 的三个槽

所有 COM 接口都继承自 `IUnknown`，前三个槽固定：

| 槽 | 方法 | 作用 |
|---|---|---|
| 0 | `QueryInterface` | 询问对象是否支持某个接口，支持则 `AddRef` 并返回指针 |
| 1 | `AddRef` | 引用计数 +1 |
| 2 | `Release` | 引用计数 -1，返回剩余计数；归零时销毁对象 |

引用计数规则：谁 `AddRef` 谁 `Release`；`QueryInterface` 成功会自动 `AddRef`。

### 3.3 Windows x64 ABI 四件套

**① 前四个参数：RCX / RDX / R8 / R9**

`CoCreateInstance` 是 5 参数函数：

| 参数 | C 签名 | 寄存器 |
|---|---|---|
| 1 | `REFCLSID rclsid` | `RCX` |
| 2 | `LPUNKNOWN pUnkOuter` | `RDX` |
| 3 | `DWORD dwClsContext` | `R8D` |
| 4 | `REFIID riid` | `R9` |
| 5 | `LPVOID *ppv` | `[rsp + 32]` |

第 5 个参数就是本章最重要的栈槽练习。

**② 32 字节影子空间**

`wmain` 分配 96 字节：

```text
96 = 32（影子） + 8（CoCreateInstance 第 5 参数） + 32（本地槽） + 24（余量）
```

`[rsp+32]` 只用于 `CoCreateInstance` 那一次调用；其余时间它是影子空间的一部分，可以安全忽略。

**③ 16 字节对齐**

```text
wmain 入口      RSP % 16 == 8
push rbp        RSP % 16 == 0
sub rsp, 96     RSP % 16 == 0（96 是 16 的倍数）
```

**④ 非易失寄存器**

`wmain` 只使用 `RAX/RCX/RDX/R8/R9` 和本地槽，不碰 `RBX/RDI/RSI`。COM 方法本身可能改写非易失寄存器，但**调用者只负责自己保存自己改的那些**——只要不在 `wmain` 里留下"我改了但没恢复"的状态即可。

### 3.4 GUID 的内存布局

`CLSID_ShellLink = {00021401-0000-0000-C000-000000000046}`。GUID 由 4 部分组成，前 3 部分是整数，按**小端**存储；第 4 部分是 8 字节原样：

```text
Data1（u32，小端）   01 14 02 00
Data2（u16，小端）   00 00
Data3（u16，小端）   00 00
Data4（8 字节原样）  C0 00 00 00 00 00 00 46
```

合起来 16 字节。写错字节序会得到 `REGDB_E_CLASSNOTREG`（类未注册），而不是"随便一个失败"。

### 3.5 CoCreateInstance 的参数

```text
CoCreateInstance(&clsid, pUnkOuter, dwClsContext, &iid, &ppv)
```

- `rclsid`：要创建的类 ID（`CLSID_ShellLink`）；
- `pUnkOuter`：聚合用的外部未知，本章传 `NULL`；
- `dwClsContext`：`CLSCTX_INPROC_SERVER=1`，只要进程内服务器（DLL）；
- `riid`：想拿到的接口 ID（`IID_IShellLinkW`）；
- `ppv`：输出参数，指向接口指针的指针。

### 3.6 QueryInterface 与 Release

`QueryInterface(this, &iid, &ppvObject)`：询问 `this` 对象是否支持 `iid` 接口。支持则把接口指针写入 `*ppvObject` 并 `AddRef`，返回 `S_OK`；不支持返回错误码，`*ppvObject` 不会被写入。

`Release(this)`：引用计数 -1，返回**剩余计数**。注意返回值是 `ULONG`，不是 `HRESULT`。归零时对象被销毁，之后再用指针就是悬空。

本章引用计数流程：

```text
CoCreateInstance 成功 → pLink 引用计数 = 1
QueryInterface(IID_IUnknown) 成功 → pUnk 引用计数 = 2（同一对象，QI 会 AddRef）
Release(pUnk) → 返回 1
Release(pLink) → 返回 0，对象销毁
```

## 4. 实践用例

本章 `comdemo.asm` 创建一个 `ShellLink` COM 对象，查询 `IUnknown` 接口，然后两次 `Release`，用输出验证引用计数从 2 降到 0。

### 4.1 构建命令

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l comdemo.obj.lst -o comdemo.obj comdemo.asm
gcc -municode -o comdemo.exe comdemo.obj -lole32 -lshell32
```

### 4.3 真实运行输出（原 README 已验证）

```text
CoInitializeEx               = 0x00000000
CoCreateInstance(ShellLink)  = 0x00000000
QueryInterface(IID_IUnknown) = 0x00000000
Release(IUnknown)            -> 1
Release(IShellLinkW)         -> 0
CoUninitialize               done
EXIT=0
```

三个 `0x00000000` 都是 `S_OK`；`1 → 0` 证明引用计数正确：`QueryInterface` 让计数从 1 变 2，两次 `Release` 依次回到 1 和 0，对象销毁。

> 注意：`wprintf` 的格式串使用了 NASM 反引号字符串（`` `...\n` ``）。普通双引号字符串**不解析** `\n` 转义，这一点在第 10 章已经踩过。

### 4.4 `.lst` 摘录

**槽 0：QueryInterface**

```text
   106 00000093 488B4DF8                    mov     rcx, [rbp - 8]          ; this
   107 00000097 488B01                      mov     rax, [rcx]              ; rax = lpVtbl
   108 0000009A 488D15(20000000)            lea     rdx, [rel iid_iunknown] ; riid
   109 000000A1 4C8D45F0                    lea     r8,  [rbp - 16]         ; ppvObject
   110 000000A5 FF10                        call    qword [rax + IUNKNOWN_QUERY_INTERFACE * 8]
```

`FF10` 拆开：`FF` 是 `call r/m64` 的 opcode，ModRM `10` 表示 `[RAX]`（无位移）。因为槽 0 的偏移是 0，NASM 省掉了位移字节。

**槽 2：Release**

```text
   124 000000C8 488B01                      mov     rax, [rcx]
   125 000000CB FF5010                      call    qword [rax + IUNKNOWN_RELEASE * 8]
```

`FF5010`：`FF` = `call r/m64`，ModRM `50` 表示 `[RAX + disp8]`，`10` = 位移 16 = 槽 2 × 8。两次 `Release` 的机器码完全一样，说明槽位计算一致。

## 5. 代码重点讲解

挑出 5 处关键代码，回扣前面的知识点。

**① CoInitializeEx**

```asm
    xor     ecx, ecx
    mov     edx, COINIT_APARTMENTTHREADED
    call    CoInitializeEx
    mov     [rbp - 24], eax
```

回扣知识点 3.5：`CoInitializeEx(NULL, COINIT_APARTMENTTHREADED=2)`。单线程场景用套间线程模型即可。返回值 `S_OK=0`，但也可能是 `S_FALSE=1`（已经初始化过），两者都算成功。

**② CoCreateInstance 的第 5 参数**

```asm
    lea     rcx, [rel clsid_shelllink]
    xor     edx, edx
    mov     r8d, CLSCTX_INPROC_SERVER
    lea     r9,  [rel iid_ishelllinkw]
    lea     rax, [rbp - 8]
    mov     qword [rsp + 32], rax        ; ppv（第 5 参数）
    call    CoCreateInstance
```

回扣知识点 3.3①：第 5 参数 `ppv` 走 `[rsp+32]`，必须 `mov qword`。`CLSCTX_INPROC_SERVER=1` 表示"只要进程内服务器"。

**③ QueryInterface 的槽 0 调用**

```asm
    mov     rcx, [rbp - 8]          ; this
    mov     rax, [rcx]              ; rax = lpVtbl
    lea     rdx, [rel iid_iunknown] ; riid
    lea     r8,  [rbp - 16]         ; ppvObject
    call    qword [rax + IUNKNOWN_QUERY_INTERFACE * 8]
```

回扣知识点 3.1/3.2：先从接口指针第一格取出 `lpVtbl`，再调用槽 0。`IID_IUnknown` 是 `{00000000-0000-0000-C000-000000000046}`，前 12 字节全 0。

**④ 两次 Release 验证引用计数**

```asm
    mov     rcx, [rbp - 16]         ; 查询到的 IUnknown
    mov     rax, [rcx]
    call    qword [rax + IUNKNOWN_RELEASE * 8]   ; 返回 1

    mov     rcx, [rbp - 8]          ; 原始 IShellLinkW
    mov     rax, [rcx]
    call    qword [rax + IUNKNOWN_RELEASE * 8]   ; 返回 0
```

回扣知识点 3.6：`Release` 返回剩余引用计数。`QueryInterface` 成功会 `AddRef`，所以计数从 2 开始：第一次 `Release` 返回 1，第二次返回 0 并销毁对象。

**⑤ CoUninitialize**

```asm
    call    CoUninitialize
```

回扣知识点 3.5：与 `CoInitializeEx` 成对。没有这一步，线程的 COM 状态不会释放。

## 6. 常见坑

1. **GUID 字节序写反**：得到 `0x80040154 (REGDB_E_CLASSNOTREG)`，而不是 `S_OK`。
2. **`CoCreateInstance` 第 5 参数写 `mov dword [rsp+32], ...`**：低 4 字节对了，高 4 字节是垃圾，COM 会写到非法地址。
3. **忘记 `CoUninitialize`**：短命控制台程序看不出问题，但在 GUI 里会累积。
4. **`Release` 后继续使用接口指针**：对象可能已销毁，典型表现是访问 `[rax]` 时崩溃。
5. **以为 `Release` 返回 `HRESULT`**：它返回 `ULONG` 计数，`0` 才是"对象已销毁"。
6. **`wprintf` 没有 `\n`**：输出会全部挤在一行。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item comdemo.exe,comdemo.obj,comdemo.obj.lst`。

## 7. 练习

1. 把 `IID_IShellLinkW` 换成 `IID_IUnknown` 再 `CoCreateInstance`，观察返回值是否仍是 `S_OK`。
2. 注释掉第二次 `Release`，观察进程退出时是否有对象泄漏（可用 `QueryInterface` 计数推断）。
3. 在 `QueryInterface` 之后打印 `pUnk` 的地址，再打印 `pLink` 的地址，比较它们是否相同（同对象的不同接口可能指向同一块内存的不同位置）。
4. 故意把 `CLSCTX_INPROC_SERVER` 改成 `0`，观察 `CoCreateInstance` 的失败码。
5. 用 GDB 在 `call qword [rax]` 处 `si`，`info registers rax rcx`，用 `x/4gx $rax` 查看虚表前四个槽。

## 8. 下一章预览

第 17 章把这些知识直接用在 Direct2D：

- `D2D1CreateFactory` 创建 `ID2D1Factory`；
- 从 `d2d1.h` 的 `ID2D1FactoryVtbl` 数出 `CreateHwndRenderTarget` 是槽 14；
- 填充 `D2D1_RENDER_TARGET_PROPERTIES` 与 `D2D1_HWND_RENDER_TARGET_PROPERTIES`；
- `BeginDraw` / `Clear` / `EndDraw` 的槽位 48 / 47 / 49。
