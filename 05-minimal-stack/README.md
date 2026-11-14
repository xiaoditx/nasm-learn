# 第 05 章：栈、栈帧与 call/ret

> 阶段零（00~05）不配 Makefile。
> 本章源码：[stack.asm](stack.asm)
> 附加源码：[bare.asm](bare.asm)（零依赖实验，**只编译，不要运行**）
> 本章清单：[stack.lst](stack.lst)

## 1. 本章目标

前面几章一直在用 `sub rsp, 40` 和 `call`，但没解释栈到底怎么动。本章回答：

- `push` / `pop` 对 `RSP` 做了什么？
- `call` 和 `ret` 如何配合？
- 标准栈帧 `push rbp / mov rbp, rsp / sub rsp, 32` 每一行在做什么？
- 递归时栈如何增长？
- 为什么入口处直接 `ret` 不是可靠的退出方式？

程序用递归阶乘 `5! = 120` 作为可验证结果。

## 2. 知识点讲解

### 2.1 栈的基本操作

x64 的栈**向下增长**：`push` 时 `RSP` 减小，`pop` 时 `RSP` 增大。栈顶就是"当前 `RSP` 指向的位置"。

| 操作 | 效果 |
|---|---|
| `push rax` | `RSP -= 8`，然后把 `RAX` 写到 `[RSP]` |
| `pop rax` | 从 `[RSP]` 读到 `RAX`，然后 `RSP += 8` |
| `call label` | `RSP -= 8`，把返回地址写到 `[RSP]`，跳转到 `label` |
| `ret` | 从 `[RSP]` 弹出返回地址到 `RIP`，然后 `RSP += 8` |

`call` 和 `ret` 本质上是一对"压返回地址 + 跳"和"弹返回地址 + 跳"的配合。

### 2.2 Windows x64 栈的两条硬规则

1. **没有红区（red zone）**：不能往 `[rsp-8]` 之类未分配区域写数据，函数调用会覆盖它。（System V ABI 有红区，Windows x64 没有。）
2. **影子空间（shadow space）**：调用任何 Windows x64 函数前，调用者要在栈上留出 32 字节，供被调用者保存 `RCX/RDX/R8/R9` 的参数。即使函数只有 1 个参数，这 32 字节也必须留。

### 2.3 ABI 对齐四件事（阶段零总结）

1. **入口 `RSP % 16 == 8`**：`call` 压入 8 字节返回地址后，被调用函数看到的就是这个状态。
2. **`call` 指令执行时 `RSP % 16 == 0`**：调用者必须先把自己的栈对齐到 16。
3. **序言二选一**：
   - 叶子函数或不需要帧指针：`sub rsp, 40`（8 字节对齐 + 32 字节影子空间）；
   - 需要帧指针：`push rbp`（`% 16 == 0`）+ `mov rbp, rsp` + `sub rsp, 32`（影子空间）。
4. **非易失寄存器**：`RBX / RBP / RDI / RSI / R12~R15` 由被调用者保存；`RAX / RCX / RDX / R8~R11` 是易失的。

完整 ABI 四件套（`RCX/RDX/R8/R9` 参数传递、32 字节影子空间、16 字节对齐、非易失寄存器）会在第 06 章配 Makefile 后系统展开。

### 2.4 标准栈帧的逐行含义

```asm
push rbp        ; 保存调用者的帧指针；RSP 减 8 → %16==0
mov  rbp, rsp   ; RBP 指向当前栈帧底部（保存的旧 RBP 位置）
sub  rsp, 32    ; 分配 32 字节本地槽 + 影子空间；仍是 16 的倍数
```

此后 `[rbp]` 是旧 RBP，`[rbp+8]` 是返回地址，`[rbp-1]` 往下是本地变量。`leave` 等于 `mov rsp, rbp; pop rbp`，把栈恢复到调用前。

### 2.5 递归时栈的增长

每次递归调用，栈上多出一帧：

```text
8   返回地址（call 压入）
8   保存的 RBP（push rbp）
32  影子空间/本地槽（sub rsp, 32）
── 合计 48 字节/层
```

`fact(5)` → `fact(4)` → ... → `fact(1)`，栈逐层向下增长 48 字节。基线条件（`n <= 1` 返回 1）保证递归收敛，否则栈溢出。

### 2.6 为什么入口直接 `ret` 不靠谱

入口栈顶的返回地址属于 `KERNEL32!BaseThreadInitThunk` 的内部流程。`ret` 之后继续执行依赖启动代码自己的栈状态——这不是给用户程序准备的退出路径，退出码也无法控制。实测入口直接 `ret` 会导致进程挂起。

**结论：正式程序一律调用 `ExitProcess`（或 `ExitThread`），不要靠入口 `ret` 退进程。**

## 3. 实践用例

打开 [stack.asm](stack.asm)。程序递归计算 `5! = 120`，结果作为退出码。

### 3.1 构建与运行

```powershell
nasm -f win64 -l stack.lst -o stack.obj stack.asm
ld -o stack.exe stack.obj -L "C:/msys64/ucrt64/lib" -lkernel32 --subsystem console --entry=_start
.\stack.exe
$LASTEXITCODE
```

实测结果：

