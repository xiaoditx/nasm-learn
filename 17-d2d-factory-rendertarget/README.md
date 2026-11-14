# 第 17 章：Direct2D 工厂与 HwndRenderTarget

> 第一次真正用 Direct2D：创建工厂、创建窗口渲染目标、清屏。
> 本章源码：[d2d_target.asm](d2d_target.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[d2d_target.obj.lst](d2d_target.obj.lst)

## 1. 本章目标

- 调用 `D2D1CreateFactory` 创建 `ID2D1Factory`；
- 从 `d2d1.h` 的 `ID2D1FactoryVtbl` **数出** `CreateHwndRenderTarget` 是槽 14；
- 从 `d2d1.h` 提取 `D2D1_RENDER_TARGET_PROPERTIES`（28 字节）与 `D2D1_HWND_RENDER_TARGET_PROPERTIES`（24 字节）；
- 在 `WM_PAINT` 里完成 `BeginDraw` → `Clear` → `EndDraw`；
- 在 `WM_DESTROY` 里按"渲染目标 → 工厂"的顺序 `Release`。

跑通后你应该能回答：

- `D2D1CreateFactory` 的 4 个参数各是什么？
- 为什么 `rt_props` 全部填 0 就是"默认硬件渲染"？
- 槽 14 和 `0x70` 是什么关系？
- `Clear` 的参数为什么是 `D2D1_COLOR_F*` 而不是 `COLORREF`？

## 2. 前置 / 项目结构

```text
masm-learn/
├── common.asm                      D2D 结构体、COM_CALL、槽位常量
└── 17-d2d-factory-rendertarget/
    ├── Makefile
    ├── d2d_target.asm
    ├── README.md
    └── d2d_target.obj.lst         make 后生成
```

只有 `.asm` 源码。链接 `user32` 与 `d2d1`，产物依赖 `d2d1.dll`。本章是 GUI 程序，**只编译不运行**，用 `objdump -p` 验证子系统与导入表。

## 3. 知识点讲解

### 3.1 Direct2D 的对象层级

Direct2D 的绘制需要三层对象：

```text
ID2D1Factory              工厂（顶层，创建渲染目标）
    │
    ▼
ID2D1HwndRenderTarget     窗口渲染目标（绑定 HWND，执行绘制）
    │
    ├─ BeginDraw()        开始绘制
    ├─ Clear(color)       清屏
    ├─ EndDraw()          结束绘制，呈现到窗口
    │
    ▼
画刷 / 几何图形等资源     （第 18 章）
```

工厂是线程级的单例，渲染目标绑定具体窗口。释放顺序是"先子后父"：渲染目标 → 工厂。

### 3.2 Windows x64 ABI 四件套

**① 前四个参数：RCX / RDX / R8 / R9**

`D2D1CreateFactory` 有 4 个参数，全部走寄存器：

| 参数 | C 签名 | 寄存器 |
|---|---|---|
| 1 | `D2D1_FACTORY_TYPE factoryType` | `ECX` |
| 2 | `REFIID riid` | `RDX` |
| 3 | `const D2D1_FACTORY_OPTIONS *pFactoryOptions` | `R8` |
| 4 | `void **ppIFactory` | `R9` |

`ID2D1Factory::CreateHwndRenderTarget` 也是 4 个参数（`this` + 3 个指针），同样全部走寄存器：

```text
RCX = this
RDX = &rt_props
R8  = &hwnd_props
R9  = &p_rt
```

**② 32 字节影子空间**

`WndProc`、`wmain` 的 `sub rsp, 32` 就是影子空间。本章的 D2D 方法调用都没有第 5 个参数，因此不需要额外的栈槽。

**③ 16 字节对齐**

`wmain` 分配 128 字节（32 影子 + 64 `CreateWindowExW` 栈参数 + 32 本地槽），`push rbp` 后 `sub rsp, 128` 仍满足 `% 16 == 0`。

**④ 非易失寄存器**

本章所有状态都放在 `.bss` 全局变量里（`p_factory`、`p_rt`），`WndProc` 不碰非易失寄存器，因此只有 `push rbp / leave`。`COM_CALL` 只破坏 `RAX`——它是易失寄存器，调用者不需要保存。

### 3.3 从 MinGW 头文件提取 D2D 结构体

**D2D1_RENDER_TARGET_PROPERTIES**（`d2d1.h` 约 453 行）：

```c
typedef struct D2D1_RENDER_TARGET_PROPERTIES {
    D2D1_RENDER_TARGET_TYPE type;
    D2D1_PIXEL_FORMAT       pixelFormat;
    FLOAT                   dpiX;
    FLOAT                   dpiY;
    D2D1_RENDER_TARGET_USAGE usage;
    D2D1_FEATURE_LEVEL      minLevel;
} D2D1_RENDER_TARGET_PROPERTIES;
```

`D2D1_PIXEL_FORMAT` 是 8 字节（`format` + `alphaMode` 各 4 字节），所以：

| 字段 | 偏移 | 大小 |
|---|---|---|
| `type` | 0 | 4 |
| `pixelFormat.format` | 4 | 4 |
| `pixelFormat.alphaMode` | 8 | 4 |
| `dpiX` | 12 | 4 |
| `dpiY` | 16 | 4 |
| `usage` | 20 | 4 |
| `minLevel` | 24 | 4 |
| 合计 | | **28** |

全部填 0 的含义：`type=0`（默认，自动选硬件/软件）、`format=0`（`DXGI_FORMAT_UNKNOWN`，由系统决定）、`dpi=0`（用系统 DPI）、`usage=0`、`minLevel=0`。这就是"默认硬件渲染"。

**D2D1_HWND_RENDER_TARGET_PROPERTIES**（`d2d1.h` 约 420 行）：

```c
typedef struct D2D1_HWND_RENDER_TARGET_PROPERTIES {
    HWND             hwnd;
    D2D1_SIZE_U      pixelSize;
    D2D1_PRESENT_OPTIONS presentOptions;
} D2D1_HWND_RENDER_TARGET_PROPERTIES;
```

| 字段 | 偏移 | 大小 |
|---|---|---|
| `hwnd` | 0 | 8 |
| `pixelSize.width` | 8 | 4 |
| `pixelSize.height` | 12 | 4 |
| `presentOptions` | 16 | 4 |
| 尾部填充 | 20 | 4 |
| 合计 | | **24** |

**D2D1_COLOR_F**：

```c
typedef struct D2D1_COLOR_F {
    FLOAT r; FLOAT g; FLOAT b; FLOAT a;
} D2D1_COLOR_F;
```

4 个 `FLOAT`，16 字节。用 `istruc` 在 `.data` 里直接初始化，`dd 0.12` 会写成 IEEE-754 单精度位模式。

### 3.4 数虚表槽位

这是本章的核心技能。`d2d1.h` 里每个接口都有一个 `*Vtbl` 结构体，**字段顺序就是槽位顺序**。

**ID2D1FactoryVtbl**（1635～1652 行）：

```c
typedef struct ID2D1FactoryVtbl {
    IUnknownVtbl Base;                         // 槽 0,1,2

    STDMETHOD(ReloadSystemMetrics)(...);       // 槽 3
    STDMETHOD_(void, GetDesktopDpi)(...);      // 槽 4
    STDMETHOD(CreateRectangleGeometry)(...);   // 槽 5
    STDMETHOD(CreateRoundedRectangleGeometry); // 槽 6
    STDMETHOD(CreateEllipseGeometry);          // 槽 7
    STDMETHOD(CreateGeometryGroup);            // 槽 8
    STDMETHOD(CreateTransformedGeometry);      // 槽 9
    STDMETHOD(CreatePathGeometry);             // 槽 10
    STDMETHOD(CreateStrokeStyle);              // 槽 11
    STDMETHOD(CreateDrawingStateBlock);        // 槽 12
    STDMETHOD(CreateWicBitmapRenderTarget);    // 槽 13
    STDMETHOD(CreateHwndRenderTarget);         // 槽 14  ← 本章用
    STDMETHOD(CreateDxgiSurfaceRenderTarget);  // 槽 15
    STDMETHOD(CreateDCRenderTarget);           // 槽 16
} ID2D1FactoryVtbl;
```

`IUnknownVtbl` 占 3 槽（`QueryInterface/AddRef/Release`），所以 `CreateHwndRenderTarget` = **14**，偏移 `14 * 8 = 112 = 0x70`。

**ID2D1RenderTargetVtbl 中本章用到的槽**：

基类 `ID2D1ResourceVtbl` = `IUnknownVtbl`(3) + `GetFactory`(1) = 4 槽。从槽 4 开始数：

| 槽 | 方法 | 偏移 |
|---|---|---|
| 47 | `Clear` | `0x178` |
| 48 | `BeginDraw` | `0x180` |
| 49 | `EndDraw` | `0x188` |

`ID2D1HwndRenderTargetVtbl` 在基类 57 槽（0～56）之后追加 `Resize`（槽 58，第 19 章用）。

### 3.5 D2D1CreateFactory

`D2D1CreateFactory(factoryType, riid, pFactoryOptions, ppIFactory)`：

- `factoryType`：`D2D1_FACTORY_TYPE_SINGLE_THREADED=0`，单线程工厂足够给一个窗口用；多线程工厂每调用一次都要加锁；
- `riid`：`IID_ID2D1Factory`；
- `pFactoryOptions`：传 `NULL` 用默认选项；
- `ppIFactory`：输出工厂指针。

### 3.6 渲染目标的绘制流程

```text
WM_PAINT
    │
    ▼
BeginDraw()                    槽 48，开始帧
    │
    ▼
Clear(&D2D1_COLOR_F)           槽 47，用纯色清屏
    │
    ▼
（绘制图元，第 18 章）
    │
    ▼
EndDraw(NULL, NULL)            槽 49，结束帧并呈现
```

`BeginDraw` 和 `EndDraw` 必须成对；`EndDraw()` 的两个参数是 `D2D1_TAG*`，可传 `NULL`。`Clear` 的参数是 `D2D1_COLOR_F*`（RGBA 浮点颜色），不是 GDI 的 `COLORREF`。

## 4. 实践用例

本章 `d2d_target.asm` 创建 D2D 工厂和窗口渲染目标，在 `WM_PAINT` 里用深蓝灰色清屏，`WM_DESTROY` 里按顺序释放。

### 4.1 构建命令

```powershell
make
```

### 4.2 真实编译输出

```text
nasm -f win64 -l d2d_target.obj.lst -o d2d_target.obj d2d_target.asm
gcc -municode -mwindows -o d2d_target.exe d2d_target.obj -luser32 -ld2d1
```

产物 `d2d_target.exe` 为 142178 字节。

### 4.3 objdump 实证（子系统与导入表）

```text
Subsystem               00000002        (Windows GUI)
        DLL Name: d2d1.dll
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
```

GUI 子系统，导入 `d2d1.dll`（Direct2D）和 `USER32.dll`。**只编译不运行**。手动体验：`.\d2d_target.exe`，窗口背景是深蓝灰色（`0.12/0.16/0.22`），ESC 退出。

### 4.4 `.lst` 摘录

**D2D1CreateFactory**：

```text
   220 0000020F 31C9                        xor     ecx, ecx
   221 00000211 488D15(68000000)            lea     rdx, [rel iid_d2d1factory]
   222 00000218 4531C0                      xor     r8d, r8d
   223 0000021B 4C8D0D(BC000000)            lea     r9,  [rel p_factory]
   224 00000222 E8(00000000)                call    D2D1CreateFactory
```

**槽 14 的机器码**：

```text
   250                                      COM_CALL rcx, FACTORY_CREATE_HWND_RENDER_TARGET
    60 0000028A 488B01              <1>  mov rax, [%1]
    61 0000028D FF5070              <1>  call qword [rax + (%2) * 8]
```

`FF5070` = `call qword [RAX + 0x70]`，`0x70 = 112 = 14 * 8`。这条机器码就是"槽位表"的最终证据。

**BeginDraw / Clear / EndDraw**：

```text
    95                                      COM_CALL rcx, RT_BEGIN_DRAW
    60 00000046 488B01              <1>  mov rax, [%1]
    61 00000049 FF9080010000        <1>  call qword [rax + (%2) * 8]

   100                                      COM_CALL rcx, RT_CLEAR
    61 00000060 FF9078010000        <1>  call qword [rax + (%2) * 8]

   106                                      COM_CALL rcx, RT_END_DRAW
    61 00000075 FF9088010000        <1>  call qword [rax + (%2) * 8]
```

三个偏移 `0x180 / 0x178 / 0x188` 分别对应 48 / 47 / 49。`FF90` 表示 `call qword [RAX + disp32]`。

**Release**：

```text
   135                                      COM_CALL rcx, IUNKNOWN_RELEASE
    61 000000B4 FF5010              <1>  call qword [rax + (%2) * 8]
```

`FF5010` = `[RAX + 0x10]`，`0x10 = 16 = 2 * 8`。

## 5. 代码重点讲解

挑出 5 处关键代码，回扣前面的知识点。

**① D2D1CreateFactory**

```asm
    xor     ecx, ecx                          ; D2D1_FACTORY_TYPE_SINGLE_THREADED
    lea     rdx, [rel iid_d2d1factory]
    xor     r8d, r8d                          ; pFactoryOptions = NULL
    lea     r9,  [rel p_factory]
    call    D2D1CreateFactory
```

回扣知识点 3.5：4 个参数全在寄存器。单线程工厂足够一个窗口用。`IID_ID2D1Factory = {06152247-6F50-465A-9245-118BFD3B6007}`。

**② 清零两个属性结构体**

```asm
    lea     rdi, [rel rt_props]
    xor     eax, eax
    mov     ecx, D2D1_RENDER_TARGET_PROPERTIES_size / 4      ; 7
    rep     stosd

    lea     rdi, [rel hwnd_props]
    xor     eax, eax
    mov     ecx, D2D1_HWND_RENDER_TARGET_PROPERTIES_size / 4 ; 6
    rep     stosd
```

回扣知识点 3.3：28/4 = 7 个 dword，24/4 = 6 个 dword。`rep stosd` 一次清零整个结构体。`rt_props` 全 0 就是"默认硬件渲染"。

**③ 创建渲染目标（槽 14）**

```asm
    mov     rcx, [rel p_factory]
    lea     rdx, [rel rt_props]
    lea     r8,  [rel hwnd_props]
    lea     r9,  [rel p_rt]
    COM_CALL rcx, FACTORY_CREATE_HWND_RENDER_TARGET
```

回扣知识点 3.4：`COM_CALL` 展开为 `mov rax, [rcx]` + `call qword [rax + 14*8]`。`.lst` 里 `FF5070` 证明偏移是 `0x70 = 14*8`。

**④ WM_PAINT：BeginDraw → Clear → EndDraw**

```asm
    mov     rcx, [rel p_rt]
    COM_CALL rcx, RT_BEGIN_DRAW              ; 槽 48

    mov     rcx, [rel p_rt]
    lea     rdx, [rel clear_color]
    COM_CALL rcx, RT_CLEAR                   ; 槽 47

    mov     rcx, [rel p_rt]
    xor     edx, edx
    xor     r8d, r8d
    COM_CALL rcx, RT_END_DRAW                ; 槽 49
```

回扣知识点 3.6：`BeginDraw`/`EndDraw` 成对，`Clear` 参数是 `D2D1_COLOR_F*`。`.lst` 里三个偏移 `0x180/0x178/0x188` 对应槽 48/47/49。

**⑤ 释放顺序**

```asm
.on_destroy:
    mov     rcx, [rel p_rt]
    COM_CALL rcx, IUNKNOWN_RELEASE
    mov     qword [rel p_rt], 0
    ...
    mov     rcx, [rel p_factory]
    COM_CALL rcx, IUNKNOWN_RELEASE
```

回扣知识点 3.1：先释放渲染目标，再释放工厂，最后 `PostQuitMessage`。顺序反了不会立刻崩，但会让 `p_rt` 持有已失效的工厂引用。

## 6. 常见坑

1. **`rt_props` 没有清零**：`type/usage/minLevel` 里是垃圾值，`CreateHwndRenderTarget` 返回 `E_INVALIDARG`。
2. **`pixelSize` 与窗口客户区不一致**：图像被拉伸；窗口一创建就 `WM_SIZE`，可以用实际宽高（第 19 章会做）。
3. **工厂创建失败却继续调用**：`p_factory = NULL`，`COM_CALL` 会在 `mov rax, [rcx]` 时访问 0 地址崩溃。必须 `test eax, eax` / `jnz .fail_d2d`。
4. **`WM_PAINT` 里没有 `p_rt` 判空**：窗口销毁后再收到重绘会崩。
5. **忘了 `-ld2d1`**：链接报 `undefined reference to D2D1CreateFactory`。
6. **把 `Clear` 当成 `FillRectangle`**：`Clear` 不接受画刷，参数是 `D2D1_COLOR_F*`。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item d2d_target.exe,d2d_target.obj,d2d_target.obj.lst`。

## 7. 练习

1. 把 `rt_props.type` 改成 `D2D1_RENDER_TARGET_TYPE_SOFTWARE`（2），重新编译。运行时画面还在吗？（软件渲染只是换实现，仍然可见。）
2. 在 `WM_SIZE` 里打印 `g_width/g_height`，和 `pixelSize` 比较，确认窗口创建时的初始值。
3. 把 `Clear` 颜色改成 `(1.0, 0, 0, 1.0)` 全红，观察 alpha 参数是否影响窗口（HWND 渲染目标忽略 alpha）。
4. 在 `.lst` 里找 `mov ecx, D2D1_RENDER_TARGET_PROPERTIES_size / 4`，确认立即数是 7。
5. 用 GDB 在 `call qword [rax + 0x70]` 前 `si`，`info registers rax rcx rdx r8`，`x/4gx $rax` 查看工厂虚表。

## 8. 下一章预览

第 18 章开始画图元：

- `CreateSolidColorBrush`（槽 8）与 `D2D1_COLOR_F`；
- `FillRectangle` / `DrawRectangle` / `FillEllipse`；
- **FLOAT 参数走 `XMM3`** 这条容易忘的规则；
- 画刷、渲染目标、工厂的完整释放顺序。
