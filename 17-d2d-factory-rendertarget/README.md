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
- 为什么 `rt_props` 全部填 0 表示默认配置，却不保证一定走硬件渲染？
- 槽 14 和 `0x70` 是什么关系？
- `Clear` 的参数为什么是 `D2D1_COLOR_F*` 而不是 `COLORREF`？

## 2. 前置 / 项目结构

```text
nasm-learn/
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

工厂**不是线程级单例**：每次成功调用 `D2D1CreateFactory` 都会向调用者返回一个工厂接口引用，程序可以创建多个工厂。`SINGLE_THREADED` 描述的是该工厂及其派生资源的线程使用约定，不是“全线程只能存在一个工厂”。

渲染目标绑定具体窗口和设备相关资源。程序应在不再使用派生资源后，按“先子后父”的顺序清理：画刷等资源 → 渲染目标 → 工厂。这是清晰的资源依赖顺序；每个 COM 接口仍按自己的引用计数独立释放，不能笼统地说“先释放工厂就必然让子对象内部指针失效”。

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

`WndProc` 把状态放在 `.bss` 全局变量里（`p_factory`、`p_rt`），除帧指针 `RBP` 外不修改其他非易失寄存器。`COM_CALL` 本身用 `RAX` 查虚表，`RAX` 是易失寄存器；被调用的方法也必须按 ABI 保住非易失寄存器。

但 **`wmain` 并不满足“完全不碰非易失寄存器”**：它两次用 `lea rdi,...; rep stosd` 清零结构体，`RDI` 会被修改却没有保存恢复。这与第 13～15 章的同类问题一样，是当前源码的 ABI 瑕疵，不应复制到通用函数。可保存恢复 `RDI`，或改用易失寄存器配合显式清零。

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

全部填 0 的含义：`type=0`（`DEFAULT`，由 Direct2D 选择硬件或软件实现）、`format=0`（`DXGI_FORMAT_UNKNOWN`，由系统决定）、`dpiX/dpiY=0`（使用默认桌面显示密度，下一小节解释）、`usage=0`、`minLevel=0`。准确说法是“**默认渲染目标配置**”，不是保证一定使用硬件渲染；硬件不可用或配置不支持时可能使用软件路径。

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

4 个 `FLOAT`，16 字节，每个通道通常位于 `0.0～1.0`，顺序是 **R、G、B、A**，与 GDI 的整数 `0x00BBGGRR` 完全不同。`A` 是 alpha，表示不透明度：`1.0` 为完全不透明，`0.0` 为完全透明；具体透明效果还取决于渲染目标和合成场景，不能把 HWND 当成自动支持透明窗口。

用 `istruc` 在 `.data` 里初始化时，`dd 0.12` 写的是 IEEE-754 二进制32位浮点位模式，不是整数 `0` 或 `12`。例如：

```asm
dd 1.0    ; 数值位模式 0x3F800000，内存字节 00 00 80 3F
dd 0.5    ; 数值位模式 0x3F000000，内存字节 00 00 00 3F
dd 1      ; 整数位模式 0x00000001；当成 FLOAT 读取时不是 1.0
```

以 `1.0` 为例：符号位为 0，指数为 127（即 `0x7F`），尾数有效位为 0，拼成 `0 01111111 00000000000000000000000`，就是 `0x3F800000`。目前不必手算每个小数，但必须区分 `dd 1.0` 和 `dd 1`。

#### 3.3.1 像素与 DIP：两套单位不要混写

`hwnd_props.pixelSize` 使用**物理像素**，与窗口客户区的像素尺寸对应；后续 `FillRectangle`、坐标、半径等 Direct2D 绘图值通常使用 **DIP**（device-independent pixel，设备无关像素）。**DPI**（dots per inch）在这里表示显示缩放密度，96 DPI 是本节换算的基准。

换算关系是：

```text
物理像素 = DIP × DPI / 96
DIP      = 物理像素 × 96 / DPI
```

在 96 DPI 下，100 DIP = 100 像素；在 144 DPI 下，缩放倍率为 `144/96=1.5`，所以 100 DIP = 150 像素。

本章 `Clear` 没有坐标参数，因此暂时不用传 DIP；但 `pixelSize.width=640`、`pixelSize.height=480` 仍是像素。另一个现实限制是：`CreateWindowExW` 的 640×480 是**整个窗口**的初始尺寸，包含标题栏和边框，不等于客户区恰好 640×480。本章源码又把这两个值直接用于渲染目标，且没有处理后续 `WM_SIZE/Resize`，所以尺寸并不严格同步；第 19 章改为在 `WM_SIZE` 中从 `lParam` 取出客户区宽高，再调用 `Resize`。`GetClientRect` 是另一种常见的客户区尺寸获取方式。

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

`ID2D1RenderTarget` 基接口占 57 个槽（0～56）。`ID2D1HwndRenderTarget` 随后先追加 `CheckWindowState`（槽 57），再追加 `Resize`（槽 58，第 19 章用）。数槽时不能漏掉中间的 `CheckWindowState`，否则会把 `Resize` 错算成 57。

### 3.5 D2D1CreateFactory

`D2D1CreateFactory(factoryType, riid, pFactoryOptions, ppIFactory)`：

- `factoryType`：`D2D1_FACTORY_TYPE_SINGLE_THREADED=0`，表示只从单线程访问工厂及其派生资源，不为多线程并发访问提供内部同步；`MULTI_THREADED` 则允许受支持的多线程使用，但会有同步开销；
- `riid`：`IID_ID2D1Factory`，说明输出接口类型；
- `pFactoryOptions`：传 `NULL` 用默认选项；
- `ppIFactory`：输出工厂接口指针变量的地址，本例为 `&p_factory`。

成功后返回 `S_OK` 并取得一个需要 `Release` 的工厂引用。Direct2D 使用 COM 接口和调用约定，但这个创建流程不要求像第 16 章那样先调用 `CoInitializeEx`；“采用 COM ABI”不等于“所有库的初始化函数都相同”。

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

三个方法的汇编参数和返回值并不相同：

| 方法 | 参数 | 返回 |
|---|---|---|
| `BeginDraw` | `RCX=this` | `void`，不把 `EAX` 当 `HRESULT` |
| `Clear` | `RCX=this、RDX=&D2D1_COLOR_F` | `void` |
| `EndDraw` | `RCX=this、RDX=tag1 或 NULL、R8=tag2 或 NULL` | `EAX=HRESULT` |

`EndDraw` 的两个可选输出参数用于接收绘图诊断标签，本章都传 `NULL`。`Clear` 接受 RGBA 浮点颜色结构的地址，不是 GDI 的整数 `COLORREF`。

#### 3.6.1 BeginDraw/EndDraw 不等于 BeginPaint/EndPaint

这两组名字很像，但层级不同：

- `BeginDraw/EndDraw` 是 **Direct2D 帧边界**，管理渲染目标的绘制与呈现；
- `BeginPaint/EndPaint` 是 **Win32 WM_PAINT 边界**，取得绘制信息并把窗口更新区域标记为有效。

只调用 D2D 的 `BeginDraw/EndDraw`，不会自动完成 Win32 的 `BeginPaint/EndPaint` 语义。当前源码在 `WM_PAINT` 中没有调用后者，也没有 `ValidateRect`，`p_rt==NULL` 时甚至直接返回；它是只突出 D2D 槽位的简化示例，不是完整的消息处理模板。通用结构应先处理 Win32 绘制边界，再在其中执行 D2D 帧，或按窗口逻辑明确验证更新区域，避免更新区一直无效而反复请求绘制。

#### 3.6.2 EndDraw 的 HRESULT 与设备丢失

`EndDraw` 可能失败，其中 `D2DERR_RECREATE_TARGET=0x8899000C` 表示当前渲染目标相关的设备资源需要重建。显示设备重置、驱动状态变化等情况都可能让旧目标不能继续使用。通用处理流程是：

```text
EndDraw 返回 D2DERR_RECREATE_TARGET
    → 停止使用旧渲染目标
    → Release 画刷、位图等依赖该目标的资源
    → Release 旧渲染目标并清空全局指针
    → 用仍有效的工厂重新创建渲染目标及设备相关资源
    → 下一帧重新绘制
