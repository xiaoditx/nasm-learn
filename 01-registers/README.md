# 第 01 章：寄存器全景

> 阶段零（00~05）不配 Makefile，统一用"单文件 + README 命令"。
> 本章源码：[registers.asm](registers.asm)
> 本章清单：[registers.lst](registers.lst)

## 1. 本章目标

第 00 章只用了 `RAX`、`RCX`、`RSP`、`RIP` 四个寄存器。本章把 x64 的通用寄存器补全：

- 16 个通用寄存器：`RAX RBX RCX RDX RSI RDI RBP RSP R8~R15`
- 同一个寄存器的 8 / 16 / 32 / 64 位名字
- `R8~R15` 的特殊命名：`R8B / R8W / R8D / R8`
- 写 32 位寄存器会**自动清零高 32 位**；写 8/16 位**不会**
- `movzx` / `movsx` 如何避免"脏高位"
- `xchg` 交换

仍然用退出码作为唯一输出，仍然用 `.lst` + GDB 验证。

前置：已完成第 00 章，能独立执行 `nasm` 和 `ld`。

## 2. 知识点讲解

### 2.1 低 8 个通用寄存器

| 64 位 | 32 位 | 16 位 | 8 位（低） | 8 位（高） | 常见用途 |
|---|---|---|---|---|---|
| `RAX` | `EAX` | `AX` | `AL` | `AH` | 累加器、返回值 |
| `RBX` | `EBX` | `BX` | `BL` | `BH` | 被调用者保存 |
| `RCX` | `ECX` | `CX` | `CL` | `CH` | 第 1 个参数、计数器 |
| `RDX` | `EDX` | `DX` | `DL` | `DH` | 第 2 个参数、`div` 的高位 |
| `RSI` | `ESI` | `SI` | `SIL` | — | 源索引 |
| `RDI` | `EDI` | `DI` | `DIL` | — | 目的索引 |
| `RBP` | `EBP` | `BP` | `BPL` | — | 帧指针 |
| `RSP` | `ESP` | `SP` | `SPL` | — | 栈指针 |

两个易错点：

1. `AH/BH/CH/DH` 是"高 8 位"，而 `SIL/DIL/BPL/SPL` 是"低 8 位"。两者不能混着记。
2. `AH/BH/CH/DH` **不能**和 REX 前缀一起使用。比如 `mov r8b, ah` 无法编码；需要高 8 位时优先用 `movzx` 搬到 32 位寄存器再处理。

### 2.2 高 8 个通用寄存器（R8~R15）

`R8~R15` 没有 `AH` 这种高 8 位形式，只有：

| 64 位 | 32 位 | 16 位 | 8 位 |
|---|---|---|---|
| `R8` | `R8D` | `R8W` | `R8B` |
| `R9` | `R9D` | `R9W` | `R9B` |
| … | … | … | … |
| `R15` | `R15D` | `R15W` | `R15B` |

命名规律：`D` = doubleword（32 位），`W` = word（16 位），`B` = byte（8 位）。

### 2.3 写寄存器的三条铁律

这是 x64 和 16/32 位时代最大的行为差异之一，也是很多"高位脏数据"bug 的来源：

1. **写 32 位**（如 `mov eax, 0x12345678`）：高 32 位自动清零 → `RAX = 0x0000000012345678`。
2. **写 16 位**（如 `mov ax, 0x1234`）：只改低 16 位，高 48 位保留。
3. **写 8 位**（如 `mov al, 0x99`）：只改最低 8 位，其余 56 位保留。

**推论**：给函数传参数时，如果参数是 32 位及以下（绝大多数 Windows API 的 `DWORD`/`UINT`），务必用 32 位寄存器（`ECX`/`EDX`/`R8D`/`R9D`），让高 32 位自动清零。写 16 位或 8 位会留下高位垃圾。

### 2.4 `movzx` 与 `movsx`：扩展到更宽的寄存器

从窄寄存器读到宽寄存器时，高位怎么处理有两种选择：

- `movzx`（move zero-extend）：高位填 0。无符号扩展。
- `movsx`（move sign-extend）：高位填符号位。有符号扩展。

例如 `al = 0x80`：

```text
movzx ecx, al   → ECX = 0x00000080  （128）
movsx edx, al   → EDX = 0xFFFFFF80  （-128）
```

当你需要把一个字节/字当作无符号数参与 32 位运算时，用 `movzx`；当作有符号数时用 `movsx`。**不要假设高位是 0**——除非你刚写过 32 位寄存器。

### 2.5 `xchg`：不经过第三寄存器的交换

`xchg a, b` 交换两个操作数的值。寄存器之间的 `xchg` 编码很短（`xchg eax, ebx` 只有 1 字节 `93`）。注意 `xchg` 与内存操作数一起使用时隐含 `lock` 前缀，会带来总线锁开销，性能敏感场景要留意。

### 2.6 特殊寄存器

