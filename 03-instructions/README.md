# 第 03 章：常用指令、循环与自检

> 阶段零（00~05）不配 Makefile。
> 本章源码：[instructions.asm](instructions.asm)
> 本章清单：[instructions.lst](instructions.lst)

## 1. 本章目标

本章把"单条指令"升级为"能干活的小程序"：

- 算术：`add / sub / imul / div`
- 逻辑：`and / or / xor / test`
- 比较与跳转：`cmp / jmp / jcc`
- 循环：手工维护下标与计数器
- 函数：`call / ret`、参数寄存器、返回值
- 用退出码表达自检结果：`0 = 全部通过`

本章不再逐条打印结果，而是让程序自己检查 6 项，失败就置对应位。退出码为 0 才代表全部正确。

## 2. 知识点讲解

本章新引入的“标志位”可以先理解为 CPU 保存的若干个 1 位计算结果标记。例如 ZF（Zero Flag）记录结果是否为零，CF（Carry Flag）参与无符号进位/借位判断。后面的跳转指令读取这些标记，作用类似高级语言的 `if` 条件。先会在 `cmp/test` 后使用它们，不必一次背完标志寄存器。

### 2.1 算术指令

| 指令 | 作用 | 注意 |
|---|---|---|
| `add dst, src` | dst += src | 影响 OF/SF/ZF/CF |
| `sub dst, src` | dst -= src | `cmp` 就是不存结果的 `sub` |
| `imul` | 有符号乘法 | 见下 |
| `div` | 无符号除法 | 隐含 `RDX:RAX`，见下 |

**`div` 的隐含操作数**是 x64 汇编最容易踩的坑之一。`EDX:EAX` 和 `RDX:RAX` 中的冒号表示把两个寄存器拼成更宽的被除数，冒号前保存高位，冒号后保存低位：

```text
div ecx   →   EDX:EAX / ECX，商 → EAX，余数 → EDX
div rcx   →   RDX:RAX / RCX，商 → RAX，余数 → RDX
```

本章的普通被除数只放在 `EAX/RAX` 中，高位应为 0，所以除法前要把 `EDX`（32 位除）或 `RDX`（64 位除）清零。否则高位会污染被除数，得到错误商；商超出目的寄存器能表示的范围时还会触发除法错误，使进程终止。

**`imul` 的三种形式**：

```asm
imul eax, ecx          ; eax = eax * ecx          （二操作数）
imul eax, ecx, 6       ; eax = ecx * 6            （三操作数，不碰 EDX）
imul rcx               ; RDX:RAX = RAX * RCX      （单操作数，结果更宽）
```

日常用三操作数形式最省心，不碰 `RDX`，也不会和 `div` 的约定纠缠。

### 2.2 逻辑与测试

`and / or / xor` 是按位运算，会修改目的操作数。`test` 等价于"不保存结果的 `and`"，只改标志位。常见用法：

```asm
test eax, 1     ; 检查最低位（奇偶）。ZF=1 表示偶数
test eax, eax   ; 检查是否为 0。ZF=1 表示为 0（比 cmp eax, 0 更短）
```

### 2.3 比较与条件跳转

`cmp a, b` 做 `a - b` 但不保存结果，只改标志位。后续 `jcc` 依据标志位跳转。表中还会遇到 SF（Sign Flag，记录结果最高位）和 OF（Overflow Flag，记录有符号运算是否溢出）；第 2.7 节会用具体数字验证，这里先知道有符号跳转会读取它们即可：

| 指令 | 含义 | 标志依据 |
|---|---|---|
| `je` / `jz` | 相等 / 为零 | ZF=1 |
| `jne` / `jnz` | 不等 / 非零 | ZF=0 |
| `jb` | 小于（无符号） | CF=1 |
| `ja` | 大于（无符号） | CF=0 且 ZF=0 |
| `jl` | 小于（有符号） | SF≠OF |
| `jg` | 大于（有符号） | ZF=0 且 SF=OF |

