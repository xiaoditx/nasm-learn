# 第 04 章：从 16 位 MASM 迁移到 NASM x64

> 阶段零（00~05）不配 Makefile。
> 本章源码：[port16.asm](port16.asm)
> 本章清单：[port16.lst](port16.lst)

## 1. 本章目标

如果你写过 16 位 MASM，会带着一批"肌肉记忆"进入 x64：`mov ax, 0B800h`、`int 21h`、`mov dx, offset msg`、`assume cs:_TEXT, ds:_DATA`、`buffer db 100 dup(?)`。

这些写法在 64 位 Windows 下**要么不存在，要么含义完全变了**。本章做两件事：

1. 给出一张可查的"16 位 MASM → NASM x64"对照表；
2. 用一个真实程序把 VGA 文本缓冲区地址的计算翻译过来，并用退出码验证结果。

> 本章程序只**计算** VGA 地址 `0xB8000`，绝不往那里写数据。Windows 用户态不能直接访问物理显存。

## 2. 知识点讲解

### 2.1 为什么不能照抄

| 16 位 DOS | 64 位 Windows |
|---|---|
| 实模式，段基址可任意设置 | 长模式，CS/DS/ES/SS 基址强制为 0 |
| 可以直接访问 `0xB8000` 显存 | 用户态访问会触发访问违例 |
| `int 21h` / `int 10h` 由 DOS/BIOS 提供 | 没有这些中断；改用 kernel32/user32 API |
| 默认 16 位操作数 | 默认 32 位操作数，64 位需要 REX.W |
| 寻址 `[bx+si]` | 只能用 64 位（或 32 位）基址/索引 |
| `.model small`、`segment`、`assume` | 扁平模型，直接 `section .data/.text` |
| 汇编器 MASM 语法 | NASM 语法（大小写敏感、十六进制前缀不同） |

核心变化是**从段式内存模型变成扁平线性模型**：段寄存器不再提供基址，地址就是线性地址，所有"段+偏移"的计算都要改成直接的线性地址。

### 2.2 语法与伪指令对照

| 16 位 MASM | NASM x64 | 说明 |
|---|---|---|
| `1234h` | `0x1234` | NASM 用 `0x`，不是后缀 `h` |
| `0B800h` | `0xB800` | 字母开头的十六进制必须加 `0x` |
| `mov ax, 0B800h` | `mov eax, 0xB8000` | 显存基址是线性地址，段基址不再自动加 |
| `mov dx, offset msg` | `lea rdx, [rel msg]` | `offset` 在 NASM 中不用于取地址 |
| `byte ptr [bx]` | `byte [rbx]` | NASM 用 `byte/word/dword/qword` |
| `db 100 dup(?)` | `resb 100` | 未初始化空间 |
| `db 100 dup(0)` | `times 100 db 0` | 有初始值 |
| `.model small` | （删除） | 扁平内存模型 |
| `assume cs:_TEXT, ds:_DATA` | （删除） | 段基址恒为 0 |
| `_TEXT segment ... _TEXT ends` | `section .text` | 段名不再重要 |
| `proc` / `endp` | 普通标签 + 手写序言 | 没有自动栈帧 |
| `end start` | `global _start` + `ld --entry=_start` | 入口由链接器指定 |
| `int 21h`（打印/退出） | `call ExitProcess` 等 API | DOS 中断不存在 |
| `int 10h`（显示） | GDI / D2D / 控制台 API | BIOS 中断不存在 |

### 2.3 寄存器与指令对照

| 16 位写法 | 64 位写法 | 说明 |
|---|---|---|
| `mov ax, 80` | `mov eax, 80` | 默认操作数变成 32 位 |
| `mov cx, 3` | `mov ecx, 3` | 写 32 位会清零高 32 位 |
| `mul cx` | `imul ecx, ecx, 80` | 三操作数形式更直接，不碰 DX:AX |
| `shl ax, 1` | `shl eax, 1` | VGA 每字符 2 字节 |
| `pusha` / `popa` | 逐个 `push` / `pop` | x64 没有 `pusha/popa` |
| `loop label` | `dec rcx` + `jnz`（或 `loop`） | `loop` 用 `RCX`，但通常更慢 |
| `[bx+si]` | `[rbx+rsi]` | 16 位寻址组合在长模式无效 |

### 2.4 十六进制与常量

| MASM | NASM |
|---|---|
| `0FFh` | `0xFF` |
| `1010b` | `0b1010` |
| `'A'` | `'A'` |
| `$`（当前地址） | `$`（含义相同） |
| `equ` | `equ`（相同） |

## 3. 实践用例

打开 [port16.asm](port16.asm)。本章把"行 3、列 5 的 VGA 字符单元地址"从 16 位写法翻译过来：

