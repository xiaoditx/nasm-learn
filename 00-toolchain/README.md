# 第 00 章：NASM 源码骨架与第一个 Windows 程序

> 本章没有 Makefile。阶段零全部采用"单文件 + README 命令"的方式。
> 本章源码：[hello.asm](hello.asm)
> 本章清单：[hello.lst](hello.lst)

## 1. 本章目标

本章只做一件事：**不借助 C 运行库（CRT）的启动与输出函数，自己指定入口，写出一个能运行的 64 位 Windows 程序。**

主线只有四步：认识源码中的名字 → 汇编并链接 → 运行后查看退出码 → 用清单核对两条数据复制指令。RIP 相对寻址、Windows 调用约定、PE（Windows 可执行文件格式）内部结构和 GDB 都只介绍当前所需的最小直觉，后续章节再逐层展开；不要求在本章一次掌握。

学完本章你应该能回答：

- `magic`、`slot`、`_start` 中哪些是作者起的名字？`section`、`global`、`extern` 分别给谁下命令？
- `nasm` 和 `ld` 各产出什么文件？为什么两条命令都要执行？
- `mov rax, [rel magic]` 与 `mov [rel slot], rax` 各复制了什么？
- `default rel` 为什么是伪指令？`sub rsp, 40` 为哪次函数调用做准备？
- 如何用 `.lst` 和 `objdump` 核对机器码、入口和依赖库？

GDB 指令级调试是随后的验证实验，不是理解上述内容的额外门槛。

前置：理解高级语言中的变量、函数和十六进制记数；NASM 3.02 已在 PATH，MinGW 的 `ld`、GDB 与 objdump 可用。

第一次接触汇编时，请按 [汇编入门前言](../preface/README.md) 的“最小必读路线”准备。你不需要提前掌握栈、Windows ABI 或 PE 结构；本章遇到这些词时会先给当前所需的解释。

## 2. 知识点讲解

### 阅读准备：先分清“我们起的名字”和“NASM 的写法”

先看本章真正要复制的两份数据：

```asm
magic dq 0x1122334455667788
slot  resq 1

mov rax, [rel magic]
mov [rel slot], rax
```

- `magic` 和 `slot` **不是指令，也不是 NASM 保留字**，只是作者为两个存储位置起的名字，作用类似高级语言中的变量名。把 `magic` 改成 `source_value` 并不影响程序含义。
- `dq` 表示“在这里放一个有初始值的 8 字节数据”；`resq 1` 表示“保留 1 个 8 字节空间”。它们由 NASM 处理，不是 CPU 执行的动作。
- `mov` 才是 CPU 指令。这里先把 `mov rax, [rel magic]` 理解为“把 `magic` 处的 8 字节复制到 RAX”，把第二条理解为“再把 RAX 的 8 字节复制到 `slot`”。
- 方括号表示按地址访问内存；`rel` 是找到这个地址的一种写法，马上在 2.3 节解释。

源码中的 `default`、`section`、`global`、`extern`、`dq`、`resq` 都是在告诉**汇编器或链接器如何工作**，与 `mov` 这类最终由 CPU 执行的指令不同。先建立这个区分，再看三段式骨架。

### 2.1 `.asm` 文件的三段式骨架

一个最小的 NASM 程序由三个段组成，分工明确：

| 段 | 作用 | 特点 |
|---|---|---|
| `.data` | 已初始化数据 | 有初始值，会写进 PE 文件，占用磁盘空间 |
| `.bss` | 未初始化数据 | 只保留空间，文件里不占字节，加载时由系统清零 |
| `.text` | 代码 | 可执行指令 |

数据定义用 `db`（1 字节）/`dw`（2 字节）/`dd`（4 字节）/`dq`（8 字节）——"d"是 define，后跟宽度。空间保留用 `resb`/`resw`/`resd`/`resq`——"res"是 reserve。**两者不能混用**：`.data` 用 `dq`，`.bss` 用 `resq`。

### 2.2 `global` 与 `extern`：和链接器的契约

