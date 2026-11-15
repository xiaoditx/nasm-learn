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
- 用真实输出观察当前对象的 `Release` 计数，同时理解它为什么不能当通用控制逻辑。

跑通后你应该能回答：

- `pLink` 指向的内存里，前 8 个字节是什么？
- GUID 的 `Data1/Data2/Data3` 为什么要按小端写？
- `QueryInterface` 失败时应该怎样检查 `HRESULT` 和输出指针？
- `Release` 的返回值是什么？为什么本章第二次调用观察到 0，却不能据此决定释放次数？

## 2. 前置 / 项目结构

```text
nasm-learn/
├── common.asm                COM_CALL 宏、IUnknown 槽位常量
└── 16-com-iunknown/
    ├── Makefile
    ├── comdemo.asm
    ├── README.md
    └── comdemo.obj.lst       make 后生成
```

只有 `.asm` 源码。链接 `ole32`（COM 库）与 `shell32`（ShellLink 的 CLSID 实现）。本章是**控制台程序**，原 README 含真实运行输出（已验证），这里原样保留作为实证。

## 3. 知识点讲解

### 3.1 先分清：COM 类、对象、接口和接口指针

COM（Component Object Model）是一套**跨语言、跨模块使用二进制对象的约定**，不是 NASM 的新指令，也不要求先学 C++。本章只用到四个角色：

| 名词 | 本章例子 | 作用 |
|---|---|---|
| CLSID | `CLSID_ShellLink` | 标识“要创建哪一类对象” |
| IID | `IID_IShellLinkW`、`IID_IUnknown` | 标识“想使用哪一种接口” |
| COM 对象 | 系统创建的一个 ShellLink 对象 | 真正实现功能，内部布局通常不公开 |
| 接口指针 | `pLink`、`pUnk` | 调用者拿到的访问入口，通过它调用约定好的方法 |

CLSID 和 IID 都是 16 字节 GUID，但用途不同，不能互换。`CoCreateInstance` 同时需要两者：前者回答“创建谁”，后者回答“返回哪种调用视图”。

`pLink` 的准确名字是 **`IShellLinkW` 接口指针**，不是“整个对象的裸内存地址”。同一对象查询出的 `IUnknown*` 与 `IShellLinkW*` 可以相同，也可以不同；调用者不能根据对象内部布局做假设，只能依赖接口公开约定。

### 3.2 接口指针、虚表与 `this`：两次解引用

在微软 x64 ABI 的 COM 布局中，接口指针指向一小块接口数据，其**第一个 8 字节字段是虚表指针 `lpVtbl`**。虚表本身是一个函数地址数组，数组下标就是“槽位”。

```text
pLink = 0x2000
   │
   ▼
地址 0x2000: [0x3000]  ← 第一格：lpVtbl
                  │
                  ▼
        地址 0x3000: [QueryInterface 地址]   槽 0，偏移 0
        地址 0x3008: [AddRef 地址]           槽 1，偏移 8
        地址 0x3010: [Release 地址]          槽 2，偏移 16
        地址 0x3018: [IShellLinkW 下一方法]  槽 3，偏移 24
```

以上地址是为手算虚构的，重点是指向关系。调用 `Release(pLink)` 时，CPU 实际经历：

```asm
mov rcx, [rbp-8]        ; RCX = pLink = 0x2000，作为 this
mov rax, [rcx]          ; 第一次解引用：RAX = [0x2000] = 0x3000
call qword [rax + 2*8]  ; 第二次查表：调用 [0x3000+16] 中的函数地址
```

`this` 就是被调用方法要操作的那个接口实例，必须作为第一个参数放入 `RCX`。只取到函数地址却忘了设置 `RCX`，方法就不知道要操作哪个对象。

所以“调用第 N 个方法”的通用模式是：

```asm
; RCX 已持有接口指针，其余参数也已准备好
mov  rax, [rcx]                 ; rax = lpVtbl
call qword [rax + N * 8]        ; 调用第 N 个槽
```

`common.asm` 的 `COM_CALL` 宏只做这两步：

