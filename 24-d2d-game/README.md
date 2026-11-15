# 第 24 章：纯汇编 Direct2D 小游戏 —— 弹球打砖块（零 CRT）

> 批次 D 收官之作。把第 19 章的 D2D 综合窗口、第 22 章的无 CRT 入口、第 21 章的 ld 直连全部合体：
> 一个**只有 3 个 DLL 依赖**（KERNEL32/USER32/d2d1）的完整可玩游戏。
> 本章源码：[breakout.asm](breakout.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[breakout.obj.lst](breakout.obj.lst)

## 1. 本章目标

- 在零 CRT 的 `_start` 里完成"窗口 + D2D 工厂 + 渲染目标 + 定时器 + 消息循环"全套启动流程；
- 用 SSE 标量浮点指令（`movss/addss/subss/mulss/comiss/cvtsi2ss`）实现游戏物理：位置积分、AABB 碰撞；
- 掌握"**WM_TIMER 心跳 + 按键状态位**"的游戏循环结构（而非"按一下走一步"）；
- 最终验证：一个游戏，真的可以不要 CRT。

本章**只编译不运行**（GUI 程序，弹窗会阻塞）。所有结论用 PE 头、导入表与清单文件验证。

跑通后你应该能回答：

- 为什么游戏用 `WM_KEYDOWN/WM_KEYUP` 维护"按键状态"，而不是在 `WM_KEYDOWN` 里直接移动挡板？
- `comiss` 之后为什么用 `ja/jae/jb/jbe`（无符号跳转）而不是 `jg/jl`？
- `[rel bricks + rbx*4]` 为什么汇编不过？正确写法是什么？
- `D2DERR_RECREATE_TARGET` 在本章哪条路径上触发，怎么恢复？

## 2. 前置 / 项目结构

前置：第 18～19 章的浮点参数与 D2D 场景管理、第 22 章的无 CRT 窗口。本章新增的是游戏状态更新、碰撞判断和浮点比较，不再重复讲解窗口或 COM 的创建过程。

```text
nasm-learn/
├── common.asm              新增：WM_KEYUP、VK_LEFT/UP/RIGHT/DOWN
└── 24-d2d-game/
    ├── Makefile            -luser32 -lkernel32 -ld2d1
    ├── breakout.asm        ~700 行：_start + WndProc + update_game + draw_scene
    ├── README.md
    └── breakout.obj.lst    make 后生成
```

## 3. 知识点讲解

### 3.1 ABI 复习：多个函数分别检查栈帧

第 06、18、20、22 章已经讲过这些规则。这里只核对本章各函数的保存寄存器与栈帧，不把整节当作新知识。

1. **参数**：`RCX/RDX/R8/R9`，第 5 个起走栈。本章栈参大户仍是 `CreateWindowExW`（后 8 参，`[rsp+32..88]`）。
2. **影子空间**：每个 `call` 前 32 字节。COM 调用（`COM_CALL` 宏展开成 `call qword [rax+slot*8]`）同样受 ABI 约束。
3. **对齐**：`_start` 入口 `%16==8` → `sub rsp, 104`（推导同第 22 章：32 影子 + 64 栈参 + 8 补齐）；`update_game` 用 `push rbp + push rbx + sub rsp, 40`（8+40=48，凑齐 16 倍数）；`draw_scene` 用 `push rbp + push rbx + push rsi + sub rsp, 48`。**每多 push 一个非易失寄存器，帧大小就要重新凑齐。**
4. **非易失寄存器**：`update_game`/`draw_scene` 用 `RBX` 当循环计数器，后者用 `RSI` 持砖块数组基址，都在序言里 push、尾声里 pop。`XMM0～XMM5` 是易失的，本章浮点计算全程只用它们；`XMM6～XMM15` 才是非易失。**当前 `create_render_target` 用 `RDI` 清零结构体却未保存，是遗留瑕疵**；它由 `_start` 或 `WndProc` 调用时都不能假定调用者不在乎旧 `RDI`，通用版本必须保存/恢复或改用易失寄存器。

### 3.2 游戏架构：心跳 + 状态位

```text
_start
  ├─ GetModuleHandleW → 注册窗口类 → CreateWindowExW
  ├─ D2D1CreateFactory → create_render_target（RT + 3 画刷）
  ├─ reset_game（命=3、砖=32、球居中）
  ├─ SetTimer(hwnd, 1, 16ms)        ← 心跳
  └─ 消息循环
        WM_TIMER ──→ update_game（物理/碰撞/命数）→ InvalidateRect
        WM_PAINT ──→ draw_scene（Clear + 砖 + 挡板 + 球 + 命点）
        WM_KEYDOWN/UP ──→ key_left / key_right 状态位
        WM_DESTROY ──→ KillTimer + 全部 Release + PostQuitMessage
```

**为什么用心跳 + 状态位**：`WM_KEYDOWN` 是"按下"事件，在里面直接 `paddle_x -= 8` 会得到"按一下走一步、按住靠键盘重复"的卡顿手感。做法是 KEYDOWN 置 1、KEYUP 清 0，每次逻辑更新在 `update_game` 中根据状态位移——不再依赖键盘重复消息，每次更新的位移也一致。至于真实帧率是否恒定，还取决于计时与调度，见 3.8。

### 3.3 游戏状态机

状态全部在 `.bss`：`ball_x/y/vx/vy`（float）、`paddle_x`（float）、`lives`、`key_left/right`、`bricks[32]`（1 存活 / 0 碎）。这里的 `resd 1` 只预留 32 位存储；把它解释为整数还是 IEEE-754 单精度浮点，取决于后续使用 `mov eax,...` 还是 `movss xmm0,...`。

```text
游戏状态内存（概念图，实际地址由链接器决定）
┌──────────────┬────────┬──────────────────────────┐
│ 变量         │ 字节数 │ 含义                     │
├──────────────┼────────┼──────────────────────────┤
│ ball_x/y     │ 4 + 4  │ 球心坐标（float）        │
│ ball_vx/vy   │ 4 + 4  │ 每次逻辑更新的位移       │
│ paddle_x     │ 4      │ 挡板左缘                 │
│ lives        │ 4      │ 剩余命数                 │
│ key_left/right│ 4 + 4 │ 按键是否仍按住           │
│ bricks[32]   │ 128    │ 每块砖一个 dword 状态    │
└──────────────┴────────┴──────────────────────────┘
```

本章没有单独的 `GAME_MENU/GAME_OVER` 状态枚举，而是始终处于“运行”模式：丢命、通关和命数耗尽都直接调用重置函数。因此它是**隐式状态机**，不是带开始菜单和暂停界面的完整游戏框架。

每帧转移规则（`update_game`）：

| 事件 | 转移 |
|---|---|
| 球碰左/右/顶墙 | 对应速度分量乘 -1，位置贴回墙边（防止穿透后反复反弹） |
| 球碰挡板（仅 `vy>0` 下落时检测） | `vy` 反向，球贴回挡板顶 |
| 球与某块存活砖 AABB 重叠 | 砖置 0，`vy` 反向，本帧不再检测其他砖 |
| 球心越过 y=488 | `lives--`；>0 则 `reset_ball`，=0 则 `reset_game`（命回 3、砖全恢复） |
| 32 块砖全碎（`or` 扫描结果为 0） | `reset_bricks + reset_ball`，进入下一局 |

AABB（Axis-Aligned Bounding Box，轴对齐包围盒）碰撞只比较包围盒边界。球虽然画成椭圆，物理计算时却近似成 `[x-r,x+r] × [y-r,y+r]` 的正方形，所以角落可能出现“视觉未接触但判定接触”的误差。

以球心 `(50,50)`、半径 `8`，砖块 `[60,132] × [40,60]` 为例：球的包围盒是 `[42,58] × [42,58]`，球右缘 58 小于砖左缘 60，因此无碰撞。若球下一帧移到 `(54,50)`，球右缘变为 62，且其余三个方向也重叠，则判定命中。源码对砖块使用严格重叠，对挡板把边缘接触也算命中；两者边界条件略有差异。

本章砖块碰撞一律让 `vy` 反向，而且每帧最多击碎一块砖；它不计算最小穿透轴，也不把球位置移出砖块，因此是简化模型。提高速度后可能穿过薄砖或出现不自然反弹，进阶应使用扫掠碰撞或更小的时间步。

### 3.4 SSE 浮点三件套

SSE 是 x64 的浮点与向量指令体系；本章只用 `XMM` 寄存器中的一个 32 位浮点数，不涉及一次并行算多个数。第 18～19 章已经用 `movd/movss/cvtsi2ss` 搬运和转换浮点数，本章新增算术与比较。物理计算只有三种模式：

```nasm
; 积分：ball_x += ball_vx
movss   xmm0, [rel ball_x]
addss   xmm0, [rel ball_vx]
movss   [rel ball_x], xmm0

; 比较：comiss 设置 CF/ZF（类似无符号比较）
movss   xmm0, [rel ball_x]
comiss  xmm0, [rel c_ball_r]    ; ball_x < r → CF=1
jae     .no_wall_l              ; >= 就跳过

; 反向：乘 -1.0（IEEE754 乘法，-1 是精确值）
mulss   xmm0, [rel c_neg1]
```

**关键坑**：`comiss` 之后必须用 `ja/jae/jb/jbe`（无符号跳转，看 CF/ZF），不能用 `jg/jl`（有符号跳转，看 SF/OF——`comiss` 根本不设置 SF/OF）。砖块索引是整数（`imul`），画矩形时 `cvtsi2ss` 转成 float——**整数干活、浮点出场**，每帧反复横跳。

### 3.5 一个真实的 NASM 寻址坑：RIP 相对 + 变址

`default rel` 下写 `[rel bricks + rbx*4]` 是**非法**的：RIP 相对寻址编码里没有变址寄存器的位置。必须先 `lea` 把数组基址取进寄存器：

```nasm
lea     r10, [rel bricks]       ; r10 = &bricks（易失，本函数内不调 API）
...
cmp     dword [r10 + rbx*4], 0
```

`draw_scene` 里因为循环体内有 COM 调用（会踩烂 r10），基址改放非易失的 `RSI`（序言里 push 保护）。这是"易失寄存器 vs 非易失寄存器"在实战中的典型取舍。

### 3.6 设备丢失与自愈

显卡驱动重置、远程桌面环境变化等都可能让 `EndDraw` 返回 `D2DERR_RECREATE_TARGET`（`0x8899000C`）。本章只在 `draw_scene` 最后的 `EndDraw` 检查这个特定值：

```text
EndDraw → EAX == 0x8899000C
       → WM_PAINT 调 release_scene
       → p_rt/p_brick/p_paddle/p_ball 全清 0
       → 游戏状态仍保留
       → 下一次 WM_PAINT 重建 RT 与画刷
```

释放的是“设备相关场景”，不是 `ball_x/lives/bricks` 等逻辑状态，所以重建后可以从原局面继续。工厂也不随场景释放，直到 `WM_DESTROY` 才释放。

### 3.7 固定逻辑坐标与窗口尺寸

游戏常量把场地写死为 `640 × 480`：右墙球心上限 `632=640-8`，挡板右界 `540=640-100`，丢球线 `y=488`。`WM_SIZE` 虽会更新渲染目标像素尺寸，却**不会改变这些物理常量，也没有添加缩放变换**。因此窗口变大只留空白，窗口变小会裁掉场地。

另外，`CreateWindowExW(...,640,480,...)` 给的是包含边框和标题栏的**窗口外框尺寸**，不保证客户区恰好 640×480；高分屏也会影响显示坐标。当前示例保留这些简化，不展开窗口尺寸与高分屏换算。改进时需要读取真实客户区，再统一调整外框或设置逻辑坐标到显示坐标的变换。

### 3.8 时间步、焦点与完整生命周期

`SetTimer(16ms)` 只是请求消息心跳，不是精确的 60Hz 时钟。本章 `ball_vx=3`、`ball_vy=-4` 的单位应理解为“每次逻辑更新的位移”，不是严格的“像素/秒”。消息延迟时游戏会变慢。若以后要求恒速，再测量距上次更新的实际时间，并学习固定时间步或受限的可变时间步；本章不引入新的计时 API。

按键状态也有生命周期：窗口在按住方向键时失去焦点，程序可能收不到对应 `WM_KEYUP`，挡板会持续移动。通用版本应在失焦消息中清空 `key_left/key_right`。`WM_DESTROY` 的顺序则是“停计时器 → 释放场景 → 释放工厂 → `PostQuitMessage`”；`_start` 收到 `WM_QUIT` 后调用 `ExitProcess`，完成进程级收尾。

当前 `create_render_target` 未保存 `RDI`、启动失败路径只 `ExitProcess(3)`、绘图消息没有 `BeginPaint/EndPaint` 配对，都是本章保留的教学简化。可运行演示不等于通用窗口/库代码模板，扩展时应逐项补齐。

## 4. 实践用例

本章 [breakout.asm](breakout.asm) 约 700 行，包含 `_start`、`WndProc`、`update_game`、`draw_scene`、`create_render_target`、`release_scene`、`reset_game/ball/bricks` 等函数，构成完整的弹球打砖块游戏。

### 4.1 构建（真实输出）

```powershell
make
```

真实输出：

```text
nasm -f win64 -l breakout.obj.lst -o breakout.obj breakout.asm
ld -e _start --subsystem windows -o breakout.exe breakout.obj -L C:/msys64/ucrt64/lib -luser32 -lkernel32 -ld2d1
```

链接命令是第 22 章的扩展：追加 `-ld2d1`。三个库的分工：`user32`（窗口/消息/定时器/光标图标）、`kernel32`（`GetModuleHandleW`/`ExitProcess`）、`d2d1`（`D2D1CreateFactory`）。

### 4.2 objdump 实证：一个游戏只要 3 个 DLL

```powershell
objdump -p breakout.exe | Select-String "Subsystem|DLL Name|ImageBase|AddressOfEntryPoint"
```

真实输出：

```text
AddressOfEntryPoint     00000000000018ec
ImageBase               0000000140000000
Subsystem               00000002        (Windows GUI)
        DLL Name: d2d1.dll
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
start address 0x00000001400018ec
```

- 导入表**有且只有** `d2d1.dll + KERNEL32.dll + USER32.dll`——没有 msvcrt、没有 vcruntime、没有任何运行时。这就是"彻底摆脱 CRT"的最终证据。
- 入口 `0x18ec`：`.text` 里游戏函数在前、`_start` 在最后（约 6.3KB 代码），`start address = 0x1400018ec` 与之一致。

手动体验时运行 `.\breakout.exe`：左右方向键移动挡板，ESC 退出；左上角圆点表示剩余命数。窗口缩放、高分屏和失焦粘键的边界见 3.7～3.8。

### 4.3 `.lst` 摘录

浮点比较与反向（机器码层面的"物理引擎"）：

```text
  336 000002AB 0F2F05(CC000000)            comiss  xmm0, [rel c_ball_r]
  341 000002CC F30F5905(C8000000)          mulss   xmm0, [rel c_neg1]
  456 000004F4 FF0D(30010000)              dec     dword [rel lives]
```

- `0F 2F /r` = `comiss`；`F3 0F 59 /r` = `mulss`（F3 前缀是 scalar 单精度标志）；
- `FF /1` = `dec r/m32`——`dec dword [rel lives]` 一条指令完成"命数减一并设置 ZF"，紧接着 `jz .game_over` 直接分流；
- 括号里是 RIP 相对重定位占位，链接后由 ld 填成到 `.data` 的真实偏移。

整数→浮点转换（画砖块矩形时反复出现）：

```text
  517 00000585 F30F2AC0                    cvtsi2ss xmm0, eax
```

`F3 0F 2A /r`：`cvtsi2ss`，把 `EAX` 里的砖块像素坐标转成 IEEE754 单精度塞进 `XMM0`。

## 5. 代码重点讲解

1. **`sub rsp, 104` 的栈帧推导（知识点 3.1 ③）**：与第 22 章同理——32 影子 + 64 栈参（`CreateWindowExW` 后 8 参）+ 8 对齐补齐 = 104。`_start` 入口 `%16==8`，减 104 后 `%16==0`。

2. **WM_TIMER 心跳 + 按键状态位（知识点 3.2）**：`WM_KEYDOWN` 置 `key_left/right=1`，`WM_KEYUP` 清 0。`update_game` 每 16ms 根据状态位移挡板。这避免了"按一下走一步、按住靠键盘重复"的卡顿，是实时游戏的通用结构。

3. **SSE 浮点三件套（知识点 3.4）**：`movss/addss` 做积分，`comiss` 做比较，`mulss [c_neg1]` 做反向。`comiss` 后必须用 `ja/jae/jb/jbe`（无符号跳转看 CF/ZF），不能用 `jg/jl`（有符号跳转看 SF/OF，`comiss` 不设这两个标志）。

4. **`lea r10, [rel bricks]` 再 `[r10+rbx*4]`（知识点 3.5）**：`default rel` 下 RIP 相对寻址不能带变址，必须先 `lea` 取基址。`draw_scene` 循环体内有 COM 调用会踩烂易失的 `r10`，所以基址改放非易失的 `RSI`（序言 push 保护）。

5. **`dec dword [rel lives]` + `jz .game_over`**：`FF /1` 一条指令完成"命数减一 + 置 ZF"，紧接着 `jz` 直接分流到游戏结束。这是 x86 读-改-写指令的高效用法。

6. **`D2DERR_RECREATE_TARGET` 自愈（知识点 3.6）**：`EndDraw` 返回 `0x8899000C` 时 `release_scene` 丢掉旧渲染目标，下一帧 `WM_PAINT` 里 `create_render_target` 重建。显卡驱动重置/锁屏切换都可能触发，必须处理而非继续用旧 `p_rt`。

## 6. 常见坑

1. **`comiss` 后用错跳转**：`jg/jl` 看 SF/OF，`comiss` 不设这两个标志，结果不可预测。一律 `ja/jae/jb/jbe`。
2. **RIP 相对寻址带变址**：`[rel arr + rbx*4]` 汇编报错或生成不了的编码；先 `lea reg, [rel arr]`。
3. **穿透与抖动**：墙面和挡板碰撞会贴回边界再反向；砖块碰撞只反向、不修正位置，而且每帧只处理一块砖。提高速度后仍可能穿透或连续抖动，需要扫掠检测/子步进。
4. **挡板漏球**：球速 4px/帧、挡板厚 12px，不会穿；若把速度调大，要改成"扫掠检测"或限制单帧位移。
5. **设备丢失**：显卡驱动更新/锁屏切换都可能让 `EndDraw` 返回 `D2DERR_RECREATE_TARGET`。本章在 `WM_PAINT` 里检测后 `release_scene`，下一帧 `create_render_target` 自动重建——与第 19 章同一套自愈逻辑。
6. **忘记 KEYUP 清状态**：挡板会一直滑到边缘。KEYDOWN/KEYUP 必须成对维护。
7. **窗口缩放后仍假设场地为 640×480**：物理常量没有随 `WM_SIZE` 改变，且外框尺寸不等于客户区。需要完整适配时，应分离逻辑坐标与显示坐标并做缩放。
8. **失焦后忘记清按键**：窗口可能收不到 KEYUP；应在失焦时清 `key_left/key_right`，避免挡板“粘键”。
9. **把 16ms 定时器当精确时钟**：当前速度单位是“每次 WM_TIMER 的位移”，实际游戏速度会随消息调度变化。
10. **漏掉 `create_render_target` 的 `RDI` 保存**：当前源码是教学反例；被普通调用者或窗口过程调用时仍必须遵守非易失寄存器约定。
11. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item breakout.exe,breakout.obj,breakout.obj.lst`。

## 7. 练习

1. **角度反弹**：根据球击中挡板的位置改变 `vx`（击中点越靠边缘 `|vx|` 越大），让高手能控球。
2. **加速**：每击碎 10 块砖，`vx/vy` 同乘 1.1（用 `mulss` 与浮点常量 `1.1`），形成难度曲线。
3. **彩色砖行**：按行号选 4 种画刷（把 `p_brick` 改成 4 个画刷的数组，`i >> 3` 作索引）。
4. **暂停**：`VK_SPACE` 切换一个 `paused` 标志，`update_game` 开头检查为零就直接返回。
5. **贴边判定强化**：砖块碰撞目前一律 `vy` 反向；根据重叠量判断是侧碰（`vx` 反向）还是正碰（`vy` 反向）。

## 8. 至此，三个阶段全部完成

- **阶段一（01~12）**：寄存器、内存、指令、栈，到 CRT 时代的控制台程序；
- **阶段二（13~19）**：窗口、消息、GDI、COM、Direct2D 综合；
- **阶段三（20~24）**：`_start` 入口 → ld 直连 → 无 CRT 窗口 → 自建工具库 → **零 CRT 的 D2D 游戏**。

从"CRT 替你铺好的路"到"每一块字节都自己负责"——这套知识正是写引擎、写驱动、写嵌入式代码的底层内功。后续想继续深入，可以挑战：DirectWrite 文字渲染（游戏中的比分）、XInput 手柄支持、或者把游戏循环改成 `PeekMessage` 驱动的无定时器高精度循环。
