# 第 19 章：Direct2D 综合窗口

> 阶段二的收尾：把工厂、渲染目标、画刷、消息循环、定时器、设备丢失处理组装成一个可动的窗口。
> 本章源码：[d2d_capstone.asm](d2d_capstone.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[d2d_capstone.obj.lst](d2d_capstone.obj.lst)

## 1. 本章目标

- 把创建/释放资源封装成 `create_render_target` 与 `release_scene` 两个函数；
- 在 `WM_SIZE` 里调用 `ID2D1HwndRenderTarget::Resize`（槽 58）；
- 用 `SetTimer(hwnd, 1, 16, NULL)` + `WM_TIMER` 驱动 60 FPS 动画；
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
masm-learn/
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

WndProc
  ├─ WM_CREATE    SetTimer(16ms)
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

**④ 非易失寄存器**

三个函数都只用 `RAX/RCX/RDX/R8/R9`，不改 `RBX/RDI/RSI/R12~R15`，因此序言只有 `push rbp`。`create_render_target` 的返回值放在 `EAX`（`RAX` 的低 32 位），这是 Windows x64 的整数返回值约定。

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

`Resize` 失败通常意味着设备丢失（显卡驱动重置、远程桌面切换等），此时应丢掉场景，`WM_PAINT` 里重新创建。

### 3.4 create_render_target 的返回码

`create_render_target` 把资源创建封装成一个函数，返回码约定：

| EAX | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 没有工厂 |
| 2 | 画刷创建失败（已回滚） |
| 3 | 渲染目标创建失败 |

失败路径会先 `call release_scene` 回滚，避免半成品泄漏。像素尺寸来自 `g_width/g_height`，它们由 `WM_SIZE` 更新，所以窗口缩放后重建的渲染目标尺寸是正确的。

### 3.5 定时器与动画

`SetTimer(hwnd, 1, 16, NULL)` 设置一个 16ms（约 60 FPS）的定时器。`WM_TIMER` 只做两件事：帧号 +1、请求重画。

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

回扣知识点 3.5：`SetTimer(hwnd, 1, 16, NULL)`，16ms ≈ 60 FPS。id 用 1，不用 0（系统保留）。

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
4. **`SetTimer` 用 0 作为 id**：0 由系统保留，行为未定义；用 1。
5. **`WM_DESTROY` 里先释放工厂再 `KillTimer`**：定时器回调可能还会用到场景，顺序应为"停定时器 → 释放场景 → 释放工厂"。
6. **`cvtsi2ss xmm0, eax` 写成 `movd`**：得到的是整数位模式，坐标会变成 0 或极大的值。
7. **`CreateWindowExW` 的栈参数只写 4 字节**：高 4 字节残留，尺寸可能异常。
8. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item d2d_capstone.exe,d2d_capstone.obj,d2d_capstone.obj.lst`。

## 7. 练习

1. 把定时器周期改成 33 ms，观察动画速度。
2. 把 `g_tick & 63` 改成 `& 127`，运动范围变大但会超出客户区，想想为什么 `Resize` 不能解决"坐标越界"。
3. 在 `WM_TIMER` 里按 `g_tick` 切换 `SetColor` 改变方块颜色。
4. 人为在 `WM_PAINT` 里把 `p_rt` 置 0 并 `release_scene`，模拟设备丢失，验证下一帧能否自动恢复。
5. 用 GDB 在 `call qword [rax + 0x1D0]` 处断下，用 `x/2dw $rdx` 查看 `D2D1_SIZE_U` 的宽高。

## 8. 下一章预览（阶段三起点）

第 20 章开始脱离 CRT：

- 自己写入口 `_start`，不再依赖 `wmainCRTStartup`；
- 手动从 PEB 取 `ImageBase` / `ProcessParameters`，或改用 `GetModuleHandleW`；
- 用 `ExitProcess` 保证进程可控退出；
- 为最终"纯汇编 Direct2D 游戏"做准备。
