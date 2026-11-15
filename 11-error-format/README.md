# 第 11 章：错误码与系统错误文本

> 本章源码：[errorfmt.asm](errorfmt.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[errorfmt.obj.lst](errorfmt.obj.lst)

## 1. 本章目标

Win32 API 不会通过返回值告诉你所有细节，很多失败信息在"最后错误码"里。本章：

- 打开一个不存在的文件，拿到 `INVALID_HANDLE_VALUE`；
- 立刻调用 `GetLastError`，得到 `2`；
- 用 `FormatMessageW` 把错误码转成系统文本；
- 用 `WideCharToMultiByte(CP_UTF8)` + `WriteFile` 输出中文；
- 演示 `FormatMessageW` 的 7 个参数如何分配寄存器和栈。

## 2. 前置 / 项目结构

前置知识：第 08 章 `CreateFileW` 与 `GetLastError`、第 10 章 UTF-16 码元概念。本章首次使用 `FormatMessageW` 和 `WideCharToMultiByte`，这两个函数参数多（7~8 个），后几个必须放栈上。

```text
nasm-learn/11-error-format/
├── Makefile
├── errorfmt.asm
├── README.md
└── errorfmt.obj.lst
```

## 3. 知识点讲解

### 3.1 `GetLastError`：先判断失败，再立即保存

`GetLastError` 没有参数，返回当前线程保存的一个 **32 位 `DWORD` 错误码**，所以结果看 `EAX`。它不是“所有 API 共用的全局变量”，也不会在每次成功调用后可靠地清零。通用判断顺序是：

```text
调用 API
  → 按该 API 的文档检查返回值
  → 只有返回值表示失败，才调用 GetLastError
  → 立即把 EAX 保存到本地槽
  → 再清理资源、格式化或调用其他 API
```

“立即”不是要求连一条 `mov` 都不能有，而是中间不要插入可能改变线程错误状态的 API。下面才是可复用的失败路径骨架：

```asm
    call    CreateFileW
    cmp     rax, INVALID_HANDLE_VALUE
    jne     .opened
    call    GetLastError            ; 失败后先取原因
    mov     dword [rbp-12], eax     ; 保存 DWORD
    ; 此后才可以 wprintf、CloseHandle 或调用其他函数
.opened:
    ; 成功路径使用 RAX 中的有效句柄
```

**本章现有源码需要带着批判性阅读**：它在 `CreateFileW` 之后先调用 `wprintf` 打印返回句柄，随后才调用 `GetLastError`，并且事先没有检查 `INVALID_HANDLE_VALUE`。这与上述契约不一致。当前环境里常常仍显示 2，但那依赖中间调用没有改变错误状态，不能作为通用保证。学习“错误码获取时机”时应以本节的顺序为准，不要复制源码的先后次序。

同样，不能仅用 `GetLastError()==0` 判断上一次调用成功。某些 API 成功时也可能设置非零值，另一些 API 的文档甚至说明不使用最后错误码；返回值永远是第一判断依据。

### 3.1.1 错误码是 32 位 DWORD，不是句柄或负数返回值

`ERROR_FILE_NOT_FOUND` 的数值为 2，`ERROR_PATH_NOT_FOUND` 为 3，`ERROR_ACCESS_DENIED` 为 5。它们是系统定义的整数标识，应优先比较常量而不是依赖文本。

本章第一次打开失败时涉及三种不同数据：

| 数据 | 位宽 | 本章示例 | 用途 |
|---|---:|---|---|
| `CreateFileW` 返回的句柄 | 64 | `0xFFFFFFFFFFFFFFFF` | 仅表示打开失败，不能说明原因 |
| `GetLastError` 返回的错误码 | 32 | `EAX=2` | 表示 `ERROR_FILE_NOT_FOUND` |
| `FormatMessageW` 返回的码元数 | 32 | 随系统语言变化 | 表示文本长度，不是错误码 |

源码格式串使用 `%lu` 打印错误码。Windows 的 `unsigned long` 即使在 x64 下仍是 **32 位**，所以把 `EDX` 作为可变参数与 `%lu` 对应是合适的；不要套用某些 64 位 Unix 平台 `unsigned long=64位` 的规则。`%p` 则对应 64 位指针宽度的句柄值，所以源码使用完整 `RDX`。

### 3.2 `FormatMessageW`：错误码 → 系统文本

```c
DWORD FormatMessageW(
    DWORD   dwFlags,        // ECX
    LPCVOID lpSource,       // RDX
    DWORD   dwMessageId,    // R8D
    DWORD   dwLanguageId,   // R9D
    LPWSTR  lpBuffer,       // [rsp+32]
    DWORD   nSize,          // [rsp+40]
    va_list *Arguments      // [rsp+48]
);
```

本章只需把新类型读作：`LPWSTR` 是可写的 UTF-16 缓冲区指针，`LPCVOID` 是只读内存指针。`va_list *Arguments` 用于提供消息模板里的插入数据；本章传入 `NULL` 并设置 `FORMAT_MESSAGE_IGNORE_INSERTS`，不需要先学习 C 语言可变参数的实现。

返回值：写入的**码元数**（不包含结尾 0）。

标志位（本章用到）：

| 标志 | 值 | 含义 |
|---|---|---|
| `FORMAT_MESSAGE_FROM_SYSTEM` | `0x1000` | 从系统消息表查找 |
| `FORMAT_MESSAGE_IGNORE_INSERTS` | `0x200` | 忽略 `%1` 之类的插入参数 |
| 合计 | `0x1200` | |

- `lpSource = NULL`：从系统消息表查，不需要自己提供消息源；
- `dwMessageId`：错误码（如 2）；
- `dwLanguageId = 0`：让系统按当前语言选择；
- `lpBuffer`：接收缓冲区；
- `nSize`：缓冲区容量，单位是**码元数**（不是字节）；
- `Arguments = NULL`：本章同时指定 `IGNORE_INSERTS`，不提供插入参数。

### 3.2.1 标志位、插入项和返回值分别控制什么

`dwFlags` 是按位组合，不是随意选择的函数编号。除了本章两个标志，还会经常见到：

| 标志 | 值 | 与本章模式的关系 |
|---|---:|---|
| `FORMAT_MESSAGE_FROM_SYSTEM` | `0x1000` | 本章使用：查系统消息表 |
| `FORMAT_MESSAGE_FROM_HMODULE` | `0x0800` | 从指定模块的消息资源查，此时 `lpSource` 是模块句柄 |
| `FORMAT_MESSAGE_ALLOCATE_BUFFER` | `0x0100` | 让 API 分配输出内存；`lpBuffer` 的含义随之变成“接收指针的地址”，用完要 `LocalFree`，本章没有采用 |
| `FORMAT_MESSAGE_IGNORE_INSERTS` | `0x0200` | 本章使用：不把 `%1` 等序列当插入项展开 |

`FROM_SYSTEM` 与 `FROM_HMODULE` 指定不同消息来源，不应不加区分地全部 OR 在一起。`0x1200 = 0x1000 | 0x0200` 的逐位计算是：bit 12 与 bit 9 置 1，其余为 0。

`FormatMessageW` 自己不是 `wprintf` 那样的变参函数；它固定有 7 个参数，最后一个参数恰好是 `va_list *` 类型。消息模板中的 `%1`、`%2` 是 **FormatMessage 插入项编号**，不是 printf 的 `%d/%s`。`IGNORE_INSERTS` 的语义是不展开这些序列并原样保留，不是自动删除 `%1` 字符。对本章这种不需要路径等插入数据的系统错误文本，这是最省事的模式。

成功时 `EAX` 是写入的 UTF-16 码元数，不含结尾 0，缓冲区通常带有 0 终止；失败时返回 0，此时才可读取新的 `GetLastError`。系统消息经常自带 `CRLF`，所以后续若要拼接单行日志，应利用返回长度先去掉尾部 `\r\n`，而不是盲目再补换行。

### 3.3 `WideCharToMultiByte`：UTF-16 → UTF-8

```c
int WideCharToMultiByte(
    UINT   CodePage,            // ECX
    DWORD  dwFlags,             // EDX
    LPCWSTR lpWideCharStr,      // R8
    int    cchWideChar,         // R9D
    LPSTR  lpMultiByteStr,      // [rsp+32]
    int    cbMultiByte,         // [rsp+40]
    LPCSTR lpDefaultChar,       // [rsp+48]
    LPBOOL lpUsedDefaultChar    // [rsp+56]
);
```

返回值：写入的**字节数**。

- `CodePage = CP_UTF8`（65001）：转成 UTF-8；
- `cchWideChar`：码元数；
- `cbMultiByte`：目标缓冲区字节数；
- `lpDefaultChar` / `lpUsedDefaultChar`：对 `CP_UTF8` 必须传 `NULL`；UTF-8 不需要用默认替代字符表示无法映射的 Unicode。

为什么不用 `WriteConsoleW`？因为本环境的 stdout 可能是 PowerShell 管道或重定向文件，而不是控制台句柄；`WriteConsoleW` 只对控制台有效。`WriteFile` 可以写管道和文件，也能在当前控制台输出场景中工作，因此本章统一走字节输出。

### 3.3.1 正数长度、`-1` 长度和结尾 0

`cchWideChar` 有两种模式，不能混淆返回值：

| 输入方式 | 输入是否必须 0 终止 | 转换内容 | 返回字节数是否包含 UTF-8 的 0 |
|---|---|---|---|
| `cchWideChar > 0` | 不必须 | 恰好指定数量的 UTF-16 码元 | 不包含，因为调用者没要求转换终止符 |
| `cchWideChar = -1` | 必须 | 一直读到并包含结尾 0 | 包含 |

本章 `print_utf8(s, chars)` 使用 `FormatMessageW` 返回的正数长度，所以只转换正文，不追加 UTF-8 终止符。随后 `WriteFile(..., byteCount, ...)` 又使用显式字节数，因此不需要终止符。若把同一缓冲区交给 `%s` 等窄字符串函数，才需要另行补 0。

### 3.3.2 固定容量与“两次调用”查询容量

UTF-16 到 UTF-8 不是固定的“一个码元变两个字节”：ASCII 通常 1 字节，常用汉字通常 3 字节，代理对对应的码点通常 4 字节。因此不能简单用 `chars*2` 作为 UTF-8 容量。

本章使用固定 `utf8_buf[1024]`，`cbMultiByte=1024`。容量不足时转换返回 0，源码直接跳到 `.done`，没有打印失败原因；这是教学示例的简化。更通用的做法是先查询：

```c
int needed = WideCharToMultiByte(CP_UTF8, 0, s, chars,
                                 NULL, 0, NULL, NULL);
```

第一次调用的输出指针为 `NULL`、容量为 0，成功返回值就是所需字节数；确认 `needed > 0` 后准备足够缓冲区，再用相同输入长度调用第二次。若使用 `cchWideChar=-1`，查询值也会包含终止符所需的一个字节。

本章还省略了 `GetStdHandle`/`WriteFile` 的失败检查和实际写入字节数检查。完整封装应检查标准句柄、`WriteFile` 的 `BOOL` 与 `written==byteCount`。`msg_buf` 和 `utf8_buf` 都是全局单份缓冲区，适合单线程演示；并发调用同一个 `print_utf8` 会互相覆盖，不能直接当作可重入库函数。

### 3.4 ABI 四件套（本章复述）

#### 3.4.1 RCX / RDX / R8 / R9

`FormatMessageW` 7 个参数、`WideCharToMultiByte` 8 个参数，前 4 个在寄存器，后 3~4 个在栈（见 3.2、3.3）。

#### 3.4.2 32 字节影子空间

`wmain` 用 `sub rsp, 128`，`print_utf8` 用 `sub rsp, 96`。两者都能容纳各自需要的栈参数，且保持 16 字节对齐。

以 `print_utf8` 调用 `WideCharToMultiByte` 为例，执行 `push rbp; mov rbp,rsp; sub rsp,96` 后，`rsp=rbp-96`，调用前的布局是：

| 区域 | 以 RSP 表示 | 以 RBP 表示 |
|---|---|---|
| 32 字节影子空间 | `[rsp+0..31]` | `[rbp-96..-65]` |
| 第 5 参数 `lpMultiByteStr` | `[rsp+32]` | `[rbp-64]` |
| 第 6 参数 `cbMultiByte` | `[rsp+40]` | `[rbp-56]` |
| 第 7 参数 `lpDefaultChar` | `[rsp+48]` | `[rbp-48]` |
| 第 8 参数 `lpUsedDefaultChar` | `[rsp+56]` | `[rbp-40]` |
| 已保存的字符串、长度、字节数、句柄 | 不使用上述区域 | `[rbp-32..-1]` |

源码的 `written` 使用 `[rbp-36..-33]`，与第 8 参数槽的高 4 字节重叠，但它是在 `WideCharToMultiByte` 返回之后才作为 `WriteFile` 的输出变量使用，此时旧第 8 参数已经不再需要，所以当前指令顺序可以工作。写通用函数模板时最好不要依赖这种生命周期错开：额外分配 16 字节，把局部变量与所有 outgoing 参数槽彻底分开，更容易审查和维护。

#### 3.4.3 16 字节对齐

入口 8 → `push rbp` 后 0 → `sub rsp, 128/96` 后 0。两个函数的 `call` 点都对齐。

#### 3.4.4 非易失寄存器

本章没有修改 `RBX/RDI/RSI/R12~R15`。`RBP` 由序言保存和恢复。

### 3.5 `wprintf` 缓冲与 `WriteFile` 顺序

`wprintf` 有内部缓冲（行缓冲或全缓冲），`WriteFile` 没有。如果先 `wprintf` 几行，再 `WriteFile` 输出错误文本，结果会是 `WriteFile` 的内容先出现。

修正：`wprintf` 之后、`WriteFile` 之前调用 `fflush(NULL)` 刷新所有输出流。

## 4. 实践用例

打开 [errorfmt.asm](errorfmt.asm)。程序打开不存在的 `no_such_file.txt`，取错误码，转成系统文本，再用 UTF-8 输出。

### 4.1 构建与运行

```powershell
make
.\errorfmt.exe
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l errorfmt.obj.lst -o errorfmt.obj errorfmt.asm
gcc -municode -o errorfmt.exe errorfmt.obj
CreateFileW returned FFFFFFFFFFFFFFFF
GetLastError() = 2
FormatMessageW() = 13 chars
system message: 系统找不到指定的文件。

0
```

系统语言不同，`FormatMessageW` 返回的文本会不同；`error=2` 和 `13 chars` 可能变化。末尾空行来自系统消息自带的 `CRLF` 加上本章补的一个换行。退出码 `0`。

### 4.2 `.lst` 摘录

```text
   116 000000ED B900120000                  mov     ecx, 0x1200
   117 000000F2 31D2                        xor     edx, edx
   118 000000F4 448B45F4                    mov     r8d, dword [rbp - 12]
   119 000000F8 4531C9                      xor     r9d, r9d
   120 000000FB 488D05(00000000)            lea     rax, [rel msg_buf]
   121 00000102 4889442420                  mov     qword [rsp + 32], rax
   122 00000107 48C744242800020000          mov     qword [rsp + 40], 512
   123 00000110 48C744243000000000          mov     qword [rsp + 48], NULL
   124 00000119 E8(00000000)                call    FormatMessageW
   126 0000011E 85C0                        test    eax, eax
   127 00000120 744A                        jz      .format_failed
   128 00000122 8945F0                      mov     dword [rbp - 16], eax
   140 00000144 31C9                        xor     ecx, ecx
   141 00000146 E8(00000000)                call    fflush
```

读法：

- `B900120000`：`mov ecx, 0x1200`（`FORMAT_MESSAGE_FROM_SYSTEM | IGNORE_INSERTS`）；
- `4889442420`：`mov [rsp+32], rax`；
- `48C744242800020000`：`mov qword [rsp+40], 512`；
- `E8(00000000)`：调用外部函数，链接后由重定位填上真实位移；
- `31C9`：`xor ecx, ecx`（`fflush(NULL)`）。

## 5. 代码重点讲解

1. **错误码获取顺序需要修正（知识点 3.1）**：典型失败确实是 `CreateFileW` 返回 `INVALID_HANDLE_VALUE`，错误码 2 表示 `ERROR_FILE_NOT_FOUND`。但源码实际顺序是“保存句柄 → `wprintf` → `GetLastError`”，不是旧文档所说的“下一条立即取错误码”。这段输出可用于观察典型现象，正确写法仍应先检查失败并保存错误码，再打印。

2. **`FormatMessageW` 的 7 个参数（知识点 3.2）**：前 4 个在寄存器（`ECX=0x1200`、`EDX=NULL`、`R8D=错误码`、`R9D=0`），后 3 个在栈（`lpBuffer`、`nSize=512`、`Arguments=NULL`）。`nSize` 单位是码元数，不是字节。返回值 `EAX` 是写入的码元数（13）。

3. **`print_utf8` 的 `WideCharToMultiByte`（知识点 3.3）**：8 个参数，前 4 个寄存器（`ECX=CP_UTF8`、`EDX=0`、`R8=宽串`、`R9D=码元数`），后 4 个栈（`lpMultiByteStr`、`cbMultiByte=1024`、`NULL`、`NULL`）。返回字节数，再 `WriteFile` 到 stdout。

4. **`fflush(NULL)` 保证输出顺序（知识点 3.5）**：`wprintf` 有缓冲，`WriteFile` 没有。先 `wprintf "system message: "`，再 `fflush(NULL)` 刷新，最后 `print_utf8` 直写，顺序才对。

5. **`print_utf8` 用 `WriteFile` 而非 `WriteConsoleW`（知识点 3.3）**：stdout 在管道/重定向时不是控制台句柄，`WriteConsoleW` 会失败；`WriteFile` 对管道、文件、控制台都可靠。

6. **`GetStdHandle(STD_OUTPUT_HANDLE)`**：`STD_OUTPUT_HANDLE = -11`，返回标准输出句柄，传给 `WriteFile`。

## 6. 常见坑

1. **失败后先做了别的事再 `GetLastError`**：错误码可能已被覆盖；本章源码先 `wprintf` 的顺序就是反例，应改成先检查返回值并保存错误码。
2. **`nSize` 传字节数**：`FormatMessageW` 的单位是 WCHAR 数，不是字节。
3. **`lpBuffer` 没留够空间**：本章留了 512 个码元；太小会返回失败。
4. **忘记 `FORMAT_MESSAGE_IGNORE_INSERTS`**：消息里如果有 `%1`，可能触发插入参数解析。
5. **把返回值当字节数**：返回值是码元数；转 UTF-8 后字节数由 `WideCharToMultiByte` 给出。
6. **混用 `wprintf` 和 `WriteFile` 不 flush**：输出顺序会乱。
7. **在管道里用 `WriteConsoleW`**：stdout 不是控制台句柄，调用失败。
8. **以为错误文本一定是英文**：系统语言决定文本，解析时不要依赖具体字符串。
9. **系统消息自带换行**：再补一个换行会出现空行。

## 7. 练习

1. 把文件名改成 `C:\Windows\System32\config\SAM`，观察是否得到 `ERROR_ACCESS_DENIED (5)`。
2. 去掉 `FORMAT_MESSAGE_IGNORE_INSERTS`，看看消息文本有什么变化。
3. 把 `nSize` 改成 8，观察 `FormatMessageW` 是否因缓冲区太小而失败，并立即记录新的错误码。
4. 让程序在成功取到错误文本时返回 0，否则返回 1，用 `$LASTEXITCODE` 验证。
5. 用 `MessageBoxW` 显示错误文本（GUI 章节只编译不运行，避免弹窗卡住）。
6. 把 `print_utf8` 改成输出到文件，比较 UTF-8 和 UTF-16 的字节数。

## 8. 下一章

第 12 章是阶段一综合练习：

- 多文件：`main.asm` + `io.asm` + `text.asm`；
- 模块间函数调用与共享结构体；
- 写文件、读回、统计字符/行/单词；
- 多目标 `Makefile` 与自检退出码。
