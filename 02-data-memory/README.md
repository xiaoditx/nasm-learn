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

为什么要对齐？x64 访问 8 字节数据时，如果地址是 8 的倍数，CPU 一次访存就能读完；否则可能拆成两次访存，甚至触发某些指令的对齐异常。养成习惯：`dq` 之前 `align 8`，`dd` 之前 `align 4`。

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
6. **`and eax, 0xFF`**：把 32 位校验和截成 8 位退出码。Windows 退出码是 32 位 `UINT`，但 shell 只显示低 8 位。

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
