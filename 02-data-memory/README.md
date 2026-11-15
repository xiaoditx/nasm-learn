# 第 02 章：数据定义与内存布局

> 阶段零（00~05）不配 Makefile。
> 本章源码：[layout.asm](layout.asm)
> 本章清单：[layout.lst](layout.lst)

## 1. 本章目标

第 01 章所有数据都放在寄存器里。本章开始把数据放进 PE 的节区：

- `db / dw / dd / dq`：定义 1 / 2 / 4 / 8 字节数据
- `equ`：编译期常量，不占空间
- `times`：重复定义
- `.data` 与 `.bss` 的区别
- `resb / resw / resd / resq`：在 `.bss` 里保留空间
- `align`：对齐与填充
- `default rel` 与 `[rel sym]`：RIP 相对寻址
- 小端字节序

程序的最终退出码是一个**逐项算出来的校验和**，用来验证这些数据真的按预期布局。

## 2. 知识点讲解

### 2.1 数据定义与空间保留指令

| 指令 | 宽度 | 用途 | 示例 |
|---|---|---|---|
| `db` | 1 字节 | 定义字节（define byte） | `db 0x56` |
| `dw` | 2 字节 | 定义字 | `dw 0x1234` |
| `dd` | 4 字节 | 定义双字 | `dd 0xDEADBEEF` |
| `dq` | 8 字节 | 定义四字 | `dq 0x1122334455667788` |
| `equ` | 0 字节 | 编译期常量（类似 `#define`） | `MSG_LEN equ 4` |
| `times` | — | 重复定义 | `times 3 db 0xAA` |
| `resb` | 1 字节 | 保留字节（reserve byte） | `resb 1` |
| `resw` | 2 字节 | 保留字 | `resw 1` |
| `resd` | 4 字节 | 保留双字 | `resd 1` |
| `resq` | 8 字节 | 保留四字 | `resq 1` |

**核心区别**：`db/dw/dd/dq` 有初始值，会写进 PE 文件；`resb/resw/resd/resq` 只保留空间，文件里不占字节，加载时由系统清零。所以 `.data` 用 `d*`，`.bss` 用 `res*`，**不能混用**。

### 2.2 小端字节序

x86/x64 是小端架构：多字节数据在内存里**低字节在前**。

```text
dw 0x1234   → 内存：34 12
dd 0xDEADBEEF → 内存：EF BE AD DE
dq 0x1122334455667788 → 内存：88 77 66 55 44 33 22 11
```

从内存读回来时，CPU 自动按小端还原，所以 `mov rax, [val64]` 仍然得到 `0x1122334455667788`。但当你用 `movzx eax, byte [val32]` 只取最低字节时，拿到的是 `0xEF`（不是 `0xDE`）——这是小端直接可见的影响。

### 2.3 `align`：对齐填充

`align N` 把当前位置向上补到 N 的倍数，插入的填充字节默认为 `0x90`（`nop`）。

“对齐”指地址是某个边界的整数倍。例如 8 字节对齐就是地址能被 8 整除。某些指令要求对齐，普通数据合理对齐也常有利于访问效率；但 x64 并不是所有未对齐访问都会出错。本章只观察 `align` 如何改变布局，不推导 CPU 内部访存过程。

### 2.4 从内存读数据：宽度必须匹配

从内存读数据时，操作数宽度必须显式指定：

| 读取宽度 | 指令 | 说明 |
|---|---|---|
| 1 字节 | `movzx eax, byte [mem]` | 必须 `movzx`，否则高位残留 |
| 2 字节 | `movzx eax, word [mem]` | 同上 |
| 4 字节 | `mov eax, [mem]` | 32 位写入自动清零高位 |
| 8 字节 | `mov rax, [mem]` | 直接读 |

**易错**：`mov ecx, [val8]` 会读 4 字节，不是 1 字节。读窄数据必须写 `byte`/`word` 并配合 `movzx`。

### 2.5 `equ`：编译期常量

`MSG_LEN equ 4` 不占任何空间，它只是告诉 NASM"把 `MSG_LEN` 替换成 `4`"。它没有地址，不能 `lea`。常用于数组长度、循环计数等不变值。

### 2.6 标签、偏移与运行时地址不是一回事

```asm
section .data
val8  db 0x56
val16 dw 0x1234
```

这里：

- `val8`、`val16` 是我们自己起的标签，用来标记位置；
- `db/dw` 决定从这个位置开始写入多少字节；
- `.lst` 中的 `00000000`、`00000001` 是**当前节内偏移**，也就是相对本段开头的距离；
- 链接和加载后，标签会对应进程中的实际地址，但编程时不需要手算这个绝对地址。