- `global _start`：把 `_start` 这个标签**导出**给链接器。`ld --entry=_start` 要靠它找到入口。
- `extern ExitProcess`：声明一个**外部符号**。`ExitProcess` 不在本文件里，链接时由 kernel32 导入库解析；具体机制留到第 21 章，本章只需知道 `extern` 不是函数定义。

`_start` 也是作者选定的入口标签，下划线并非必须。只要 `global` 导出的名字与 `ld --entry=` 后写的名字一致即可；Windows 并没有要求所有程序都使用 `_start` 这个名字。

### 2.3 从 `[magic]` 到 `[rel magic]`：先会读，再理解 `default rel`

`magic` 是我们前面定义的数据标签。程序运行时，这个标签会对应一个内存地址；`[magic]` 表示访问那个地址中的内容，而不是访问字母 m、a、g、i、c。

x64 常用 **RIP 相对寻址**来找到这类全局数据。RIP（Instruction Pointer，指令指针）记录 CPU 当前取指的位置；`rel` 是 relative（相对）的缩写。`[rel magic]` 可以分两步读：

```text
先由 NASM/链接器记录“magic 距离这条指令有多远”
CPU 执行时再以指令位置为基准找到 magic，并访问其中的数据
```

`default rel` 是一条 **NASM 伪指令**：它告诉汇编器，后面写 `[magic]` 时默认按 `[rel magic]` 处理。它本身不会变成 CPU 指令。本章仍显式写 `[rel magic]`，只是为了让寻址方式在源码中可见，并不是写了两遍。

现在只需记住：

- `mov rax, [rel magic]`：读取 `magic` 地址中的 8 字节；
- `lea rax, [rel magic]`：只计算 `magic` 的地址放入 RAX，不读取该地址的内容。

“位移怎样编码、为什么能让代码不依赖固定装载地址”留到第 02 章结合内存布局再讲；本章不展开 32 位位移、代码模型和重定位。

### 2.4 先用会 `sub rsp, 40`：为 `call ExitProcess` 准备栈

`RSP` 是栈指针，栈是函数调用时使用的一块内存。第 05 章才会完整讲 `call` 怎样使用栈；本章调用 `ExitProcess` 前，只需先遵守 Windows x64 的两条规则：

1. 执行 `call` 时，RSP 要是 16 的倍数；
2. 调用者还要在栈上预留 32 字节，供被调用函数临时使用。这 32 字节叫**影子空间**（shadow space），即使 `ExitProcess` 只有一个参数也不能省略。

本程序入口观察到 `RSP % 16 == 8`，所以减去 40：

```text
40 = 8（让 RSP 从余 8 调整为 16 的倍数）+ 32（影子空间）
sub rsp, 40 后，RSP % 16 == 0，可以执行 call
```

这就是本章对 `sub rsp, 40` 的全部要求。入口为什么呈现这个状态、`call/ret` 如何压入和弹出返回地址，将在第 05 章展开；完整 Windows x64 调用约定在第 06 章整理。现在不必学习 SSE、异常码或其他 ABI 细节。

### 2.5 `.lst` 清单：汇编器的"对账表"

`nasm -l hello.lst` 生成的清单文件有四列：

| 列 | 含义 |
|---|---|
| 源码行号 | 对应 `.asm` 的第几行 |
| 段内偏移 | 该指令在当前 section 内的偏移（不是最终虚拟地址） |
| 机器码 | 实际字节 |
| 源码 | NASM 看到的原始语句 |

几个关键现象：
- `(00000000)`：这里有一个地址位移要等链接时才能确定；“链接器后补地址或位移”叫重定位。本章只需认出占位符，不手算它。
- `????????????????`（`.bss`）：只占大小，文件里没有字节。
- 指令长度可以直接从机器码列数出来（`sub rsp,40` 是 4 字节 `4883EC28`）。

### 2.6 按需调试：GDB 的 `si` 而非 `s`

