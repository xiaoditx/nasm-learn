# 第 18 章：Direct2D 画刷与图元

> 渲染目标会清屏了，本章开始画矩形和椭圆。
> 本章源码：[d2d_shapes.asm](d2d_shapes.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[d2d_shapes.obj.lst](d2d_shapes.obj.lst)

## 1. 本章目标

- 用 `CreateSolidColorBrush` 创建三个画刷（填充、描边、圆）；
- 用 `FillRectangle` / `DrawRectangle` / `FillEllipse` 画图元；
- 掌握“第 4 个参数是 FLOAT 时走 `XMM3`，第 5 个参数走栈”这条 x64 ABI 规则；
- 看懂 `release_if_nonnull` 辅助函数，并识别当前叶子函数版本的对齐瑕疵；
- 按“画刷 → 渲染目标 → 工厂”的顺序释放资源；
- 分清“当前示例在理想条件下可走通的流程”和“符合 ABI、可复用的正确写法”。

跑通后你应该能回答：

- `DrawRectangle(rect, brush, strokeWidth, strokeStyle)` 的 `strokeWidth` 为什么走 `XMM3` 而不是 `R9`？
- 第 5 个参数 `strokeStyle` 为什么必须写在调用前的 `[rsp+32]`，即使 `R9` 没有存放有效参数？
- `mov eax, 0x40000000` 为什么表示 `2.0f`？
- 画刷为什么要先于渲染目标释放？

## 2. 前置 / 项目结构

```text
nasm-learn/
├── common.asm                  D2D1_COLOR_F / RECT_F / ELLIPSE / BRUSH_PROPERTIES
└── 18-d2d-brush-shapes/
    ├── Makefile
    ├── d2d_shapes.asm
    ├── README.md
    └── d2d_shapes.obj.lst     make 后生成
```

只有 `.asm` 源码。链接 `user32` + `d2d1`。本章是 GUI 程序，**只编译不运行**，用 `objdump -p` 验证子系统与导入表。

## 3. 知识点讲解

### 3.1 D2D 图元与画刷

Direct2D 的图元绘制需要"渲染目标 + 画刷"配合：

```text
渲染目标（ID2D1RenderTarget）
    │
    ├─ CreateSolidColorBrush(&color, NULL, &brush)   创建纯色画刷
    │
    ├─ FillRectangle(&rect, brush)                   填充矩形（槽 17）
    ├─ DrawRectangle(&rect, brush, strokeWidth, NULL) 画矩形边框（槽 16）
    └─ FillEllipse(&ellipse, brush)                  填充椭圆（槽 21）
```

画刷是"颜料"，渲染目标是"画布"。画刷由渲染目标创建，持有对渲染目标的引用，所以释放时画刷要先于渲染目标。

### 3.2 Windows x64 ABI 四件套

**① 参数按“位置”分配；第 5 个位置一定上栈**

| 位置 | 整数/指针 | 浮点 |
|---|---|---|
| 1 | `RCX` | `XMM0` |
| 2 | `RDX` | `XMM1` |
| 3 | `R8` | `XMM2` |
| 4 | `R9` | `XMM3` |
| 5 | 调用前 `[rsp+32]` | 调用前 `[rsp+32]` |
| 6 | 调用前 `[rsp+40]` | 调用前 `[rsp+40]` |

前四个位置中，整数/指针与浮点数分别使用对应的整数寄存器或 XMM 寄存器。**但从第 5 个位置开始一律使用栈，不能把“空着的”整数寄存器继续分配给后面的参数。**

`ID2D1RenderTarget::DrawRectangle(this, rect, brush, strokeWidth, strokeStyle)`：

| 位置 | 参数 | 类型 | 标准去向 |
|---|---|---|---|
| 1 | `this` | 指针 | `RCX` |
| 2 | `rect` | 指针 | `RDX` |
| 3 | `brush` | 指针 | `R8` |
| 4 | `strokeWidth` | `FLOAT` | **`XMM3`** |
| 5 | `strokeStyle` | 指针 | **调用前 `[rsp+32]`** |

C++ 声明中的 `strokeStyle = NULL` 只是编译器的默认实参；机器码层面不存在“省略第 5 个参数”。调用者仍须提供一个 8 字节栈槽。被调函数入口后，返回地址又压入 8 字节，所以它在被调方视角位于 `[rsp+40]`。

**② 32 字节影子空间与额外栈参**

每次 COM/API 调用前都必须预留 32 字节影子空间。`DrawRectangle` 还需要额外的第 5 参数槽，因此通用标准帧至少要 `32 + 8 = 40` 字节；`WndProc` 在 `push rbp` 后已经对齐，所以应把帧大小从 32 调整为 **48**（40 向上补到 16 的倍数），并在调用前写：

```asm
    mov     qword [rsp + 32], 0     ; 第 5 参 strokeStyle = NULL
```

当前源码只有 `sub rsp, 32`，且只执行 `xor r9d, r9d`，**没有提供第 5 参数栈槽**。此时 `[rsp+32]` 恰好是保存的旧 `RBP`，并不是 NULL。若某个运行环境看似能画，只能说明该 D2D 实现/路径没有按预期暴露问题，不能把它当作 ABI 正确或可移植的依据。

**③ 16 字节对齐**

普通 `WndProc` 路径：入口 `RSP % 16 == 8` → `push rbp` 后为 0 → 帧大小必须是 16 的倍数。当前 `sub rsp, 32` 的对齐本身正确，但没有给第 5 参数留槽；标准改法是 `sub rsp, 48`。

**④ 非易失寄存器**

`RBX/RBP/RDI/RSI/R12～R15/XMM6～XMM15` 属于被调方保存寄存器。`release_if_nonnull` 只改易失的 `RAX/RCX`，但它没有序言：入口 `RSP % 16 == 8`，直接执行 `COM_CALL` 时 call 点仍是 8，违反对齐规则。当前示例能否运行取决于 `Release` 的实现是否容忍；通用写法应在入口 `sub rsp, 40`、返回前 `add rsp, 40`。第 19 章的 `release_scene` 展示了带标准序言的版本。

当前 `wmain` 还用 `RDI` 配合 `rep stosd` 清零结构体，却没有保存调用者原有的 `RDI`。单次示例通常不会因此立刻出错，但作为由 CRT 调用的普通函数并不完整；可复用写法应保存/恢复 `RDI`，或改用易失寄存器加显式清零循环。

### 3.3 从 MinGW 头文件提取 D2D 图元结构

**D2D1_RECT_F**（`d2dbasetypes.h`）：

```c
typedef struct D2D_RECT_F {
    FLOAT left; FLOAT top; FLOAT right; FLOAT bottom;
} D2D_RECT_F;
```

4 个 `FLOAT`，16 字节。

**D2D1_ELLIPSE**（`d2d1.h` 约 405 行）：

```c
typedef struct D2D1_ELLIPSE {
    D2D1_POINT_2F point;
    FLOAT radiusX;
    FLOAT radiusY;
} D2D1_ELLIPSE;
```

`D2D1_POINT_2F` 是 2 个 `FLOAT`（8 字节），所以：

| 字段 | 偏移 |
|---|---|
| `point.x` | 0 |
| `point.y` | 4 |
| `radiusX` | 8 |
| `radiusY` | 12 |

共 16 字节。

**D2D1_BRUSH_PROPERTIES**（`d2d1.h` 约 392 行）：

```c
typedef struct D2D1_BRUSH_PROPERTIES {
    FLOAT opacity;
    D2D1_MATRIX_3X2_F transform;
} D2D1_BRUSH_PROPERTIES;
```

`D2D1_MATRIX_3X2_F` 是 6 个 `FLOAT`（24 字节），合计 **28 字节**。本章传 `NULL`，表示 `opacity = 1`、单位矩阵。

### 3.4 ID2D1SolidColorBrushVtbl 槽位

```c
typedef struct ID2D1SolidColorBrushVtbl {
    ID2D1BrushVtbl Base;                                   // 槽 0～7
    STDMETHOD_(void, SetColor)(..., const D2D1_COLOR_F*);  // 槽 8
    STDMETHOD_(D2D1_COLOR_F, GetColor)(...);               // 槽 9
} ID2D1SolidColorBrushVtbl;
```

`ID2D1BrushVtbl` = `ID2D1ResourceVtbl`(4 槽) + `SetOpacity/SetTransform/GetOpacity/GetTransform`(4 槽) = 8 槽，所以 `SetColor` 是槽 **8**（`0x40`）。

### 3.5 FLOAT 的位模式

`strokeWidth` 是 `FLOAT`，要用 IEEE-754 单精度位模式传给 `XMM3`。`2.0f` 的位模式是 `0x40000000`：

```text
符号位 0 | 指数 0x80(=128) → 2^(128-127)=2 | 尾数 0 → 1.0 × 2 = 2.0
```

用 `movd xmm3, eax` 把 32 位位模式搬进 `XMM3` 低 32 位。**注意 `movd` 搬的是位模式，不是整数转换**：`movd xmm3, 2` 会把 `0x00000002` 搬进去，解释成浮点几乎是 0（次正规数）。

### 3.6 渲染目标槽位回顾

本章用到的渲染目标槽位：

| 槽 | 方法 | 偏移 |
|---|---|---|
| 8 | `CreateSolidColorBrush` | `0x40` |
| 16 | `DrawRectangle` | `0x80` |
| 17 | `FillRectangle` | `0x88` |
| 21 | `FillEllipse` | `0xA8` |
| 47 | `Clear` | `0x178` |
| 48 | `BeginDraw` | `0x180` |
| 49 | `EndDraw` | `0x188` |

## 4. 实践用例

本章 `d2d_shapes.asm` 创建三个画刷（蓝填充、黄描边、红圆），在窗口里画一个填充矩形、一个描边矩形和一个椭圆。

### 4.1 构建命令

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l d2d_shapes.obj.lst -o d2d_shapes.obj d2d_shapes.asm
gcc -municode -mwindows -o d2d_shapes.exe d2d_shapes.obj -luser32 -ld2d1
```

产物 `d2d_shapes.exe` 为 143078 字节。

### 4.3 objdump 实证（子系统与导入表）

```text
Subsystem               00000002        (Windows GUI)
        DLL Name: d2d1.dll
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
```

GUI 子系统，导入 `d2d1.dll`。**只编译不运行**。手动体验：`.\d2d_shapes.exe`，应看到蓝色填充矩形、黄色描边、右侧红色椭圆，ESC 退出。

### 4.4 `.lst` 摘录

**槽位全景**：

```text
   141                                      COM_CALL rcx, D2D1_RT_BEGIN_DRAW
    61 00000061 FF9080010000        <1>  call qword [rax + (%2) * 8]   ; 0x180 = 48

   146                                      COM_CALL rcx, D2D1_RT_CLEAR
    61 00000078 FF9078010000        <1>  call qword [rax + (%2) * 8]   ; 0x178 = 47

   152                                      COM_CALL rcx, D2D1_RT_FILL_RECTANGLE
    61 00000096 FF9088000000        <1>  call qword [rax + (%2) * 8]   ; 0x88 = 17

   163                                      COM_CALL rcx, D2D1_RT_DRAW_RECTANGLE
    61 000000C0 FF9080000000        <1>  call qword [rax + (%2) * 8]   ; 0x80 = 16

   169                                      COM_CALL rcx, D2D1_RT_FILL_ELLIPSE
    61 000000DE FF90A8000000        <1>  call qword [rax + (%2) * 8]   ; 0xA8 = 21

   175                                      COM_CALL rcx, D2D1_RT_END_DRAW
    61 000000F3 FF9088010000        <1>  call qword [rax + (%2) * 8]   ; 0x188 = 49
```

**FLOAT → XMM3**：

```text
   160 000000B1 B800000040                  mov     eax, 0x40000000         ; 2.0f 的位模式
   161 000000B6 660F6ED8                    movd    xmm3, eax
   162 000000BA 4531C9                      xor     r9d, r9d
```

`660F6ED8`：`66` 是操作数前缀，`0F 6E` 是 `movd xmm, r/m32`，`D8` 的 ModRM 表示目标 `XMM3`、源 `EAX`（reg 字段=3）。

**辅助函数**：

```text
   202 0000012A E8D1FEFFFF                  call    release_if_nonnull
```

`E8D1FEFFFF` 是 `call rel32`，位移 `0xFFFFFED1 = -303`，即向后 303 字节——正好回到函数开头。

## 5. 代码重点讲解

挑出 5 处关键代码，回扣前面的知识点。

**① 创建纯色画刷**

```asm
    mov     rcx, [rel p_rt]
    lea     rdx, [rel fill_color]
    xor     r8d, r8d                ; brushProperties = NULL
    lea     r9,  [rel p_fill]
    COM_CALL rcx, D2D1_RT_CREATE_SOLID_COLOR_BRUSH
```

回扣知识点 3.1/3.6：`CreateSolidColorBrush(this, color, brushProperties, out)` 槽 8，4 个参数全在寄存器。`brushProperties = NULL` 表示 `opacity=1`、单位矩阵。三个画刷分别是填充蓝、描边黄、圆红。

**② FillRectangle（槽 17）**

```asm
    mov     rcx, [rel p_rt]
    lea     rdx, [rel rect_fill]
    mov     r8,  [rel p_fill]
    COM_CALL rcx, D2D1_RT_FILL_RECTANGLE
```

回扣知识点 3.6：槽 17，偏移 `0x88`。`FillRectangle(rect, brush)` 只需前三个参数位置。

**③ DrawRectangle：当前源码与标准写法**

当前源码：

```asm
    mov     rcx, [rel p_rt]
    lea     rdx, [rel rect_fill]
    mov     r8,  [rel p_stroke]
    mov     eax, 0x40000000         ; 2.0f 的位模式
    movd    xmm3, eax
    xor     r9d, r9d                ; 只清 R9，不能代替第 5 个栈参数
    COM_CALL rcx, D2D1_RT_DRAW_RECTANGLE
```

`strokeWidth` 是第 4 个位置的 `FLOAT`，所以走 `XMM3`；`0x40000000` 是 `2.0f` 的 IEEE-754 位模式，`movd` 只搬位、不做整数转换。当前源码的问题是第 5 个 `strokeStyle` 没有写入栈槽。把 `WndProc` 的帧扩为 48 字节后，标准调用应写成：

```asm
    mov     rcx, [rel p_rt]
    lea     rdx, [rel rect_fill]
    mov     r8,  [rel p_stroke]
    mov     eax, 0x40000000
    movd    xmm3, eax               ; 第 4 参
    mov     qword [rsp + 32], 0     ; 第 5 参 strokeStyle = NULL
    COM_CALL rcx, D2D1_RT_DRAW_RECTANGLE
```

这里不再给 `R9` 赋参数，因为第 5 个位置不属于寄存器参数区。

**④ FillEllipse（槽 21）**

```asm
    mov     rcx, [rel p_rt]
    lea     rdx, [rel circle_shape]
    mov     r8,  [rel p_circle]
    COM_CALL rcx, D2D1_RT_FILL_ELLIPSE
```

回扣知识点 3.6：槽 21，偏移 `0xA8`。

**⑤ release_if_nonnull 与释放顺序**

```asm
release_if_nonnull:
    test    rcx, rcx
    jz      .ret
    COM_CALL rcx, IUNKNOWN_RELEASE
.ret:
    ret
```

调用处：

```asm
    mov     rcx, [rel p_fill]
    call    release_if_nonnull      ; 先释放画刷
    ...
    mov     rcx, [rel p_rt]
    call    release_if_nonnull      ; 再释放渲染目标
    ...
    mov     rcx, [rel p_factory]
    call    release_if_nonnull      ; 最后释放工厂
```

回扣知识点 3.1/3.2④：画刷由渲染目标创建，先释放画刷再释放渲染目标最后工厂。注意这个叶子版 `release_if_nonnull` 的 `call` 点不对齐（教学反例），第 19 章会修正。

## 6. 常见坑

1. **`strokeWidth` 写进 `R9`**：第 4 个位置的类型是 `FLOAT`，必须走 `XMM3`；写错位置会导致线宽和后续参数都不符合被调方预期。
2. **把 `strokeStyle` 放进 `R9`**：它仍是第 5 个位置，必须写调用前 `[rsp+32]`。当前源码在这里是教学反例，不能照抄为通用 ABI 模板。
3. **只 `sub rsp, 32` 又写 `[rsp+32]`**：这会覆盖保存的旧 `RBP`。使用第 5 参数前必须扩大帧；本章 `WndProc` 可改为 `sub rsp, 48`。
4. **`movd xmm3, 2`**：`movd` 搬的是**位模式**，不是整数转换。`2` 的位模式是 `0x00000002`，解释成浮点几乎是 0（次正规数）。整数 2 转浮点应使用 `cvtsi2ss`，常量 `2.0f` 的位模式才是 `0x40000000`。
5. **画刷创建后不检查 HRESULT**：当前源码连续创建三个画刷后不检查返回值，并假定工厂、渲染目标和画刷都创建成功。通用写法应在每次调用后用 `test eax,eax; js 失败路径`，失败时按“已创建资源的逆序”清理。
6. **先释放渲染目标再释放画刷**：资源依赖关系不清晰，容易在后续扩展成设备相关资源时出错。统一按“画刷 → 渲染目标 → 工厂”释放，并在释放后把全局指针清零。
7. **`release_if_nonnull` 叶子版与未保存的 `RDI`**：前者 call 点未对齐，后者破坏调用者的非易失寄存器。当前示例依赖具体调用环境，通用库代码必须修正。
8. **把 `EndDraw` 当 `void`**：当前源码没有检查设备丢失，也没有完整 `BeginPaint/EndPaint` 配对；它只演示最小 D2D 调用序列。第 19 章加入 `D2DERR_RECREATE_TARGET` 处理，但完整 Win32 绘图消息仍应按验证区域的生命周期处理。
9. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item d2d_shapes.exe,d2d_shapes.obj,d2d_shapes.obj.lst`。

## 7. 练习

1. 把 `0x40000000` 改成 `0x40400000`（3.0f），观察描边变粗。
2. 创建一个 `D2D1_BRUSH_PROPERTIES`，设 `opacity = 0.5`，传给填充画刷，观察半透明效果。
3. 用 `SetColor`（槽 8）在 `WM_TIMER` 里循环改圆画刷颜色。
4. 把 `FillEllipse` 的半径改成 120/40，观察椭圆形状变化。
5. 在 `.lst` 里找 `movd xmm3, eax` 的 4 字节机器码，与 `movd xmm0, eax` 对比编码差异。

## 8. 下一章预览

第 19 章把本章内容组装成一个真正的"动画窗口"：

- `WM_SIZE` 里调用 `ID2D1HwndRenderTarget::Resize`（槽 58）；
- `SetTimer` + `WM_TIMER` 驱动动画；
- `cvtsi2ss` 把整数帧号转成浮点坐标；
- `EndDraw` 检测 `D2DERR_RECREATE_TARGET` 并重建资源；
- `release_scene` / `create_render_target` 两个标准序言的辅助函数。