**无符号 vs 有符号跳转**：数组下标、长度、计数器通常是非负数，用 `jb/ja`；有符号数比较用 `jl/jg`。本章循环计数用 `jb`。

### 2.4 循环的标准写法

虽然 x64 也提供 `loop` 指令，本教程仍显式维护计数器并用条件跳转结束循环，因为这样能直接看清高级语言 `for/while` 对应的每一步。本章不比较不同循环指令的性能：

```text
初始化计数器 i=0，总和=0
.loop:
    sum += arr[i]
    i++
    if i < len: goto .loop
```

寻址 `[base + index*scale]`：`[rsi + rdx*8]` 表示"基址 rsi + 索引 rdx * 8"，scale 只能是 1/2/4/8。

### 2.5 `call` / `ret` 与栈帧

`call label` 做两件事：把返回地址压栈，然后跳到 `label`。`ret` 从栈顶弹出返回地址并跳回去。

被调用函数的标准序言/尾声：

```asm
sum_qwords:
    push rbp            ; 保存旧帧指针
    mov  rbp, rsp       ; 建立新帧指针
    sub  rsp, 32        ; 32 字节影子空间（也是 16 的倍数）
    ...
    leave               ; = mov rsp, rbp + pop rbp
    ret
```

**对齐推导**（与第 00 章入口对齐同理）：
- 调用者 `call` 时 `RSP%16==0` → 压入返回地址后，被调方入口 `RSP%16==8`。
- `push rbp` 减 8 → `RSP%16==0`。
- `sub rsp, 32` 仍是 16 的倍数 → 保持 `RSP%16==0`。

这样被调方内部再 `call` 其他函数时仍然对齐。

### 2.6 指令操作数：NASM 的方向与宽度

NASM 使用“目的在前，源在后”：

```asm
add rax, rbx    ; RAX = RAX + RBX，RBX 不变
sub rcx, 1      ; RCX = RCX - 1
```

常见合法组合是：

```text
寄存器 ← 立即数
寄存器 ← 寄存器
寄存器 ← 内存
内存   ← 寄存器
内存   ← 立即数（通常必须显式写宽度）
```

普通 `mov/add/sub` 不能同时用两个内存操作数。例如不能写 `mov [a],[b]`；要经过寄存器：

```asm
mov rax, [rel b]
mov [rel a], rax
```

两个操作数的宽度还必须一致。`mov eax, al` 一边是 32 位、一边是 8 位，不能直接编码；应按语义选 `movzx eax,al` 或 `movsx eax,al`。

### 2.7 标志位：用具体数字看 ZF、CF、SF、OF

以 8 位运算为例，CPU 只保留低 8 位结果，同时记录标志：

| 运算 | 保存的结果 | ZF | CF | SF | OF | 解释 |
|---|---|---:|---:|---:|---:|---|
| `0+0` | `0x00` | 1 | 0 | 0 | 0 | 结果为零 |
| `0xFF+1` | `0x00` | 1 | 1 | 0 | 0 | 无符号 255+1 回绕，有进位 |
| `0x80-1` | `0x7F` | 0 | 0 | 0 | 1 | 有符号 -128-1 应为 -129，超出范围 |
| `0x7F+1` | `0x80` | 0 | 0 | 1 | 1 | 有符号 127+1 应为 128，超出范围 |
| `5-3` | `0x02` | 0 | 0 | 0 | 0 | 无借位，结果为正 |

不要只背“CF=进位、OF=溢出”就混用：

- 对无符号解释，重点看 CF；
- 对有符号解释，重点看 OF/SF；
- `cmp` 后的 `jb/ja` 和 `jl/jg` 正是为两种解释分别准备的。

例如 `cmp 0x80,0x01`：作为无符号数，`128>1`，所以 `ja` 会跳；作为有符号 8 位数，`-128<1`，所以 `jl` 会跳。寄存器里的字节完全一样，跳转选择不同。

### 2.8 为什么 `test eax,eax` 能判断零

`test eax,eax` 计算 `EAX & EAX`。任何数与自己做 AND 都等于自身，因此：

