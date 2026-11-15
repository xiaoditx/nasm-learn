# 第 19 章：Direct2D 综合窗口

> 阶段二的收尾：把工厂、渲染目标、画刷、消息循环、定时器、设备丢失处理组装成一个可动的窗口。
> 本章源码：[d2d_capstone.asm](d2d_capstone.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[d2d_capstone.obj.lst](d2d_capstone.obj.lst)

## 1. 本章目标

- 把创建/释放资源封装成 `create_render_target` 与 `release_scene` 两个函数；
- 在 `WM_SIZE` 里调用 `ID2D1HwndRenderTarget::Resize`（槽 58）；
- 用 `SetTimer(hwnd, 1, 16, NULL)` + `WM_TIMER` 驱动目标约 60 FPS 的动画，并理解它不是精确实时时钟；
- 用 `cvtsi2ss` 把整数帧号转成浮点坐标；
- 在 `EndDraw` 后检测 `D2DERR_RECREATE_TARGET`，设备丢失时释放场景、下一帧重建；
- 在 `WM_DESTROY` 里 `KillTimer` + 完整释放。

跑通后你应该能回答：

- 为什么 `Resize` 失败或 `EndDraw` 返回 `D2DERR_RECREATE_TARGET` 时要调用 `release_scene`？
- `create_render_target` 返回 0/1/2/3 各代表什么？
- `cvtsi2ss` 和 `movd` 的区别是什么？
- 为什么 `release_scene` 不释放工厂？

## 2. 前置 / 项目结构

```text
nasm-learn/
├── common.asm                   D2D 结构体、槽位、D2DERR_RECREATE_TARGET
└── 19-d2d-capstone/
    ├── Makefile
    ├── d2d_capstone.asm
    ├── README.md
    └── d2d_capstone.obj.lst    make 后生成
```

只有 `.asm` 源码。链接 `user32` + `d2d1`。本章是 GUI 程序，**只编译不运行**，用 `objdump -p` 验证子系统与导入表。

## 3. 知识点讲解

### 3.1 动画窗口的整体架构

本章把前两章的 D2D 能力组装成一个完整的动画窗口，关键模块：

```text
wmain
  ├─ D2D1CreateFactory          创建工厂
  ├─ RegisterClassExW / CreateWindowExW
  ├─ create_render_target       封装渲染目标+画刷创建
  └─ 消息循环

wmain（创建窗口并取得工厂后）
  └─ SetTimer(16ms)

WndProc
  ├─ WM_SIZE      更新 g_width/g_height → Resize
  ├─ WM_TIMER     g_tick++ → InvalidateRect
  ├─ WM_PAINT     create_render_target（若空）→ BeginDraw → 画 → EndDraw → 检测设备丢失
  ├─ WM_DESTROY   KillTimer → release_scene → Release(factory) → PostQuitMessage
  └─ WM_KEYDOWN   ESC 退出
```

### 3.2 Windows x64 ABI 四件套

**① 前四个参数：RCX / RDX / R8 / R9**

本章用到的多参数调用都在 4 个以内：

| 调用 | RCX | RDX | R8 | R9 |
|---|---|---|---|---|
| `SetTimer` | `hwnd` | `1`（id） | `16`（ms） | `NULL` |
| `KillTimer` | `hwnd` | `1` | - | - |
| `Resize` | `this` | `&size_u` | - | - |
| `create_render_target` | 无参 | - | - | - |

`CreateWindowExW` 仍然有 12 个参数，后 8 个从 `[rsp+32]` 开始。

**② 32 字节影子空间**

三个函数都预留了影子空间：

```asm
release_scene:          sub rsp, 32              ; 32
create_render_target:   sub rsp, 64              ; 32 影子 + 32 余量
WndProc:                sub rsp, 32              ; 32
```

`create_render_target` 里要连续调用 `CreateHwndRenderTarget` 和两次 `CreateSolidColorBrush`，64 字节给足余量且保持 16 对齐。

**③ 16 字节对齐**

```text
create_render_target 入口   RSP % 16 == 8
push rbp                    RSP % 16 == 0
sub rsp, 64                 RSP % 16 == 0（64 是 16 的倍数）
```

`release_scene` 与 `WndProc` 用 `sub rsp, 32`，同样成立。

**④ 非易失寄存器：当前源码有两处瑕疵**

`RBX/RBP/RDI/RSI/R12～R15/XMM6～XMM15` 都是非易失寄存器。`release_scene` 只使用易失寄存器并保护 `RBP`，这一部分正确；但：

- `create_render_target` 用 `RDI` 执行两次 `rep stosd`，没有保存它；
- `wmain` 也用 `RDI` 清零 `wndclass`，同样没有保存。

`create_render_target` 由 `WndProc` 调用时，还会间接改变窗口过程本应替系统保存的 `RDI`。当前示例能否运行取决于调用者是否恰好不依赖旧值，不能作为通用函数模板。正确写法可在 `push rbp` 后增加 `push rdi`，重新调整帧大小，并按相反顺序恢复；也可改用易失寄存器配合清零循环。`create_render_target` 的返回码放在 `EAX`，这是 Windows x64 的 32 位整数返回值约定。

以 `create_render_target` 为例，若选择保存 `RDI`，一种可行布局是：

```asm
    push    rbp                     ; 入口 8 → 0
    mov     rbp, rsp
    push    rdi                     ; 0 → 8
    sub     rsp, 72                 ; 8 → 0；72 覆盖原来的 64 字节工作区
    ; ... 函数体 ...
    add     rsp, 72
    pop     rdi
    pop     rbp
    ret
```

这里不能照搬原来的 `leave`，因为 `leave` 会把 `RSP` 直接恢复到 `RBP`，跳过位于其后的 `pop rdi`；应按保存的逆序显式恢复。

### 3.3 D2D1_SIZE_U 与 Resize

`D2D1_SIZE_U`（`d2dbasetypes.h`）：

```c
typedef struct D2D1_SIZE_U {
    UINT32 width;
    UINT32 height;
} D2D1_SIZE_U;
```

8 字节，无填充。

`ID2D1HwndRenderTargetVtbl` 在基类 57 槽（0～56）之后：

| 槽 | 方法 |
|---|---|
| 57 | `CheckWindowState` |
| 58 | `Resize(const D2D1_SIZE_U*)` |
| 59 | `GetHwnd` |

`58 * 8 = 464 = 0x1D0`，`.lst` 里的 `FF90D0010000` 就是它。

`Resize` 失败不一定都是设备丢失，也可能来自无效尺寸等参数问题。当前源码采用保守策略：**任何非 S_OK 都释放场景**，让下一次 `WM_PAINT` 尝试重建。这样实现简单，但若是持续性参数错误会反复创建失败；工程代码应记录 `HRESULT`，并只对适合重建的错误执行该策略。

`WM_SIZE` 的参数映射为：`RCX=hwnd`、`EDX=WM_SIZE`、`R8=wParam`（尺寸状态）、`R9=lParam`。新宽度在 `lParam` 低 16 位，新高度在高 16 位。例如 `lParam=0x01E00280`，手算可得宽 `0x0280=640`、高 `0x01E0=480`。源码用 `movzx ecx,ax` 取低 16 位，再右移 16 位取高度。

### 3.4 create_render_target 的返回码

`create_render_target` 把资源创建封装成一个函数，返回码约定：

| EAX | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 没有工厂 |
| 2 | 画刷创建失败（已回滚） |
| 3 | 渲染目标创建失败 |

任一个画刷创建失败都会进入 `.fail_brush`，通过 `call release_scene` 回滚已经创建的场景资源；`.fail_create` 直接返回 3，`.no_factory` 直接返回 1。通常 RT 创建失败时输出指针仍为空，因此当前流程可行；通用封装最好在所有失败入口统一清理，并先确保 `p_rt/p_box/p_dot` 初始为 0。像素尺寸来自 `g_width/g_height`，它们由 `WM_SIZE` 更新，所以窗口缩放后重建的渲染目标会使用最近记录的客户区尺寸。

### 3.5 定时器与动画

`SetTimer(hwnd, 1, 16, NULL)` 请求以 16ms 为间隔投递 `WM_TIMER`，理论频率约 `1000/16=62.5` 次/秒，通常粗略称为 60 FPS。它是消息定时器，受系统计时器粒度、消息循环繁忙程度和 `WM_TIMER` 合并影响，**不保证每 16ms 到一次，也不保证稳定 60 FPS**。本章每次收到消息只把帧号加 1，所以实际动画速度会随消息到达速度变化；高精度循环应测量真实经过时间。

`WM_TIMER` 只做两件事：帧号 +1、调用 `InvalidateRect` 请求重画。更新与绘制分离后，`WM_PAINT` 负责真正渲染。

动画坐标由帧号 `g_tick` 计算：

```text
水平：(tick & 63) * 7       → 0～441
垂直：(tick & 15) * 12 + 40 → 40～220
```

`& 63` 让水平坐标在 0～441 之间循环，`& 15` 让垂直坐标在 40～220 之间循环。

### 3.6 cvtsi2ss vs movd

这是本章最容易混淆的两条指令：

| 指令 | 作用 | 示例 |
|---|---|---|
| `cvtsi2ss xmm, r/m32` | 把**整数值转换**成浮点数 | `cvtsi2ss xmm0, eax`（eax=7 → xmm0=7.0f） |
| `movd xmm, r/m32` | 搬**位模式**，不做转换 | `movd xmm3, eax`（eax=0x40000000 → xmm3=2.0f） |

本章用 `cvtsi2ss` 把帧号计算出的整数坐标转成浮点坐标，再存入 `D2D1_RECT_F`。如果错用 `movd`，得到的是整数位模式，坐标会变成 0 或极大的值。

### 3.7 设备丢失与 D2DERR_RECREATE_TARGET

`EndDraw` 返回 `D2DERR_RECREATE_TARGET = 0x8899000C` 时，表示渲染目标失效（显卡驱动重置、远程桌面切换、显示器热插拔等）。正确处理是**丢掉并重建**，而不是继续用旧 `p_rt`：

```text
EndDraw 返回 D2DERR_RECREATE_TARGET
    │
    ▼
release_scene（释放画刷+渲染目标，p_rt 清 0）
    │
    ▼
下一帧 WM_PAINT → p_rt 为空 → create_render_target 重建
```

### 3.8 释放顺序

`WM_DESTROY` 的清理顺序：

```text
KillTimer(hwnd, 1)          停定时器（避免回调用到已释放的场景）
    │
    ▼
release_scene               释放画刷 + 渲染目标（不释放工厂）
    │
    ▼
Release(p_factory)          释放工厂
    │
    ▼
PostQuitMessage(0)          退出消息循环
```

`release_scene` 不释放工厂，因为工厂生命周期比场景长，只有在 `WM_DESTROY` 才释放。

### 3.9 当前源码的运行条件与通用写法边界

本章源码演示的是“消息驱动的最小 D2D 动画骨架”，并依赖以下条件：

- 工厂、窗口和首轮资源创建成功；启动失败分支只返回错误码，没有逐层回滚；
- `WM_PAINT` 主要由 `InvalidateRect` 触发，当前没有 `BeginPaint/EndPaint` 配对。完整 Win32 写法应验证更新区域，并避免把 D2D 的 `BeginDraw/EndDraw` 误当成它们的替代品；
- `EndDraw` 只特殊处理 `D2DERR_RECREATE_TARGET`，其他失败 `HRESULT` 没有记录；
- `create_render_target` 与 `wmain` 未保存 `RDI`，属于当前源码的 ABI 瑕疵；
- `SetTimer` 只提供近似心跳，不提供基于真实时间的恒速运动。

因此，本章可以用来逐行理解“创建—更新—绘制—丢失—重建—释放”的状态流，但不能原样当作生产级窗口模板。通用版本至少应补齐参数检查、失败清理、非易失寄存器保存、绘图消息生命周期和错误日志。

## 4. 实践用例

本章 `d2d_capstone.asm` 实现一个动画窗口：蓝色方块按帧号移动，橙色圆跟随，窗口拉伸时 `Resize` 保持清晰，设备丢失时自动重建。

### 4.1 构建命令

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l d2d_capstone.obj.lst -o d2d_capstone.obj d2d_capstone.asm
gcc -municode -mwindows -o d2d_capstone.exe d2d_capstone.obj -luser32 -ld2d1
```

产物 `d2d_capstone.exe` 为 144490 字节。

### 4.3 objdump 实证（子系统与导入表）

```text
Subsystem               00000002        (Windows GUI)
        DLL Name: d2d1.dll
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
```

GUI 子系统，导入 `d2d1.dll`。**只编译不运行**。手动体验：`.\d2d_capstone.exe`，蓝色方块左右上下移动，橙色圆跟随，拉伸窗口不糊，ESC 退出。

### 4.4 `.lst` 摘录

**Resize（槽 58）**：

```text
   236 000001D7 488D15(BC000000)            lea     rdx, [rel size_u]
   237                                      COM_CALL rcx, D2D1_HWND_RT_RESIZE
    60 000001DE 488B01              <1>  mov rax, [%1]
    61 000001E1 FF90D0010000        <1>  call qword [rax + (%2) * 8]
```

`0x1D0 = 464 = 58 * 8`。

**辅助函数调用**：

```text
   174 0000012A E8D1FEFFFF                  call    release_scene
   240 000001EB E810FEFFFF                  call    release_scene
   267 00000232 E82AFEFFFF                  call    create_render_target
   333 00000354 E8A7FCFFFF                  call    release_scene
```

四个 `call` 的 `rel32` 位移都不同，但目标只对应两个函数：负位移回到前面，正负组合取决于调用点位置。

**cvtsi2ss**：

```text
   283 00000272 F30F2AC0                    cvtsi2ss xmm0, eax
   284 00000276 F30F1105(F0000000)          movss   [rel anim_rect + D2D1_RECT_F.left], xmm0
```

`F3 0F 2A` 是 `cvtsi2ss` 的前缀与 opcode，`C0` 的 ModRM 表示 `XMM0 <- EAX`。`F3 0F 11` 是 `movss`（单精度标量存储），后面是 RIP 相对的 4 字节浮点槽。

## 5. 代码重点讲解

挑出 6 处关键代码，回扣前面的知识点。

**① create_render_target 的标准序言与返回码**

```asm
create_render_target:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64

    mov     rax, [rel p_factory]
    test    rax, rax
    jz      .no_factory                     ; 返回 1
```

回扣知识点 3.2③/3.4：标准序言保证 16 对齐。返回码 0=成功、1=无工厂、2=画刷失败、3=RT 失败，失败路径 `.fail_brush` 会先 `call release_scene` 回滚。

**② WM_SIZE 里 Resize**

```asm
.on_size:
    mov     eax, r9d
    movzx   ecx, ax
    mov     [rel g_width], ecx
    shr     eax, 16
    movzx   ecx, ax
    mov     [rel g_height], ecx

    mov     rax, [rel p_rt]
    test    rax, rax
    jz      .size_done

    lea     rax, [rel size_u]
    mov     ecx, [rel g_width]
    mov     [rax + D2D1_SIZE_U.width], ecx
    ...
    COM_CALL rcx, D2D1_HWND_RT_RESIZE
    test    eax, eax
    jz      .size_done
    call    release_scene          ; Resize 失败：下一帧重建
```

回扣知识点 3.3：`Resize` 槽 58，`.lst` 里 `FF90D0010000` 证明偏移 `0x1D0 = 58*8`。`Resize` 失败意味着设备丢失，直接 `release_scene`，下一帧重建。

**③ SetTimer 驱动动画**

```asm
    mov     rcx, [rel hwnd]
    mov     edx, 1
    mov     r8d, 16
    xor     r9d, r9d
    call    SetTimer
```

回扣知识点 3.5：`SetTimer(hwnd, 1, 16, NULL)` 请求约 16ms 一次的消息心跳，但不保证精确实时。这里的 `1` 是本程序自选、与 `KillTimer` 和 `WM_TIMER` 判断保持一致的计时器 ID，便于管理，不是因为“0 被系统保留”。

**④ cvtsi2ss 整数转浮点**

```asm
    mov     eax, [rel g_tick]
    and     eax, 63
    imul    eax, eax, 7                 ; 0..441
    cvtsi2ss xmm0, eax
    movss   [rel anim_rect + D2D1_RECT_F.left], xmm0
```

回扣知识点 3.6：`cvtsi2ss` 把整数值**转换成**浮点数，`movd` 只是搬位模式，两者不能混用。`.lst` 里 `F30F2AC0` 是 `cvtsi2ss xmm0, eax`。

**⑤ EndDraw 检测设备丢失**

```asm
    COM_CALL rcx, D2D1_RT_END_DRAW
    cmp     eax, D2DERR_RECREATE_TARGET
    jne     .paint_done
    call    release_scene
```

回扣知识点 3.7：`D2DERR_RECREATE_TARGET = 0x8899000C`。触发后 `release_scene` 丢掉场景，下一帧 `WM_PAINT` 重建。

**⑥ WM_DESTROY 清理顺序**

```asm
    mov     rcx, [rel hwnd]
    mov     edx, 1
    call    KillTimer
    call    release_scene

    mov     rcx, [rel p_factory]
    ...
    COM_CALL rcx, IUNKNOWN_RELEASE
```

回扣知识点 3.8：顺序是"停定时器 → 释放场景 → 释放工厂 → PostQuitMessage"。`release_scene` 不释放工厂，工厂留到最后才 `Release`。

## 6. 常见坑

1. **`WM_PAINT` 里不判空 `p_rt`**：`EndDraw` 失败后 `p_rt` 已被清 0，下一帧必须先 `create_render_target`。
2. **`EndDraw` 返回值只判 `S_OK`**：`D2DERR_RECREATE_TARGET` 是"可恢复"的，必须单独处理。
3. **`Resize` 后忘记 `InvalidateRect`**：窗口拉伸后画面停留在旧尺寸，直到下一次定时器触发。
4. **把 16ms 当作精确的 60 FPS**：`WM_TIMER` 会受消息循环与系统粒度影响；本章动画按“消息次数”推进，不是按真实秒数推进。
5. **资源释放后继续使用旧指针**：`release_scene` 已把场景指针清零；重建必须等下一次 `WM_PAINT`，不要缓存旧的 `p_rt/p_box/p_dot`。
6. **`create_render_target` 与 `wmain` 未保存 `RDI`**：当前示例可能正常运行，但违反非易失寄存器约定；通用写法必须保存/恢复，或改用易失寄存器。
7. **`cvtsi2ss xmm0, eax` 写成 `movd`**：前者做整数数值转换，后者只复制位模式，结果完全不同。
8. **`CreateWindowExW` 的栈参数只写 4 字节**：每个栈参数槽为 8 字节，应写完整 `qword`，避免高位残留。
9. **启动失败路径没有逆序清理**：当前 `.fail_d2d` 直接返回 3，依赖进程退出回收；通用程序应释放已经创建的场景、工厂和窗口。
10. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item d2d_capstone.exe,d2d_capstone.obj,d2d_capstone.obj.lst`。

## 7. 练习

1. 把定时器周期改成 33 ms，观察动画速度。
2. 把 `g_tick & 63` 改成 `& 127`，运动范围变大但会超出客户区，想想为什么 `Resize` 不能解决"坐标越界"。
3. 在 `WM_TIMER` 里按 `g_tick` 切换 `SetColor` 改变方块颜色。
4. 人为在 `WM_PAINT` 里把 `p_rt` 置 0 并 `release_scene`，模拟设备丢失，验证下一帧能否自动恢复。
5. 用 GDB 在 `call qword [rax + 0x1D0]` 处断下，用 `x/2dw $rdx` 查看 `D2D1_SIZE_U` 的宽高。

## 8. 下一章预览（阶段三起点）

第 20 章开始脱离 CRT：

- 自己写入口 `_start`，用 `gcc -nostartfiles` 去掉 CRT 启动文件；
- 用 `GetCommandLineW` 获取原始命令行，并用 `WriteConsoleW` 输出；
- 用 `ExitProcess` 保证进程可控退出；
- 认识控制台输出与重定向的差别，为最终“纯汇编 Direct2D 游戏”做准备。