```asm
%macro COM_CALL 2
    mov  rax, [%1]
    call qword [rax + (%2) * 8]
%endmacro
```

宏不会自动加载 `this`，不会准备 `RDX/R8/R9`，也不会检查 `HRESULT`。例如 `COM_CALL rcx, 47` 展开后仍要求 `RCX` 已经是对应接口指针；调用前还必须有 32 字节影子空间和正确的栈对齐。

### 3.3 IUnknown 的三个槽

所有 COM 接口都以 `IUnknown` 的三个方法开头，所以前三个槽固定：

| 槽 | 方法 | C 形式签名 | 作用 |
|---|---|---|---|
| 0 | `QueryInterface` | `QI(this, riid, ppvObject)` | 查询另一接口；成功时输出新接口指针并增加引用 |
| 1 | `AddRef` | `AddRef(this)` | 增加引用计数，返回一个计数值 |
| 2 | `Release` | `Release(this)` | 释放本接口引用；最后一个引用释放后对象可销毁 |

基本所有权规则是：**每次成功的 `CoCreateInstance`、`QueryInterface` 或显式 `AddRef` 所取得的引用，都要恰好对应一次 `Release`。** 不是“每个对象只 Release 一次”，也不是“把同一个指针 Release 到返回 0 为止”。

`AddRef/Release` 返回的计数主要用于调试和测试，不应被通用业务逻辑当作精确的全局对象状态。对象可能有其他内部引用，不同接口的计数语义也不能随意推断。本章的 `1 → 0` 是当前实现、当前调用序列下的观察结果，而不是所有 COM 对象都保证出现的输出。

### 3.4 Windows x64 ABI 四件套

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

`wmain` 分配 96 字节，并为局部变量、影子空间和额外参数槽预留位置。调用前 `RSP=RBP-96`，与本例相关的布局是：

```text
高地址
RBP-8    pLink：IShellLinkW*，8 字节
RBP-16   pUnk：IUnknown*，8 字节
RBP-24   临时 HRESULT，低 4 字节
         ...
RBP-64   CoCreateInstance 第 5 参数槽     ← [rsp+32]
RBP-96   32 字节影子空间最低地址          ← [rsp+0]
低地址
```

`[rsp+32..39]` 是第 5 参数槽，**不属于**本次调用的 32 字节影子空间 `[rsp+0..31]`。调用返回后 `RSP` 没有变化；下一次只传四个参数的调用仍只拥有 `[rsp+0..31]` 作为影子空间，不能把旧的第 5 参数槽随便当局部变量使用。局部 `pLink/pUnk` 则放在更高的 `RBP` 附近，不与这些 outgoing 槽重叠。

**③ 16 字节对齐**

```text
wmain 入口      RSP % 16 == 8
push rbp        RSP % 16 == 0
sub rsp, 96     RSP % 16 == 0（96 是 16 的倍数）
```

**④ 非易失寄存器**

`wmain` 只使用易失寄存器和本地槽，不修改 `RBX/RDI/RSI` 等非易失寄存器。遵守 Windows x64 ABI 的 COM 方法与普通函数一样，**必须保住非易失寄存器**，但可以自由覆盖 `RAX/RCX/RDX/R8～R11` 等易失寄存器。

所以把 `pLink` 只放在 `RCX` 中，然后调用 `wprintf`，返回后还指望 `RCX` 不变，是错误的。本章把接口指针放在 `[rbp-8]`、`[rbp-16]` 的局部内存里，每次调用前重新加载。

### 3.5 GUID 的内存布局

`CLSID_ShellLink = {00021401-0000-0000-C000-000000000046}`。GUID 由 4 部分组成，前 3 部分是整数，按**小端**存储；第 4 部分是 8 字节原样：

```text
Data1（u32，小端）   01 14 02 00
Data2（u16，小端）   00 00
Data3（u16，小端）   00 00
Data4（8 字节原样）  C0 00 00 00 00 00 00 46
```

