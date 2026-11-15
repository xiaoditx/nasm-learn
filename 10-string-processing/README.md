# 第 10 章：UTF-16 字符串处理

> 本章源码：[strings.asm](strings.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[strings.obj.lst](strings.obj.lst)

## 1. 本章目标

Windows 的 W 版 API 全部使用 UTF-16。本章把字符串拆开看：

- UTF-16 的"码元"和"码点"有什么区别？
- 如何遍历一个 `wchar_t *`？
- 如何自己实现 `wlen`、ASCII 大小写转换、单词计数？
- 为什么 `%ls` 能打印宽字符串？
- 中文字符在 UTF-16 里到底是什么数值？

程序会打印样本文本的长度、大小写转换结果、单词数，以及每个码元的 `U+XXXX`。

## 2. 前置 / 项目结构

前置知识：第 06 章 ABI 四件套与 Windows 变参槽位、第 07 章本地槽布局、第 09 章 `struc` 思想（虽然本章不用结构体，但“地址 + 偏移”思路一致）。

```text
nasm-learn/10-string-processing/
├── Makefile
├── strings.asm
├── README.md
└── strings.obj.lst
```

## 3. 知识点讲解

### 3.1 UTF-16 基础

- `wchar_t` 在 Windows 上是 **2 字节**；
- UTF-16 的基本单位叫"码元"（code unit），一个码元 16 位；
- BMP（基本多文种平面，U+0000~U+FFFF）内的字符占 **1 个码元**，例如汉字"汇"是 `U+6C47`，"编"是 `U+7F16`；
- BMP 之外的字符（例如部分 emoji）用 **代理对**，占 2 个码元。本章不处理代理对，先假设都是 BMP。

本章样本：

```asm
sample: WSTR "x64 assembly 汇编"
```

`WSTR` 把它展开成 UTF-16LE：

```text
x  0x0078
6  0x0036
4  0x0034
   0x0020
a  0x0061
...
汇 0x6C47
编 0x7F16
0  0x0000  ← 由 dw 0 补上
```

长度是 15 个码元（3 + 1 + 8 + 1 + 2）。

### 3.1.1 码点、码元、字节和“用户看到的字符”不是同一层

一个 **Unicode 码点**用 `U+...` 编号；UTF-16 把这个编号编码成一个或两个 16 位码元；每个码元在 x86 内存中又按小端保存为两个字节。例如“汇”：

```text
码点：U+6C47
码元：0x6C47（一个码元）
内存：47 6C（两个字节，小端）
```

BMP 外的码点会编码成两个码元。例如 `U+1F600` 对应 `0xD83D 0xDE00`，所以 `wlen` 会把它数成 **2 个码元**，而不是 1 个码点。多个码点还可能共同组成用户在屏幕上看到的一个字形，因此“码元数”“码点数”和“屏幕字符数”都不能混为一谈。

本章只遍历和转换 BMP 样本，逐码元打印 `U+%04X`；代理对怎样合并、复杂字形怎样划分都不影响当前实验，留到真正处理完整 Unicode 文本时再学。

### 3.2 ABI 复习：本章函数怎样交接参数

#### 3.2.1 RCX / RDX / R8 / R9

本章自定义函数约定：

| 函数 | 参数 |
|---|---|
| `wlen` | `RCX` = 字符串，返回 `EAX` |
| `ascii_upper` | `RCX` = 源，`RDX` = 目标 |
| `count_words` | `RCX` = 字符串，`EDX` = 码元数，返回 `EAX` |
| `wprintf` | `RCX` = 格式，`RDX/R8/R9` = 前三个可变参数 |

#### 3.2.2 32 字节影子空间

`wmain` 序言：

```asm
push rbp
mov  rbp, rsp
sub  rsp, 64
```

`64 = 32 影子 + 32 本地槽`，`call` 点对齐。

`wlen` 是叶子函数，不调用别人，也不需要影子空间；它甚至没有序言，直接用 `RCX`。

#### 3.2.3 16 字节对齐

所有会 `call` 的函数都必须保证调用点 `RSP % 16 == 0`。本章只有 `wmain` 会调用，序言已处理。

#### 3.2.4 非易失寄存器

`ascii_upper` 用了 `RSI` 和 `RDI`：

```asm
ascii_upper:
    push    rsi
    push    rdi
    ...
    pop     rdi
    pop     rsi
    ret
```

`RSI` / `RDI` 是非易失的，修改前必须保存。这里没有 `call`，所以 `push` 两个寄存器不会破坏对齐要求（只有 `call` 点才要求 `% 16 == 0`）。

### 3.3 字符串长度：数到 0 为止

`wlen` 的逻辑：从字符串起点开始，逐个码元读，遇到 `0` 就停止，返回走过的码元数。

```asm
wlen:
    xor     eax, eax          ; 计数器
.loop:
    cmp     word [rcx + rax*2], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret
```

- `word` 明确按 2 字节读取（UTF-16 码元）；
- `[rcx + rax*2]` 是"基址 + 索引 * 2"寻址（2 是码元大小）；
- 返回 `EAX` 是码元数，不是字节数。

这里源码注释写了 `size_t wlen(...)`，但实现和本章接口表实际约定的是 **32 位 `EAX` 返回值**。严格的 64 位 `size_t` 应使用 `RAX` 并考虑更长字符串；本章样本很短，统一按 32 位长度处理。读接口时要以寄存器约定和指令宽度为准，不能只看 C 风格注释的名字。

`wlen` 没有容量参数，前提和 C 的 `wcslen` 一样：输入必须是可读且带 0 终止的字符串。若指针无效、缓冲区没有终止符，它会一直向高地址扫描，最终越界。汇编不会自动检查这些情况。对“缓冲区 + 容量”形式的不可信输入，应实现带最大码元数的上限版本。

`ascii_upper` 还多了一个目标缓冲区前提：`dst` 至少有容纳源字符串全部码元和结尾 0 的空间。本章 `upper_buf` 有 64 个码元，而 `sample_ascii` 只有 12 个码元，所以足够；函数本身无法从指针自动知道容量。

### 3.4 ASCII 大小写转换

ASCII 的小写字母 `'a'`~`'z'`（0x61~0x7A）比对应大写 `'A'`~`'Z'`（0x41~0x5A）大 32。所以转换逻辑：

```text
如果 'a' <= c <= 'z'，则 c -= 32；否则不变。
```

汉字（如 `0x6C47`）不在这个范围，保持原样。

### 3.5 单词计数：状态机

单词数用 `in_word` 状态变量：

```text
分隔符 → 非分隔符：单词数 +1，in_word = 1
非分隔符 → 非分隔符：不计数（连续字符）
非分隔符 → 分隔符：in_word = 0
分隔符 → 分隔符：不计数
```

本章的分隔符：空格（32）、TAB（9）、CR（13）、LF（10）。

以 `"one  two"`（中间两个空格）为例，状态变化为：

| 读到的内容 | 进入本轮前的 `in_word` | 动作 | 单词数 |
|---|---:|---|---:|
| `o`、`n`、`e` | 初始为 0，随后为 1 | 第一个 `o` 使计数 +1，其余字母不重复计 | 1 |
| 第一个空格 | 1 | 设为 0 | 1 |
| 第二个空格 | 0 | 保持 0，不增加 | 1 |
| `t` | 0 | 新单词开始，设为 1，计数 +1 | 2 |
| `w`、`o` | 1 | 仍在同一单词 | 2 |

函数使用显式长度 `EDX` 控制循环，不依赖终止符；`words_len` 又在 `dw 0` 之前计算，所以结尾 0 不参与统计。`r9d` 作为索引从 0 增加到 `len-1`，每次写 `r9d` 都会清零 `R9` 高 32 位，因此 `[rcx+r9*2]` 使用完整 64 位基址加索引是安全的。`r10w` 只写低 16 位，但后续也只比较 `r10w`，没有把它误当成已清零的 64 位值。

### 3.6 RIP 相对寻址不能带索引

逐码元打印时，想用 `[rel sample + rax*2]`，但这是**非法**的——RIP 相对寻址不支持索引寄存器。正确做法：

```asm
lea     rax, [rel sample]     ; 先把基址放进寄存器
mov     qword [rbp - 16], rax ; 或存到本地槽
...
mov     r8, qword [rbp - 16]
movzx   edx, word [r8 + rax*2]  ; 用 [基址寄存器 + 索引*2]
```

`movzx edx, word [...]` 把 16 位码元**零扩展**成 32 位，避免高 16 位垃圾。

## 4. 实践用例

打开 [strings.asm](strings.asm)。程序计算样本长度、转大写、数单词、逐码元打印 `U+XXXX`。

### 4.1 构建与运行

```powershell
make
.\strings.exe
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l strings.obj.lst -o strings.obj strings.asm
gcc -municode -o strings.exe strings.obj
length of sample = 15 WCHAR units
uppercase = X64 ASSEMBLY
words = 4
code units: U+0078 U+0036 U+0034 U+0020 U+0061 U+0073 U+0073 U+0065 U+006D U+0062 U+006C U+0079 U+0020 U+6C47 U+7F16
0
```

最后两个码元 `U+6C47 U+7F16` 就是"汇""编"。退出码 `0`。

### 4.2 `.lst` 摘录

```text
   131 000000A0 488D0D(60000000)            lea     rcx, [rel fmt_len]
   132 000000A7 8B55FC                      mov     edx, dword [rbp - 4]
   134 000000AC E8(00000000)                call    wprintf
   138 000000B8 488D15(00000000)            lea     rdx, [rel upper_buf]
   139 000000BF E84AFFFFFF                  call    ascii_upper
   148 000000E0 BA12000000                  mov     edx, words_len
   149 000000E5 E859FFFFFF                  call    count_words
   161 00000108 488D05(00000000)            lea     rax, [rel sample]
   162 0000010F 488945F0                    mov     qword [rbp - 16], rax
   169 00000122 4C8B45F0                    mov     r8, qword [rbp - 16]
   170 00000126 410FB71440                  movzx   edx, word [r8 + rax*2]
   178 0000013E 488D0D(F0000000)            lea     rcx, [rel fmt_nl]
   180 00000147 E8(00000000)                call    wprintf
```

读法：

- `E84AFFFFFF`：`call ascii_upper`，位移 `-0xB6`，函数在 `wmain` 之前；
- `BA12000000`：`mov edx, 18`，`words_len = 18`；
- `410FB71440`：`movzx edx, word [r8 + rax*2]`；`0FB7` 是 `movzx r32, r/m16`，`44` 是 SIB（`rax*2 + r8`）；
- `488945F0`：把基址存到 `[rbp-16]`。

## 5. 代码重点讲解

1. **`wlen` 的 `[rcx + rax*2]`（知识点 3.3）**：`cmp word [rcx + rax*2], 0` 逐个码元读，遇到 0 停止。`*2` 是因为 UTF-16 码元占 2 字节。返回码元数（15），不是字节数（30）。

2. **`ascii_upper` 的 `push rsi / push rdi`（知识点 3.2.4）**：`RSI`/`RDI` 是非易失寄存器，修改前必须保存。这里没有 `call`，`push` 两个不影响对齐。转换逻辑：`'a' <= c <= 'z'` 时 `sub ax, 32`，其他保持原样。注意实际转换的输入是 `sample_ascii = "x64 assembly"`，不是带中文的完整 `sample`；这样可以专注于 ASCII 规则，也避免当前控制台 locale 把中文宽字符输出成问号。

3. **`count_words` 的状态机（知识点 3.5）**：`r10d` 是 `in_word`，从"分隔符"进入"非分隔符"时 `inc eax`（单词数 +1）。连续非分隔符不重复计数。

4. **RIP 相对寻址不带索引（知识点 3.6）**：`lea rax, [rel sample]` 先取基址到寄存器，再 `mov r8, [rbp-16]` 取基址，最后 `movzx edx, word [r8 + rax*2]` 用 `[基址 + 索引*2]`。不能写 `[rel sample + rax*2]`。

5. **`movzx edx, word [...]`（知识点 3.6）**：16 位码元零扩展到 32 位，避免 `EDX` 高 16 位有垃圾影响 `%04X` 的打印。

6. **`WSTR` 不带结尾 0 的坑（见常见坑）**：`sample` 用 `WSTR`（不带 0），然后 `dw 0` 手动补终止符。`sample_len` 要在补 0 **之前**算，否则长度会多 1。

## 6. 常见坑

1. **把字节数当字符数**：`wlen` 返回码元数，字符串字节数是它的 2 倍。
2. **`[rel label + rax*2]` 无效**：RIP 相对寻址不支持索引寄存器，必须先取基址。
3. **16 位读取后直接参与 32 位运算**：用 `movzx` 清零高 16 位。
4. **只处理 BMP**：代理对会被当成两个码元；要完整处理需要判断 `0xD800~0xDBFF`。
5. **大小写转换只适用于 ASCII**：汉字、带重音字母都不在这个范围。
6. **`%s` 打宽字符串**：用 `%ls`。
7. **字符串没有 0 结尾**：`WSTR` 不带 0，必须补。
8. **`cmp word` 与 `cmp ax` 混用**：保持操作数大小一致，避免标志位误读。

## 7. 练习

1. 把样本改成纯中文，确认长度按"码元"计数。
2. 实现 `ascii_lower`，把 `X64 ASSEMBLY` 转回小写。
3. 增加一个 `is_ascii_digit` 循环，统计样本里的数字个数。
4. 把 `count_words` 的分隔符集合改成"只认空格"，观察连续空格的处理。
5. 打印样本的 UTF-8 字节（用第 11 章的 `WideCharToMultiByte`），比较字节数与码元数。
6. 找一个 BMP 外的 emoji，观察它在 UTF-16 中的两个码元。

## 8. 下一章

第 11 章进入错误处理：

- `GetLastError` 的调用时机；
- `FormatMessageW` 的 7 个参数，后 3 个在栈上；
- `WideCharToMultiByte(CP_UTF8)` + `WriteFile` 输出中文；
- `wprintf` 缓冲与 `WriteFile` 直写的顺序问题。