日常写 `[rel val8]` 时，汇编器和链接器会算出“从下一条指令的 RIP 到变量的距离”，CPU 执行时再加上当时的 RIP。RVA、装载基址等地址术语只在你需要分析 PE 布局时查阅前言第 6 节，不是本章数据读写实验的前置条件。

### 2.7 `.data` 与 `.bss` 在文件和内存中的差别

假设定义：

```asm
section .data
a dd 0x12345678
section .bss
b resd 1
```

| 阶段 | `a` | `b` |
|---|---|---|
| `.asm` | 有明确初始值 | 只声明大小 |
| `.obj/.exe` 文件 | 保存 `78 56 34 12` | 不保存 4 个实际字节，只记录所需大小 |
| Windows 加载后 | 从文件映像得到初始值 | 所在未初始化区域按约定清零 |
| 程序运行中 | 可读写 | 可读写 |

`.bss` 的“零初始化”发生在加载时，不是每次执行到标签都清零。如果程序写入 `b`，再次读取就会得到新值。

也不要把“未初始化数据”理解成“这段内存不存在”。它在进程内存中真实占据空间，只是不必在磁盘文件中保存一串零。

### 2.8 一次内存访问需要回答三个问题

以 `movzx eax, byte [rel val8]` 为例：

1. **地址在哪里？** `rel val8`：由链接器计算相对 RIP 的位移；
2. **访问多宽？** `byte`：只读取 1 字节；
3. **读来以后怎么放？** `movzx ... eax`：零扩展到 32 位并写入 EAX。

再看写内存：

```asm
mov byte  [rel val8], 1    ; 写 1 字节
mov word  [rel val16], 2   ; 写 2 字节
mov dword [rel val32], 3   ; 写 4 字节
mov qword [rel val64], 4   ; 写 8 字节
```

当源操作数是立即数时，CPU 无法仅凭 `1` 判断你想写多宽，因此 `byte/word/dword/qword` 不能省。若源操作数是寄存器：

```asm
mov [rel val32], eax       ; EAX 已表明写 4 字节，不必再写 dword
```

### 2.9 重叠读取：亲手验证小端与宽度

沿用本章 `val32 dd 0xDEADBEEF`，其内存为 `EF BE AD DE`：

| 指令 | 读取的原始字节 | 寄存器结果 |
|---|---|---|
| `movzx eax, byte [rel val32]` | `EF` | `0x000000EF` |
| `movzx eax, word [rel val32]` | `EF BE` | `0x0000BEEF` |
| `mov eax, [rel val32]` | `EF BE AD DE` | `0xDEADBEEF` |

如果误用 `mov eax,[rel val8]`，CPU 会从 `val8` 开始连续读 4 字节，把后面的 `val16` 和 `val32` 第一个字节也读进来。它不会根据标签名字自动停在 `val8` 末尾——标签不携带运行时长度信息。

### 2.10 对齐填充的逐步计算

本章前三个变量大小为 `1+2+4=7`，所以下一位置是偏移 7。下一个小于 7 的 8 的倍数是 0，下一个是 8：

```text
当前偏移 7 → align 8 → 插入 1 字节 → 新偏移 8
```

因此 `val64` 从偏移 8 开始。若改成 `align 16`，当前位置 7 要前进到 16，会插入 9 字节。对齐计算针对**当前偏移**，不是针对变量数值。

## 3. 实践用例

打开 [layout.asm](layout.asm)。程序从 `.data` 依次读取不同宽度的数据，经过加减异或算出校验和，最后 `and eax, 0xFF` 只留低 8 位作为退出码。预期退出码 **220**（`0xDC`）。

校验和逐步计算：

| 步骤 | 表达式 | 结果 |
|---|---|---|
| 1 | `0x56 + 0x1234` | `0x0000128A` |
| 2 | `0x128A ^ 0xDEADBEEF` | `0xDEADAC65` |
| 3 | `^ 0x55667788`（`val64` 低 32 位） | `0x8BCBDBED` |
| 4 | `+ 0xEF`（`val32` 最低字节） | `0x8BCBDCDC` |
| 5 | `+ 0`（`bss32`） | `0x8BCBDCDC` |
| 6 | `& 0xFF` | `0xDC = 220` |

### 3.1 构建与运行

```powershell
nasm -f win64 -l layout.lst -o layout.obj layout.asm
ld -o layout.exe layout.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
.\layout.exe
$LASTEXITCODE
```

实测结果：

```text
PS> .\layout.exe
PS> $LASTEXITCODE
220
```

### 3.2 `.lst` 摘录：数据段真实布局