第一次学习时，先完成构建、运行和 `.lst` 核对即可；这一小节可以等到做 3.5 的调试实验时再读。GDB 是用来逐条观察指令、寄存器和内存的工具，不是学习本章其余内容的前提。

NASM 产出的 Win64 目标文件即使加 `-g`，GDB 的源码级调试信息也不完美。阶段零需要调试时统一用：

- `si` / `stepi`：**指令级**单步，永远可用。
- `disas`：你的"源码窗口"，对照 `.lst` 看当前指令。
- `info registers`：看寄存器值。
- `x`：看内存。

**不要**用 `s` / `step`（源码级单步）——没有行号信息时行为不理想。

### 2.7 用 objdump 验证结果，而不是背 PE 结构

PE（Portable Executable）是 Windows 可执行文件格式；`.exe` 不只有机器码，还带有入口位置、依赖库等描述信息。`objdump -p` 用来查看这些信息。本章只核对三项：

- `Subsystem`：程序按控制台还是图形界面（GUI）方式启动；本章 `--subsystem console` 对应值 3；
- `AddressOfEntryPoint`：链接器记录的程序入口位置；
- `DLL Name`：程序依赖哪些动态链接库（DLL）。本例只应出现 `KERNEL32.dll`。

PE 头布局、装载地址和导入表内部结构都不是本章主线，需要时再查前言第 6 节。

### 2.8 逐行读 `hello.asm`

完整源码很短，但每一行属于不同层面。先按类别读，不要把它当成一整块咒语。

#### 注释与预处理

```asm
default rel
```

这不是 CPU 指令，不会出现在 `.text` 机器码中。它告诉 NASM：后面遇到 `[magic]` 这类内存地址时，默认按 RIP 相对方式编码。源码仍显式写 `[rel magic]`，是为了让初学者一眼看出寻址方式。

分号 `;` 后到行尾是注释。注释帮助人阅读，不参与汇编。

#### 节区与数据

```asm
section .data
magic dq 0x1122334455667788

section .bss
slot resq 1
```

`magic`、`slot` 是标签。`dq` 在文件中写入 8 字节初始值；`resq 1` 保留 1 个 qword，即 8 字节，但不往文件写 8 个零。

这里容易把“变量声明”和“执行赋值”混淆：这两行只安排静态存储，CPU 不会依次执行它们。真正的复制发生在后面的两条 `mov`。

#### 链接声明

```asm
section .text
global _start
extern ExitProcess
```

- `section .text`：以下内容属于代码节；
- `global _start`：让 `_start` 成为其他文件和链接器可见的符号；
- `extern ExitProcess`：声明函数由外部提供，本文件只产生调用和重定位信息。

`global/extern` 都是汇编期声明，不会在运行时“执行一次”。

#### 入口标签与第一条指令

```asm
_start:
    sub rsp, 40
```

`_start:` 末尾的冒号定义代码位置。Windows 加载器准备进程后，会根据 PE 头中的入口地址开始执行；链接器通过 `--entry=_start` 把这个标签写进入口信息。

`sub rsp,40` 是第一条真正由 CPU 执行的指令。十进制 40 等于十六进制 `0x28`，所以 `.lst` 机器码最后是 `28`。它一次完成对齐修正和 32 字节影子空间预留，推导见知识点 2.4。

#### 两次内存访问

```asm
mov rax, [rel magic]
mov [rel slot], rax
```

第一条：RAX 是 64 位，所以从 `magic` 地址读取 8 字节。执行后：

```text
RAX = 0x1122334455667788
magic 中仍是原值，mov 不是“移动后清空”
```

第二条：RAX 表明写入宽度为 8 字节，把这 8 字节复制到 `slot`。此时 magic 与 slot 各有一份相同的值。

所谓 `mov` 更接近“复制”，不是把源位置搬走。

#### API 调用与进程结束

```asm
mov ecx, 42
call ExitProcess
```

先查函数原型，再决定参数放哪里：

```c
void ExitProcess(unsigned int uExitCode);
```

只有一个 32 位整数参数，因此放入 ECX；写 ECX 同时清除 RCX 高 32 位。`call` 时 RSP 已对齐且有 32 字节影子空间。

