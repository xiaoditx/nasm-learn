# 第 13 章：最小 Win32 窗口

> 从这里开始进入 GUI 阶段：不再只有控制台，而是让 Windows 给我们一个真正的窗口。
> 本章源码：[firstwindow.asm](firstwindow.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[firstwindow.obj.lst](firstwindow.obj.lst)

## 1. 本章目标

- 用纯汇编完成 `RegisterClassExW` → `CreateWindowExW` → `ShowWindow` → 消息循环的最小闭环；
- 第一次处理"参数超过 4 个"的 Windows API（`CreateWindowExW` 有 12 个参数）；
- 从 MinGW 头文件里读出 `WNDCLASSEXW` 的布局，用 NASM `struc/endstruc` 定义出来；
- 把 Windows x64 ABI 的四件套在真实 GUI 程序里落地。

跑通后你应该能回答：

- 为什么 `WNDCLASSEXW` 的 `cbSize` 必须是 80？
- 第 5～12 个参数为什么要写到 `[rsp+32]`、`[rsp+40]`……？
- `GetMessageW` 返回 0 和返回 -1 有什么区别？
- `wmain` 和 `WndProc` 的栈对齐在入口处分别是什么状态？

## 2. 前置 / 项目结构

```text
masm-learn/
├── common.asm                    共享常量、结构体、WSTRZ 宏
└── 13-first-window/
    ├── Makefile
    ├── firstwindow.asm
    ├── README.md
    └── firstwindow.obj.lst       make 后生成
```

本目录只有 `.asm` 源码，没有 `.c/.cpp/.inc`。所有共享定义都来自 `%include "../common.asm"`。本章是 GUI 程序，**只编译不运行**，用 `objdump -p` 验证子系统与导入表。

## 3. 知识点讲解

### 3.1 Windows 窗口的生命周期

一个最小 Win32 窗口的诞生要走完四步：

```text
RegisterClassExW        注册窗口类（告诉系统"这类窗口长什么样、由谁处理消息"）
      │
CreateWindowExW         按类创建一个具体窗口实例
      │
ShowWindow              让窗口可见
      │
消息循环 GetMessageW    不断取消息 → DispatchMessageW → 系统回调 WndProc
```

窗口类（`WNDCLASSEXW`）是"模板"，窗口是"实例"。同一个类可以创建多个窗口。`WndProc` 是窗口过程——系统把消息投递进来，由它决定怎么响应。

### 3.2 Windows x64 ABI 四件套

GUI 编程里这四条同样是所有崩溃的根源。

**① 前四个参数：RCX / RDX / R8 / R9**

| 参数序号 | 整数/指针寄存器 | 浮点寄存器 |
|---|---|---|
| 1 | `RCX` | `XMM0` |
| 2 | `RDX` | `XMM1` |
| 3 | `R8` | `XMM2` |
| 4 | `R9` | `XMM3` |
| 5 及以后 | `[rsp + 32]`、`[rsp + 40]`…… | 同样从 `[rsp + 32]` 开始 |

本章的 `WndProc(HWND, UINT, WPARAM, LPARAM)` 正好 4 个参数，全部走寄存器：`RCX = hwnd`、`EDX = message`、`R8 = wParam`、`R9 = lParam`。

**② 32 字节影子空间**

调用任何 Windows x64 函数前，调用者必须在栈上预留 32 字节影子空间。被调函数可以把寄存器参数"溢出"到这块空间里存放。`WndProc` 的 `sub rsp, 32` 就是给 `DefWindowProcW` / `PostQuitMessage` 留的影子空间。

`CreateWindowExW` 有 12 个参数，前 4 个走寄存器，后 8 个从 `[rsp+32]` 写到 `[rsp+88]`。所以 `wmain` 分配了 128 字节：32 影子 + 64 栈参数 + 32 本地槽。

**③ 16 字节对齐**

- 入口（`wmain` 或 `WndProc` 刚被调用）：`RSP % 16 == 8`（调用者的 `call` 压入返回地址，把 16 对齐的栈变成了 8）；
- `call` 执行的那一刻：`RSP % 16 == 0`；
- `push rbp` 之后 `% 16 == 0`，再 `sub rsp, 32`（32 是 16 的倍数）仍然对齐。

本章两个函数都用 `push rbp / mov rbp, rsp / sub rsp, 32` 的序言。

**④ 非易失寄存器**

| 类别 | 寄存器 | 规则 |
|---|---|---|
| 非易失 | `RBX`、`RBP`、`RDI`、`RSI`、`R12`~`R15`、`XMM6`~`XMM15` | 改了必须恢复 |
| 易失 | `RAX`、`RCX`、`RDX`、`R8`~`R11`、`XMM0`~`XMM5` | 调用后不保证 |

本章 `wmain` 用了 `RDI`（`rep stosd` 清零 `WNDCLASSEXW`），严格来说 `wmain` 作为被 CRT 调用的函数也应保存 `RDI`。第 15 章会演示标准的 `push rbx` / `pop rbx` 成对写法。

### 3.3 从 MinGW 头文件提取 WNDCLASSEXW

没有 Windows SDK，就从头文件里"逆向"结构体。MinGW 的声明在 `C:\msys64\ucrt64\include\winuser.h`（约 897 行）：

```c
typedef struct tagWNDCLASSEXW {
    UINT      cbSize;
    UINT      style;
    WNDPROC   lpfnWndProc;
    int       cbClsExtra;
    int       cbWndExtra;
    HINSTANCE hInstance;
    HICON     hIcon;
    HCURSOR   hCursor;
    HBRUSH    hbrBackground;
    LPCWSTR   lpszMenuName;
    LPCWSTR   lpszClassName;
    HICON     hIconSm;
} WNDCLASSEXW;
```

x64 下按"每个字段自然对齐"推偏移——指针 8 字节对齐、`UINT` 4 字节对齐：

| 字段 | 类型 | 偏移 | 大小 |
|---|---|---|---|
| `cbSize` | `UINT` | 0 | 4 |
| `style` | `UINT` | 4 | 4 |
| `lpfnWndProc` | 指针 | 8 | 8 |
| `cbClsExtra` | `int` | 16 | 4 |
| `cbWndExtra` | `int` | 20 | 4 |
| `hInstance` | 指针 | 24 | 8 |
| `hIcon` | 指针 | 32 | 8 |
| `hCursor` | 指针 | 40 | 8 |
| `hbrBackground` | 指针 | 48 | 8 |
| `lpszMenuName` | 指针 | 56 | 8 |
| `lpszClassName` | 指针 | 64 | 8 |
| `hIconSm` | 指针 | 72 | 8 |

合计 **80 字节**。注意 `cbWndExtra` 占 20～23，`hInstance` 从 24 开始正好 8 字节对齐，因此中间**没有**隐式填充。`common.asm` 中的定义与上表逐项对应，`WNDCLASSEXW_size` 是 NASM 自动生成的后缀常量，值为 80。

`cbSize` 是结构体自描述字段，`RegisterClassExW` 靠它判断你用的是哪个版本的结构体。填错（比如 72 或 76）会直接注册失败。

### 3.4 12 参数的 CreateWindowExW

`CreateWindowExW` 是本章参数最多的调用。前 4 个走寄存器，后 8 个按 8 字节一个槽写到栈上：

```text
参数   含义               去向
 1    dwExStyle          ECX
 2    lpClassName        RDX
 3    lpWindowName       R8
 4    dwStyle            R9D
 5    X                  [rsp+32]
 6    Y                  [rsp+40]
 7    nWidth             [rsp+48]
 8    nHeight            [rsp+56]
 9    hWndParent         [rsp+64]
10    hMenu              [rsp+72]
11    hInstance          [rsp+80]
12    lpParam            [rsp+88]
```

关键规则：即使 C 原型里 `X/Y/Width/Height` 是 `int`（4 字节），x64 调用约定仍按 **8 字节槽**传递，高位写 0 即可。写成 `mov dword [rsp+48], 640` 只写低 4 字节，高 4 字节残留旧值，必须用 `mov qword`。

### 3.5 消息循环与 GetMessageW 的返回值

```text
GetMessageW(&msg, NULL, 0, 0)
      │
      ├─ 返回 0  → 收到 WM_QUIT，正常退出
      ├─ 返回 -1 → 出错（msg 结构体无效等），也应退出
      └─ 返回 >0 → 有消息，TranslateMessage → DispatchMessageW
```

`test eax, eax` 判 0，`js`（符号位，即负数）判 -1，两条跳转覆盖退出条件。`WM_QUIT` 由 `PostQuitMessage` 产生，通常在 `WM_DESTROY` 里调用。

### 3.6 窗口过程的最小写法

`WndProc` 只需要自己处理关心的消息，其余全部交给 `DefWindowProcW`。本章只处理 `WM_DESTROY`：调用 `PostQuitMessage(0)`，让消息循环退出。`PostQuitMessage` 的参数是退出码，会作为 `WM_QUIT` 的 `wParam`。

## 4. 实践用例

本章 `firstwindow.asm` 实现一个 640×480 的空白窗口，完整演示注册类、创建窗口、消息循环的最小闭环。

### 4.1 构建命令

在 `13-first-window` 目录下：

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l firstwindow.obj.lst -o firstwindow.obj firstwindow.asm
gcc -municode -mwindows -o firstwindow.exe firstwindow.obj -luser32
```

产物 `firstwindow.exe` 为 139279 字节。

### 4.3 objdump 实证（子系统与导入表）

```powershell
objdump -p firstwindow.exe | Select-String "Subsystem|DLL Name"
```

```text
Subsystem               00000002        (Windows GUI)
        DLL Name: KERNEL32.dll
        DLL Name: api-ms-win-crt-environment-l1-1-0.dll
        ...
        DLL Name: USER32.dll
```

`Subsystem = 2` 确认是 Windows GUI 子系统（`-mwindows` 的作用）；导入表含 `USER32.dll`（窗口 API）和 CRT 环境相关 DLL。**本章只编译不运行**：运行会弹出窗口并阻塞在消息循环里，不适合自动化验证。想手动看效果可以 `.\firstwindow.exe`，关闭窗口即退出。

### 4.4 `.lst` 摘录

**结构体偏移**：

```text
   114 00000000 ????????            <1>     .cbSize:        resd 1      ; +0
   115 00000004 ????????            <1>     .style:         resd 1      ; +4
   ...
   125 00000048 ????????????????    <1>     .hIconSm:       resq 1      ; +72
   126                              <1> endstruc                        ; = 80
```

`struc` 里的 `resd/resq` 不产生机器码，所以机器码列是 `????????`；偏移列 `00000000`、`00000048` 正是上表的 0 和 72。最后一行 `= 80` 是 NASM 计算出的结构体大小。

**两个关键调用**：

```text
    92 00000087 488D0D(00000000)            lea     rcx, [rel wndclass]
    93 0000008E E8(00000000)                call    RegisterClassExW
    ...
   111 000000E8 4889442450                  mov     qword [rsp + 80], rax       ; hInstance
   112 000000ED 48C744245800000000          mov     qword [rsp + 88], 0         ; lpParam
   113 000000F6 E8(00000000)                call    CreateWindowExW
```

`4889442450` 的含义：`48` = REX.W，`89` = `mov r/m64, r64`，`44` = ModRM（`[rsp+disp8]`，源 `RAX`），`24` = SIB（base=RSP），`50` = 位移 `0x50` = 80。所以它精确地写到了 `[rsp+80]`，即第 11 个参数 `hInstance`。

`E8(00000000)` 是尚未重定位的 `call rel32`，真实目标要等链接后由 `objdump -d` 才能看到。

## 5. 代码重点讲解

挑出 5 处关键代码，回扣前面的知识点。

**① `WndProc` 的序言与影子空间**

```asm
WndProc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                 ; 32 字节影子空间
```

回扣知识点 3.2②③：入口 `RSP%16==8`，`push rbp` 后 `0`，`sub 32` 仍 `0`，`call` 点对齐。32 字节影子空间供 `DefWindowProcW` 使用。

**② 清零 WNDCLASSEXW**

```asm
    lea     rdi, [rel wndclass]
    xor     eax, eax
    mov     ecx, WNDCLASSEXW_size / 4    ; 20 个 dword
    rep     stosd
```

回扣知识点 3.3：80 字节 / 4 = 20 次 `stosd`。先清零再填字段，避免 `cbClsExtra/cbWndExtra/lpszMenuName` 里的垃圾值导致 `RegisterClassExW` 失败。

**③ cbSize 与窗口过程指针**

```asm
    mov     dword [rax + WNDCLASSEXW.cbSize], WNDCLASSEXW_size
    lea     rcx, [rel WndProc]
    mov     [rax + WNDCLASSEXW.lpfnWndProc], rcx
```

回扣知识点 3.3：`cbSize` 必须是 80，否则注册失败。`lpfnWndProc` 存的是 `WndProc` 函数地址，`CreateWindowExW` 用类名把窗口和这个过程关联起来。

**④ CreateWindowExW 的栈参数**

```asm
    mov     eax, CW_USEDEFAULT
    mov     qword [rsp + 32], rax       ; X
    mov     qword [rsp + 40], rax       ; Y
    mov     qword [rsp + 48], 640       ; nWidth
    ...
    mov     qword [rsp + 88], 0         ; lpParam
    call    CreateWindowExW
```

回扣知识点 3.4：第 5～12 个参数按 8 字节槽写，必须用 `mov qword`。`.lst` 里 `4889442450` 精确证明了 `[rsp+80]` 的写入。

**⑤ 消息循环的双分支退出**

```asm
    call    GetMessageW
    test    eax, eax
    jz      .done                   ; 0 = WM_QUIT
    js      .done                   ; 负数 = -1，出错也退出
```

回扣知识点 3.5：`test` 判 0、`js` 判负数，同时覆盖正常退出和错误退出。漏掉 `js` 会让出错时无限循环。

## 6. 常见坑

1. **`cbSize` 填成 72 或 76**：`RegisterClassExW` 返回 0，`CreateWindowExW` 也拿不到窗口。这个结构体是 80。
2. **忘了清零 `WNDCLASSEXW`**：`cbClsExtra/cbWndExtra/lpszMenuName` 里的垃圾值会让注册失败。
3. **`CreateWindowExW` 的栈参数写成 4 字节**：例如 `mov dword [rsp+48], 640` 只写低 4 字节，高 4 字节是影子空间里的旧值；应写 `mov qword`。
4. **`GetMessageW` 只判断 0**：不判断 -1 时，出错会当成"有消息"继续循环。
5. **`hbrBackground` 忘了 `+1`**：`COLOR_WINDOW` 是颜色索引，画刷句柄是索引 +1。
6. **`make clean` 在纯 PowerShell 下失败**：Makefile 的 `clean` 调 `rm`，`make` 直接 `CreateProcess` 找不到 `rm.exe`（只在 MSYS 的 `usr/bin` 里）。在 MSYS2/MinGW 终端里执行没问题；PowerShell 里可手动删除：
   ```powershell
   Remove-Item firstwindow.exe,firstwindow.obj,firstwindow.obj.lst
   ```

## 7. 练习

1. 把窗口尺寸从 640×480 改成 800×600，重新 `make`，在 `.lst` 里找到 `mov qword [rsp + 48], 800` 的机器码。
2. 在 `WndProc` 里加一句 `cmp edx, WM_CLOSE` 并 `je .on_destroy`，观察点关闭按钮时程序是否直接退出。
3. 把 `hbrBackground` 改成 0，窗口背景会怎样？为什么第 17 章 D2D 正好需要 0？
4. 用 `objdump -p firstwindow.exe | Select-String "Subsystem"` 验证 `-mwindows` 的作用；去掉 `-mwindows` 再链接，观察子系统变化和是否弹出控制台。
5. 在 GDB 里对 `WndProc` 下断点（先 `.\firstwindow.exe` 再附加，或直接 `gdb --args firstwindow.exe`），用 `info registers rcx rdx r8 r9` 确认四个参数。

## 8. 下一章预览

第 14 章把这个壳子补成"会说话的窗口"：

- 完整消息分发表：`WM_CREATE / WM_SIZE / WM_KEYDOWN / WM_CLOSE / WM_PAINT / WM_ERASEBKGND`；
- 从 `lParam` 里拆出宽高（`movzx` + `shr 16`）；
- 用 `wsprintfW` 生成标题并 `SetWindowTextW`；
- 用 `LoadIconW/LoadCursorW` 给窗口配上图标和箭头光标。
