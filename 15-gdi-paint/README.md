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
masm-learn/
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

`HDC` 是绘图的"画布句柄"，所有 GDI 函数都需要它。`BeginPaint` 返回的 `HDC` 只在 `BeginPaint`/`EndPaint` 之间有效。

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

4 个 `LONG`，共 16 字节，无填充。本章复用了 `PAINTSTRUCT`（72 字节）和 `RECT`（16 字节），定义都在 `common.asm`，偏移已由 `.lst` 验证。

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

### 3.5 GDI 对象的生命周期

GDI 对象（画笔、画刷、字体等）是内核对象，创建后必须释放，否则泄漏。本章的画刷生命周期：

```text
CreateSolidBrush(color)  ──► HBRUSH
        │
        ├─ FillRect(hdc, &rect, brush)    填充矩形
        ├─ FrameRect(hdc, &rect, brush)   画矩形边框
        │
        ▼
DeleteObject(brush)        释放画刷
```

`COLORREF` 的布局是 `0x00BBGGRR`（注意字节顺序：蓝、绿、红），`0x00D0E8F0` 是浅蓝灰。

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

`InvalidateRect` 只是"标记脏"，真正绘制发生在后续的 `WM_PAINT`。第三个参数 `TRUE` 表示重绘前先擦除背景。

## 4. 实践用例

本章 `gdi_paint.asm` 在窗口客户区画三行文字（标题、客户区尺寸、提示）和一个填充矩形带边框，拉伸窗口时文字实时更新。

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

**③ TextOutW 的第 5 参数写 8 字节槽**

```asm
    mov     rcx, rbx                ; hdc
    mov     edx, 24                 ; x
    mov     r8d, 32                 ; y
    lea     r9,  [rel banner]       ; str
    mov     qword [rsp + 32], banner_len   ; len（第 5 参数）
    call    TextOutW
```

回扣知识点 3.2①：第 5 参数走 `[rsp+32]`，必须用 `mov qword`。写成 `mov dword` 只写低 4 字节，高 4 字节是垃圾。

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

回扣知识点 3.3：`client_rect.right/bottom` 就是客户区宽高（`left/top` 恒为 0）。`wsprintfW` 返回写入的字符数，后面当 `TextOutW` 的长度用。`[rbp-24]` 位于影子空间之上的安全区，不会被 `call` 踩掉。

**⑤ GDI 对象成对创建/释放**

```asm
    mov     ecx, 0x00D0E8F0
    call    CreateSolidBrush
    mov     [rbp - 16], rax
    ...
    mov     rcx, [rbp - 16]
    call    DeleteObject
```

回扣知识点 3.5：`CreateSolidBrush` 返回 `HBRUSH`，必须 `DeleteObject`。每重绘一次泄漏一个 GDI 对象，任务管理器里 GDI 句柄数会一路上涨。

**⑥ WM_SIZE 触发重绘**

```asm
.on_size:
    ...
    mov     rcx, [rel hwnd]
    xor     edx, edx                ; 整个客户区
    mov     r8d, TRUE               ; 擦除背景后再画
    call    InvalidateRect
```

回扣知识点 3.6：窗口尺寸变化后主动 `InvalidateRect`，保证拉伸时文字跟着重画。

## 6. 常见坑

1. **`sub rsp, 48`**：在 `push rbx` 之后，48 是 16 的倍数，`call` 点会变成 `% 16 == 8`，调用 GDI 可能直接崩在 `movaps` 上。用 56。
2. **`mov dword [rsp + 32], banner_len`**：只写低 4 字节，高 4 字节是垃圾，`TextOutW` 可能读到巨大的长度。
3. **`banner_len` 忘了 `-1`**：会把结尾 0 也画进去（通常不可见，但长度语义错了）。
4. **`CreateSolidBrush` 后不 `DeleteObject`**：每重绘一次泄漏一个 GDI 对象，任务管理器里 GDI 句柄数会一路上涨。
5. **把局部槽放进影子空间**：本例影子空间是 `rbp-64 .. rbp-33`；若把 `[rbp-48]` 当局部槽，`call` 会覆盖它。本例的 `[rbp-16]` / `[rbp-24]` 都在安全区。
6. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item gdi_paint.exe,gdi_paint.obj,gdi_paint.obj.lst`。

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