`ExitProcess` 会结束当前进程，正常不返回。后面的：

```asm
add rsp, 40
xor eax, eax
ret
```

只是防御性收尾，正常执行不到。不能删除 `call ExitProcess`，却指望这三行成为标准退出方式；第 05 章会专门解释入口直接 `ret` 的问题。

### 2.9 退出码、控制台输出与图形窗口是三种不同结果

本章运行后看不到文字，因为源码没有调用任何输出函数。结果通过进程退出码交给父进程，PowerShell 用 `$LASTEXITCODE` 查看。

```text
没有控制台文字 ≠ 程序没有运行
退出码 42      = 本章事先约定的观察结果
```

Windows 退出码是 32 位值，不是只能取 0～255。本章选 42 只是为了便于识别。后续某些章节会主动 `and eax,0xFF` 截取低 8 位，那是示例为了得到短结果，不是系统强制限制。

### 2.10 为什么必须重新执行两条构建命令

只修改 `.asm` 后，磁盘上旧 `.obj` 和旧 `.exe` 不会自动变化：

```text
修改 hello.asm
  → 重新 nasm，得到新 hello.obj
  → 重新 ld，得到新 hello.exe
  → 运行新 hello.exe
```

若只执行 `nasm` 后直接运行，运行的仍是旧 EXE；若只执行 `ld`，链接的仍是旧 OBJ。第 06 章的 Makefile 会根据时间戳自动完成这两个步骤，但底层顺序不变。

## 3. 实践用例

学完上面的知识点，打开 [hello.asm](hello.asm) 对照阅读。这个程序做的事很简单：从 `.data` 读一个 8 字节常量，复制到 `.bss`，然后用退出码 42 结束。

### 3.1 构建命令

在本目录下执行：

```powershell
nasm --version

nasm -f win64 -l hello.lst -o hello.obj hello.asm

ld -o hello.exe hello.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start

.\hello.exe
$LASTEXITCODE
```

| 参数 | 作用 |
|---|---|
| `-f win64` | 输出 x64 Windows 目标文件，其中保存机器码和链接所需信息 |
| `-l hello.lst` | 生成清单文件 |
| `-o hello.obj` | 目标文件名 |
| `-L "C:/msys64/ucrt64/lib"` | MinGW 导入库目录 |
| `-lkernel32` | 链接 `libkernel32.a`，提供 `ExitProcess` |
| `--subsystem console` | PE 子系统设为控制台 |
| `--entry=_start` | 指定入口符号，必须和 `global _start` 一致 |

> 关于 `-l $@.lst`：阶段零手动写死 `-l hello.lst`。从第 06 章起用 Makefile，模式规则写成 `nasm -f win64 -l $@.lst -o $@ $<`，其中 `$@` 是目标名。

### 3.2 运行结果

程序没有控制台输出，**退出码就是结果**：

```text
PS> .\hello.exe
PS> $LASTEXITCODE
42
```

### 3.3 `.lst` 摘录

```text
    19 00000000 8877665544332211            magic dq 0x1122334455667788
    23 00000000 ????????????????            slot resq 1

    38 00000000 4883EC28                    sub rsp, 40
    41 00000004 488B05(00000000)            mov rax, [rel magic]
    42 0000000B 488905(00000000)            mov [rel slot], rax
    46 00000012 B92A000000                  mov ecx, 42
    47 00000017 E8(00000000)                call ExitProcess
```

### 3.4 objdump 检查

```powershell
objdump -p hello.exe | Select-String "Subsystem|AddressOfEntryPoint|DLL Name|ExitProcess"
```

实际输出：

```text
AddressOfEntryPoint     0000000000001000
ImageBase               0000000140000000
Subsystem               00000003        (Windows CUI)
DLL Name: KERNEL32.dll
        00005038  <none>  017c  ExitProcess
```

导入表里只有 `KERNEL32.dll` 的 `ExitProcess`，没有 `msvcrt`，说明确实是"零 CRT"。

