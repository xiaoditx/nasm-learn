# 第 14 章：窗口过程与消息分发

> 第 13 章只会"开窗"，本章让窗口真正响应消息：改尺寸、按键、关闭、重绘。
> 本章源码：[winproc.asm](winproc.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[winproc.obj.lst](winproc.obj.lst)

## 1. 本章目标

- 建立一张可扩展的消息分发表（`cmp` + `je` 链）；
- 从 `WM_SIZE` 的 `lParam` 里拆出宽高；
- 从 `WM_KEYDOWN` 的 `wParam` 取虚拟键码，用 `wsprintfW` + `SetWindowTextW` 显示；
- 正确配对 `BeginPaint` / `EndPaint`；
- 认识 `WM_ERASEBKGND` 返回 1 的作用。

跑通后你应该能回答：

- `WM_SIZE` 的 `lParam` 低 16 位和高 16 位各是什么？为什么用 `movzx ecx, ax` 而不是 `mov ecx, eax`？
- `wsprintfW` 的参数从哪里来？为什么调用前要 `xor eax, eax`？
- `WM_CLOSE`、`WM_DESTROY`、`DestroyWindow`、`PostQuitMessage` 的先后顺序是什么？

## 2. 前置 / 项目结构

```text
masm-learn/
├── common.asm                    WNDCLASSEXW / MSG / PAINTSTRUCT 定义
└── 14-window-messages/
    ├── Makefile
    ├── winproc.asm
    ├── README.md
    └── winproc.obj.lst           make 后生成
```

本目录只有 `.asm` 源码。`MSG`、`PAINTSTRUCT` 的布局都在 `common.asm` 里，来源是 `winuser.h`。本章是 GUI 程序，**只编译不运行**，用 `objdump -p` 验证子系统与导入表。

## 3. 知识点讲解

### 3.1 消息驱动模型

Windows GUI 是**事件驱动**的：程序不主动轮询输入，而是等待系统把消息投递到 `WndProc`。消息的三个关键参数：

| 参数 | 寄存器 | 含义 |
|---|---|---|
| `hwnd` | `RCX` | 目标窗口句柄 |
| `msg` | `EDX` | 消息编号（`WM_*` 常量） |
| `wParam` | `R8` | 附加参数 1（随消息不同） |
| `lParam` | `R9` | 附加参数 2（随消息不同） |

`wParam` / `lParam` 的含义由具体消息决定：`WM_SIZE` 时 `lParam` 压缩了宽高，`WM_KEYDOWN` 时 `wParam` 是虚拟键码。

### 3.2 Windows x64 ABI 四件套

**① 前四个参数：RCX / RDX / R8 / R9**

`WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)`：

| 参数 | 寄存器 | 本章用法 |
|---|---|---|
| `hwnd` | `RCX` | 多数消息里用全局 `hwnd` 也能拿到 |
| `msg` | `EDX` | 消息分发的判断依据 |
| `wParam` | `R8` | `WM_KEYDOWN` 的虚拟键码 |
| `lParam` | `R9` | `WM_SIZE` 的宽高、`WM_CREATE` 的 `CREATESTRUCT*` |

**② 32 字节影子空间**

`WndProc` 的 `sub rsp, 32` 留出 32 字节，供 `DefWindowProcW`、`DestroyWindow`、`BeginPaint`、`EndPaint`、`wsprintfW`、`SetWindowTextW` 使用。`wsprintfW` 的 `wParam` 作为可变参数走 `R8`，**不需要**栈；但影子空间依然必须存在。

**③ 16 字节对齐**

- `WndProc` 入口 `RSP % 16 == 8`；
- `push rbp` → 0；
- `sub rsp, 32` → 仍是 0（32 是 16 的倍数）；
- 因此每个 `call` 点都满足 `% 16 == 0`。

`wmain` 分配 128 字节：32 影子 + 64 栈参数（`CreateWindowExW` 的后 8 个）+ 32 本地槽。

**④ 非易失寄存器**

本章 `WndProc` 不碰 `RBX/RDI/RSI/R12~R15`，状态都放全局变量（`g_width`、`g_height`、`g_keys`）。这是有意的取舍：**全局变量比寄存器保存更直观**，也避免初学者在多个 `ret` 分支里漏掉 `pop`。第 15 章会用 `RBX` 演示标准的"改了必须恢复"。

### 3.3 从 MinGW 头文件提取 MSG 与 PAINTSTRUCT

**MSG**（`winuser.h` 约 955 行）：

```c
typedef struct tagMSG {
    HWND   hwnd;
    UINT   message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD  time;
    POINT  pt;
} MSG;
```

按 x64 对齐规则推（指针 8 对齐、`UINT` 4 对齐）：

| 字段 | 类型 | 偏移 | 说明 |
|---|---|---|---|
| `hwnd` | 指针 | 0 | 8 字节 |
| `message` | `UINT` | 8 | 4 字节 |
| （隐式填充） | - | 12 | `wParam` 需要 8 对齐 |
| `wParam` | `UINT_PTR` | 16 | 8 字节 |
| `lParam` | `LONG_PTR` | 24 | 8 字节 |
| `time` | `DWORD` | 32 | 4 字节 |
| `pt.x` | `LONG` | 36 | 4 字节 |
| `pt.y` | `LONG` | 40 | 4 字节 |
| （尾部填充） | - | 44 | 结构体按 8 对齐 |
| 合计 | | **48** | |

**NASM 的 `struc` 不会自动补隐式填充**，所以必须显式写 `.pad0`、`.pad1`。

**PAINTSTRUCT**（`winuser.h` 约 1823 行）：

```c
typedef struct tagPAINTSTRUCT {
    HDC  hdc;
    BOOL fErase;
    RECT rcPaint;
    BOOL fRestore;
    BOOL fIncUpdate;
    BYTE rgbReserved[32];
} PAINTSTRUCT;
```

`hdc` 8 字节，`fErase` 从 8 开始，`rcPaint` 是 4 个 `LONG`（12～27），`fRestore` 28、`fIncUpdate` 32，`rgbReserved` 36～67，最后补 4 字节到 72。合计 **72 字节**。

### 3.4 消息分发表

`WndProc` 的主体是一串 `cmp edx, WM_xxx` + `je .on_xxx`：

```text
edx == WM_CREATE ?   → .on_create
edx == WM_SIZE ?     → .on_size
edx == WM_KEYDOWN ?  → .on_keydown
edx == WM_CLOSE ?    → .on_close
edx == WM_DESTROY ?  → .on_destroy
edx == WM_PAINT ?    → .on_paint
edx == WM_ERASEBKGND?→ .on_erase
        │
        └─ 都不匹配 → DefWindowProcW（系统默认处理）
```

不认识的消息必须交给 `DefWindowProcW`，否则窗口行为异常（例如不会自动重绘标题栏）。

### 3.5 WM_SIZE：从 lParam 拆宽高

`lParam` 是 32 位压缩值：**低 16 位是宽度，高 16 位是高度**。

```text
lParam (32 bit)
┌─────────────────┬─────────────────┐
│   HIWORD = 高   │   LOWORD = 宽   │
└─────────────────┴─────────────────┘
  31           16   15            0
```

拆法：

- 宽度：`movzx ecx, ax`——只取 `AX`（低 16 位）并零扩展到 32 位；
- 高度：`shr eax, 16` 后 `AX` 就是高 16 位，再 `movzx ecx, ax`。

如果写成 `mov ecx, eax`，`ecx` 会同时含高 16 位的垃圾，宽度可能变成几百万。

### 3.6 WM_KEYDOWN 与变参函数 wsprintfW

`wsprintfW(LPWSTR buf, LPCWSTR fmt, ...)` 是变参函数：

| 位置 | 参数 | 寄存器 |
|---|---|---|
| 1 | `buf` | `RCX` |
| 2 | `fmt` | `RDX` |
| 3 | 第一个可变参数 | `R8` |

变参函数调用前必须 **`AL = 0`**（表示没有浮点参数）。`wsprintfW` 没有 `float`/`double` 参数，所以用 `xor eax, eax` 清零 `AL`。忘记清 `AL` 会破坏变参约定。

### 3.7 WM_PAINT 必须成对

`BeginPaint` 和 `EndPaint` 必须严格配对。`BeginPaint` 返回 `HDC`（设备上下文句柄），即使不用也必须 `EndPaint`，否则窗口会一直处于"等待绘制"状态，CPU 空转重绘。

### 3.8 WM_ERASEBKGND 返回 1

`WM_ERASEBKGND` 是系统在重绘前问"要不要我帮你擦背景"。返回 1 表示"我已经擦过了，不用系统擦"，可以减少闪烁。本章其实没真正擦背景（背景刷由系统负责），但返回 1 能避免系统重复擦除。

### 3.9 窗口关闭的生命周期

```text
点关闭按钮
    │
    ▼
WM_CLOSE ──► DestroyWindow ──► WM_DESTROY ──► PostQuitMessage(0)
                                                       │
                                                       ▼
                                          WM_QUIT ──► GetMessageW 返回 0
                                                       │
                                                       ▼
                                                    进程退出
```

`WM_CLOSE` 的默认处理就是 `DestroyWindow`。本章把它显式写出来，是为了让你看到完整的生命周期。正确顺序是：`WM_CLOSE` → `DestroyWindow`（不要直接 `PostQuitMessage`，否则窗口句柄泄漏）。

## 4. 实践用例

本章 `winproc.asm` 在第 13 章窗口基础上增加了 6 个消息处理：尺寸变化时更新宽高、按键时在标题显示键码、绘制时配对 BeginPaint/EndPaint、关闭时走标准生命周期。

### 4.1 构建命令

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l winproc.obj.lst -o winproc.obj winproc.asm
gcc -municode -mwindows -o winproc.exe winproc.obj -luser32
```

产物 `winproc.exe` 为 142013 字节。

### 4.3 objdump 实证（子系统与导入表）

```text
Subsystem               00000002        (Windows GUI)
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
```

GUI 子系统，导入 `USER32.dll`。**只编译不运行**。手动体验：`.\winproc.exe`，按任意键看标题变化，ESC 或关闭按钮退出。

### 4.4 `.lst` 摘录

**分发表**：

```text
    62 00000008 83FA01                      cmp     edx, WM_CREATE
    63 0000000B 7438                        je      .on_create
    64 0000000D 83FA05                      cmp     edx, WM_SIZE
    65 00000010 7437                        je      .on_size
    66 00000012 81FA00010000                cmp     edx, WM_KEYDOWN
    67 00000018 744B                        je      .on_keydown
    70 00000023 83FA02                      cmp     edx, WM_DESTROY
    ...
    75 00000038 0F84B7000000                je      .on_erase
```

看两点：

- 小于 128 的常量用 `83FA imm8`（3 字节）；`WM_KEYDOWN = 0x0100` 超过 1 字节，NASM 生成 `81FA imm32`（6 字节）；
- 近距离跳转用 `74 rel8`（2 字节），远的用 `0F84 rel32`（6 字节）。汇编器的选择会自动出现在机器码里。

**拆宽高**：

```text
    89 00000049 4489C8                      mov     eax, r9d
    90 0000004C 0FB7C8                      movzx   ecx, ax                 ; LOWORD(lParam)
    92 00000055 C1E810                      shr     eax, 16
    93 00000058 0FB7C8                      movzx   ecx, ax                 ; HIWORD(lParam)
```

`0FB7C8` = `movzx ecx, ax`：`0F B7` 是 16→32 位零扩展，ModRM `C8` 表示 `ECX <- AX`。

**变参函数前置**：

```text
   110 00000082 31C0                        xor     eax, eax
   111 00000084 E8(00000000)                call    wsprintfW
```

`31C0` 就是 `xor eax, eax`（2 字节），同时清零 `AL`。

**BeginPaint**：

```text
   148 000000CB 488B0D(C8000000)            mov     rcx, [rel hwnd]
   149 000000D2 488D15(80000000)            lea     rdx, [rel ps]
   150 000000D9 E8(00000000)                call    BeginPaint
```

`488D15(...)` 是 `lea rdx, [rip+disp32]`，括号里的值未重定位。

## 5. 代码重点讲解

挑出 5 处关键代码，回扣前面的知识点。

**① 消息分发表的 cmp/je 链**

```asm
    cmp     edx, WM_CREATE
    je      .on_create
    cmp     edx, WM_SIZE
    je      .on_size
    ...
    call    DefWindowProcW
```

回扣知识点 3.4：不认识的消息交给 `DefWindowProcW`。`.lst` 里 `83FA` 与 `81FA` 的差异证明了汇编器会根据常量大小自动选择 `imm8`/`imm32` 编码。

**② WM_SIZE 拆宽高**

```asm
    mov     eax, r9d
    movzx   ecx, ax                 ; LOWORD(lParam) = 宽
    mov     [rel g_width], ecx
    shr     eax, 16
    movzx   ecx, ax                 ; HIWORD(lParam) = 高
```

回扣知识点 3.5：`movzx` 零扩展避免高位垃圾。如果改成 `mov ecx, eax`，宽度会包含高 16 位。

**③ wsprintfW 的变参前置**

```asm
    lea     rcx, [rel title_buf]
    lea     rdx, [rel fmt_key]
    mov     r8d, r8d                ; wParam 已在 R8
    xor     eax, eax
    call    wsprintfW
```

回扣知识点 3.6：变参函数前 `AL = 0`。`r8d` 是 `WM_KEYDOWN` 的虚拟键码，格式串 `%04X` 消费它。

**④ BeginPaint / EndPaint 配对**

```asm
.on_paint:
    mov     rcx, [rel hwnd]
    lea     rdx, [rel ps]
    call    BeginPaint
    ...
    call    EndPaint
```

回扣知识点 3.7：即使不用返回的 `HDC` 也必须 `EndPaint`，否则窗口永远"脏"。

**⑤ WM_CLOSE → DestroyWindow**

```asm
.on_close:
    mov     rcx, [rel hwnd]
    call    DestroyWindow
    xor     eax, eax
    leave
    ret
```

回扣知识点 3.9：`WM_CLOSE` 应调用 `DestroyWindow` 而非直接 `PostQuitMessage`，否则窗口句柄泄漏。`DestroyWindow` 会触发 `WM_DESTROY`，再由它 `PostQuitMessage`。

## 6. 常见坑

1. **`mov ecx, eax` 取宽高**：高 16 位没清掉，宽度可能变成几百万。
2. **`wsprintfW` 前没清 `AL`**：变参约定被破坏。
3. **`WM_CLOSE` 里直接 `PostQuitMessage`**：窗口没销毁就退出，句柄泄漏；正确做法是 `DestroyWindow`。
4. **`BeginPaint` 没有 `EndPaint`**：窗口永远"脏"，CPU 空转重绘。
5. **`DefWindowProcW` 前破坏了 `RCX/RDX/R8/R9`**：必须原样传进去，别在中间插入别的调用。
6. **`make clean` 依赖 `rm`**：纯 PowerShell 下 `make` 找不到 `rm.exe`，改用 `Remove-Item winproc.exe,winproc.obj,winproc.obj.lst`。

## 7. 练习

1. 在 `WM_LBUTTONDOWN` 里用 `wsprintfW` 显示鼠标坐标（`lParam` 同样低 16 位 x、高 16 位 y），常量已在 `common.asm`。
2. 把 `g_keys` 计数显示到标题里，验证每按一次普通键 +1、ESC 不计数。
3. 注释掉 `.on_erase` 分支，观察窗口拉伸时的闪烁差异。
4. 在 `.on_create` 里把 `g_width/g_height` 初始化为 0，再在 `WM_SIZE` 前后打日志（或 GDB 观察），确认 `WM_SIZE` 一定在 `CreateWindowExW` 返回前到达。
5. 在 GDB 中对 `WndProc` 下断点，用 `info registers rcx rdx r8 r9` 观察不同消息的参数。

## 8. 下一章预览

第 15 章开始真正画东西：

- `BeginPaint` 返回的 `HDC` 放进 `RBX`，演示非易失寄存器的保存/恢复；
- `TextOutW` 的 5 个参数（第 5 个走 `[rsp+32]`）；
- `GetClientRect` + `wsprintfW` 显示客户区尺寸；
- `CreateSolidBrush` → `FillRect` → `FrameRect` → `DeleteObject` 的 GDI 对象生命周期。