- EAX=0 → AND 结果为 0 → ZF=1 → `jz` 跳转；
- EAX≠0 → AND 结果非 0 → ZF=0 → `jnz` 跳转。

`test eax,1` 则只保留最低位用于判断：偶数最低位为 0，所以 ZF=1；奇数最低位为 1，所以 ZF=0。`test` 不把 AND 结果写回 EAX。

### 2.9 循环逐轮展开

本章求和循环的核心是：

```asm
; RSI=数组首地址，RDX=i，RCX=10，RAX=sum
.sum_loop:
    add rax, [rsi + rdx*8]
    inc rdx
    cmp rdx, rcx
    jb .sum_loop
```

前几轮与最后一轮：

| 进入循环时 i | 本次加入 | add 后 sum | inc 后 i | `i<10`？ | 下一步 |
|---:|---:|---:|---:|---|---|
| 0 | 1 | 1 | 1 | 是 | 跳回 |
| 1 | 2 | 3 | 2 | 是 | 跳回 |
| 2 | 3 | 6 | 3 | 是 | 跳回 |
| … | … | … | … | … | … |
| 9 | 10 | 55 | 10 | 否 | 顺序离开循环 |

退出条件发生在 `i` 已增加到 10 之后，所以访问过的下标是 0～9，恰好 10 个元素。把 `jb` 改成 `jbe` 会多访问下标 10，越过数组末尾；把 `inc` 放到 `add` 前又会先访问下标 1、漏掉下标 0。分析循环时要把**初值、访问、递增、比较**四件事分开。

### 2.10 `call` 前后 RIP/RSP 的具体变化

假设 `call sum_qwords` 位于地址 `0x1000`，长度为 5 字节：

```text
执行 call 前：RIP=0x1000，RSP=S
call 做的事：把下一条地址 0x1005 写入 [S-8]，RSP=S-8，RIP=sum_qwords
函数 ret 时：从 [S-8] 取出 0x1005，RSP 恢复为 S，RIP=0x1005
```

所以返回地址不是 `call` 自己，也不是函数末尾，而是**调用指令的下一条指令**。如果函数内部用栈保存数据，返回前必须恢复 RSP，否则 `ret` 会把局部变量当成地址跳走。

## 3. 实践用例

打开 [instructions.asm](instructions.asm)。程序做 6 项自检，**通过则跳过置位，失败才置位**，所以全过时退出码为 0：

| 位 | 值 | 检查 |
|---|---|---|
| bit 0 | 1 | 循环求和 1..10 = 55 |
| bit 1 | 2 | 字符串 `"hello"` 长度为 5 |
| bit 2 | 4 | `imul`：7 * 6 = 42 |
| bit 3 | 8 | `div`：42 / 6 商 7 余 0 |
| bit 4 | 16 | `test` 判 42 为偶数 |
| bit 5 | 32 | `call/ret` 调用本地求和函数 |

### 3.1 构建与运行

```powershell
nasm -f win64 -l instructions.lst -o instructions.obj instructions.asm
ld -o instructions.exe instructions.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
.\instructions.exe
$LASTEXITCODE
```

实测结果：

```text
PS> .\instructions.exe
PS> $LASTEXITCODE
0
```

`0` 表示 6 项全部通过。故意改坏一项（比如把 `cmp rax, 55` 改成 `cmp rax, 56`），退出码就会变成 `1`。

### 3.2 `.lst` 摘录

```text
    35 00000017 480304D6                    add rax, [rsi + rdx*8]
    36 0000001B 48FFC2                      inc rdx
    37 0000001E 4839CA                      cmp rdx, rcx
    38 00000021 72F4                        jb .sum_loop
    39 00000023 4883F837                    cmp rax, 55
    48 00000036 803C0600                    cmp byte [rsi + rax], 0
    60 0000004E 6BC006                      imul eax, eax, 6
    70 00000066 F7F1                        div ecx
    81 0000007B A901000000                  test eax, 1
    89 00000092 E812000000                  call sum_qwords
   106 000000A9 55                          push rbp
   108 000000AD 4883EC20                    sub rsp, 32
   118 000000C2 C9                          leave
   119 000000C3 C3                          ret
```