合起来 16 字节。文本 `{00021401-...}` 中看到的是整数的通常书写顺序，内存里的前三个整数字段则按小端排列；`Data4` 是字节数组，不整体颠倒。若把 16 字节全部反转，得到的已经是另一个 GUID。错误发生在 CLSID 时可能得到 `REGDB_E_CLASSNOTREG`，发生在 IID 时也可能得到 `E_NOINTERFACE` 等结果，不能只凭一个错误码反推一定是字节序问题。

### 3.6 CoCreateInstance 的参数

```text
CoCreateInstance(&clsid, pUnkOuter, dwClsContext, &iid, &ppv)
```

- `rclsid`：要创建的类 ID（`CLSID_ShellLink`）；
- `pUnkOuter`：聚合用的外部未知，本章传 `NULL`；
- `dwClsContext`：`CLSCTX_INPROC_SERVER=1`，只要进程内服务器（DLL）；
- `riid`：想拿到的接口 ID（`IID_IShellLinkW`）；
- `ppv`：输出参数，指向“接口指针变量”的指针。

最后一项最容易绕晕。本例想接收一个 8 字节接口指针 `pLink`，变量本身在 `[rbp-8]`；API 需要能修改这个变量，所以传入的是它的**地址**：

```asm
lea rax, [rbp-8]          ; RAX = &pLink，不是 pLink 的当前值
mov qword [rsp+32], rax   ; 第 5 参数 = &pLink
call CoCreateInstance     ; 成功后 [rbp-8] 才被写成新接口指针
```

这就是 C 语言中 `CoCreateInstance(..., (LPVOID*)&pLink)` 对应的汇编过程。若误传 `pLink` 当前值（初始为 0），COM 就没有合法的输出位置可写。

### 3.7 QueryInterface、HRESULT 与 Release

`QueryInterface(this, &iid, &ppvObject)` 询问接口所属对象是否支持 `iid`。成功时把新接口指针写入 `*ppvObject`、增加引用并返回成功 `HRESULT`；失败时返回失败码，COM 约定要求输出指针为 `NULL`。调用者仍应先把输出变量清零，并且**先判断 `HRESULT`**，不要依赖失败路径中某个指针的偶然内容。

`HRESULT` 是 32 位状态值，不是句柄，也不是布尔值。最高位为 1 通常表示失败，因此 Windows x64 汇编中可用有符号判断：

```asm
call SomeComMethod       ; EAX = HRESULT
test eax, eax
js   .com_failed         ; sign=1，FAILED(hr)
; S_OK=0、S_FALSE=1 等都不会跳转，均属于 SUCCEEDED(hr)
```

不要写成 `test eax,eax; jnz .fail`，因为 `S_FALSE=1` 是非零成功码。本章输出中的 `0x80040154` 就是一个负数形式表示的失败 `HRESULT`。

`Release(this)` 释放当前接口的一个引用，返回 `ULONG` 计数值，不是 `HRESULT`。最后一个引用释放后对象可以销毁；此后必须停止通过该接口指针调用任何方法，并把保存的指针视为失效。

本章在当前 ShellLink 实现和没有额外引用的条件下，观察到：

```text
CoCreateInstance 成功 → 获得 pLink 的一个引用
QueryInterface(IID_IUnknown) 成功 → 获得 pUnk 的另一个引用
Release(pUnk) → 本次返回 1
Release(pLink) → 本次返回 0，最后引用释放
```

它验证的是“成功 QI 需要配对 Release”的所有权规则，不是让程序以后根据 `Release==0` 决定何时停止释放。正确做法仍是每个成功取得的引用各释放一次。

### 3.8 CoInitializeEx 的成功、失败与配对清理

使用大多数 COM API 前，线程要先声明 COM 套间模型。本章：

```asm
xor ecx, ecx                         ; 保留参数 NULL
mov edx, COINIT_APARTMENTTHREADED    ; STA，单线程套间
call CoInitializeEx
```