```

工厂与渲染目标的生命周期不同，通常不需要因为这一个错误就把整个进程退出。本章源码忽略了 `EndDraw` 返回值，也没有重建路径；第 19 章会继续讨论 Resize 和资源重建。学习本章时至少要能识别：“`BeginDraw/EndDraw` 成对”并不包含“所有错误都已处理”。

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

回扣知识点 3.3：28/4 = 7 个 dword，24/4 = 6 个 dword。`rep stosd` 一次清零整个结构体，`rt_props` 全 0 表示默认配置，由 Direct2D 选择实现。还要注意 `RDI` 会随 `stosd` 改变；当前 `wmain` 未保存它，是源码中的非易失寄存器瑕疵。

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

回扣知识点 3.6：`BeginDraw`/`EndDraw` 成对，`Clear` 参数是 `D2D1_COLOR_F*`。`.lst` 里三个偏移 `0x180/0x178/0x188` 对应槽 48/47/49。只有 `EndDraw` 在这里返回需要检查的 `HRESULT`；当前源码未检查，也未处理 `D2DERR_RECREATE_TARGET`。此外，D2D 帧边界不能替代 Win32 的 `BeginPaint/EndPaint`。

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

回扣知识点 3.1：这里按“渲染目标 → 工厂”的依赖顺序清理，并把全局指针清零，最后 `PostQuitMessage`。每个接口都只对自己的成功引用调用一次槽 2；不要把清理顺序解释成“父对象 Release 后子对象一定立即悬空”。

当前 `.fail_d2d` 失败出口只返回退出码 3，没有统一释放已经创建的工厂、渲染目标或窗口。短进程退出时系统会回收进程资源，但通用程序仍应使用统一清理路径，尤其当代码被嵌入长期运行的程序时。

## 6. 常见坑

1. **`rt_props` 没有初始化**：枚举、浮点和格式字段会是不可预测的值，创建可能失败或产生非预期配置。全 0 是本章明确选择的默认配置，不是“内存天生为 0”。
2. **把窗口外部尺寸当客户区像素尺寸**：`CreateWindowExW` 的 640×480 包含非客户区；本章硬编码的渲染目标尺寸并不严格等于客户区，后续还需要 `GetClientRect` 与 `Resize`。
3. **工厂创建失败却继续调用**：`p_factory` 可能仍为 NULL，`COM_CALL` 会在 `mov rax,[rcx]` 时访问空地址。先检查 `HRESULT`，再检查输出。通用 `HRESULT` 模板用 `test eax,eax; js .fail`；源码的 `jnz` 只适合这里明确以 `S_OK=0` 为唯一成功结果的调用，不是通用判断宏。
4. **忘记 `p_rt` 判空**：窗口创建期间、D2D 初始化失败或资源释放后都可能收到消息。当前源码已有判空，但空路径还没有处理 Win32 更新区验证。
5. **只用 D2D 的 BeginDraw/EndDraw 处理 WM_PAINT**：它不会自动替代 `BeginPaint/EndPaint` 或 `ValidateRect`，当前示例省略了这一层。
6. **忽略 EndDraw 的设备丢失**：`D2DERR_RECREATE_TARGET` 需要释放并重建渲染目标及设备相关资源，不能只把窗口关掉。
7. **把 DIP 当物理像素**：`pixelSize` 用像素，后续图形坐标通常用 DIP；DPI 缩放时两者不再一一相等。
8. **把 `dd 1` 当浮点 `1.0`**：前者位模式是整数值 1，后者才是 `0x3F800000`。
9. **忘了 `-ld2d1`**：链接报 `undefined reference to D2D1CreateFactory`。
10. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item d2d_target.exe,d2d_target.obj,d2d_target.obj.lst`。