| 寄存器 | 作用 |
|---|---|
| `RIP` | 指令指针。`[rel sym]` 就是以它为基准 |
| `RSP` | 栈指针。`push` 减 8，`pop` 加 8 |
| `RBP` | 常用作帧指针，指向当前栈帧底部 |
| `RFLAGS` | 标志位。不能直接 `mov`，常用 `pushfq` / `popfq` 或条件跳转读取 |

## 3. 实践用例

打开 [registers.asm](registers.asm)。本章程序不打印任何东西，用 6 项检查组成一个位掩码，最后把掩码作为退出码：

| 位 | 值 | 检查内容 |
|---|---|---|
| bit 0 | 1 | 写 `EAX` 清零 `RAX` 高 32 位 |
| bit 1 | 2 | 写 `AL` 只改最低字节 |
| bit 2 | 4 | `movzx` 零扩展 |
| bit 3 | 8 | `movsx` 符号扩展 |
| bit 4 | 16 | `xchg` 交换 |
| bit 5 | 32 | `R8/R8D/R8W/R8B` 命名与零扩展 |

6 项全过 → `1|2|4|8|16|32 = 63`。

### 3.1 构建与运行

```powershell
nasm -f win64 -l registers.lst -o registers.obj registers.asm
ld -o registers.exe registers.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
.\registers.exe
$LASTEXITCODE
```

实测结果：

```text
PS> .\registers.exe
PS> $LASTEXITCODE
63
```

> `63` 是**预期的成功结果**，不是构建失败。

### 3.2 `.lst` 摘录

```text
    mov rax, 0xFFFFFFFFFFFFFFFF
    mov eax, 0x12345678            ← 写 EAX，RAX 高 32 位清零
    cmp rax, 0x12345678
    jne .c1
    or r15d, 1                     ← bit 0 置位
```

```text
    mov al, 0x80
    movzx ecx, al                  ← 0x00000080
    movsx edx, al                  ← 0xFFFFFF80
```

```text
    mov r8, 0x1122334455667788
    mov r8d, 0x99AABBCC            ← 写 R8D，R8 高 32 位清零
    mov r9, 0x0000000099AABBCC
    cmp r8, r9                     ← 相等
```

## 4. 代码重点讲解

1. **入口 `sub rsp, 40`（第 00 章知识点）**：和第 00 章完全一致，入口 `RSP%16==8`，减 40 后 `%16==0`。本章不调 API，但规矩不变。
2. **检查 1「写 32 位清零高 32 位」（知识点 2.3）**：先 `mov rax, 0xFFFFFFFFFFFFFFFF` 填满，再 `mov eax, 0x12345678`。如果高 32 位没有清零，`cmp rax, 0x12345678` 就会失败。这是铁律 1 的实证。
3. **检查 2「写 8 位保留高位」（知识点 2.3）**：`mov al, 0x99` 后 `RAX` 变成 `0x1122334455667799` 而不是 `0x99`。铁律 3 的实证。
4. **检查 3/4「movzx 与 movsx」（知识点 2.4）**：同一个 `al = 0x80`，`movzx` 得到 128，`movsx` 得到 -128。这是无符号/有符号扩展的直观对照。
5. **检查 6「R8 系列命名」（知识点 2.2）**：`r8d` 是 `r8` 的低 32 位，写 `r8d` 同样把 `r8` 高 32 位清零——铁律 1 对 R8~R15 同样成立。
6. **用 `R15` 累加位掩码**：`or r15d, 1/2/4/...`。最后把 `R15D` 复制到 `ECX` 作为退出码传给 `ExitProcess`。选 `R15` 是因为它在检查过程中不被占用。

## 5. 常见坑

1. **写 `cx` 传参数**：高位残留，Windows API 收到错误值。一律用 `ecx`。
2. **`AH` 与 REX 冲突**：`mov r8b, ah` 无法编码。
3. **忘记 `movzx` 直接 `mov ecx, al`**：NASM 报错操作数宽度不匹配；必须显式扩展。
4. **假设高位为 0**：除非刚写过 32 位寄存器，否则高位是上一次留下的垃圾。
5. **`xchg` 与内存的隐含 lock**：性能敏感场景改用 `mov` 三次交换。

## 6. 练习

1. 写一个检查：`mov ebx, 0x11223344` 后 `RBX` 的高 32 位是否为 0？用 GDB 验证。
2. 把 `movzx ecx, al` 改成 `movsx ecx, al`，手动算退出码变化。
3. 增加检查：`mov r10w, 0x1234` 后 `R10` 的高 48 位是否保留？
4. 用 `xchg` 交换 `RAX` 和 `RBX`，对比三次 `mov` 写法的 `.lst` 长度。
5. 在 `al = 0x7F` 时再做一次 `movzx`/`movsx`，解释为什么这次结果相同。

## 7. 下一章

第 02 章把数据放进 PE 节区：`db/dw/dd/dq`、`.data` 与 `.bss`、`align`、小端字节序，以及 RIP 相对寻址的实际内存布局。
