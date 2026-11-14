# 第 12 章：阶段一综合 —— 多文件文本统计器

> 本章源码：[main.asm](main.asm)、[io.asm](io.asm)、[text.asm](text.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[main.obj.lst](main.obj.lst)、[io.obj.lst](io.obj.lst)、[text.obj.lst](text.obj.lst)

## 1. 本章目标

前 11 章都是单文件。本章把阶段一的能力拼起来：

- 三个 `.asm` 文件分别负责主流程、文件 I/O、文本统计；
- 共享结构体 `TEXT_STATS` 放在 `common.asm`；
- `Makefile` 同时生成三个 `.obj` 并链接；
- 程序写文件、读回、统计、打印、自检；
- 退出码含义：`0` 成功，`1` 自检失败，`2` I/O 失败。

## 2. 前置 / 项目结构

前置知识：第 06~11 章全部内容（CRT 启动、ABI 四件套、文件 I/O、堆与结构体、UTF-16 字符串、错误处理）。本章是阶段一综合，把这些能力组合到一个多文件工程里。

```text
rebuild/12-console-capstone/
├── Makefile
├── main.asm      入口、数据、自检
├── io.asm        io_write_file / io_read_file
├── text.asm      text_stats
├── README.md
├── main.obj.lst
├── io.obj.lst
├── text.obj.lst
└── capstone.txt  运行后生成
```

`common.asm` 新增共享结构体：

```asm
struc TEXT_STATS
    .chars: resd 1
    .lines: resd 1
    .words: resd 1
endstruc
```

`TEXT_STATS_size = 12`，两个模块都通过 `%include "../common.asm"` 使用同一份偏移。

## 3. 知识点讲解

### 3.1 多文件工程：`global` / `extern`

单文件时，函数在同一个编译单元里，label 直接跳转。多文件时，函数定义在一个 `.asm`，调用在另一个 `.asm`，需要：

- 定义方用 `global io_write_file` 导出符号；
- 调用方用 `extern io_write_file` 声明外部符号；
- 链接器（gcc）把多个 `.obj` 的符号拼起来。

```asm
; io.asm（定义方）
section .text
    global io_write_file
io_write_file:
    ...
    ret

; main.asm（调用方）
section .text
    extern io_write_file
    call io_write_file
```

### 3.2 模块接口靠注释

汇编没有头文件，模块间的接口约定（参数寄存器、返回值、栈对齐责任）写在各模块文件头部的注释里，调用双方共同遵守：

| 函数 | 参数 | 返回 |
|---|---|---|
| `io_write_file` | `RCX` = 路径，`RDX` = 缓冲区，`R8D` = 字节数 | `EAX`：1 成功，0 失败 |
| `io_read_file` | `RCX` = 路径，`RDX` = 缓冲区，`R8D` = 容量（字节） | `EAX`：读到的字节数，失败 `-1` |
| `text_stats` | `RCX` = 缓冲区，`EDX` = 码元数，`R8` = `TEXT_STATS *` | 无 |

### 3.3 共享结构体放在 `common.asm`

`TEXT_STATS` 定义在 `common.asm`，`main.asm` 和 `text.asm` 都 `%include "../common.asm"`。这样两个模块看到的字段偏移完全一致：

| 字段 | 偏移 | 大小 |
|---|---|---|
| `chars` | 0 | 4 |
| `lines` | 4 | 4 |
| `words` | 8 | 4 |

**注意**：`common.asm` 只能放预处理指令（`%define`、宏、`struc`、`equ`），不能放 `section`/变量，否则每个包含它的对象都会产生重复符号，链接报错。

### 3.4 ABI 四件套（本章复述）

#### 3.4.1 RCX / RDX / R8 / R9

三个模块函数都只使用前三个参数，全部在寄存器里：

- `io_write_file` / `io_read_file`：`RCX`、`RDX`、`R8D`；
- `text_stats`：`RCX`、`EDX`、`R8`；
- 返回值一律用 `EAX`。

`CreateFileW` 的第 5/6/7 参数仍然放在 `[rsp+32]`、`[rsp+40]`、`[rsp+48]`（在 `io.asm` 内部）。

#### 3.4.2 32 字节影子空间

`main` 用 `sub rsp, 128`，`io_write_file` / `io_read_file` 用 `sub rsp, 96`。**每个函数都为自己的 `call` 预留影子空间，不能依赖调用者**。

#### 3.4.3 16 字节对齐

所有函数入口 `RSP % 16 == 8`，`push rbp` 后 `0`，再减 96 或 128 仍是 `0`。`text_stats` 没有 `call`，是叶子函数，不需要序言。

#### 3.4.4 非易失寄存器

三个模块都没有修改 `RBX/RDI/RSI/R12~R15`。`RBP` 由各自的 `push rbp` / `leave` 保存和恢复。`text_stats` 只用 `R9/R10/R11`，都是易失寄存器。

### 3.5 数据流

```text
main.asm
  content（UTF-16，3 行，37 码元 / 74 字节）
        │
        ├─ io_write_file(path, content, 74) ──► capstone.txt
        │
        ├─ io_read_file(path, read_buf, 512)  ◄── capstone.txt（74 字节）
        │
        └─ text_stats(read_buf, 37, &stats)
                 │
                 ▼
        stats.chars = 37
        stats.lines = 3
        stats.words = 6
                 │
                 ▼
        wprintf 打印 + 自检
```

字节数 → 码元数：UTF-16 每个码元 2 字节，所以 `shr eax, 1`。

### 3.6 文本统计的两个细节

- **行数只数 `LF`（10）**：避免 `CRLF` 被算两次（CR 一次、LF 一次）；
- **单词数用 `in_word` 状态机**：从"分隔符"进入"非分隔符"时计数 +1，连续非分隔符不重复计数。

### 3.7 多目标 Makefile

```make
TARGET := capstone.exe
OBJS   := main.obj io.obj text.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<
```

- `$^` 展开为 `main.obj io.obj text.obj`，gcc 按顺序链接；
- 每个 `.obj` 都有自己的 `.lst`；
- `common.asm` 变化会触发三个对象全部重编；
- `-municode` 让链接器使用 `wmainCRTStartup`。

## 4. 实践用例

打开三个源码文件 [main.asm](main.asm)、[io.asm](io.asm)、[text.asm](text.asm)。程序写 `capstone.txt`，读回，统计字符/行/单词，打印并自检。

### 4.1 构建与运行

```powershell
make
.\capstone.exe
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l main.obj.lst -o main.obj main.asm
nasm -f win64 -l io.obj.lst -o io.obj io.asm
nasm -f win64 -l text.obj.lst -o text.obj text.asm
gcc -municode -o capstone.exe main.obj io.obj text.obj
io_write_file: 74 bytes
io_read_file : 74 bytes
text_stats   : chars=37 lines=3 words=6
self-check OK
0
```

数量核对：

- 3 行文本：`first line`(10) + CRLF(2) + `second line`(11) + CRLF(2) + `third line`(10) + CRLF(2) = 37 码元；
- 37 * 2 = 74 字节；
- 行数 = 3 个 `LF`；
- 单词数 = 每行 2 个，共 6。

生成的 `capstone.txt` 大小为 74 字节。退出码 `0`。

### 4.2 `.lst` 摘录

`main.obj.lst`：

```text
    46                                  wmain:
    47 00000000 55                          push    rbp
    48 00000001 4889E5                      mov     rbp, rsp
    49 00000004 4881EC80000000              sub     rsp, 128
    52 0000000B 488D0D(00000000)            lea     rcx, [rel path]
    53 00000012 488D15(1A000000)            lea     rdx, [rel content]
    54 00000019 41B84A000000                mov     r8d, content_bytes
    55 0000001F E8(00000000)                call    io_write_file
    56 00000024 85C0                        test    eax, eax
    57 00000026 0F84CC000000                jz      .fail
```

`io.obj.lst`：

```text
    22                                  io_write_file:
    23 00000000 55                          push    rbp
    24 00000001 4889E5                      mov     rbp, rsp
    25 00000004 4883EC60                    sub     rsp, 96
    31 00000014 BA00000040                  mov     edx, GENERIC_WRITE
    34 0000001F 48C744242002000000          mov     qword [rsp + 32], CREATE_ALWAYS
    37 0000003A E8(00000000)                call    CreateFileW
```

`text.obj.lst`：

```text
    14 00000003 41C7400400000000            mov     dword [r8 + TEXT_STATS.lines], 0
    15 0000000B 41C7400800000000            mov     dword [r8 + TEXT_STATS.words], 0
    27 0000002A 41FF4004                    inc     dword [r8 + TEXT_STATS.lines]
    42 00000055 41FF4008                    inc     dword [r8 + TEXT_STATS.words]
```

可以看到跨模块调用在 `.lst` 里仍是 `E8(00000000)`，真实位移要等链接后才确定；字段访问已经变成固定偏移（`+4`、`+8`）。

## 5. 代码重点讲解

1. **`global` / `extern` 跨模块调用（知识点 3.1）**：`io.asm` 用 `global io_write_file` 导出，`main.asm` 用 `extern io_write_file` 声明。链接器把三个 `.obj` 的符号解析到一起。`.lst` 里 `call io_write_file` 仍是 `E8(00000000)`，链接后才填真实位移。

2. **每个函数自己留影子空间（知识点 3.4.2）**：`main` 用 `sub rsp, 128`，`io_write_file` 用 `sub rsp, 96`。`main` 调用 `io_write_file` 时，`io_write_file` 自己的序言再分配栈，不依赖 `main` 的栈布局。

3. **`shr eax, 1` 字节数 → 码元数（知识点 3.5）**：`io_read_file` 返回字节数（74），`text_stats` 要码元数（37）。UTF-16 每码元 2 字节，右移 1 位等于除以 2。

4. **`text_stats` 只数 `LF`（知识点 3.6）**：`cmp r11w, 10` 判断换行，避免 `CRLF` 被算两次。单词数用 `r10d`（`in_word`）状态机，跳变时计数。

5. **`io_read_file` 先存 `bytesRead` 再 `CloseHandle`**：`ReadFile` 成功后 `bytesRead` 在 `[rbp-40]`，`mov [rbp-44], eax` 先存，再 `CloseHandle`（会改变 `EAX`），最后 `mov eax, [rbp-44]` 恢复。否则返回值会被 `CloseHandle` 的返回值覆盖。

6. **自检把期望值写死**：`chars=37`、`lines=3`、`words=6`。改动 `content` 后要同步更新，否则退出码为 1。

## 6. 常见坑

1. **忘记 `global`**：模块函数必须 `global io_write_file`，否则链接报 `undefined reference`。
2. **两边结构体偏移不一致**：必须都 `%include "../common.asm"`；手抄一份迟早会漂移。
3. **把定义放进 `common.asm`**：`common.asm` 只能有 `%define`、宏、`struc`、`equ`，不能有 `section`/变量，否则每个包含它的对象都会产生重复符号。
4. **跨模块寄存器假设**：调用者不能假设 `RDX/R8/R9` 在函数返回后还有原值。
5. **字节数当码元数**：`io_read_file` 返回字节数，`text_stats` 要码元数，必须 `shr 1`。
6. **CRLF 算两行**：只数 `LF`，或同时判断 `CR` 后跳过 `LF`。
7. **`CloseHandle` 覆盖返回值**：`io_read_file` 先把 `bytesRead` 存到本地槽，再关闭句柄。
8. **失败路径不关句柄**：`io_write_file` 在 `WriteFile` 失败时仍会 `CloseHandle`。
9. **多目标链接顺序**：`gcc -o capstone.exe main.obj io.obj text.obj`，入口在 `main.obj`，但链接器只看符号，不严格要求顺序。
10. **自检数字写死**：内容改动后要同步更新期望值，否则退出码为 1。

## 7. 练习

1. 增加第 4 行，更新 `content`、期望的 `chars/lines/words` 和自检数字。
2. 在 `text_stats` 里增加"最长单词长度"，扩展 `TEXT_STATS`。
3. 把 `io_read_file` 的缓冲区改成 1024 字节，验证大文件。
4. 用 `WideCharToMultiByte(CP_UTF8)` 把 `read_buf` 写成 UTF-8 文件，比较文件大小。
5. 让程序接受命令行参数作为文件名（`wmain` 的 `argv[1]`），没有参数时用默认值。
6. 把三个模块的接口注释整理成一张表，模拟"手写头文件"的约束。

## 8. 阶段一总结

到这里，阶段一（06~12）完成：

- CRT 启动与 `wmain`；
- 宽字符参数表；
- Win32 文件 I/O；
- 堆与结构体；
- UTF-16 字符串处理；
- 错误码与系统消息；
- 多文件工程与 Makefile。

下一批（13~19）进入阶段二：窗口、消息循环、GDI/Direct2D 的前置知识。GUI 章节只编译不运行，避免弹窗卡住。
