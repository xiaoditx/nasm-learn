# 第 06 章：CRT 启动、wmain 与第一套 Makefile

> 本章开始进入"有构建系统"的阶段：每章配 `Makefile`，编译自动生成 `.lst`。
> 本章源码：[hello_wmain.asm](hello_wmain.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[hello_wmain.obj.lst](hello_wmain.obj.lst)

## 1. 本章目标

阶段零（00~05）一直用 `ld --entry=_start` 自己指定入口，不依赖 CRT。本章换一种方式：

- 让 **CRT 负责进程启动**，入口符号是 `wmain`（宽字符版 `main`）；
- 用 `wprintf` 输出宽字符串；
- 建立全项目共用的 `common.asm`；
- 写出第一套 `Makefile`，把 `nasm`、`gcc`、`.lst` 生成串起来；
- 把 Windows x64 ABI 的"四件套"正式讲完整。

跑通后你应该能回答：

- `global wmain` 和 `global main` 有什么区别？`-municode` 在做什么？
- `Makefile` 里的 `$@`、`$<`、`$^` 各指什么？
- 为什么入口处 `RSP % 16 == 8`，而 `call` 执行时必须是 `0`？
- 32 字节影子空间到底给谁用？
- 哪些寄存器改了必须还原？
- `.lst` 中 `4883EC20`、`E8(00000000)` 分别代表什么？

## 2. 前置 / 项目结构

本章真正需要的前置是：`default rel` 与 `[rel label]` 的基本写法（第 00 章引入，第 02 章继续练习）、`lea` 取地址（第 02～03 章），以及栈帧序言 `push rbp / mov rbp, rsp / sub rsp, N`（第 05 章）。第 04 章的旧式 16 位代码迁移是选读，不影响本章。

```text
nasm-learn/
├── common.asm                共享常量与宏（只有预处理指令）
└── 06-crt-makefile/
    ├── Makefile
    ├── hello_wmain.asm
    ├── README.md
    └── hello_wmain.obj.lst   make 后生成
```

本目录只有 `.asm` 源码，没有 `.c/.cpp/.inc`。`common.asm` 用 `%include "../common.asm"` 引入，路径相对于**当前工作目录**（Makefile 在章节目录里执行 `nasm`）。

## 3. 知识点讲解

### 3.1 CRT 启动与 `wmain`

阶段零的 `_start` 是"裸入口"：栈由内核设置好，`ret` 不可靠（见第 05 章）。本章改用 **CRT（C Runtime）启动**，启动流程变成：

```text
进程加载
  └─ 内核 → ntdll 启动
       └─ wmainCRTStartup（UCRT 提供）
            ├─ 初始化堆、I/O、全局对象
            └─ call wmain（我们写的入口）
                 └─ 返回值 → ExitProcess
```

入口是 `wmain` 而不是 `main`，因为全项目走 **W 版 API（宽字符）**。`wmain` 的签名是：

```c
int wmain(int argc, wchar_t **argv);
```

- `argc`：命令行参数个数（含程序名本身）；
- `argv`：UTF-16 字符串指针数组，`argv[argc] == NULL`。

链接时要给 gcc 加 `-municode`，否则 CRT 默认找 ANSI 的 `main`，会报 `undefined reference to WinMain`。

### 3.2 共享定义 `common.asm`

`common.asm` 只放预处理指令（`%define`、宏、`struc`、`equ`），**不产生任何段或数据**，因此每个 `.asm` 都可以安全 `%include`，不会出现重复符号。本章用到的关键定义：

| 定义 | 值 | 含义 |
|---|---|---|
| `WCHAR_SIZE` | `2` | UTF-16 码元字节数 |
| `FRAME_SUB_RSP` | `32` | `push rbp` 之后再 `sub rsp, 32` 留影子空间 |
| `NULL` | `0` | 空指针/空值 |

宽字符串宏（在 `common.asm` 里定义）：

```asm
%macro WSTR 1         ; 展开为 UTF-16LE 码元，不带结尾 0
    dw __utf16__(%1)
%endmacro

%macro WSTRZ 1        ; 展开为 UTF-16LE 码元，并追加一个 0 结尾
    dw __utf16__(%1), 0
%endmacro
```

`WSTR` **不带结尾 0**，换行和字符串终止要自己补：

```asm
msg_args: WSTR "wmain received %d argument(s)"
          dw 10, 0        ; UTF-16 的 LF（10），再补结尾 0
```

如果后面直接跟另一个标签又没补 0，`wprintf("%ls")` 会一路读进下一个字符串。这是第 10 章实际踩过的坑。

### 3.3 Windows x64 ABI 四件套

这里集中学习完整规则；后续章节只回顾当前调用需要的部分，不再把整套规则当作新知识重复讲解。

#### 3.3.1 前四个参数：RCX / RDX / R8 / R9

| 参数序号 | 整数/指针寄存器 | 浮点寄存器 |
|---|---|---|
| 1 | `RCX` | `XMM0` |
| 2 | `RDX` | `XMM1` |
| 3 | `R8` | `XMM2` |
| 4 | `R9` | `XMM3` |
| 5 及以后 | `[rsp + 32]`、`[rsp + 40]`…… | 同样从 `[rsp + 32]` 开始 |

第 5 个参数不是随便放的：调用者必须先预留 32 字节影子空间，然后从 `[rsp + 32]` 开始依次写入。

`wmain` 被 CRT 调用时：`ECX = argc`，`RDX = argv`。

#### 3.3.2 32 字节影子空间

调用任何 Windows x64 函数前，调用者要在自己的栈上留出 **32 字节**。被调用者可以把 `RCX/RDX/R8/R9` 溢出到这块区域，调试器也依赖它。**哪怕函数只有 1 个参数，也要留**。

```asm
sub rsp, 32          ; 只留影子空间
sub rsp, 48          ; 32 影子 + 16 字节本地槽
```

#### 3.3.3 16 字节对齐

- 进程入口（包括 `wmain` 被 CRT 调用时）：`RSP % 16 == 8`；
- `call` 指令执行的那一刻：`RSP % 16 == 0`；
- 被调用函数刚进入时：`RSP % 16 == 8`（返回地址占 8 字节）。

所以标准的两种序言：

```asm
; 方式 A：叶子函数，不需要帧指针
sub rsp, 40          ; 8（对齐）+ 32（影子）

; 方式 B：需要帧指针
push rbp             ; RSP 从 8 变 0
mov rbp, rsp
sub rsp, 32          ; 影子空间
```

本章用方式 B。`sub rsp, 32` 之后 `RSP % 16 == 0`，可以安全 `call`。

#### 3.3.4 非易失寄存器

| 类别 | 寄存器 | 规则 |
|---|---|---|
| 非易失 | `RBX`、`RBP`、`RDI`、`RSI`、`R12`~`R15`、`XMM6`~`XMM15` | 被调用者如果修改，必须恢复 |
| 易失 | `RAX`、`RCX`、`RDX`、`R8`~`R11`、`XMM0`~`XMM5` | 调用后内容不保证 |

本章 `wmain` 只动 `RAX/RCX/RDX`，都属于易失寄存器，因此除了 `RBP` 之外没有额外保存。

### 3.4 Windows 变参函数：按“槽位”传参，不看 `AL`

`wprintf` 是变参函数，也就是参数个数由格式串决定的函数：

```c
int wprintf(const wchar_t *format, ...);
```

本章第一次调用等价于 `wprintf(msg_args, argc)`。它总共两个参数，所以映射非常直接：

| 参数槽位 | 实际值 | 调用前放置位置 |
|---|---|---|
| 固定参数 `format` | `msg_args` 的地址 | `RCX` |
| 第一个可变参数 | `argc`，32 位 `int` | `EDX` |

如果格式串里还有第二、第三个转换项，就继续使用 `R8`、`R9`；第五个参数槽才放到 `[rsp+32]`。**参数槽位由参数位置决定，不由格式符的字符个数决定。**

必须特别纠正一个常见混淆：**Windows x64 不使用 `AL` 记录浮点参数数量**。`AL = XMM 寄存器参数个数` 是 Linux/macOS 常见 System V AMD64 ABI 的变参规则，不能套到本章。Windows x64 对变参函数中的浮点参数采用“同一个值同时放对应 XMM 和整数寄存器槽”的规则；本章只有整数参数，不涉及这种双写。

源码在 `call wprintf` 前保留 `xor eax, eax`，只是把 `RAX` 清零，**不是 Windows ABI 的必需步骤**，可以把它理解为演示代码留下的无害指令。最后 `wmain` 返回前的 `xor eax, eax` 则确实有必要，因为它把返回值设为 0；两处指令相同，目的不同。

还要区分“参数已经放好”和“格式串是否匹配”：ABI 只负责把值送到约定位置。若格式串写 `%d`，就必须提供兼容的 32 位整数；若写 `%p`，就应提供指针宽度的值。类型不匹配不会由 NASM 自动发现。

### 3.5 Makefile 基础

```make
NASM := nasm
CC   := gcc

NASMFLAGS := -f win64
CFLAGS    := -municode

TARGET := hello_wmain.exe
OBJS   := hello_wmain.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all run clean
```

要点：

- `:=` 是"立即展开"，变量值当场确定；
- `$@` = 目标名（`hello_wmain.exe`），`$^` = 全部依赖，`$<` = 第一个依赖；
- `%.obj: %.asm ../common.asm` 是模式规则：任何 `.obj` 都由同名 `.asm` 生成；`common.asm` 改动后所有对象都会重编；
- `-l $@.lst` 生成 `hello_wmain.obj.lst`（注意 `.obj` 和 `.lst` 拼在一起的名字）；
- `-municode` 让 gcc 链接 `wmainCRTStartup`；
- `$(OBJS:.obj=.obj.lst)` 把 `hello_wmain.obj` 变成 `hello_wmain.obj.lst`，供 `clean` 删除；
- `.PHONY` 声明 `all/run/clean` 不是真实文件。

### 3.6 第一次执行 make 时究竟发生了什么

`make` 不是编程语言解释器在“运行 exe”，它先根据目标和依赖构造一张更新图。首次构建时：

```text
all
 └─ hello_wmain.exe
     └─ hello_wmain.obj
         ├─ hello_wmain.asm
         └─ ../common.asm
```

因为 `.exe` 不存在，`make` 先发现需要 `.obj`；`.obj` 也不存在，于是执行模式规则中的 NASM 命令。此时自动变量展开为：

```text
$@ = hello_wmain.obj       当前规则要生成的目标
$< = hello_wmain.asm       第一个依赖
$^ = hello_wmain.asm ../common.asm
```

生成 `.obj` 后再回到 EXE 规则：`$@ = hello_wmain.exe`，`$^ = hello_wmain.obj`，所以链接命令变成 `gcc -municode -o hello_wmain.exe hello_wmain.obj`。

第二次立刻执行 `make`，若目标比所有依赖都新，就会显示“无需处理”或类似提示，而不是机械地重编。修改 `common.asm` 后它的时间戳比三个章节的对象文件新，依赖它的对象才会重建。可以用 `make -n` 只显示将执行的命令，用 `make clean` 删除生成物后强制走一遍完整流程。

Makefile 的配方行必须以 **Tab** 开头，不能用四个空格代替；这是初学者手写 Makefile 时最常见的语法错误之一。

## 4. 实践用例

打开 [hello_wmain.asm](hello_wmain.asm)。程序打印 `argc` 和三行宽字符串，返回 0 作为退出码。

### 4.1 构建与运行

在 `06-crt-makefile` 目录下：

```powershell
make
.\hello_wmain.exe alpha beta
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l hello_wmain.obj.lst -o hello_wmain.obj hello_wmain.asm
gcc -municode -o hello_wmain.exe hello_wmain.obj
wmain received 3 argument(s)
hello from wmain
built with nasm + gcc, wide API by default
0
```

也可以：

```powershell
make run
make clean
```

`make clean` 会删除 exe、obj 和 `.obj.lst`。

> 如果 `nasm` 不在 PATH，先执行 `$env:PATH = "C:\Program Files\NASM;" + $env:PATH`（第 00 章的约定）。

### 4.2 `.lst` 摘录

`make` 生成 `hello_wmain.obj.lst`。`wmain` 部分摘录：

```text
    24 00000000 55                          push    rbp
    25 00000001 4889E5                      mov     rbp, rsp
    26 00000004 4883EC20                    sub     rsp, FRAME_SUB_RSP      ; 32 字节影子空间
    29 00000008 89CA                        mov     edx, ecx
    30 0000000A 488D0D(00000000)            lea     rcx, [rel msg_args]
    31 00000011 31C0                        xor     eax, eax
    32 00000013 E8(00000000)                call    wprintf
    42 00000034 31C0                        xor     eax, eax
    43 00000036 C9                          leave
    44 00000037 C3                          ret
```

四列分别是：源码行号、段内偏移、机器码、源码。

几个关键点：

- `55` = `push rbp`（1 字节）；`4889E5` = `mov rbp, rsp`（3 字节）；`4883EC20` = `sub rsp, 32`（4 字节），`20` 就是 32；
- `89CA` = `mov edx, ecx`：`89` 是 `mov r/m32, r32`，`CA` 编码 `edx <- ecx`；
- `31C0` = `xor eax, eax`，2 字节，用来清零 `AL`；
- `E8(00000000)` 里的 `00000000` 是**尚未重定位**的相对位移；链接后 `objdump -d` 才能看到真实值；
- `C9` = `leave`，`C3` = `ret`；
- 偏移不连续（`0x13` 到 `0x34`）是因为中间有 `.rdata` 的行号，`.text` 的偏移只统计代码字节。

### 4.3 GDB 指令级验证栈对齐

CRT 程序的 `wmain` 是一个普通函数，可以下断点。实测：

```powershell
gdb -q -batch `
  -ex "set pagination off" `
  -ex "b wmain" `
  -ex "run alpha beta" `
  -ex "info registers rip rsp rcx rdx" `
  -ex "si" `
  -ex "si" `
  -ex "si" `
  -ex "info registers rsp rbp" hello_wmain.exe
```

关键输出：

```text
Thread 1 hit Breakpoint 1, 0x00007ff747b01450 in wmain ()
rip            0x7ff747b01450
rsp            0x5ffe58            0x5ffe58
rcx            0x3                 3
rdx            0x710700            7407360
...
rsp            0x5ffe30            0x5ffe30
rbp            0x5ffe50            0x5ffe50
```

- 入口 `RSP = 0x...e58`，`% 16 == 8`；
- `RCX = 3` 就是 `argc`（程序名 + alpha + beta）；
- 三条 `si` 执行完 `push rbp` / `mov rbp,rsp` / `sub rsp,32`，`RSP = 0x...e30`，`% 16 == 0`；
- `RBP = 0x...e50`，正好是保存旧 `RBP` 的位置。

GDB 在这里是**指令级**：`si` 单步一条指令，`disas` 看反汇编，不要期待源码级单步。

## 5. 代码重点讲解

1. **序言 `push rbp / mov rbp, rsp / sub rsp, FRAME_SUB_RSP`（知识点 3.3）**：`FRAME_SUB_RSP=32`。入口 `RSP%16==8` → `push rbp` 后 `0` → `sub rsp,32` 后仍 `0`，`call wprintf` 合法。`32` 字节全部是影子空间（本章没有本地槽）。

2. **`mov edx, ecx` 把 `argc` 传给 `wprintf`（知识点 3.3.1）**：`wmain` 的第一个参数 `argc` 在 `ECX`。此时还没做任何 `call`，`ECX` 还是原值，所以不需要先存到本地槽。`wprintf` 的第一个可变参数放 `RDX`，正好用 `mov edx, ecx` 接上。

3. **`lea rcx, [rel msg_args]`（RIP 相对寻址）**：`default rel` 让标签默认按 RIP 相对寻址。`lea` 只算地址不访问内存，比 `mov rcx, msg_args` 更符合 PIC 习惯。

4. **调用前的 `xor eax, eax` 不是 Windows 的 `AL` 要求（知识点 3.4）**：它只是清零 `RAX`，对本章整数版 `wprintf` 调用无害但非必需。不要把它背成 Windows 变参规则；最后返回前的同一指令才是设置 `wmain` 返回值 0。

5. **`xor eax, eax / leave / ret`**：`wmain` 的返回值就是进程退出码。`leave` = `mov rsp, rbp` + `pop rbp`，然后 `ret` 回到 CRT，CRT 会把返回值传给 `ExitProcess`。返回 0 表示成功。

6. **`default rel` + `%include "../common.asm"`**：文件开头两行。前者开启 RIP 相对寻址（见第 03 章），后者把 `common.asm` 的宏和常量展开进来，不产生任何段。

## 6. 常见坑

1. **忘了 `-municode`**：CRT 找 `main`，链接报 `undefined reference to WinMain`。
2. **把 System V 的 `AL` 规则搬到 Windows**：Windows x64 的 `wprintf` 不要求调用前设置 `AL`。真正容易出错的是格式符与参数类型不匹配、槽位顺序错误、栈未对齐或影子空间不足。
3. **`WSTR` 后忘记补 `dw 0`**：下一段数据会被当成字符串的一部分。要么用 `WSTRZ`，要么紧跟 `dw 10, 0`。
4. **本地槽放进影子空间**：`sub rsp, 32` 时 `[rbp-8]` 正好在影子空间里，`call` 会覆盖它。要么把槽放在更高的地址（`[rbp-8]` 之上？不，`[rbp-8]` 已经在 `sub rsp,32` 的范围内）。正确做法是额外分配，例如 `sub rsp, 48`，让影子空间位于 `rsp..rsp+31`，本地槽位于 `rbp-16..rbp-1` 之类。第 07 章会实际演示这个坑。
5. **`make clean` 把 `.lst` 删了**：`.lst` 是生成物，需要时重新 `make`。
6. **以为 `wmain` 的 `argv` 是 ANSI**：`wmain` 的 `argv` 是 `wchar_t **`，每个元素是 UTF-16 字符串。
7. **在本环境里直接 `wprintf` 打印中文看到 `????`**：UCRT 会按窄字符输出转换，当前 locale 下非 ASCII 可能变成 `?`。第 11 章用 `WideCharToMultiByte(CP_UTF8)` + `WriteFile` 解决。

## 7. 练习

1. 把 `wmain` 的返回值改成 `7`，确认 `$LASTEXITCODE` 为 7。
2. 用 `%ls` 打印 `argv[0]`，观察它是完整路径还是程序名。
3. 运行 `make -n`，只看命令不执行，确认模式规则的展开结果。
4. 用 `objdump -p hello_wmain.exe | Select-String "DLL Name"` 查看导入了哪些 DLL。
5. 删除 `Makefile` 里的 `-municode`，观察链接错误，再恢复。
6. 把 `sub rsp, FRAME_SUB_RSP` 改成 `sub rsp, 24`，在 GDB 里检查 `call` 前 `RSP % 16`，解释为什么错。

## 8. 下一章

第 07 章进入 `wmain` 的参数表：

- `argv` 是一个指针数组，`argv[argc] == NULL`；
- 用 `argv[i]` 遍历宽字符串；
- 实际演示"本地槽不能放进影子空间"的坑；
- 继续用 `wprintf` 的 `%d / %p / %ls` 组合。
