# 第 07 章：wmain 的参数表 —— argc / argv

> 本章源码：[args.asm](args.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[args.obj.lst](args.obj.lst)

## 1. 本章目标

第 06 章只打印了 `argc`。本章把参数表真正走一遍：

- `argv` 到底是什么类型？它在内存里怎么排？
- 为什么 `argv[argc]` 一定是 `NULL`？
- 如何用 `[基址 + 索引*8]` 取出每个参数？
- 为什么本章的序言是 `sub rsp, 64` 而不是 32？
- 本地槽放错位置会怎样？本章会展示一个真实踩过的坑。

## 2. 前置 / 项目结构

前置知识：第 06 章的 CRT 启动、`wmain` 签名、`wprintf` 变参约定、ABI 四件套。

```text
rebuild/07-wide-console-args/
├── Makefile
├── args.asm
├── README.md
└── args.obj.lst
```

## 3. 知识点讲解

### 3.1 `argv` 的内存布局

假设运行 `args.exe alpha beta`，`argv` 指向一个**指针数组**（不是字符串）：

```text
argv ──► +0  ┌───────────────┐
             │ 指向 argv[0]  │ ──► "C:\...\args.exe\0"（UTF-16）
             ├───────────────┤
        +8   │ 指向 argv[1]  │ ──► "alpha\0"
             ├───────────────┤
        +16  │ 指向 argv[2]  │ ──► "beta\0"
             ├───────────────┤
        +24  │ NULL          │
             └───────────────┘
```

要点：

- `argv[i]` 是 `wchar_t *`，本身占 8 字节（指针大小）；
- `argv` 的元素个数是 `argc + 1`，最后一个是 `NULL` 哨兵；
- 参数字符串内容在别处（CRT 准备好的区域），`argv` 只是指针数组。

取值用基址 + 索引 * 8 的寻址：

```asm
mov r8, [r8 + rax*8]     ; r8 = argv[i]
```

`rax` 必须是 64 位有效的索引。前面用 `mov eax, [rbp-20]` 读 `i`，写 `EAX` 会自动把 `RAX` 高 32 位清零，因此可以直接参与寻址。

### 3.2 ABI 四件套（本章复述）

#### 3.2.1 RCX / RDX / R8 / R9

`wmain(int argc, wchar_t **argv)`：

| 参数 | 寄存器 |
|---|---|
| `argc` | `ECX`（写 `ECX` 会清零 `RCX` 高 32 位） |
| `argv` | `RDX` |

`wprintf` 是变参函数：格式串在 `RCX`，之后的可变参数依次是 `RDX`、`R8`、`R9`，第 5 个开始放 `[rsp+32]`。

#### 3.2.2 32 字节影子空间

每次 `call wprintf` 之前，`[rsp]` 到 `[rsp+31]` 必须属于调用者预留的区域。`wprintf` 可以把 `RCX/RDX/R8/R9` 溢出到这里。

#### 3.2.3 16 字节对齐

- `wmain` 入口：`RSP % 16 == 8`；
- `call wprintf` 执行时：`RSP % 16 == 0`。

本章序言：

```asm
push rbp             ; 8 → 0
mov  rbp, rsp
sub  rsp, 64         ; 0 → 0
```

`64 = 32 影子 + 32 本地槽`。`64 % 16 == 0`，所以对齐保持。

#### 3.2.4 非易失寄存器

| 类别 | 寄存器 |
|---|---|
| 非易失 | `RBX`、`RBP`、`RDI`、`RSI`、`R12`~`R15`、`XMM6`~`XMM15` |
| 易失 | `RAX`、`RCX`、`RDX`、`R8`~`R11`、`XMM0`~`XMM5` |

本章没有使用 `RBX/RDI/RSI`，所有中间值都放在 `[rbp-*]` 本地槽里，所以不需要额外 `push`。

### 3.3 本地槽与影子空间的布局

`sub rsp, 64` 之后，栈长这样：

```text
高地址
rbp     ──► 保存的旧 RBP
rbp+8   ──► 返回地址
rbp-1   ──┐
rbp-4   ──┤ argc
rbp-16  ──┤ argv
rbp-20  ──┤ i              本地槽（[rbp-20 .. rbp-1]，不会被 call 覆盖）
rbp-33  ──┘
rbp-34  ──┐
...      ──┤ 未使用
rbp-63  ──┘
rbp-64  ──┐
rsp     ──┤ [rsp .. rsp+31] = [rbp-64 .. rbp-33]  → 影子空间
低地址
```

判断本地槽是否安全的标准：**本地槽地址必须大于 `rsp + 32`**（即不在影子空间范围内）。

本章 `rsp = rbp - 64`，影子空间是 `[rbp-64 .. rbp-33]`，本地槽在 `[rbp-20 .. rbp-1]`，两者不重叠。

### 3.4 本章踩过的坑：本地槽落进影子空间

初版写的是 `sub rsp, 48`，把 `i` 放在 `[rbp-20]`：

```text
rsp = rbp - 48
影子空间：[rbp-48 .. rbp-17]
i 所在：  [rbp-20]        ← 正好落在影子空间里！
```

调用 `wprintf` 后，`i` 被 `wprintf` 溢出的数据覆盖，循环判断 `i >= argc` 立即成立，结果一行参数都没打印。

修正方法有两个：

1. 把本地槽往前挪（例如 `[rbp-4]`、`[rbp-8]`、`[rbp-16]`）；
2. 多分配 16 字节（`sub rsp, 64`），本章采用这个。

### 3.5 `wprintf` 的格式说明符

本章用到三个格式符：

| 格式 | 含义 | 参数位置 |
|---|---|---|
| `%d` | 十进制整数（32 位） | `RDX` |
| `%p` | 指针（64 位） | `R8` |
| `%ls` | 宽字符串（`wchar_t *`） | `R9` |

`wprintf` 的第一个可变参数放 `RDX`（对应第一个 `%`），第二个放 `R8`，第三个放 `R9`。本章格式串 `argv[%d] @ %p = %ls` 正好对应 `RDX=i`、`R8=argv[i]`、`R9=argv[i]`。

## 4. 实践用例

打开 [args.asm](args.asm)。程序打印 `argc` 和每个 `argv[i]` 的地址与内容。

### 4.1 构建与运行

```powershell
make
.\args.exe alpha beta "two words"
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l args.obj.lst -o args.obj args.asm
gcc -municode -o args.exe args.obj
argc = 4
argv[0] @ 0000018AF13B84E0 = C:\Users\Administrator\Documents\masm-learn\07-wide-console-args\args.exe
argv[1] @ 0000018AF13B6CD0 = alpha
argv[2] @ 0000018AF13B6CF0 = beta
argv[3] @ 0000018AF13B6A90 = two words
0
```

指针值是 ASLR 后的实际地址，每次运行都可能不同；`argc = 4` 和四条内容是稳定的。退出码 `0`。

### 4.2 `.lst` 摘录

```text
    21 00000000 55                          push    rbp
    22 00000001 4889E5                      mov     rbp, rsp
    23 00000004 4883EC40                    sub     rsp, 64
    25 00000008 894DFC                      mov     dword [rbp - 4], ecx
    26 0000000B 488955F0                    mov     qword [rbp - 16], rdx
    27 0000000F C745EC00000000              mov     dword [rbp - 20], 0
    36 0000002A 3B45FC                      cmp     eax, dword [rbp - 4]
    37 0000002D 7D20                        jge     .done
    39 0000002F 4C8B45F0                    mov     r8, qword [rbp - 16]
    40 00000033 4D8B04C0                    mov     r8, qword [r8 + rax*8]
    41 00000037 4D89C1                      mov     r9, r8
    43 0000003A 89C2                        mov     edx, eax
    46 00000045 E8(00000000)                call    wprintf
    48 0000004A FF45EC                      inc     dword [rbp - 20]
    49 0000004D EBD8                        jmp     .loop
```

读法：

- `4883EC40`：`sub rsp, 64`，`40` 是 64；
- `894DFC`：`mov [rbp-4], ecx`；`FC` 是 -4；
- `488955F0`：`mov [rbp-16], rdx`；`F0` 是 -16；
- `C745EC00000000`：`mov dword [rbp-20], 0`，`EC` 是 -20；
- `4D8B04C0`：`mov r8, [r8 + rax*8]`；`04` 是 SIB 字节，`C0` 表示 `rax*8 + r8`；
- `FF45EC`：`inc dword [rbp-20]`；
- `EBD8`：`jmp` 回 `-0x28`（`0x4D` 的下一条是 `0x4F`，`0x4F - 0x28 = 0x27`，即 `.loop`）。

## 5. 代码重点讲解

1. **序言 `sub rsp, 64`（知识点 3.3、3.4）**：`64 = 32 影子 + 32 本地槽`。`rsp = rbp - 64`，影子空间 `[rbp-64..rbp-33]`，本地槽 `[rbp-20..rbp-1]`，两者不重叠。初版 `sub rsp, 48` 导致 `i` 落进影子空间被覆盖，改成 64 后正常。

2. **保存 `argc`/`argv`/`i` 到本地槽**：`mov [rbp-4], ecx`、`mov [rbp-16], rdx`、`mov [rbp-20], 0`。因为 `wmain` 体内要多次 `call wprintf`，`ECX/RDX` 会被覆盖，所以先存到本地槽。注意 `argc` 用 `dword`（4 字节），`argv` 用 `qword`（8 字节）。

3. **`mov r8, [r8 + rax*8]` 取 `argv[i]`（知识点 3.1）**：第一次 `mov r8, [rbp-16]` 取数组基址；第二次用 `[基址 + 索引*8]` 取第 `i` 个指针。`*8` 是因为每个指针占 8 字节。

4. **`mov r9, r8` 复制指针**：`R8` 既要作为 `%p` 的参数（指针值），又要作为 `%ls` 的参数（字符串地址）。两者打印同一个地址，对照输出可以确认"指针数组元素指向字符串"。

5. **`mov edx, eax` 把 `i` 传给 `%d`**：格式串 `argv[%d] @ %p = %ls` 有三个可变参数，按顺序落在 `RDX`（`i`）、`R8`（`argv[i]` 指针）、`R9`（`argv[i]` 字符串）。

6. **`inc dword [rbp-20]` + `jmp .loop`**：循环计数器 `i` 自增，无条件跳回循环头。`jge .done` 在循环开头判断 `i >= argc`，不满足就继续。

## 6. 常见坑

1. **本地槽落进影子空间**：本章初版 `sub rsp, 48`、`i` 在 `[rbp-20]`，被 `wprintf` 覆盖，循环直接退出。改成 64 后正常。判断标准：本地槽地址必须大于 `rsp + 32`。
2. **把 `argv` 当字符串**：`argv` 是 `wchar_t **`，第一次解引用才是字符串。`%ls` 要传 `argv[i]`，不是 `argv`。
3. **用 `%s` 打宽字符串**：在 `wprintf` 里优先写 `%ls`，明确表示宽字符串。
4. **忘记 `argv[argc] == NULL`**：循环条件用 `i < argc`，不要去打印哨兵。
5. **用 32 位寄存器存指针**：`mov r8d, [rbp-16]` 会截断高 32 位，必须用 `mov r8, qword [...]`。
6. **索引没清零高 32 位**：`mov eax, [rbp-20]` 会自动清零 `RAX` 高 32 位；如果直接 `mov rax, [rbp-20]` 读到 8 字节垃圾就麻烦了。
7. **在循环里用 `RBX/RSI/RDI` 却不保存**：它们是非易失的，CRT 或其他调用者可能依赖原值。

## 7. 练习

1. 传 5 个参数，验证 `argc = 6` 且输出 6 行。
2. 打印 `argv[argc]` 的指针值（应为 `0`），理解哨兵。
3. 在循环里累加每个参数字符串的码元数，打印总长度。
4. 传一个中文参数（例如 `.\args.exe 中文`），观察本环境的 `wprintf` 是否显示为 `????`，并思考第 11 章的 UTF-8 方案。
5. 把序言改回 `sub rsp, 48`，在 GDB 里观察 `[rbp-20]` 是否在 `call` 后被改写。

## 8. 下一章

第 08 章进入文件 I/O：

- `CreateFileW` 的 7 个参数，后 3 个在栈上；
- `WriteFile` / `ReadFile` / `CloseHandle`；
- 写入 UTF-16 文本，关闭后重新打开读回；
- 失败句柄 `INVALID_HANDLE_VALUE` 的判断。