### 3.5 GDB 实测

```text
(gdb) b _start
(gdb) run
(gdb) info registers rip rsp
rip            0x00007ff69f431000
rsp            0x5fff28        ← 末位 8，RSP % 16 == 8

(gdb) si
(gdb) info registers rsp
rsp            0x5fff00        ← 末位 0，sub rsp,40 后 RSP % 16 == 0

(gdb) info registers rax
rax            0x1122334455667788
```

## 4. 代码重点讲解

以下几点把实践代码与知识点回扣起来：

1. **`sub rsp, 40`（知识点 2.4）**：`4883EC28`，4 字节。入口 `RSP%16==8`，减 40（`8+32`）后 `%16==0`。这是调用 Windows API 的前提，本章只用一次 `ExitProcess`，但规矩从第一章立。
2. **`mov rax, [rel magic]` vs `mov [rel slot], rax`（知识点 2.3）**：前一句从 `.data` 取 8 字节内容，后一句写入 `.bss`。方括号始终是"取/存内容"，RIP 相对寻址由 `rel` 指定。
3. **`mov ecx, 42`（知识点 2.4 / 第 01 章预告）**：写 32 位寄存器会自动把高 32 位清零，所以 `RCX` 正确等于 42。如果写 `mov cx, 42`（16 位），高位残留垃圾，`ExitProcess` 收到的退出码就不对。
4. **`call ExitProcess`**：参数走 `RCX`（第 1 参数），`ExitProcess` 不返回，所以后面的 `add rsp,40` / `ret` 只是防御性代码。
5. **`.lst` 里的 `(00000000)`（知识点 2.5）**：`mov rax,[rel magic]` 的 RIP 位移在汇编时还不知道（取决于链接后 `.data` 与 `.text` 的相对位置），留待 `ld` 填写。

## 5. 常见坑

1. **`ld: cannot find hello.obj`**：先执行 `nasm`，再执行 `ld`。
2. **入口找不到**：`global _start` 与 `--entry=_start` 必须一致。
3. **`mov rax, magic` 与 `mov rax, [rel magic]` 混淆**：前者取地址，后者取内容；取地址推荐 `lea rax, [rel magic]`。
4. **忘记 `sub rsp, 40`**：可能"看起来能跑"，但对齐已非法，后续章节会越来越明显。
5. **`mov cx, 42` 而非 `mov ecx, 42`**：16 位写入不清零高位。
6. **`.bss` 用了 `dq`**：`.bss` 只能用 `res*`。
7. **NASM 大小写敏感**，十六进制用 `0x1234`（不要写 MASM 的 `1234h`）。
8. **GDB 显示 `0x7ff...` 而非 `0x140001000`**：ASLR 正常现象，用符号和 `% 16` 判断。
9. **用 `s` 期待源码单步**：阶段零请用 `si`。
10. **`ExitProcess` 之后的代码**：正常永远执行不到。

## 6. 练习

1. 把退出码改成 `7`，重新构建并检查 `$LASTEXITCODE`；在 `.lst` 里确认 `mov ecx, 7` 的机器码是 `B907000000`。
2. 在 `.data` 增加 `magic2 dq 0xDEADBEEFCAFEBABE`，在 `.bss` 增加 `slot2 resq 1`，把两个值都复制过去，用 GDB 的 `x/gx` 验证。
3. 删掉 `sub rsp, 40` 再运行，开 GDB 看 `RSP % 16`，解释"为什么即使侥幸能跑仍然是错的"。
4. 用 `objdump -d hello.exe` 找到 `ExitProcess` 的 `jmp *...(%rip)` thunk，说明它跳到哪张表。
5. 试试用 `starti` 代替 `b _start`，比较两种进入方式。

## 7. 下一章

第 01 章进入寄存器全景：`RAX~R15`、8/16/32/64 位子寄存器、`RIP` 与 `RSP/RBP` 的角色，以及 `movzx/movsx`。仍然不调用任何外部函数，仍然用 `.lst` + GDB 观察。
