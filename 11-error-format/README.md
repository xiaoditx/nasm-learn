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
rebuild/11-error-format/
├── Makefile
├── errorfmt.asm
├── README.md
└── errorfmt.obj.lst
```

## 3. 知识点讲解

### 3.1 `GetLastError` 的调用时机

Win32 API 失败时，错误码存放在线程局部存储（TLS）里，由 `GetLastError` 读出。**必须在失败后立刻调用**——中间只要再调用任何可能设置错误码的 API（包括 `CloseHandle`），错误码就可能被覆盖。

正确顺序：

```text
失败 → GetLastError → 存到本地槽 → 其他清理操作 → 打印
```

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
- `Arguments = NULL`：配合 `IGNORE_INSERTS`，不解析 `%1` 等插入参数。

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
- `lpDefaultChar` / `lpUsedDefaultChar`：UTF-8 能表示所有 Unicode，传 `NULL`。

为什么不用 `WriteConsoleW`？因为本环境的 stdout 是 PowerShell 管道，不是控制台句柄；`WriteConsoleW` 在重定向时会失败。`WriteFile` 对管道和文件都可靠。

### 3.4 ABI 四件套（本章复述）

#### 3.4.1 RCX / RDX / R8 / R9

`FormatMessageW` 7 个参数、`WideCharToMultiByte` 8 个参数，前 4 个在寄存器，后 3~4 个在栈（见 3.2、3.3）。

#### 3.4.2 32 字节影子空间

`wmain` 用 `sub rsp, 128`，`print_utf8` 用 `sub rsp, 96`。两者都能容纳 3~4 个栈参数，且保持 16 字节对齐。

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

1. **失败后立刻 `GetLastError`（知识点 3.1）**：`CreateFileW` 返回 `INVALID_HANDLE_VALUE`，下一条就是 `call GetLastError`，结果存 `[rbp-12]`。错误码 `2` = `ERROR_FILE_NOT_FOUND`。

2. **`FormatMessageW` 的 7 个参数（知识点 3.2）**：前 4 个在寄存器（`ECX=0x1200`、`EDX=NULL`、`R8D=错误码`、`R9D=0`），后 3 个在栈（`lpBuffer`、`nSize=512`、`Arguments=NULL`）。`nSize` 单位是码元数，不是字节。返回值 `EAX` 是写入的码元数（13）。

3. **`print_utf8` 的 `WideCharToMultiByte`（知识点 3.3）**：8 个参数，前 4 个寄存器（`ECX=CP_UTF8`、`EDX=0`、`R8=宽串`、`R9D=码元数`），后 4 个栈（`lpMultiByteStr`、`cbMultiByte=1024`、`NULL`、`NULL`）。返回字节数，再 `WriteFile` 到 stdout。

4. **`fflush(NULL)` 保证输出顺序（知识点 3.5）**：`wprintf` 有缓冲，`WriteFile` 没有。先 `wprintf "system message: "`，再 `fflush(NULL)` 刷新，最后 `print_utf8` 直写，顺序才对。

5. **`print_utf8` 用 `WriteFile` 而非 `WriteConsoleW`（知识点 3.3）**：stdout 在管道/重定向时不是控制台句柄，`WriteConsoleW` 会失败；`WriteFile` 对管道、文件、控制台都可靠。

6. **`GetStdHandle(STD_OUTPUT_HANDLE)`**：`STD_OUTPUT_HANDLE = -11`，返回标准输出句柄，传给 `WriteFile`。

## 6. 常见坑

1. **失败后先做了别的事再 `GetLastError`**：错误码已被覆盖。
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
3. 把 `nSize` 改成 8，确认 `FormatMessageW` 返回失败（缓冲区太小）。
4. 让程序在成功取到错误文本时返回 0，否则返回 1，用 `$LASTEXITCODE` 验证。
5. 用 `MessageBoxW` 显示错误文本（GUI 章节只编译不运行，避免弹窗卡住）。
6. 把 `print_utf8` 改成输出到文件，比较 UTF-8 和 UTF-16 的字节数。

## 8. 下一章

第 12 章是阶段一综合练习：

- 多文件：`main.asm` + `io.asm` + `text.asm`；
- 模块间函数调用与共享结构体；
- 写文件、读回、统计字符/行/单词；
- 多目标 `Makefile` 与自检退出码。