`COINIT_APARTMENTTHREADED` 不是“程序只能创建一个线程”，而是说明当前线程以 STA 方式参与 COM。GUI 程序通常在创建窗口的线程完成这一步。本章不展开跨套间代理和 marshalling；先遵守“COM 接口在哪个套间取得，就在允许的规则和线程中使用”。

返回值需要按 `HRESULT` 判断：

- `S_OK=0`：本次初始化成功；
- `S_FALSE=1`：当前线程已经按兼容模型初始化，仍属于成功；
- 例如 `RPC_E_CHANGED_MODE=0x80010106`：线程已用不兼容模型初始化，属于失败。

**每一次成功的 `CoInitializeEx`（包括 `S_FALSE`）都对应一次 `CoUninitialize`；失败时不要补调 `CoUninitialize`。** 后续 COM 调用也不应在初始化失败后照常继续。

当前源码为了缩短主流程，只打印初始化 `HRESULT`，没有检查失败；创建对象和 QI 后也主要检查输出指针，而不是先检查 `HRESULT`，并且最后无条件调用 `CoUninitialize`。在本次已验证的成功路径上它可以工作，但通用代码应改为：

```text
CoInitializeEx
  └─ FAILED？→ 报错并退出，不 CoUninitialize
  └─ SUCCEEDED
       └─ CoCreateInstance
            └─ FAILED？→ 报错，跳到 CoUninitialize
            └─ SUCCEEDED → 使用接口
       └─ 对已经成功取得的每个接口各 Release 一次
       └─ CoUninitialize
```

输出变量先清零仍然是好的防御性初始化，但“指针非零”不能替代 `SUCCEEDED(hr)` 判断。后续 Direct2D 章节也沿用这条规则。

## 4. 实践用例

本章 `comdemo.asm` 创建一个 `ShellLink` COM 对象，取得 `IShellLinkW` 接口，再查询 `IUnknown` 接口，最后分别释放两个成功取得的引用。输出展示当前运行中两个 `Release` 返回的计数值。

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

三个 `0x00000000` 都是 `S_OK`。在本次 ShellLink 实现与调用序列中，`1 → 0` 与“QI 新增一个引用、随后两个引用分别释放”的预期一致；最后一个引用释放后对象销毁。不要把这两个返回值推广为所有 COM 对象的固定打印结果。

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

回扣知识点 3.8：`CoInitializeEx(NULL, COINIT_APARTMENTTHREADED=2)` 为当前线程选择 STA。返回值 `S_OK=0` 和 `S_FALSE=1` 都算成功，失败则不应继续正常 COM 流程。当前源码没有做这个分支，是不能照抄的简化。

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

回扣知识点 3.4① 与 3.6：第 5 参数 `ppv` 从 `[rsp+32]` 开始，写入的是 `&pLink` 这个 64 位地址，因此需要完整的 8 字节指针值。`CLSCTX_INPROC_SERVER=1` 表示“只请求进程内服务器”。

**③ QueryInterface 的槽 0 调用**

```asm
    mov     rcx, [rbp - 8]          ; this
    mov     rax, [rcx]              ; rax = lpVtbl
    lea     rdx, [rel iid_iunknown] ; riid
    lea     r8,  [rbp - 16]         ; ppvObject
    call    qword [rax + IUNKNOWN_QUERY_INTERFACE * 8]
```

回扣知识点 3.2/3.3：`RCX=pLink` 是 `this`，先从接口指针第一格取出 `lpVtbl`，再调用槽 0。`RDX` 指向 16 字节 IID，`R8` 指向局部输出变量 `pUnk`。`IID_IUnknown` 是 `{00000000-0000-0000-C000-000000000046}`，其前三个整数字段恰好都为 0，所以内存前 8 字节全 0，随后才是 `Data4`。

**④ 两次 Release 验证引用计数**

```asm
    mov     rcx, [rbp - 16]         ; 查询到的 IUnknown
    mov     rax, [rcx]
    call    qword [rax + IUNKNOWN_RELEASE * 8]   ; 返回 1

    mov     rcx, [rbp - 8]          ; 原始 IShellLinkW
    mov     rax, [rcx]
    call    qword [rax + IUNKNOWN_RELEASE * 8]   ; 返回 0
```