```text
    16 00000000 56                          val8      db  0x56
    17 00000001 3412                        val16     dw  0x1234
    18 00000003 EFBEADDE                    val32     dd  0xDEADBEEF
    19 00000007 90                          align 8
    20 00000008 8877665544332211            val64     dq  0x1122334455667788
    21 00000010 4E41534D00                  msg       db  'NASM', 0
    23 00000015 AA<rep 3h>                  times 3   db  0xAA
```

```text
    26 00000000 ??                          bss8      resb 1
    27 00000001 ????                        bss16     resw 1
    28 00000003 ????????                    bss32     resd 1
    29 00000007 ????????????????            bss64     resq 1
```

代码段里 RIP 相对的占位符：

```text
    39 00000004 0FB605(00000000)            movzx eax, byte [rel val8]
    40 0000000B 0FB70D(01000000)            movzx ecx, word [rel val16]
    43 00000014 8B0D(03000000)              mov ecx, [rel val32]
    46 0000001C 3305(08000000)              xor eax, [rel val64]
    52 0000002B 8B0D(03000000)              mov ecx, [rel bss32]
    55 00000033 25FF000000                  and eax, 0xFF
```

### 3.3 GDB 验证

断在 `and eax, 0xFF` 之前，实测：

```text
eax            0x8bcbdcdc          ← 掩码前，与手算第 5 步一致
eax            0xdc                ← and 0xFF 后，即退出码 220
ecx            0x0                 ← bss32 初值为 0
```

## 4. 代码重点讲解

1. **数据布局（知识点 2.1/2.2/2.3）**：`val8` 偏移 0、`val16` 偏移 1、`val32` 偏移 3；`align 8` 插入 `0x90` 填充使 `val64` 落在偏移 8。小端在 `.lst` 里一目了然：`3412` 是 `0x1234`，`EFBEADDE` 是 `0xDEADBEEF`。
2. **`movzx eax, byte [rel val8]`（知识点 2.4）**：只读 1 字节并零扩展到 32 位。如果写成 `mov eax, [val8]` 就读成 4 字节了。
3. **`xor eax, [rel val64]`（知识点 2.2）**：`xor` 的内存操作数按寄存器宽度（32 位）读取，所以只取了 `val64` 的低 32 位 `0x55667788`。这是"操作数宽度由寄存器决定"的体现。
4. **`movzx ecx, byte [rel val32]`（知识点 2.2）**：取 `val32` 的最低字节 `0xEF`。因为小端，最低字节是 `0xDEADBEEF` 的 `EF`。
5. **`.bss` 的 `bss32` 初值为 0**：`add eax, ecx` 不改变 `eax`。这验证了 `.bss` 加载时清零的行为。
6. **`and eax, 0xFF`**：把 32 位校验和主动截成低 8 位，便于用简短的退出码核对结果。Windows 退出码是 32 位，PowerShell 也能显示大于 255 的值；这里的截断是示例选择，不是 shell 限制。

## 5. 常见坑

1. **`.bss` 里写初始值**：`.bss` 只接受 `res*`；`bss32 dd 1` 会报错或落到别的段。
2. **`mov ecx, [rel val8]`**：这会读 4 字节，不是 1 字节。读窄数据要 `movzx`，并显式写 `byte`/`word`。
3. **`mov [rel val8], 1`**：操作数大小不明确，NASM 报 "operation size not specified"；写 `mov byte [rel val8], 1`。
4. **把 `equ` 当地址**：`MSG_LEN` 只是常量 4，没有地址；取地址用 `lea rax, [rel msg]`。
5. **`align 8` 以为不占空间**：它会插入填充字节（这里是 `0x90`），后面的偏移会变。
6. **`dq` 的小端误解**：内存里是反的，但读回来仍是原值；只取部分字节时要注意小端顺序。
7. **忘记 `default rel`**：`[val8]` 可能变成 32 位绝对地址。阶段零统一写 `[rel sym]`。
8. **`resq 1` 当 1 字节**：`resq 1` 是 8 字节。

## 6. 练习

1. 在 `val16` 后插入 `db 0x77`，重新生成 `.lst`，观察 `val32` 的偏移是否从 3 变成 4；退出码会变吗？
2. 把 `times 3 db 0xAA` 改成 `times 5 db 0xAA`，用 GDB 的 `x/8xb &msg` 查看字符串后面的字节。
3. 增加一个 `bss128 resq 16`，在代码里写满它再读回，验证 `.bss` 可读写。
4. 用 `objdump -s -j .data layout.exe` 查看 `.data` 节的实际字节，和 `.lst` 对照。
5. 把 `align 8` 改成 `align 16`，解释为什么偏移变成 16。

## 7. 下一章

第 03 章开始组合指令：算术、逻辑、比较、跳转、循环，以及用 `call/ret` 调用本地函数。程序会做 6 项自检，退出码 `0` 表示全部通过。
