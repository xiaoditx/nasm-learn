# 第 15 章：GDI 绘制与 WM_PAINT

> 窗口有了，接下来让它在客户区里画出文字和矩形。本章用 GDI，第 17 章再切到 Direct2D。
> 本章源码：[gdi_paint.asm](gdi_paint.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[gdi_paint.obj.lst](gdi_paint.obj.lst)

## 1. 本章目标

- 在 `WM_PAINT` 里完成 `BeginPaint` → 绘制 → `EndPaint`；
- 用 `TextOutW` 输出三行文字，并正确处理它的 **第 5 个参数**；
- 用 `GetClientRect` + `wsprintfW` 把客户区尺寸画到窗口上；
- 用 `CreateSolidBrush` / `FillRect` / `FrameRect` / `DeleteObject` 管理 GDI 对象；
- 第一次把 `HDC` 放进 `RBX`，演示**非易失寄存器的保存与恢复**。

跑通后你应该能回答：

- `TextOutW(hdc, x, y, str, len)` 的 `len` 为什么在 `[rsp+32]`？
- `banner_len equ ($ - banner) / 2 - 1` 里的 `/2 - 1` 各代表什么？
- 为什么 `RBX` 在 `WndProc` 里必须成对 `push/pop`？
- `FillRect` 和 `FrameRect` 的第三个参数为什么是画刷句柄而不是颜色？

## 2. 前置 / 项目结构

```text
nasm-learn/
├── common.asm                    WNDCLASSEXW / MSG / PAINTSTRUCT / RECT
└── 15-gdi-paint/
    ├── Makefile
    ├── gdi_paint.asm
    ├── README.md
    └── gdi_paint.obj.lst        make 后生成
```

本目录只有 `.asm` 源码。GDI 接口来自 `gdi32.dll`，窗口接口来自 `user32.dll`。本章是 GUI 程序，**只编译不运行**，用 `objdump -p` 验证子系统与导入表。

## 3. 知识点讲解

### 3.1 GDI 绘制模型

GDI（Graphics Device Interface）是 Windows 传统的 2D 绘图 API。绘制发生在 `WM_PAINT` 里，流程固定：

```text
WM_PAINT 到达
    │
    ▼
BeginPaint(hwnd, &ps)  ──► 返回 HDC（设备上下文句柄）
    │
    ▼
TextOutW / FillRect / FrameRect ...  （用 HDC 画图）
    │
    ▼
EndPaint(hwnd, &ps)    ──► 释放 HDC，宣告绘制完成
```

`HDC`（Device Context Handle，设备上下文句柄）可以理解为一次绘图所用的“上下文标识”：它关联目标表面以及当前文字颜色、背景模式、画刷等状态。它**不是一块可以直接用 `mov rax, [hdc]` 读取的内存**，也不能用 `DeleteObject` 释放。

`BeginPaint` 同时完成两件事：

1. 返回本次绘制使用的 `HDC`；
2. 填写 `PAINTSTRUCT ps`，其中包括实际 `HDC`、是否应擦背景、需要更新的 `rcPaint` 矩形等信息。

本例把返回值保存在 `RBX`，后面不断把它放回 `RCX`。绘制结束后必须把**同一个窗口句柄和同一个 `ps` 地址**交给 `EndPaint`。即使没有任何图形要画，也不能因为“没使用 HDC”就跳过 `EndPaint`。

#### 3.1.1 客户区、窗口区与屏幕坐标不是一回事

`TextOutW`、`FillRect` 使用的是 **HDC 当前映射下的坐标**；本章没有改变映射模式，因此可先把它们理解为客户区像素坐标：

```text
客户区左上角 (0, 0)
    ┌──────────────────────────────► x 向右增大
    │  (24,32)  x64 assembly + GDI
    │  (24,64)  WM_PAINT -> ...
    │  (24,88)  Direct2D ...
    │  (24,120) client: W x H
    │
    │         ┌─────────────┐
    │         │ (24,150)    │  本章矩形
    │         │             │
    │         └─────────────┘
    ▼
  y 向下增大
```

- **客户区**不包括标题栏、菜单和窗口边框；按钮、菜单等也不属于本章要画的区域。
- 窗口左上角在屏幕上的位置与客户区内部坐标无关。移动整个窗口不会改变 `TextOutW(hdc, 24, 32, ...)` 的 `24,32`。
- `TextOutW` 的 `x/y` 不是第几个字符，而是坐标。默认文字对齐方式下，它大致指定文字外接框的左上参考位置。
- 这里的“像素”属于 GDI 默认映射。以后 Direct2D 使用 DIP（设备无关像素，第 17 章会解释），不能直接把两套单位混为一谈。

### 3.2 Windows x64 ABI 四件套

**① 前四个参数：RCX / RDX / R8 / R9**

本章最典型的是 `TextOutW`：

| 参数 | C 签名 | 寄存器 |
|---|---|---|
| 1 | `HDC hdc` | `RCX` |
| 2 | `int x` | `EDX` |
| 3 | `int y` | `R8D` |
| 4 | `LPCWSTR lpString` | `R9` |
| 5 | `int cchString` | `[rsp + 32]` |

5 个参数 = 4 个寄存器 + 1 个栈槽。这是"第 5 个参数走栈"的最小例子。

**② 32 字节影子空间**

`WndProc` 里 `sub rsp, 56` 的构成：

```text
56 = 32（影子空间） + 8（TextOutW 第 5 参数槽） + 16（余量）
```

严格说 32+8 = 40 就够，但 40 不是 16 的倍数，配合 `push rbx` 后会导致 `call` 点不对齐，所以取 56。

**③ 16 字节对齐**

```text
WndProc 入口        RSP % 16 == 8
push rbp            RSP % 16 == 0
push rbx            RSP % 16 == 8
sub rsp, 56         RSP % 16 == 0   ← 8 - 56 = -48，-48 % 16 == 0
```

两次 `push` 让栈移动了 16 字节，`56` 也是 8 的倍数但不是 16 的倍数——组合起来刚好让 `call` 点回到 0。这就是为什么不能照抄 `sub rsp, 48`。

把 `RBP` 当作固定参照，可以看到每个区域并没有混在一起：

```text
高地址
RBP+8   返回地址（由调用者的 call 压入）
RBP+0   保存的旧 RBP
RBP-8   保存的旧 RBX                    ← push rbx
RBP-16  局部 HBRUSH，共 8 字节           ← [rbp-16]
RBP-24  wsprintfW 返回的码元数，低 4 字节 ← [rbp-24]
RBP-32  TextOutW 第 5 参数的 8 字节槽     ← call 前 [rsp+32]
         ...
RBP-64  32 字节影子空间的最低地址         ← call 前 [rsp+0]
低地址
```

因此调用 `TextOutW` 前 `RSP=RBP-64`，它看到的前五个参数槽为：

| 调用者视角 | 相对 RBP | 内容 |
|---|---|---|
| `[rsp+0..7]` | `RBP-64..-57` | 第 1 参数的影子槽 |
| `[rsp+8..15]` | `RBP-56..-49` | 第 2 参数的影子槽 |
| `[rsp+16..23]` | `RBP-48..-41` | 第 3 参数的影子槽 |
| `[rsp+24..31]` | `RBP-40..-33` | 第 4 参数的影子槽 |
| `[rsp+32..39]` | `RBP-32..-25` | 第 5 参数 `cchString` |

`[rbp-24]` 和 `[rbp-16]` 位于 outgoing 参数区之外，所以后续 API 调用不会把它们当影子空间覆盖。

**④ 非易失寄存器**

本章把 `HDC` 放进 `RBX`：

```asm
    push    rbx                     ; 保存旧值
    ...
    mov     rbx, rax                ; HDC
    ...
    pop     rbx                     ; 恢复
```

`RBX` 属于非易失寄存器：`WndProc` 是系统回调，系统（以及 CRT/调用者）默认你不会破坏它。不恢复可能让上层代码读到被改写的值，表现为"窗口关掉后程序在别处崩溃"。

`RBP` 也属于非易失，但它是帧指针，`push rbp / leave` 已经处理。

### 3.3 从 MinGW 头文件提取 RECT

`windef.h`：

```c
typedef struct tagRECT {
    LONG left;
    LONG top;
    LONG right;
    LONG bottom;
} RECT;
```

Windows 的 `LONG` 固定为 32 位有符号整数，即使在 x64 下也不是 8 字节。因此布局为：

| 字段 | 偏移 | 大小 | 本章画矩形时写入的值 |
|---|---:|---:|---:|
| `left` | 0 | 4 | 24 |
| `top` | 4 | 4 | 150 |
| `right` | 8 | 4 | 324 |
| `bottom` | 12 | 4 | 230 |
| 合计 |  | **16** | 无额外填充 |

若 `client_rect` 的地址为 `0x3000`，则 `right` 位于 `0x3008`，`bottom` 位于 `0x300C`。读取时也必须使用 32 位操作：

```asm
mov r8d, [rel client_rect + RECT.right]
```

`GetClientRect(hwnd, &rect)` 返回的是**客户区大小所对应的矩形**，正常情况下：

```text
left = 0
top = 0
right = 客户区宽度
bottom = 客户区高度
```

因此本章直接把 `right/bottom` 格式化显示为宽高。不要把这条关系套到任意 `RECT` 上：普通矩形的宽高应分别计算为 `right-left`、`bottom-top`。`RECT` 的右边和下边通常采用“排他边界”约定；本章重点只是把它交给 `FillRect/FrameRect`，不要自行把 `right` 当成最后一个可见像素的坐标再加一。

本章还复用了 `PAINTSTRUCT`（72 字节）和 `RECT`（16 字节），定义都在 `common.asm`，偏移可由 `.lst` 验证。

### 3.4 TextOutW 与字符串长度

`TextOutW(hdc, x, y, lpString, cchString)` 第 5 个参数 `cchString` 是**字符数（UTF-16 码元数）**，不是字节数。

本章用编译期常量计算长度：

```asm
banner:       WSTRZ "x64 assembly + GDI"
banner_len    equ ($ - banner) / 2 - 1
```

- `$` 是当前地址，`$ - banner` 是字节数；
- `/ 2` 换算成 UTF-16 码元数；
- `- 1` 去掉 `WSTRZ` 自动追加的结尾 0。

`.lst` 里这个值被直接编进机器码：`mov qword [rsp + 32], 0x12`（`0x12 = 18`），正好是 "x64 assembly + GDI" 的 18 个字符。

### 3.5 颜色、画刷与 GDI 对象生命周期

`FillRect` 和 `FrameRect` 的第三个参数是 `HBRUSH`，不是颜色整数。画刷决定用什么颜色或图案填充；`COLORREF` 只是创建画刷时传入的颜色描述。本章的关系是：

```text
颜色值 0x00D0E8F0
       │ CreateSolidBrush
       ▼
HBRUSH（本章拥有的新 GDI 对象）
       │
       ├─ FillRect(hdc, &rect, brush)    用画刷填充内部
       ├─ FrameRect(hdc, &rect, brush)   用画刷绘制边框
       │
       ▼ DeleteObject
释放画刷；此后该 HBRUSH 值不能再使用
```

`CreateSolidBrush` 可能返回 `NULL`，通用代码应先检查，再使用或释放。本章为突出主流程省略了失败分支，不能据此认为创建永远成功。

GDI 对象由系统管理，不能 `HeapFree`、`CloseHandle`，也不要释放两次。另一方面，`DeleteObject` 只负责画刷，不负责 `BeginPaint` 返回的 `HDC`；后者由 `EndPaint` 配对处理。若画刷仍被选入某个 DC，通用代码还应先恢复原对象，再删除画刷。本例没有把画刷 `SelectObject` 进 DC，所以可在两次绘制后删除。

#### 3.5.1 手算 COLORREF：它是 0x00BBGGRR

`COLORREF` 的 32 位布局为：

```text
31              24 23              16 15               8 7                0
┌─────────────────┬─────────────────┬─────────────────┬─────────────────┐
│ 0x00（保留）     │ Blue 蓝色分量    │ Green 绿色分量   │ Red 红色分量     │
└─────────────────┴─────────────────┴─────────────────┴─────────────────┘
```

所以 `0x00D0E8F0` 应拆为：

| 分量 | 十六进制 | 十进制 |
|---|---:|---:|
| 红色 `RR` | `F0` | 240 |
| 绿色 `GG` | `E8` | 232 |
| 蓝色 `BB` | `D0` | 208 |

它是红、绿分量较高的浅色，而不是凭十六进制外观猜出的“蓝色值 `0xD0`”。文字颜色 `0x00C06020` 则对应 `R=0x20、G=0x60、B=0xC0`。

这也解释了为什么源码把颜色写进 `ECX/EDX`：`COLORREF` 只有 32 位，句柄 `HBRUSH` 才是 64 位。

### 3.6 InvalidateRect 触发重绘

窗口尺寸变化后，需要主动请求重绘：

```text
WM_SIZE 到达
    │
    ▼
InvalidateRect(hwnd, NULL, TRUE)   标记整个客户区为"脏"
    │
    ▼
系统投递 WM_PAINT → 重新绘制
```

`InvalidateRect` 只是“把区域加入更新区”，不会在调用点立即同步执行本例的 `.on_paint`。消息循环之后取得并派发 `WM_PAINT` 时才真正绘制。第三个参数 `TRUE` 表示处理更新时让背景被擦除。

这里需要区分两个动作：

1. `InvalidateRect(..., TRUE)` 表达“希望背景擦除”；
2. 窗口类背景画刷、`WM_ERASEBKGND` 和 `WM_PAINT` 决定“实际怎样擦、画什么”。

本例窗口类设置了系统背景画刷，但 `WndProc` 收到 `WM_ERASEBKGND` 又直接返回 1，且 `.on_paint` 只在固定位置画文字和矩形，没有用客户区画刷完整覆盖旧内容。因此它是一个讲解消息分支的简化示例，**不是完整的无闪烁清屏模板**。通用做法要么让默认背景擦除发生，要么在 `WM_PAINT` 中先完整填充更新区域，再绘制内容；只有确实自己处理背景时，才应让 `WM_ERASEBKGND` 返回非零。

如果窗口没有被遮挡、尺寸没有变化，也没有代码调用 `InvalidateRect`，系统不会仅因为“程序希望画面更新”就持续发送 `WM_PAINT`。这与第 24 章游戏循环需要主动计时、更新并重绘不同。

## 4. 实践用例

本章 `gdi_paint.asm` 在窗口客户区画三行静态提示文字、一行客户区尺寸文字，以及一个填充并描边的矩形。`WM_SIZE` 请求重绘后，尺寸文字会随窗口拉伸更新；矩形仍使用源码中写死的 `(24,150)-(324,230)`，不会自动居中。

### 4.1 构建命令

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l gdi_paint.obj.lst -o gdi_paint.obj gdi_paint.asm
gcc -municode -mwindows -o gdi_paint.exe gdi_paint.obj -luser32 -lgdi32
```

产物 `gdi_paint.exe` 为 145255 字节。

### 4.3 objdump 实证（子系统与导入表）

```text
Subsystem               00000002        (Windows GUI)
        DLL Name: GDI32.dll
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
```

GUI 子系统，导入 `GDI32.dll`（绘图）和 `USER32.dll`（窗口）。**只编译不运行**。手动体验：`.\gdi_paint.exe`，拉伸窗口看 `client: W x H` 实时变化，ESC 退出。

### 4.4 `.lst` 摘录

**序言与收尾**：

```text
    79 00000004 53                          push    rbx                     ; 保存非易失寄存器
    80 00000005 4883EC38                    sub     rsp, 56
```

`53` 是 `push rbx`（1 字节）；`4883EC38` 是 `sub rsp, 0x38`（56）。

**TextOutW 的第 5 参数**：

```text
   162 000000ED 4C8D0D(56000000)            lea     r9,  [rel banner]
   163 000000F4 48C744242012000000          mov     qword [rsp + 32], banner_len
   164 000000FD E8(00000000)                call    TextOutW
```

`48C744242012000000` 拆开看：

- `48` = REX.W（64 位操作）；
- `C7` = `mov r/m64, imm32`（符号扩展）；
- `44` = ModRM（`[rsp+disp8]`）；
- `24` = SIB（base=RSP）；
- `20` = 位移 32；
- `12 00 00 00` = 立即数 `0x12` = 18。

这条机器码直接证明 `banner_len` 是 18 个 UTF-16 码元。

**DeleteObject**：

```text
   228 000001FF 488B4DF0                    mov     rcx, [rbp - 16]
   229 00000203 E8(00000000)                call    DeleteObject
```

画笔句柄从局部槽 `[rbp-16]` 取出后立刻释放，和 `CreateSolidBrush` 成对。

## 5. 代码重点讲解

挑出 6 处关键代码，回扣前面的知识点。

**① 序言：两次 push + sub rsp, 56**

```asm
WndProc:
    push    rbp
    mov     rbp, rsp
    push    rbx                     ; 保存非易失寄存器
    sub     rsp, 56
```

回扣知识点 3.2③④：`push rbp` 对齐到 0，`push rbx` 又变成 8，`sub 56` 回到 0。收尾必须完全对称（`add rsp, 56` / `pop rbx` / `leave`），所有分支都 `jmp .done` 单出口，避免漏掉 `pop rbx`。

**② banner_len 的编译期计算**

```asm
banner:       WSTRZ "x64 assembly + GDI"
banner_len    equ ($ - banner) / 2 - 1
```

回扣知识点 3.4：`$ - banner` 是字节数，`/2` 得码元数，`-1` 去结尾 0。`.lst` 里立即数 `0x12` 证明结果是 18。

**③ TextOutW 的第 5 参数写入完整栈槽**

```asm
    mov     rcx, rbx                ; hdc
    mov     edx, 24                 ; x
    mov     r8d, 32                 ; y
    lea     r9,  [rel banner]       ; str
    mov     qword [rsp + 32], banner_len   ; len（第 5 参数）
    call    TextOutW
```

回扣知识点 3.2①：第 5 参数从 `[rsp+32]` 开始，参数槽为 8 字节，所以源码用 `qword` 把整个槽写成确定值。这里要区分**槽宽**与**类型宽**：C 签名中的 `int cchString` 仍是 32 位，被调函数读取的是低 4 字节，并不会因为槽是 8 字节就把它变成 64 位长度。

因此，把旧文档中的“`dword` 一定会读出巨大长度”当作 ABI 规则是不准确的；本章采用 `qword` 是清晰、确定且统一的栈槽写法。动态长度那一处先 `mov eax, [rbp-24]`，使 `RAX` 高 32 位自动清零，再 `mov qword [rsp+32], rax`，同样能写出完整槽。

**④ GetClientRect + wsprintfW**

```asm
    mov     rcx, [rel hwnd]
    lea     rdx, [rel client_rect]
    call    GetClientRect

    lea     rcx, [rel info_buf]
    lea     rdx, [rel fmt_size]
    mov     r8d, [rel client_rect + RECT.right]
    mov     r9d, [rel client_rect + RECT.bottom]
    xor     eax, eax
    call    wsprintfW
```

参数依次是：`RCX=目标缓冲区`、`RDX=格式串`、`R8D=right`、`R9D=bottom`。回扣知识点 3.3：对于 `GetClientRect` 的结果，`right/bottom` 就是客户区宽高。

这里的 `xor eax,eax` 只是无害地清零 `RAX`，**不是 Windows x64 调用变参函数的必需步骤**。Windows x64 不使用 `AL` 记录 XMM 参数数量；那是 System V AMD64 的规则。本例两个 `%d` 对应的都是 32 位整数参数槽。

`wsprintfW` 返回写入的 UTF-16 码元数（不含结尾 0），后面可作为 `TextOutW` 的显式长度；失败时返回负值，通用代码应先检查再使用。`info_buf` 为 128 字节，即只有 **64 个 UTF-16 码元**。当前固定短格式和两个十进制尺寸足够容纳，但 `wsprintfW` 本身没有容量参数，不能把它当作通用安全格式化函数。带容量的替代写法是：

```c
int n = _snwprintf(info_buf, 64, L"client: %d x %d", width, height);
if (n < 0 || n >= 64) {
    /* 失败或结果被截断，不能使用 n 作为有效长度 */
}
```

容量单位同样是 UTF-16 码元，不是字节。

**⑤ GDI 对象成对创建/释放**

```asm
    mov     ecx, 0x00D0E8F0
    call    CreateSolidBrush
    mov     [rbp - 16], rax
    ...
    mov     rcx, [rbp - 16]
    call    DeleteObject
```

回扣知识点 3.5：`CreateSolidBrush` 返回 `HBRUSH`，成功创建并使用后必须 `DeleteObject`。若每次都创建却遗漏释放，反复重绘就会不断积累 GDI 对象，任务管理器里的 GDI 句柄数可能持续上涨。

**⑥ WM_SIZE 触发重绘**

```asm
.on_size:
    ...
    mov     rcx, [rel hwnd]
    xor     edx, edx                ; 整个客户区
    mov     r8d, TRUE               ; 擦除背景后再画
    call    InvalidateRect
```

回扣知识点 3.6：窗口尺寸变化后主动 `InvalidateRect`，让系统在后续消息处理中请求重画。这里不是直接调用 `.on_paint`，也没有在 `WM_SIZE` 内使用旧的 `HDC`。

**⑦ wmain 中还有一个容易漏掉的 ABI 瑕疵**

```asm
    lea     rdi, [rel wndclass]
    xor     eax, eax
    mov     ecx, WNDCLASSEXW_size / 4
    rep     stosd
```

`rep stosd` 会递增修改 `RDI`，而 `RDI` 在 Windows x64 中属于非易失寄存器。本章 `wmain` 没有保存、恢复它，因此这段教学代码并不完全符合 ABI；它可能在当前 CRT 调用链中没有暴露问题，但不能作为通用函数模板。应像本章 `WndProc` 保存 `RBX` 一样保存 `RDI`，或改用不修改非易失寄存器的清零方式。源码保留原样，是为了让读者能对照识别这个真实问题。

## 6. 常见坑

1. **`sub rsp, 48`**：在 `push rbx` 之后，48 是 16 的倍数，`call` 点会变成 `% 16 == 8`，调用 GDI 可能直接崩在 `movaps` 上。用 56。
2. **把 8 字节参数槽误当成 64 位 `int`**：`cchString` 仍只有 32 位。本章写 `qword` 是为了完整、确定地填写栈槽，不能由此推出被调函数会读取一个 64 位长度。
3. **把字节数直接传给 `TextOutW`**：`banner_len` 必须按 UTF-16 码元计数；忘了 `/2` 会把长度扩大两倍，忘了 `-1` 则多包含结尾 0。
4. **把 `wsprintfW` 当安全格式化函数**：它没有容量参数，也不能用 `AL=0` 解决缓冲区问题。动态或不可信文本应使用带容量、能检查截断的接口。
5. **`CreateSolidBrush` 后不 `DeleteObject`**：成功创建的画刷若每次重绘都不释放，会不断积累 GDI 对象。还要先检查创建是否成功，且不能对 `HDC` 调 `DeleteObject`。
6. **把局部槽放进影子空间**：本例影子空间是 `rbp-64 .. rbp-33`；若把 `[rbp-48]` 当持久局部槽，后续 `call` 可以覆盖它。本例的 `[rbp-16]` / `[rbp-24]` 都在 outgoing 参数区之外。
7. **认为 `WM_ERASEBKGND=1` 就已经擦好背景**：返回值只表示调用者声称已处理；本例并未完整覆盖更新区域，不能直接复制为防闪烁模板。
8. **忽略 `wmain` 的 `RDI`**：`rep stosd` 修改了非易失 `RDI`，本章源码未保存它，是需要识别而不是照抄的 ABI 瑕疵。
9. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item gdi_paint.exe,gdi_paint.obj,gdi_paint.obj.lst`。

## 7. 练习

1. 把 `banner_len` 改成 `$ - banner`（不减 1、不除 2），在 `.lst` 里看立即数变成多少；运行时会发生什么？
2. 用 `SetTextColor` 换三种颜色，分别画三行。
3. 把 `FillRect` 的矩形改到客户区中心，用 `client_rect.right/2` 计算 `left`。
4. 把 `HDC` 改放到 `R12`，把 `push rbx` 改成 `push r12`，确认程序行为不变——说明非易失规则对 `R12~R15` 同样适用。
5. 注释掉 `DeleteObject`，反复拉伸窗口 100 次，用任务管理器观察 GDI 对象数。

## 8. 下一章预览

第 16 章离开 GUI，回到控制台，把 COM 的地基打牢：

- `CoInitializeEx` / `CoUninitialize`；
- `CoCreateInstance` 创建 `CLSID_ShellLink`；
- 接口指针的第一格就是虚表指针；
- `QueryInterface` 与 `Release` 的槽位调用，并用真实运行输出验证引用计数。