## 7. 练习

1. 把 `rt_props.type` 改成 `D2D1_RENDER_TARGET_TYPE_SOFTWARE`（2），重新编译。运行时画面还在吗？（软件渲染只是换实现，仍然可见。）
2. 在 `WM_SIZE` 里打印 `g_width/g_height`，和 `pixelSize` 比较，确认窗口创建时的初始值。
3. 把 `Clear` 颜色改成 `(1.0, 0.0, 0.0, 1.0)` 全红，再分别改 RGB 通道并观察结果。alpha 的效果取决于渲染目标和合成方式，不要假设普通 HWND 因此就变成透明窗口。
4. 在 `.lst` 里找 `mov ecx, D2D1_RENDER_TARGET_PROPERTIES_size / 4`，确认立即数是 7。
5. 用 GDB 在 `call qword [rax + 0x70]` 前 `si`，`info registers rax rcx rdx r8`，`x/4gx $rax` 查看工厂虚表。

## 8. 下一章预览

第 18 章开始画图元：

- `CreateSolidColorBrush`（槽 8）与 `D2D1_COLOR_F`；
- `FillRectangle` / `DrawRectangle` / `FillEllipse`；
- **FLOAT 参数走 `XMM3`** 这条容易忘的规则；
- 画刷、渲染目标、工厂的完整释放顺序。