```text
地址 = 0xB8000 + (行 * 80 + 列) * 2
     = 0xB8000 + (3 * 80 + 5) * 2
     = 0xB8000 + 245 * 2
     = 0xB8000 + 490
     = 0xB81EA
```

为了压进 8 位退出码，取低字节 `0xEA = 234`。

### 3.1 构建与运行

```powershell
nasm -f win64 -l port16.lst -o port16.obj port16.asm
ld -o port16.exe port16.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
.\port16.exe
$LASTEXITCODE
```

实测结果：

```text
PS> .\port16.exe
PS> $LASTEXITCODE
234
```

### 3.2 `.lst` 摘录

```text
    23 00000000 4883EC28                    sub rsp, 40
    28 00000004 B800800B00                  mov eax, 0xB8000
    32 00000009 B903000000                  mov ecx, 3
    33 0000000E 6BC950                      imul ecx, ecx, 80
    34 00000011 83C105                      add ecx, 5
    35 00000014 D1E1                        shl ecx, 1
    38 00000016 01C8                        add eax, ecx
    42 00000018 25FF000000                  and eax, 0xFF
    44 0000001D 89C1                        mov ecx, eax
    45 0000001F E8(00000000)                call ExitProcess
```

- `B800800B00`：`mov eax, imm32`，立即数 `0x000B8000` 按小端存成 `00 80 0B 00`。
- `6BC950`：`imul ecx, ecx, 80`，立即数 `0x50 = 80`。
- `D1E1`：`shl ecx, 1`，移位量为 1 时用单字节编码。
- `25FF000000`：`and eax, 0xFF`。

### 3.3 GDB 验证

断在 `add eax, ecx` 之后：

```text
eax            0xb81ea    ← 0xB8000 + 490，与手算一致
eax            0xea       ← and 0xFF 后，即退出码 234
```

## 4. 代码重点讲解

1. **`mov eax, 0xB8000`（知识点 2.1/2.2）**：16 位时代写 `mov ax, 0B800h` 再靠段寄存器把段基址设成 `0xB800`。长模式下段基址恒为 0，所以直接把完整线性地址放进 `EAX`。这里只计算，不解引用。
2. **`imul ecx, ecx, 80`（知识点 2.3）**：对应 16 位的"`mov ax, 80` + `mul cx`"，但用三操作数 `imul` 不需要碰 `DX:AX`，更简洁。
3. **`shl ecx, 1`（知识点 2.3）**：乘以 2。VGA 文本模式每个字符占 2 字节（字符+属性）。
4. **`and eax, 0xFF`**：把 32 位结果截成 8 位退出码。Windows 退出码是 32 位，但 shell 只显示低 8 位。
5. **全程不访问 `0xB8000`**：只计算地址。如果真的 `mov [0xB8000], al`，Windows 用户态会触发访问违例——这是 16 位 DOS 与 64 位 Windows 最本质的区别。

## 5. 常见坑

1. **照抄 `mov ax, 0B800h`**：NASM 不认 `0B800h`，且 16 位地址不够；应写 `mov eax, 0xB8000`。
2. **真的去访问 `0xB8000`**：Windows 用户态会访问违例。显存只能通过 GDI/D2D 间接使用。
3. **继续用 `int 21h`**：不存在；退出用 `ExitProcess`，输出用控制台 API。
4. **写 `[bx+si]`**：长模式不允许 16 位基址/索引组合，必须用 `rbx/rsi`。
5. **以为段寄存器还能控制基址**：CS/DS/ES/SS 基址恒为 0；FS/GS 被 Windows 用于 TEB，别乱改。
6. **`pusha/popa` 直接搬过来**：x64 没有；要保存多个寄存器就逐条 `push`。
7. **`offset msg` 取地址**：NASM 用 `lea rax, [rel msg]`。
8. **`dup` 语法**：NASM 用 `times` 或 `res*`，没有 `dup`。

## 6. 练习

1. 把行列改成"行 10、列 0"，手算地址与低字节，再用程序验证退出码。
2. 把 `and eax, 0xFF` 改成 `and eax, 0xF`，观察退出码只剩低 4 位。
3. 用 `VGA_BASE equ 0xB8000` 替换硬编码，确认 `.lst` 机器码不变。
4. 尝试写 `mov ax, ds` 并 `movzx eax, ax`，用 GDB 看返回值；解释为什么它不能作为寻址基址。
5. 把 `imul ecx, ecx, 80` 改成 16 位风格 `mov ax, 80` + `mul cx`，自行推导需要哪些前缀和寄存器，比较代码长度。

## 7. 下一章

第 05 章回到"程序为什么能返回"：`call/ret` 的栈行为、标准栈帧、递归，以及"入口直接 `ret` 回系统"为什么不靠谱。会用 GDB 实际观察 `RSP` 在递归中的变化。
