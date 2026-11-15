# 第 20 章：_start 入口 —— 摆脱 CRT 的第一步

> 从本章起进入**阶段三：彻底摆脱 C 运行时**。第一步不是换掉编译器，而是换掉"入口"：
> 不再让 CRT 的 `wmainCRTStartup` 替我们开场，自己从 PE 入口点 `_start` 接管一切。
> 本章源码：[start.asm](start.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[start.obj.lst](start.obj.lst)

## 1. 本章目标

- 搞清楚 CRT 启动文件（`wmainCRTStartup`）到底替我们做了什么；
- 用 `gcc -nostartfiles -Wl,-e,_start` 链接出**不含任何 CRT 启动代码**的程序；
- 在 `_start` 里自己完成三件以前由 CRT 代劳的事：取命令行、输出、退出；
- 用 `objdump -p` 实证：导入表里**没有 msvcrt / ucrtbase**，只有 `KERNEL32.dll`；
- 实际运行，用退出码 42 验证流程走通。

本章是**控制台程序，会实际运行**（以退出码为准；输出文字的原因分析见第 4 节）。

跑通后你应该能回答：

- `_start` 的第一条指令执行时，`RCX` 里是 `argc` 吗？
- 为什么 `wmain` 里写 `return 0` 就行，自定义 `_start` 却应显式调用 `ExitProcess`，而不是依赖 `ret`？
- `-nostartfiles` 去掉了什么？为什么还要 `-Wl,-e,_start`？
- 为什么说"WriteConsoleW 在重定向下失败"恰好说明了 CRT 存在的意义？

## 2. 前置 / 项目结构

前置：第 06 章的 CRT 与 ABI、第 08 章的句柄、第 10 章的 UTF-16 码元。本章新增的是绕过 CRT 后的入口与退出责任，不再引入新的调用约定。

```text
nasm-learn/
├── common.asm            ENTRY_SUB_RSP / STD_OUTPUT_HANDLE / WSTR 宏
└── 20-no-crt-start/
    ├── Makefile
    ├── start.asm
    ├── README.md
    └── start.obj.lst       make 后生成
```

只有 `.asm` 源码。链接器命令里**不再有 `-municode`**——那个选项的作用是"把 CRT 入口选成 `wmainCRTStartup`"，而本章根本没有 CRT 入口了。

## 3. 知识点讲解

### 3.1 ABI 复习：无 CRT 入口仍要遵守同一套约定

第 06 章已经系统讲过这些规则。这里只强调 `WriteConsoleW` 的第 5 参数，以及 `_start` 与普通函数在返回方式上的差别。

**① 参数传递：前四进寄存器，其余走栈**

| 参数位置 | 整数/指针 | 去向 |
|---|---|---|
| 1 | `HANDLE hConsoleOutput` | `RCX` |
| 2 | `const VOID *lpBuffer` | `RDX` |
| 3 | `DWORD nNumberOfCharsToWrite` | `R8D` |
| 4 | `LPDWORD lpNumberOfCharsWritten` | `R9` |
| 5+ | `LPVOID lpReserved` | `[rsp + 32]` 起，每个 `qword` |

本章用得最多的 `WriteConsoleW` 是 5 参数函数：第 5 个参数 `lpReserved` 必须写到 `[rsp + 32]`，且必须写 `qword`——写 `dword` 会留下高 32 位垃圾。

**② 32 字节影子空间**

调用任何 Windows x64 函数前，调用者必须在栈上留出 32 字节，供被调用者保存前四个参数寄存器。即使函数只有 1 个参数，这 32 字节也必须留。本章 `_start` 一进来就 `sub rsp, 40`：

```text
40 = 32（影子空间） + 8（一个栈参数槽：WriteConsoleW 的第 5 参数）
```

`common.asm` 把它定义为 `ENTRY_SUB_RSP`。所有 API 调用都复用这 40 字节，不再增减。

**③ 16 字节对齐**

```text
_start 入口（本工具链与系统环境实测）  RSP % 16 == 8
sub rsp, 40                           RSP % 16 == 0
```

它与普通函数入口的余 8 数值相同，但不能据此推断一定是某个加载器函数执行了 `call`。`_start` 也没有 `wmain(argc, argv)` 那套寄存器参数约定；本章只采用当前环境实测的栈对齐前提，并通过后续调实验证。普通函数仍遵循：**入口处 `RSP % 16 == 8`，`call` 指令执行前 `RSP % 16 == 0`**。

**④ 非易失寄存器**

`RBX/RBP/RDI/RSI/R12～R15/XMM6～XMM15` 是普通被调方必须保存的非易失寄存器。本章 `_start` 最终以 `ExitProcess` 终结整个进程，不会返回后继续执行调用者代码，因此不需要为“返回后的调用者”恢复 `RBX/RSI`。这是进程入口主动不返回带来的简化，**不表示 `_start` 没有加载器管理的外层执行帧，也不能类推到普通函数**。本章用 `RBX` 存控制台句柄、`RSI` 存命令行指针。

> 反过来也成立：只要我们还想调 API，那 40 字节栈帧和 16 字节对齐就必须维持，因为 **API 内部会按 ABI 假设我们的栈**。

### 3.2 CRT 启动文件到底做了什么

以前链接出来的 `wmain` 程序，真正的 PE 入口是 CRT 提供的 `wmainCRTStartup`，它大致做了：

```text
wmainCRTStartup:
    初始化 CRT 堆 / 全局对象 / 浮点环境
    调 GetCommandLineW + CommandLineToArgvW 解析出 argc / argv
    调 wmain(argc, argv, envp)
    把 wmain 的返回值交给 exit() → 收尾 → ExitProcess
```

`-nostartfiles` 把这段代码整个拿掉之后：

| 以前 CRT 代劳 | 现在怎么办 |
|---|---|
| 解析命令行为 argc/argv | 自己调 `GetCommandLineW`（本章只打印原串；解析练习可用 `CommandLineToArgvW`） |
| 提供 wprintf 等输出 | 直接调 `WriteConsoleW` |
| return 后收尾退出 | 必须显式 `ExitProcess` |
| 默认入口符号 | `-Wl,-e,_start` 显式指定 |

为什么必须显式指定入口：MinGW `ld` 对控制台程序的默认入口符号是 `mainCRTStartup`；拿掉 CRT 启动文件后这个符号不存在，不给 `-e` 就会得到警告 `cannot find entry symbol mainCRTStartup; defaulting to ...`——碰巧指到 `.text` 开头也许能跑，但那是运气，不是工程。

### 3.3 WriteConsoleW 与重定向：CRT 存在的意义

`WriteConsoleW` **只能写控制台屏幕缓冲区**。当进程的标准输出被重定向到管道（IDE、CI、`cmd /c start.exe | more`）或文件时，`GetStdHandle` 拿到的是管道/文件句柄，`WriteConsoleW` 对它返回 `FALSE` 并报 `ERROR_INVALID_FUNCTION`（错误码 1）。

这恰好回答了“CRT 有什么用”：CRT 输出层需要处理同类职责，例如区分控制台与其他输出句柄，并在需要时完成宽字符到目标编码的转换；具体实现路径取决于所用 CRT。第 23 章我们会亲手实现一套检测与转码逻辑。

## 4. 实践用例

本章 [start.asm](start.asm) 的功能：`_start` 入口 → 取控制台句柄 → 取命令行并统计长度 → 输出问候语 → `ExitProcess(42)`。

### 4.1 构建与运行

```powershell
make
.\start.exe
Write-Host "EXIT=$LASTEXITCODE"
```

真实输出（在本仓库的构建环境，即"输出被管道重定向"的场景）：

```text
nasm -f win64 -l start.obj.lst -o start.obj start.asm
gcc -nostartfiles -Wl,-e,_start -o start.exe start.obj -lkernel32
EXIT=42
```

退出码 42 证明：入口 → 取命令行 → 三次 WriteConsoleW → ExitProcess 全部走完。

**为什么看不到 `cmdline: ...` 的文字输出？** 这是本章最重要的一个现象，GDB 实测（断点设在第一次 `WriteConsoleW` 返回后）：

```text
Breakpoint 1, 0x00007ff7b4141036 in _start ()
$1 = 0x0                      ← WriteConsoleW 返回 FALSE（失败）
$2 = 1                        ← GetLastError() = 1 = ERROR_INVALID_FUNCTION
```

原因即知识点 3.3：标准输出被重定向到管道时，`WriteConsoleW` 对非控制台句柄失败。

在**真实控制台窗口**（双击 exe，或在独立 cmd / PowerShell 窗口中运行）里，这个程序会正常显示：

```text
cmdline: 20-no-crt-start\start.exe
hello from _start (no CRT startup)
```

### 4.2 objdump 实证：CRT 真的没了

```powershell
objdump -p start.exe | Select-String "Subsystem|DLL Name|ImageBase"
```

真实输出：

```text
ImageBase               0000000140000000
Subsystem               00000003        (Windows CUI)
        DLL Name: KERNEL32.dll
```

对比带 CRT 的程序，导入表里会出现 `msvcrt.dll` 或 `api-ms-win-crt-*`（ucrtbase）。本章只有 `KERNEL32.dll`——**程序的每一行启动代码都是我们自己写的**。

### 4.3 `.lst` 摘录

**入口指令**：

```text
   41                                  _start:
   42 00000000 4883EC28                    sub     rsp, ENTRY_SUB_RSP
```

`4883EC28`：`48` REX.W，`83EC` = `sub rsp, imm8`，`28` = 40。`_start` 位于 `.text` 偏移 0，链接后就是 PE 的 `AddressOfEntryPoint`。

**API 调用是"待重定位"的**：

```text
   46 00000009 E8(00000000)                call    GetStdHandle
```

`E8` 是 `call rel32`，但目标地址在括号里写成 `(00000000)`——汇编器不知道 `GetStdHandle` 最终在哪，留下一个 **R_X86_64_PC32 重定位项**，由链接器在生成 exe 时填上"到 IAT 桩的相对距离"。`.lst` 里所有括号数字都是这类"链接时才确定"的占位。

**命令行长度统计循环**：

```text
   64 00000040 66833C5600                  cmp     word [rsi + rdx*2], 0
   65 00000045 7405                        je      .len_done
   66 00000047 48FFC2                      inc     rdx
   67 0000004A EBF4                        jmp     .len_loop
```

`66833C5600`：`66` 操作数大小前缀（16 位），`83 /7` = `cmp r/m16, imm8`，ModRM+SIB `3C56` 表示 `[RSI + RDX*2]`，立即数 `00`。`EBF4` 是 `jmp rel8`，`F4` = -12，跳回 5 条指令之前。字符串以 UTF-16 码元计，所以索引用 `rdx*2`。

**ExitProcess(42)**：

```text
  102 000000D9 B92A000000                  mov     ecx, 42
  103 000000DE E8(00000000)                call    ExitProcess
```

`2A` = 42。这之后没有 `ret`——`ExitProcess` 不返回，进程在此终结。

### 4.4 GDB 实测：入口时刻的寄存器

```powershell
gdb -q -batch -ex "b _start" -ex run -ex "p/x `$rsp" -ex "p (long)`$rsp % 16" `
    -ex "i r rcx rdx" -ex si -ex "p (long)`$rsp % 16" ./start.exe
```

真实输出（整理过）：

```text
Breakpoint 1, 0x00007ff7b4141000 in _start ()
$1 = 0x5fff28                 ← 入口 RSP
$2 = 8                        ← RSP % 16 == 8，与 ABI 约定一致
rcx = 0x3a8000                ← 不是 argc！
rdx = 0x7ff7b4141000          ← 也不是 argv（碰巧等于映像内地址，ntdll 内部行为）
$3 = 0                        ← sub rsp,40 之后 % 16 == 0
```

结论：`_start` 入口时**寄存器内容没有约定**，想要参数必须自己调 API。这一点与 `wmain`（RCX=argc、RDX=argv）形成鲜明对比。

## 5. 代码重点讲解

1. **`sub rsp, ENTRY_SUB_RSP`（知识点 3.1 ②③）**：入口 `RSP%16==8`，减 40（32 影子 + 8 栈参槽）后 `%16==0`，之后每个 `call` 点都对齐。这是整个 `_start` 唯一的栈帧调整。

2. **`mov ecx, STD_OUTPUT_HANDLE` + `GetStdHandle`（知识点 3.1 ①）**：`STD_OUTPUT_HANDLE = -11`，机器码 `B9F5FFFFFF`（`-11` 的 32 位补码 `0xFFFFFFF5`）。返回的句柄存进 `RBX`。本章 `_start` 最终以 `ExitProcess` 结束进程，不会返回后继续执行调用者代码，所以这里不为返回后的调用者恢复 `RBX`；普通函数不能照抄这种简化。

3. **自取命令行 + 内联 wcslen（知识点 3.2）**：CRT 的 `argc/argv` 本质上就是从 `GetCommandLineW` 的返回值解析出来的。本章只统计长度用于打印，循环里 `cmp word [rsi + rdx*2], 0` 按 UTF-16 码元扫描，所以索引是 `rdx*2`。

4. **`WriteConsoleW` 的长度是码元数不是字节数（知识点 3.3）**：第三个参数 `R8D` 传的是 UTF-16 码元个数。若误传字节数会输出两倍的"字符"，尾巴全是垃圾。第 5 参数 `lpReserved` 写到 `[rsp+32]`，必须是 `qword`。

5. **`ExitProcess(42)` 而非依赖 `ret`（知识点 3.1④/3.2）**：自定义入口由加载器接管，返回后的行为与退出状态不应由应用代码猜测；`ret` 也不是 CRT `return` 的等价物。显式 `ExitProcess` 能确定结束整个进程并设置退出码。选 42 只是为了在 `$LASTEXITCODE` 里一眼认出程序走到底。

## 6. 常见坑

1. **链接警告 `cannot find entry symbol mainCRTStartup`**：用了 `-nostartfiles` 却忘了 `-Wl,-e,_start`。也许碰巧能跑，但这是未定义行为。
2. **把 `_start` 的 `ret` 当正常退出**：它会返回加载器管理的外层帧，而不是执行 CRT 的退出清理；不同环境下的后续行为与退出状态不应依赖。要明确结束整个进程，应调用 `ExitProcess`。
3. **以为 `_start` 有 argc/argv**：入口寄存器无约定，把 `RCX` 当 argc 用迟早出事。GDB 实测 `rcx = 0x3a8000`，根本不是参数。
4. **`WriteConsoleW` 的长度传成字节数**：会输出两倍的"字符"，尾巴全是垃圾。长度单位是 UTF-16 码元。
5. **第 5 参数写 `mov dword [rsp+32], 0`**：高 32 位残留垃圾，API 行为未定义。写 `qword`。
6. **在管道/重定向环境"看不到输出"就以为程序错了**：`WriteConsoleW` 对非控制台句柄失败是设计行为（见知识点 3.3），先看退出码，再用真实控制台验证文字。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item start.exe,start.obj,start.obj.lst`。

## 7. 练习

1. 把退出码改成 `GetCommandLineW` 返回串的码元长度（提示：`rdx` 里已经是），用 `$LASTEXITCODE` 验证。
2. 去掉 `-Wl,-e,_start` 重新链接，观察警告内容；再用 `objdump -f` 看 `start address` 指向哪里。
3. 用 `CommandLineToArgvW`（`shell32.dll`）解析出 argv，逐参数打印——这基本就是自己实现一遍 CRT 的参数解析。
4. 在 `_start` 开头故意不调 `sub rsp,40` 直接调 API，用 GDB 观察 API 内部因栈未对齐而在 SSE 指令上崩溃的位置。
5. 用 `GetStdHandle(STD_ERROR_HANDLE)` 拿错误输出句柄，把 "hello" 同时写到 stdout 和 stderr。

## 8. 下一章预览

第 21 章做同一件事，但把 gcc 也拿掉：

- 直接用 `ld` 链接：`-e _start --subsystem console`；
- 搞清楚 PE 头里 `AddressOfEntryPoint`、`Subsystem`、导入表的关系；
- 链接器脚本与库搜索路径 `-L` / `-l` 在 MinGW 下的细节；
- 为第 22 章的 GUI 无 CRT 窗口做铺垫。
