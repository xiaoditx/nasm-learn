# 第 09 章：堆内存与结构体 —— HeapAlloc + struc

> 本章源码：[heap_structs.asm](heap_structs.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[heap_structs.obj.lst](heap_structs.obj.lst)

## 1. 本章目标

本章解决两个问题：

- 在汇编里怎么定义"结构体"？
- 结构体数组和链表的内存从哪里来？

内容包括：

- NASM 的 `struc` / `endstruc` / `istruc`；
- `GetProcessHeap` / `HeapAlloc` / `HeapFree`；
- 用 `i * ITEM_size` 计算数组元素地址；
- 把 3 个节点串成单向链表并遍历求和；
- 在 `.lst` 中确认字段偏移和分配大小。

## 2. 前置 / 项目结构

前置知识：第 06 章 ABI 四件套、第 07 章本地槽布局、第 08 章句柄概念（堆句柄也是 `HANDLE`）。

```text
rebuild/09-heap-structs/
├── Makefile
├── heap_structs.asm
├── README.md
└── heap_structs.obj.lst
```

## 3. 知识点讲解

### 3.1 NASM 的 `struc`：只产生偏移常量

NASM 用 `struc` / `endstruc` 定义结构体，但和高级语言不同——它**不分配内存**，只产生一组**偏移常量**。

```asm
struc ITEM
    .id:    resd 1      ; +0
    .value: resd 1      ; +4
    .next:  resq 1      ; +8
endstruc               ; NASM 自动产生 ITEM_size = 16
```

要点：

- `resd` / `resq` 在 `struc` 里**不分配内存**，只推进"当前偏移"；
- `.id`、`.value`、`.next` 是**偏移常量**（数字），不是变量；用法是 `[ptr + ITEM.id]`；
- `endstruc` 自动定义 `ITEM_size = 16`；
- NASM 不会自动插入对齐填充，字段顺序和大小由你决定。

布局：

| 字段 | 偏移 | 大小 |
|---|---|---|
| `id` | 0 | 4 |
| `value` | 4 | 4 |
| `next` | 8 | 8 |
| 总计 | 16 | |

为了让 `next`（8 字节）落在 8 字节边界，这里把两个 `resd`（各 4 字节）放在前面，正好凑成 8。

### 3.2 静态结构体：`istruc`

`struc` 只定义偏移，要真正分配内存用 `istruc`：

```asm
static_item:
    istruc ITEM
        at ITEM.id,    dd 99
        at ITEM.value, dd 1234
        at ITEM.next,  dq 0
    iend
```

`at ITEM.id, dd 99` 表示"在偏移 `ITEM.id`（即 0）处放一个 `dd 99`"。`.lst` 里可以看到这三条数据分别落在偏移 `0/4/8`。

### 3.3 进程堆：`GetProcessHeap` / `HeapAlloc` / `HeapFree`

Windows 每个进程有一个默认堆。三个 API：

```c
HANDLE GetProcessHeap(void);                       // 无参数，返回堆句柄（RAX）
LPVOID HeapAlloc(HANDLE hHeap,                     // RCX
                 DWORD  dwFlags,                   // EDX
                 SIZE_T dwBytes);                  // R8
BOOL   HeapFree(HANDLE hHeap,                      // RCX
                DWORD  dwFlags,                    // EDX
                LPVOID lpMem);                     // R8
```

- `GetProcessHeap` 返回进程默认堆的句柄；
- `HeapAlloc(hHeap, flags, bytes)` 分配 `bytes` 字节，失败返回 `NULL`；
- `HeapFree(hHeap, 0, ptr)` 释放，`dwFlags` 必须为 0；
- `HEAP_ZERO_MEMORY`（值为 8）让新分配的内存全零，省得手动清 `next`。

`SIZE_T` 是 64 位，所以 `dwBytes` 规范写法用 `R8`，不要写 `R8D` 丢掉高位（本章数据量小，写 `R8D` 也能跑）。

### 3.4 ABI 四件套（本章复述）

#### 3.4.1 RCX / RDX / R8 / R9

| 函数 | 参数 |
|---|---|
| `GetProcessHeap` | 无，返回 `RAX` |
| `HeapAlloc` | `RCX`=堆句柄，`EDX`=flags，`R8`=字节数 |
| `HeapFree` | `RCX`=堆句柄，`EDX`=flags，`R8`=指针 |

三个参数都在寄存器里，没有栈参数。

#### 3.4.2 32 字节影子空间

本章序言：

```asm
push rbp
mov  rbp, rsp
sub  rsp, 64
```

`64 = 32 影子 + 32 本地槽`。`rsp = rbp - 64`，本地槽 `[rbp-8]`~`[rbp-32]` 都在影子空间上方。

#### 3.4.3 16 字节对齐

入口 8 → `push rbp` 后 0 → `sub rsp, 64` 后 0。`call HeapAlloc`、`call wprintf` 都对齐。

#### 3.4.4 非易失寄存器

本章只用 `RAX/RCX/RDX/R8/R9` 等易失寄存器，节点指针存本地槽；`RBP` 由序言保存。

### 3.5 数组元素寻址

`HeapAlloc` 返回一块连续内存，把它当成 `ITEM` 数组。第 `i` 个元素的地址：

```text
base + i * ITEM_size
```

本章 `ITEM_size = 16`（2 的幂），所以用位移：

```asm
mov rax, rcx          ; i
shl rax, 4            ; i * 16
add rax, [rbp - 8]    ; + base
```

如果结构体大小不是 2 的幂，就要用 `imul rax, ITEM_size`。

### 3.6 链表串联与遍历

把数组的相邻元素用 `next` 指针串起来：

```text
node[0].next = &node[1]
node[1].next = &node[2]
node[2].next = NULL
```

遍历从 `node[0]` 开始，每次跟着 `next` 走，直到 `NULL`。

**关键**：遍历时要**先把 `next` 存到本地槽，再调用 `wprintf`**。因为 `wprintf` 会覆盖 `R9`（`next` 正好在 `R9`），如果等调用完再取 `next` 就丢了。

## 4. 实践用例

打开 [heap_structs.asm](heap_structs.asm)。程序分配 3 个 `ITEM`，填 `id=i`、`value=i*i`，串成链表，遍历打印并求和，最后释放。

### 4.1 构建与运行

```powershell
make
.\heap_structs.exe
$LASTEXITCODE
```

真实输出（与原 README 一致）：

```text
nasm -f win64 -l heap_structs.obj.lst -o heap_structs.obj heap_structs.asm
gcc -municode -o heap_structs.exe heap_structs.obj
allocated 48 bytes for 3 items (ITEM_size=16)
item id=0 value=0
item id=1 value=1
item id=2 value=4
sum of values = 5
static item: id=99 value=1234
HeapFree done
0
```

`sum = 0 + 1 + 4 = 5`，与 `ITEM.value = i * i` 一致。退出码 `0`。

### 4.2 `.lst` 摘录

```text
    19 00000000 63000000                            at ITEM.id,    dd 99
    20 00000004 D2040000                            at ITEM.value, dd 1234
    21 00000008 0000000000000000                    at ITEM.next,  dq 0
    ...
    47 00000000 55                          push    rbp
    48 00000001 4889E5                      mov     rbp, rsp
    49 00000004 4883EC40                    sub     rsp, 64
    52 00000008 E8(00000000)                call    GetProcessHeap
    58 00000019 41B830000000                mov     r8d, 3 * ITEM_size
    59 0000001F E8(00000000)                call    HeapAlloc
    70 00000038 4889C8                      mov     rax, rcx
    71 0000003B 48C1E004                    shl     rax, 4
    74 00000043 8908                        mov     dword [rax + ITEM.id], ecx
    77 0000004A 895004                      mov     dword [rax + ITEM.value], edx
   108 0000009F 8B10                        mov     edx, dword [rax + ITEM.id]
   109 000000A1 448B4004                    mov     r8d, dword [rax + ITEM.value]
   110 000000A5 4C8B4808                    mov     r9, qword [rax + ITEM.next]
```

读法：

- `8908`：`mov [rax], ecx`——`ITEM.id` 是 0，所以没有位移；
- `895004`：`mov [rax+4], edx`——`50 04` 中的 `04` 就是 `ITEM.value` 的偏移；
- `4C8B4808`：`mov r9, [rax+8]`——`08` 是 `ITEM.next` 的偏移；
- `48C1E004`：`shl rax, 4`；
- `41B830000000`：`mov r8d, 48`（3 * 16）。

可以看出 `struc` 的字段名在机器码里已经变成固定数字，运行期没有"结构体"这个东西，只有地址加偏移。

## 5. 代码重点讲解

1. **`struc ITEM` + `ITEM_size`（知识点 3.1）**：`struc` 只产生偏移常量（`.id=0`、`.value=4`、`.next=8`）和 `ITEM_size=16`。用 `[rax + ITEM.value]` 访问字段，本质是 `[rax + 4]`。

2. **`GetProcessHeap` → `HeapAlloc`（知识点 3.3）**：`GetProcessHeap` 返回堆句柄到 `RAX`；`HeapAlloc(rax, HEAP_ZERO_MEMORY, 3*16)` 分配 48 字节并清零。`HEAP_ZERO_MEMORY=8` 让 `next` 字段初始为 0，省得手动清。

3. **`shl rax, 4` 算数组偏移（知识点 3.5）**：`i * ITEM_size = i * 16 = i << 4`。`mov rax, rcx` 把 `i` 升到 64 位再位移，避免 32 位溢出。

4. **`lea rdx, [rax + ITEM_size]` 算下一个节点地址**：`lea` 只算地址不访问内存。`node[i].next = &node[i+1]`。最后一个节点的 `next` 设为 `NULL`。

5. **遍历先存 `next` 再 `call wprintf`（知识点 3.6）**：`mov r9, [rax + ITEM.next]` → `mov [rbp-24], r9`（先存）→ `call wprintf`（会覆盖 `R9`）→ 下一轮从 `[rbp-24]` 取。如果顺序反了，`next` 就丢了。

6. **`HeapFree` 的 `dwFlags = 0`**：`HeapFree(hHeap, 0, base)`。第二个参数必须为 0。释放后 `base` 指针悬空，不要再用也不要再释放。

## 6. 常见坑

1. **把 `ITEM.id` 当变量**：它只是偏移 0。必须写成 `[ptr + ITEM.id]`。
2. **以为 `struc` 会分配内存**：不会。`resd` 只推进偏移；要真实内存得用 `istruc` 或 `HeapAlloc`。
3. **忘记 `ITEM_size`**：它是 `endstruc` 自动生成的，大小写敏感（`ITEM_size`）。
4. **数组元素地址算错**：`i * ITEM_size` 才是第 i 个元素的起点；`i * 4` 会踩到别的字段。
5. **遍历时先 `call` 再取 `next`**：`R9` 已被覆盖。先保存 `next`。
6. **重复释放**：`HeapFree` 后指针悬空；不要再用，也不要再释放。
7. **分配失败不判断**：`HeapAlloc` 可能返回 `NULL`。
8. **`HeapAlloc` 的字节数用 `R8D`**：小数据没事，但 `SIZE_T` 是 64 位，规范写法是 `R8`。
9. **对齐假设**：`HeapAlloc` 返回 8 或 16 字节对齐，但结构体内部字段仍按你定义的偏移排列。

## 7. 练习

1. 给 `ITEM` 增加一个 `score resd 1` 字段，重新计算 `ITEM_size`，确认 `shl` 是否还适用。
2. 把节点数改成 5，验证分配字节数为 `5 * ITEM_size`、`sum = 0+1+4+9+16 = 30`。
3. 把 `shl rax, 4` 改成 `imul rax, ITEM_size`，比较 `.lst` 的机器码长度。
4. 用 `istruc` 定义 3 个静态节点，串成链表，比较"静态数据"和"堆数据"的地址差异。
5. 故意把 `HeapFree` 的 `r8` 传成 0，观察程序是否崩溃（不要在生产代码里这么做）。

## 8. 下一章

第 10 章进入 UTF-16 字符串：

- 码元（code unit）与码点（code point）的区别；
- 自己实现 `wlen`、ASCII 大小写转换、单词计数；
- 用 `movzx` 逐码元读取；
- 打印 `U+XXXX`，观察中文在 UTF-16 中的编码。
