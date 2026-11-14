# 第 08 章：文件 I/O —— CreateFileW / WriteFile / ReadFile / CloseHandle

> 本章源码：[fileio.asm](fileio.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[fileio.obj.lst](fileio.obj.lst)

## 1. 本章目标

本章用最原始的 Win32 API 完成一次"写文件 → 关闭 → 重开 → 读回 → 打印"：

- `CreateFileW` 的 7 个参数怎么传？
- 为什么第 5、6、7 个参数在 `[rsp+32]`、`[rsp+40]`、`[rsp+48]`？
- `INVALID_HANDLE_VALUE` 为什么等于 `-1` 而不是 `0`？
- `WriteFile` / `ReadFile` 的字节数参数是"字节"还是"字符"？
- 失败时如何关闭句柄、如何取错误码？

程序会在当前目录生成 `demo_file.txt`，内容是 3 行 UTF-16 文本。

## 2. 前置 / 项目结构

前置知识：第 06 章 ABI 四件套、第 07 章本地槽布局。本章首次使用 Win32 文件 API（`CreateFileW` 等），它们都从 `kernel32.dll` 导入，不需要额外链接库（gcc 会自动处理）。

```text
rebuild/08-file-io/
├── Makefile
├── fileio.asm
├── README.md
├── fileio.obj.lst
└── demo_file.txt        运行后生成
```

`Makefile` 的 `clean` 会顺带删除 `demo_file.txt`。

## 3. 知识点讲解

### 3.1 Win32 文件 API 概览

本章用到四个函数，全部来自 `kernel32.dll`：

| 函数 | 作用 |
|---|---|
| `CreateFileW` | 打开或创建文件，返回句柄 |
| `WriteFile` | 向文件写入字节 |
| `ReadFile` | 从文件读取字节 |
| `CloseHandle` | 关闭句柄 |
| `GetLastError` | 取当前线程的最后错误码 |

句柄（`HANDLE`）是 64 位指针宽度的值，用来标识内核对象（文件、线程、进程等）。用完必须 `CloseHandle`，否则句柄泄漏。

### 3.2 ABI 四件套（本章复述）

#### 3.2.1 RCX / RDX / R8 / R9

`CreateFileW` 的 7 个参数：

```c
HANDLE CreateFileW(
    LPCWSTR lpFileName,            // RCX
    DWORD   dwDesiredAccess,       // EDX
    DWORD   dwShareMode,           // R8D
    LPSECURITY_ATTRIBUTES lpSA,    // R9
    DWORD   dwCreationDisposition, // [rsp+32]
    DWORD   dwFlagsAndAttributes,  // [rsp+40]
    HANDLE  hTemplateFile          // [rsp+48]
);
```

`WriteFile`：

```c
BOOL WriteFile(
    HANDLE  hFile,                 // RCX
    LPCVOID lpBuffer,              // RDX
    DWORD   nNumberOfBytesToWrite, // R8D
    LPDWORD lpNumberOfBytesWritten,// R9
    LPOVERLAPPED lpOverlapped      // [rsp+32]
);
```

`ReadFile` 的形状完全相同，只是第 3 个参数是"最多读多少字节"。

第 5 个及以后的参数放在栈上，从 `[rsp+32]` 开始（因为 `[rsp]` 到 `[rsp+31]` 是影子空间）。

#### 3.2.2 32 字节影子空间

本章序言：

```asm
push rbp
mov  rbp, rsp
sub  rsp, 128
```

`128` 的用途：

```text
32  影子空间
24  三个栈参数（CreateFileW 的 5/6/7）
72  本地槽
```

因为 `rsp = rbp - 128`，所以栈参数的地址是：

| 栈参数 | 地址 |
|---|---|
| 第 5 个 | `[rsp+32]` = `[rbp-96]` |
| 第 6 个 | `[rsp+40]` = `[rbp-88]` |
| 第 7 个 | `[rsp+48]` = `[rbp-80]` |

本地槽只用到 `[rbp-8]` 到 `[rbp-28]`，不会和它们重叠。

#### 3.2.3 16 字节对齐

入口 `RSP % 16 == 8`，`push rbp` 后是 `0`，`sub rsp, 128` 后仍是 `0`。所有 `call` 点都对齐。

#### 3.2.4 非易失寄存器

本章没有使用 `RBX/RDI/RSI`，句柄、计数都放在本地槽。`RBP` 由 `push rbp` / `leave` 保存和恢复。

### 3.3 `INVALID_HANDLE_VALUE`

`CreateFileW` 失败时返回 `INVALID_HANDLE_VALUE`，它的值是 `((HANDLE)-1)`，在 64 位下是 `0xFFFFFFFFFFFFFFFF`。

**不要拿 `0` 判断失败**。`0` 不是合法句柄，但 `CreateFileW` 失败约定用 `-1`，不是 `0`。其他 API（如 `HeapAlloc`）失败才返回 `NULL`（`0`）。

### 3.4 字节数 vs 字符数

`WriteFile` / `ReadFile` 的 `nNumberOfBytes*` 参数单位是**字节**，不是字符。

本章内容是 UTF-16 文本，3 行共 32 个码元，所以：

```text
content_chars = ($ - content) / WCHAR_SIZE   ; 32 个码元
content_bytes = content_chars * WCHAR_SIZE   ; 64 字节
```

写入时传 `content_bytes = 64`，不是 32。

### 3.5 失败路径与错误码

Win32 API 失败时：

1. 返回值指示失败（`INVALID_HANDLE_VALUE`、`0`、`-1` 等）；
2. 立刻调用 `GetLastError` 取得错误码；
3. 做清理（`CloseHandle`）。

**注意顺序**：`GetLastError` 必须在失败后**立刻**调用。中间只要再调用任何可能设置错误码的 API（包括 `CloseHandle`），`GetLastError` 就可能变成别的值。所以本章先 `GetLastError` 存到本地槽，再 `CloseHandle`。

### 3.6 文件指针与重开

写入完成后，文件指针在文件末尾。本章选择 `CloseHandle` 后用 `OPEN_EXISTING` + `GENERIC_READ` 重新打开，而不是 `SetFilePointerEx` 移动指针——顺便演示两种打开方式（`CREATE_ALWAYS` 写、`OPEN_EXISTING` 读）。

## 4. 实践用例

打开 [fileio.asm](fileio.asm)。程序创建 `demo_file.txt`，写入 3 行 UTF-16 文本，关闭后重新打开读回并打印。

### 4.1 构建与运行

```powershell
make
.\fileio.exe
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l fileio.obj.lst -o fileio.obj fileio.asm
gcc -municode -o fileio.exe fileio.obj
WriteFile  : 64 bytes
ReadFile   : 64 bytes
--- read back from disk ---
line one

line two

line three


0
```

出现空行是因为文件里存的是 `CRLF`（`13, 10`），而 `wprintf` 的格式串又补了一个 `LF`。这不是错误，是两种换行叠加的结果。退出码 `0`。

生成的 `demo_file.txt` 大小：

```text
Length
------
    64
```

### 4.2 `.lst` 摘录

```text
    52 00000000 55                          push    rbp
    53 00000001 4889E5                      mov     rbp, rsp
    54 00000004 4881EC80000000              sub     rsp, 128
    57 0000000B 488D0D(00000000)            lea     rcx, [rel filename]
    58 00000012 BA000000C0                  mov     edx, GENERIC_READ | GENERIC_WRITE
    59 00000017 4531C0                      xor     r8d, r8d
    60 0000001A 4531C9                      xor     r9d, r9d
    61 0000001D 48C744242002000000          mov     qword [rsp + 32], CREATE_ALWAYS
    62 00000026 48C744242880000000          mov     qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    63 0000002F 48C744243000000000          mov     qword [rsp + 48], NULL
    64 00000038 E8(00000000)                call    CreateFileW
    65 0000003D 488945F8                    mov     qword [rbp - 8], rax
    66 00000041 4883F8FF                    cmp     rax, INVALID_HANDLE_VALUE
    67 00000045 0F84ED000000                je      .fail_open
```

读法：

- `4881EC80000000`：`sub rsp, 128`，`80 00 00 00` 是小端编码的 128；
- `BA000000C0`：`mov edx, 0xC0000000`（`GENERIC_READ | GENERIC_WRITE`）；
- `48C744242002000000`：`mov qword [rsp+32], 2`；`24 20` 是 SIB，表示 `[rsp+32]`；
- `4883F8FF`：`cmp rax, -1`；
- `0F84ED000000`：`je` 的近跳转，位移 `0xED`。

## 5. 代码重点讲解

1. **`CreateFileW` 的 7 个参数（知识点 3.2.1）**：前 4 个在寄存器（`RCX`=文件名、`EDX`=访问权限、`R8D`=共享模式、`R9`=安全属性），后 3 个在栈（`[rsp+32]`=创建方式、`[rsp+40]`=属性、`[rsp+48]`=模板文件）。`GENERIC_READ | GENERIC_WRITE = 0x80000000 | 0x40000000 = 0xC0000000`。

2. **`cmp rax, INVALID_HANDLE_VALUE`（知识点 3.3）**：句柄是 64 位，必须用 `RAX`（不是 `EAX`）。`INVALID_HANDLE_VALUE = -1`，`.lst` 编码为 `4883F8FF`。失败跳到 `.fail_open`，错误码 1。

3. **`WriteFile` 的字节数 `content_bytes`（知识点 3.4）**：`content` 是 3 行 UTF-16，32 码元 × 2 = 64 字节。`nNumberOfBytesToWrite` 传 64，不是 32。`&bytesWritten` 用 `lea r9, [rbp-16]` 取本地槽地址。

4. **`lpOverlapped = NULL`**：同步调用必须把 `WriteFile` 的第 5 个参数置空。`mov qword [rsp+32], NULL`。

5. **失败路径先 `GetLastError` 再 `CloseHandle`（知识点 3.5）**：`.fail_write` 里 `call GetLastError` → 存 `[rbp-28]` → `call CloseHandle` → 打印。如果先 `CloseHandle`，错误码可能被 `CloseHandle` 自己的调用覆盖。

6. **读回缓冲区的终止符**：`read_buf` 在 `.bss` 中（`resb 512`），加载时全零。读入 64 字节后，缓冲区尾部自然有 0，可以直接作为 `%ls` 的字符串打印。如果文件正好填满 512 字节，就需要手动补 0，否则 `%ls` 会越界。

## 6. 常见坑

1. **用 `EAX` 存句柄**：句柄是 64 位指针，必须用 `RAX` / `qword`。
2. **用 0 判断失败**：`CreateFileW` 失败返回 `INVALID_HANDLE_VALUE`（-1）。
3. **栈参数写错位置**：第 5 个参数必须放在当前 `RSP + 32`，不是 `RBP + 32`。
4. **字节数传成字符数**：`WriteFile` 的单位是字节，UTF-16 要乘 2。
5. **忘记 `lpOverlapped = NULL`**：同步调用必须把第 5 个参数置空。
6. **写完后直接读**：文件指针在末尾，`ReadFile` 读不到东西；要重开或 `SetFilePointerEx`。
7. **失败路径不关句柄**：`WriteFile`/`ReadFile` 失败后仍要 `CloseHandle`。
8. **读缓冲区没有终止符**：如果文件正好填满缓冲区，`%ls` 会越界。要么多留 2 字节，要么手动补 0。
9. **共享模式给 0 时别的进程打不开**：这是本章故意设置的独占行为；需要共享时改 `dwShareMode`。

## 7. 练习

1. 把内容换成 4 行，验证写入字节数变为 `4 * 2` 的对应值。
2. 用 `SetFilePointerEx(h, 0, NULL, FILE_BEGIN)` 代替"关闭后重开"。
3. 用 `GetFileSizeEx` 打印文件大小，和 `ReadFile` 的返回字节数对照。
4. 把 `CREATE_ALWAYS` 换成 `OPEN_ALWAYS`，观察第二次运行的行为。
5. 写一个只写 ASCII 的文件，再用 `WideCharToMultiByte` 转成 UTF-8 打印。
6. 故意把文件名改成一个不存在的目录，确认 `.fail_open` 打印的错误码（应为 3，`ERROR_PATH_NOT_FOUND`）。

## 8. 下一章

第 09 章进入堆与结构体：

- `GetProcessHeap` / `HeapAlloc` / `HeapFree`；
- NASM 的 `struc` / `endstruc` / `istruc`；
- 用结构体数组和 `next` 指针串成链表；
- 在 `.lst` 中观察 `[rax + ITEM.id]` 如何变成固定偏移。
