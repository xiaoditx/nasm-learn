# 第 00 章：NASM 源码骨架与第一个裸 PE

> 本章没有 Makefile。阶段零全部采用"单文件 + README 命令"的方式。
> 本章源码：[hello.asm](hello.asm)
> 本章清单：[hello.lst](hello.lst)

## 1. 本章目标

本章只做一件事：**不碰 CRT、不碰 printf/MessageBox，自己指定入口，写出一个能运行的 64 位 Windows 程序。**

学完本章你应该能回答：

- 一个 `.asm` 文件由哪些部分构成？`section`、`global`、`extern`、标签分别是什么？
- `nasm -f win64` 到底产出了什么？它和 PE 可执行文件是什么关系？
- `ld` 的 `--entry`、`--subsystem` 在做什么？
- 为什么入口处 `RSP % 16 == 8`？`sub rsp, 40` 里的 40 是怎么来的？
- 如何用 `.lst` 和 `objdump` 看到"机器码 ↔ 汇编源码"的对应？
- 如何用 GDB 做**指令级**调试，而不是期待源码级单步？

前置：NASM 3.02 已在 PATH；MinGW 的 `ld` 可用；GDB 与 objdump 可用。

## 2. 知识点讲解

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
- `extern ExitProcess`：声明一个**外部符号**。`ExitProcess` 不在本文件里，链接时由 `libkernel32.a` 提供跳板。

注意：x64 的 C 符号**没有**前导下划线（和 32 位 MinGW 不同）。`_start` 带下划线是 Windows 的入口约定名，不是 C 符号修饰。

### 2.3 RIP 相对寻址与 `default rel`

x64 用 RIP（指令指针）相对寻址访问全局数据。`default rel` 之后，`[magic]` 会被解释为"当前 RIP + 32 位位移"；也可以显式写 `[rel magic]` 更直观。

为什么必须相对寻址？因为 64 位绝对地址需要 8 字节重定位，而 Windows x64 的代码模型假设模块装在 2GB 范围内，32 位 RIP 位移足够。相对寻址生成的代码更小、不需要绝对重定位，是 x64 的标准做法。

取数据内容用 `mov rax, [rel magic]`（方括号=取内容）；取地址用 `lea rax, [rel magic]`（lea 不访问内存，只算地址）。

### 2.4 入口栈对齐：为什么是 `sub rsp, 40`

这是 Windows x64 ABI 的第一条铁律，也是本书贯穿始终的约束：

```text
进程入口（ntdll 加载器 call 我们）→ RSP % 16 == 8   （call 压入了 8 字节返回地址）
sub rsp, 40                                       → RSP % 16 == 0   （之后每个 call 点都对齐）
```

40 的构成：

```text
8 字节   ：把入口的 8 对齐到 16
32 字节  ：Windows x64 的影子空间（shadow space）
```

**影子空间**是什么？调用任何 Windows x64 函数前，调用者必须在栈上预留 32 字节，被调函数可以随意使用这 32 字节（比如把 RCX/RDX/R8/R9 的值 spill 到栈上）。即使你调用的函数只有 1 个参数，这 32 字节也必须留。

**16 字节对齐**是什么？`call` 指令执行的那一刻，`RSP % 16` 必须等于 0。Windows API（尤其是用 SSE 的）内部会用 `movaps` 等要求 16 字节对齐的指令，对齐不对就触发 `0xC0000005` 访问违例。

本章只用 `ExitProcess`，但仍然遵守：`sub rsp, 40` 是后续所有章节的标准入口序言。

### 2.5 `.lst` 清单：汇编器的"对账表"

`nasm -l hello.lst` 生成的清单文件有四列：

| 列 | 含义 |
|---|---|
| 源码行号 | 对应 `.asm` 的第几行 |
| 段内偏移 | 该指令在当前 section 内的偏移（不是最终虚拟地址） |
| 机器码 | 实际字节 |
| 源码 | NASM 看到的原始语句 |

几个关键现象：
- `(00000000)`：待重定位的 32 位位移，链接时由 `ld` 填成真实值。
- `????????????????`（`.bss`）：只占大小，文件里没有字节。
- 指令长度可以直接从机器码列数出来（`sub rsp,40` 是 4 字节 `4883EC28`）。

### 2.6 GDB 指令级调试：`si` 而非 `s`

NASM 产出的 Win64 COFF 即使加 `-g`，GDB 的源码级调试信息也不完美。阶段零统一用：

- `si` / `stepi`：**指令级**单步，永远可用。
- `disas`：你的"源码窗口"，对照 `.lst` 看当前指令。
- `info registers`：看寄存器值。
- `x`：看内存。

**不要**用 `s` / `step`（源码级单步）——没有行号信息时行为不理想。

### 2.7 PE 头与导入表

`objdump -p` 可以读出 PE 文件头的关键字段：

- `Subsystem`：`3` = 控制台（CUI），`2` = GUI。由 `--subsystem` 决定。
- `AddressOfEntryPoint`：入口 RVA，加 `ImageBase` 得到静态地址。
- `DLL Name`：导入表依赖的 DLL。零 CRT 程序只应出现 `KERNEL32.dll`。

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
| `-f win64` | 输出 x64 Windows 的 COFF 目标文件 |
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