- `480304D6`：`add rax, [rsi + rdx*8]`，`D6` 是 SIB 字节，编码 base=rsi, index=rdx, scale=8。
- `72F4`：`jb` 的短跳转，位移 `F4` = -12，跳回循环开头。
- `6BC006`：`imul eax, eax, 6` 三操作数形式。
- `F7F1`：`div ecx`。
- `E812000000`：`call` 用 32 位相对位移。
- `C9` / `C3`：`leave` / `ret`，各 1 字节。

### 3.3 GDB 验证

断在循环第一条指令，单步一次：

```text
rax            0x0    ← 循环前
rdx            0x0
rax            0x1    ← 执行 add 后，arr[0]=1 被加进来
rdx            0x0    ← inc 还没执行
```

## 4. 代码重点讲解

1. **循环求和（知识点 2.4）**：`[rsi + rdx*8]` 是基址+变址寻址，`rdx` 当下标。`jb` 用于无符号比较。循环 10 次累加 `1+2+...+10=55`。
2. **字符串长度（知识点 2.3）**：`cmp byte [rsi + rax], 0` 逐字节找到结尾的 0。`byte` 必须显式写，否则 NASM 不知道比较宽度。
3. **除法前清 EDX（知识点 2.1）**：`xor edx, edx` 是 `div ecx` 前的必修课。漏掉的话 `EDX:EAX` 变成巨大数，商可能溢出。
4. **`test eax, 1`（知识点 2.2）**：检查奇偶。42 的最低位是 0，`test` 后 ZF=1，`je` 跳转通过。
5. **本地函数栈帧（知识点 2.5）**：`sum_qwords` 的序言 `push rbp; sub rsp, 32` 保证入口 `RSP%16==8` 经 `push`→0、`sub 32`→0。`leave` 等于 `mov rsp,rbp; pop rbp`。
6. **自检逻辑方向**：通过就 `je` 跳过 `or r15d, bit`，失败才置位。写 `cmp`+`jcc` 后一定要用小例子验证分支方向。

## 5. 常见坑

1. **`div` 前忘记清 `RDX`/`EDX`**：本章使用 `RDX:RAX` 作为被除数；高位脏数据会导致错误商，甚至触发除法错误。
2. **有符号除法用 `div`**：负数要改用有符号除法 `idiv`，并先用 `cqo`（64 位）或 `cdq`（32 位）把被除数的符号位复制到 `RDX/EDX`，不要直接套用无符号 `div`。
3. **`jb`/`jl` 混用**：`jb` 无符号，`jl` 有符号。数组下标通常无符号。
4. **自检逻辑写反**：通过置位会导致全过却返回非零。
5. **`cmp byte [...]` 漏写 `byte`**：NASM 无法推断内存操作数宽度。
6. **`call` 前栈未对齐**：调用者必须保证 `call` 点 `RSP%16==0`。
7. **把 `lea` 当成读内存**：`lea` 只算地址。
8. **以为 `test` 会改操作数**：`test` 只改标志位。

## 6. 练习

1. 把 `cmp rax, 55` 改成 `cmp rax, 56`，确认退出码变成 1；再改回来。
2. 把 `ARR_LEN` 改成 9，循环只加前 9 个元素；预期和是多少？自检位会怎样？
3. 把字符串改成 `"hello, asm"`，同步修改长度检查，观察退出码。
4. 把 `div ecx` 换成 `idiv ecx`，并用 `mov eax, -42` / `cdq` / `mov ecx, 6` 计算 -42 / 6，验证商和余数。
5. 在 `sum_qwords` 入口加一条 `nop`，用 GDB `b sum_qwords` 观察 `RSP % 16 == 8`，再 `si` 三次观察序言后的对齐。

## 7. 下一章

第 04 章是选读：如果接触过 DOS 或 16 位 MASM，可以学习旧代码怎样迁移到 NASM x64；没有这方面背景可直接进入第 05 章，学习栈、函数调用与递归。