回扣知识点 3.7：两次调用分别释放 `pUnk` 和 `pLink` 各自持有的一个引用，槽位都为 2。当前运行中第一次返回 1、第二次返回 0；即使某个实现返回其他计数值，调用者也不能少释放或多释放。

**⑤ CoUninitialize**

```asm
    call    CoUninitialize
```

回扣知识点 3.8：与一次成功的 `CoInitializeEx` 成对。当前源码无条件执行它，只有初始化已成功的主路径才符合规则；通用代码必须记录初始化是否成功，并让清理路径与之匹配。

## 6. 常见坑

1. **把 GUID 的 16 字节全部倒序**：只有 `Data1/Data2/Data3` 按各自整数的小端布局存储，`Data4` 是 8 字节数组。错误 GUID 可能出现不同失败码，不能固定断言只有 `REGDB_E_CLASSNOTREG`。
2. **把 `pLink` 当成输出参数 `ppv`**：API 需要的是 `&pLink`。`lea rax,[rbp-8]` 与 `mov rax,[rbp-8]` 一个取变量地址、一个取变量值，含义完全不同。
3. **第 5 参数只保留 32 位地址**：`ppv` 是 64 位指针值，写入 `[rsp+32]` 时必须保留完整地址；8 字节参数槽在这里也确实对应一个 64 位指针类型。
4. **用 `jnz` 判断 `HRESULT` 失败**：`S_FALSE=1` 是成功。应使用 `test eax,eax` 后 `js` 判断负数失败，并先检查状态再使用输出接口。
5. **初始化失败仍继续并无条件 `CoUninitialize`**：只有成功的 `CoInitializeEx` 才配对清理。当前教学源码没有完整实现这条分支。
6. **`Release` 后继续使用接口指针**：该引用已经释放，对象可能已销毁；不要通过返回计数“试探”还能不能用。
7. **以为 `Release` 返回 `HRESULT` 或固定计数**：它返回 `ULONG` 计数值，主要用于调试。每个成功取得的引用释放一次，而不是循环释放到 0。
8. **忘记宏外的 `this` 和 ABI 准备**：`COM_CALL` 只展开两次查表调用，不会设置 `RCX`、其他参数、影子空间或栈对齐。
9. **把 `xor eax,eax` 当 Windows 变参 ABI 要求**：源码调用 `wprintf` 前的清零是无害操作，不是 Windows x64 必需的 `AL=向量参数个数` 规则。
10. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item comdemo.exe,comdemo.obj,comdemo.obj.lst`。

## 7. 练习

1. 把 `IID_IShellLinkW` 换成 `IID_IUnknown` 再 `CoCreateInstance`，观察返回值是否仍是 `S_OK`。
2. 在成功 QI 后额外调用一次 `AddRef(pUnk)`，再为它增加一次配对的 `Release`。画出引用所有权表，说明为什么总释放次数必须随之加一，而不是根据返回计数决定。
3. 在 `QueryInterface` 之后打印 `pUnk` 的地址，再打印 `pLink` 的地址，比较它们是否相同（同对象的不同接口可能指向同一块内存的不同位置）。
4. 故意把 `CLSCTX_INPROC_SERVER` 改成 `0`，观察 `CoCreateInstance` 的失败码。
5. 用 GDB 在 `call qword [rax]` 处 `si`，`info registers rax rcx`，用 `x/4gx $rax` 查看虚表前四个槽。

## 8. 下一章预览

第 17 章把这些知识直接用在 Direct2D：

- `D2D1CreateFactory` 创建 `ID2D1Factory`；
- 从 `d2d1.h` 的 `ID2D1FactoryVtbl` 数出 `CreateHwndRenderTarget` 是槽 14；
- 填充 `D2D1_RENDER_TARGET_PROPERTIES` 与 `D2D1_HWND_RENDER_TARGET_PROPERTIES`；
- `BeginDraw` / `Clear` / `EndDraw` 的槽位 48 / 47 / 49。