```text
PS> .\stack.exe
PS> $LASTEXITCODE
120
```

### 3.2 `.lst` 摘录

```text
    25 00000000 4883EC28                    sub rsp, 40
    27 00000004 B905000000                  mov ecx, 5
    28 00000009 E807000000                  call fact
    31 0000000E 89C1                        mov ecx, eax
    32 00000010 E8(00000000)                call ExitProcess
    44 00000015 55                          push rbp
    45 00000016 4889E5                      mov rbp, rsp
    46 00000019 4883EC20                    sub rsp, 32
    48 0000001D 894DFC                      mov [rbp - 4], ecx
    51 00000025 8D49FF                      lea ecx, [rcx - 1]
    54 00000028 E8E8FFFFFF                  call fact
    55 0000002D 8B4DFC                      mov ecx, [rbp - 4]
    56 00000030 0FAFC1                      imul eax, ecx
    63 0000003A C9                          leave
    64 0000003B C3                          ret
```

- `E807000000`：`call fact` 相对位移 +7。
- `E8E8FFFFFF`：递归 `call fact` 位移 -0x18，跳回函数开头。
- `894DFC`：`mov [rbp-4], ecx`，`FC` = -4。
- `C9` / `C3`：`leave` / `ret`。

### 3.3 GDB 观察栈帧

```text
fact(5) 入口    rsp = 0x...f8   (%16 == 8)
序言后          rsp = 0x...d0   rbp = 0x...f0
fact(4) 入口    rsp = 0x...c8   (比上一次入口低 0x30 = 48 字节)
```

每次递归固定下降 48 字节，与知识点 2.5 的推导一致。

### 3.4 零依赖实验 bare.asm（只编译，不运行）

[bare.asm](bare.asm) 只有两条指令：

```asm
_start:
    mov eax, 7
    ret
```

`objdump -p bare.exe | Select-String "DLL Name"` 没有任何输出，说明它确实零导入。但**不要运行**——实测进程会挂起。原因见知识点 2.6。

## 4. 代码重点讲解

1. **入口 `sub rsp, 40`（知识点 2.3）**：入口 `RSP%16==8`，减 40 后 `%16==0`，所以 `call fact` 合法。`fact` 的返回值在 `EAX`，直接作为退出码。
2. **标准栈帧（知识点 2.4）**：`push rbp` → `%16==0`，`mov rbp, rsp` 建立帧指针，`sub rsp, 32` 留影子空间。此后函数体内再 `call fact` 仍然对齐。
3. **把 `n` 存到 `[rbp-4]`**：递归调用 `fact(n-1)` 会覆盖 `ECX`，所以调用前把 `n` 保存到本地槽。`[rbp-4]` 位于 `sub rsp, 32` 分配的区域内，是安全的。
4. **`lea ecx, [rcx - 1]`**：用 `lea` 做减法（`rcx-1`），不影响标志位，比 `dec` + 处理副作用更干净。
5. **`imul eax, ecx`**：把 `(n-1)!`（在 `EAX`）乘上 `n`（从 `[rbp-4]` 恢复到 `ECX`）。
6. **`leave; ret`**：`leave` 恢复 `RSP` 和 `RBP`，`ret` 弹出返回地址。

## 5. 常见坑

1. **`call` 前忘记对齐**：不 `sub rsp, 40` 直接 `call`，被调方入口 `%16==0`，违反 ABI。简单函数可能侥幸能跑，调用 SSE 或系统 API 时容易崩。
2. **序言只 `sub rsp, 24`**：`8+24=32`，`RSP%16` 仍是 8，`call` 依然错位。要凑到 16 的倍数。
3. **以为 Windows 有红区**：没有。`[rsp-8]` 是未分配区域，`call` 会覆盖。
4. **影子空间只留 8 字节**：Windows x64 要求 32 字节。
5. **本地槽超出分配范围**：`sub rsp, 32` 后 `[rbp-32]` 到 `[rbp-1]` 才是你的。
6. **递归不收敛**：缺基线条件会栈溢出。
7. **`leave` 后再访问本地变量**：`leave` 已把 `RSP` 抬回 `RBP`，本地槽全部失效。
8. **靠入口 `ret` 退出**：退出码不可控，实测挂起；用 `ExitProcess`。

## 6. 练习

1. 把 `mov ecx, 5` 改成 `6`，验证退出码为 720；再试 `7`（5040）。
2. 在 `fact` 里增加一个本地槽 `[rbp-8]` 保存 `n-1`，观察 `.lst` 变化。
3. 用 GDB 在每次 `fact` 命中时打印 `rsp`，列出 `fact(5)` 到 `fact(1)` 的完整下降过程，验证每层固定 48 字节。
4. 把序言改成 `sub rsp, 24`，在 GDB 里检查 `call` 前的 `RSP % 16`，解释为什么错。
5. 给 `bare.asm` 加 `call ExitProcess`（并 `extern`、链接 `-lkernel32`），比较两种退出方式。

## 7. 下一章

第 06 章开始进入"有构建系统"的阶段：每章配 `Makefile`，`nasm -l $@.lst` 自动生成清单；共享定义抽到 `common.asm`，用 `%include` 复用；README 完整讲 ABI 四件套。
