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

```text
masm-learn/
├── common.asm              新增：WM_KEYUP、VK_LEFT/UP/RIGHT/DOWN
└── 24-d2d-game/
    ├── Makefile            -luser32 -lkernel32 -ld2d1
    ├── breakout.asm        ~700 行：_start + WndProc + update_game + draw_scene
    ├── README.md
    └── breakout.obj.lst    make 后生成
```

## 3. 知识点讲解

### 3.1 Windows x64 ABI 四件套

1. **参数**：`RCX/RDX/R8/R9`，第 5 个起走栈。本章栈参大户仍是 `CreateWindowExW`（后 8 参，`[rsp+32..88]`）。
2. **影子空间**：每个 `call` 前 32 字节。COM 调用（`COM_CALL` 宏展开成 `call qword [rax+slot*8]`）同样受 ABI 约束。
3. **对齐**：`_start` 入口 `%16==8` → `sub rsp, 104`（推导同第 22 章：32 影子 + 64 栈参 + 8 补齐）；`update_game` 用 `push rbp + push rbx + sub rsp, 40`（8+40=48，凑齐 16 倍数）；`draw_scene` 用 `push rbp + push rbx + push rsi + sub rsp, 48`。**每多 push 一个非易失寄存器，帧大小就要重新凑齐。**
4. **非易失寄存器**：`update_game`/`draw_scene` 用 `RBX` 当循环计数器、后者用 `RSI` 持砖块数组基址——都在序言里 push、尾声里 pop。`XMM0~XMM5` 是易失的，本章浮点计算全程只用它们，无需保存；`XMM6~15` 才是非易失。

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

**为什么用心跳 + 状态位**：`WM_KEYDOWN` 是"按下"事件，在里面直接 `paddle_x -= 8` 会得到"按一下走一步、按住靠键盘重复"的卡顿手感。正确做法是 KEYDOWN 置 1、KEYUP 清 0，每帧（16ms）在 `update_game` 里根据状态位移——帧率恒定、手感平滑，这是所有实时游戏的通用结构。

### 3.3 游戏状态机

状态全部在 `.bss`：`ball_x/y/vx/vy`（float）、`paddle_x`（float）、`lives`、`key_left/right`、`bricks[32]`（1 存活 / 0 碎）。

每帧转移规则（`update_game`）：

| 事件 | 转移 |
|---|---|
| 球碰左/右/顶墙 | 对应速度分量乘 -1，位置贴回墙边（防止穿透后反复反弹） |
| 球碰挡板（仅 `vy>0` 下落时检测） | `vy` 反向，球贴回挡板顶 |
| 球与某块存活砖 AABB 重叠 | 砖置 0，`vy` 反向，本帧不再检测其他砖 |
| 球心越过 y=488 | `lives--`；>0 则 `reset_ball`，=0 则 `reset_game`（命回 3、砖全恢复） |
| 32 块砖全碎（`or` 扫描结果为 0） | `reset_bricks + reset_ball`，进入下一局 |

AABB（Axis-Aligned Bounding Box）碰撞：球与砖块都是轴对齐矩形，判断重叠只需比较边界。本章砖块碰撞一律 `vy` 反向（简化版），进阶可按重叠量判断侧碰/正碰。

### 3.4 SSE 浮点三件套

物理计算只有三种模式：

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

显卡驱动更新/锁屏切换/显示器热插拔都可能让 `EndDraw` 返回 `D2DERR_RECREATE_TARGET`（`0x8899000C`）。正确处理是**丢掉并重建**：在 `WM_PAINT` 里检测后 `release_scene`，下一帧 `create_render_target` 自动重建——与第 19 章同一套自愈逻辑。

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
3. **穿透**：只反转速度不贴回边界，高速球会嵌进墙里每帧来回反向（抖动）。本章所有碰撞都"先贴回、再反向"。
4. **挡板漏球**：球速 4px/帧、挡板厚 12px，不会穿；若把速度调大，要改成"扫掠检测"或限制单帧位移。
5. **设备丢失**：显卡驱动更新/锁屏切换都可能让 `EndDraw` 返回 `D2DERR_RECREATE_TARGET`。本章在 `WM_PAINT` 里检测后 `release_scene`，下一帧 `create_render_target` 自动重建——与第 19 章同一套自愈逻辑。
6. **忘记 KEYUP 清状态**：挡板会一直滑到边缘。KEYDOWN/KEYUP 必须成对维护。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item breakout.exe,breakout.obj,breakout.obj.lst`。

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
