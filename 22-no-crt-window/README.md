# 第 22 章：无 CRT 的 GUI 窗口 —— `_start` 也能开窗口

> 第 13 章的窗口程序靠 CRT 启动代码把一切都"准备好"再调 `wmain`。
> 本章把 CRT 彻底拿掉：`_start` 作为进程真正入口，注册窗口类、创建窗口、跑消息循环，全程只依赖 KERNEL32/USER32。
> 本章源码：[win_nocrt.asm](win_nocrt.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[win_nocrt.obj.lst](win_nocrt.obj.lst)

## 1. 本章目标

- 把第 21 章的 ld 直连用到 GUI：`-e _start --subsystem windows -luser32 -lkernel32`；
- 搞清楚 CRT 启动代码原来替 GUI 程序做了什么（取 hInstance、对齐栈、最后 `exit`），并全部自己接手；
- 掌握 `_start` 版主函数与 `wmain` 版主函数的**栈帧差异**，会自己推导 `sub rsp, 104`；
- 用 objdump 实证：`Subsystem = 2 (Windows GUI)`，导入表只有 `KERNEL32.dll + USER32.dll`。

本章**只编译不运行**：窗口程序会阻塞在消息循环，且弹窗会干扰桌面。所有结论用 PE 头与反汇编验证。

跑通后你应该能回答：

- `_start` 入口处能直接用 `RCX` 当 hInstance 吗？为什么？
- 为什么 `_start` 里 `sub rsp, 104` 而第 13 章 `wmain` 里是 `sub rsp, 128`（push rbp 之后）？
- GUI 子系统下 `GetStdHandle(STD_OUTPUT_HANDLE)` 拿到什么？
- `_start` 结尾为什么应显式 `ExitProcess`，而不是把 `ret` 当作标准退出方式？

## 2. 前置 / 项目结构

前置：第 13 章的窗口创建与消息循环、第 20 章的无 CRT 入口、第 21 章的 ld 直连。本章把这三项旧知识组合起来，重点推导入口函数的栈帧。

```text
nasm-learn/
├── common.asm              与第 13~21 章相同
└── 22-no-crt-window/
    ├── Makefile            LD := ld，--subsystem windows
    ├── win_nocrt.asm       _start + WndProc
    ├── README.md
    └── win_nocrt.obj.lst   make 后生成
```

只有 `.asm` 源码。与第 13 章对比读最有收获：功能等价，入口不同。

## 3. 知识点讲解

### 3.1 ABI 复习：`_start` 与 `WndProc` 的不同责任

第 06、13、20 章已经讲过下列规则；这里只列出本章推导栈帧时要用到的结论。

1. **参数**：`RCX / RDX / R8 / R9`，第 5 个起走栈（`[rsp+32]`，每个 `qword`）。`CreateWindowExW` 有 12 个参数：前 4 个进寄存器，后 8 个（X、Y、nWidth、nHeight、hWndParent、hMenu、hInstance、lpParam）全部走栈，占 64 字节。
2. **影子空间**：每次 `call` 前必须备好 32 字节。被调方（包括 USER32 内部）可以随意覆写 `[rsp+0..31]`。
3. **对齐**：任何 `call` 指令执行的那一刻 `RSP % 16 == 0`。推论：函数**入口**（`call` 压入返回地址后）`RSP % 16 == 8`。
4. **非易失寄存器**：`RBX/RBP/RDI/RSI/R12～R15/XMM6～XMM15` 被调方必须保存。`WndProc` 被系统调用，必须守规矩；本章 `_start` 所有出口都 `ExitProcess`、不返回继续执行调用者，所以无需为返回后的调用者恢复 `RBX/RDI`。这不表示普通函数也能省略保存。

**`_start` 的特殊性**：本工具链/系统环境中，进程入口可观察到 `RSP % 16 == 8`，当前源码据此推导栈帧；但入口没有 `WinMain/wmain` 那样的应用层参数约定，`RCX/RDX/R8/R9` 不能当作那组参数。加载器仍有自己的外层执行帧，因此不要把它描述成“栈上什么都没有”，也不要依赖入口寄存器的偶然值。

### 3.2 `_start` 与 `wmain` 的栈帧差异

第 13 章 `wmain` 的序言：

```nasm
push    rbp
mov     rbp, rsp
sub     rsp, 128                ; 32 影子 + 64 传出栈参 + 32 本地槽
```

本章 `_start` 的序言只有一行：

```nasm
sub     rsp, 104                ; 32 影子 + 64 传出栈参 + 8 对齐
```

逐字节推导：

| 需求 | 字节数 | 说明 |
|---|---|---|
| 影子空间 | 32 | 每次 call 前必须有 |
| CreateWindowExW 后 8 个栈参 | 64 | `[rsp+32]` 到 `[rsp+88]` |
| 对齐补齐 | 8 | 入口 `RSP%16==8`，96 是 16 的倍数，减 96 后仍是 `%16==8`，必须再减 8 |
| **合计** | **104** | `104 % 16 == 8`，减完后 `RSP % 16 == 0` |

对照 `wmain`：入口 `%16==8`，`push rbp` 减 8 后 `%16==0`，再减 128（16 的倍数）保持对齐。128 里含 32 字节本地槽（存 hInstance）；本章 hInstance 改存 `.bss`（`hinst`），所以不需要本地槽，96 + 8 = 104 即可。

**规律**：栈帧大小 = 影子（32) + 最大传出栈参 + 本地变量，再向上补到"减完后 `%16==0`"。入口函数（`%16==8` 起步、无 push）补 8；`push rbp` 开头的函数补 0。

另外两个结构性差异：

- **hInstance 来源**：本教程的 `wmain` 形式是 MinGW 的 Unicode 入口约定，形参是 `argc/argv/envp`，**第 1 个参数是 argc，不是 hInstance**。以前各章和本章一样调用 `GetModuleHandleW(NULL)`；`WinMain/wWinMain` 才会由 CRT 传入 `hInstance`。
- **退出方式**：`wmain` 可以 `ret`，CRT 收到返回值后执行 `exit` 并终止进程。自定义 `_start` 的 `ret` 则回到加载器管理的外层帧，不能视为同一套退出协议；为了明确结束整个进程并指定退出码，所有出口都显式调用 `ExitProcess`。

### 3.3 GUI 子系统与标准句柄

`--subsystem windows` 的进程启动时**不会自动分配控制台**。但 `GetStdHandle(STD_OUTPUT_HANDLE)` 的结果仍取决于父进程与句柄继承：可能是 NULL/无效句柄，也可能是继承来的控制台、管道或文件句柄，不能只凭子系统字段断言。`WriteConsoleW` 还只接受合适的控制台句柄。

本章源码根本没有获取或写标准输出，所以正常观察手段是窗口、调试器和退出码；若以后添加日志，应先检查句柄类型并选择 `WriteConsoleW` 或 `WriteFile`。子系统字段也不决定能否创建窗口：console 程序照样能创建窗口，只是从资源管理器启动时通常会带一个控制台窗口。

## 4. 实践用例

本章 [win_nocrt.asm](win_nocrt.asm) 与第 13 章 `firstwindow.asm` 功能等价，差异全部在"入口与善后"。

### 4.1 构建（真实输出）

```powershell
make
```

真实输出：

```text
nasm -f win64 -l win_nocrt.obj.lst -o win_nocrt.obj win_nocrt.asm
ld -e _start --subsystem windows -o win_nocrt.exe win_nocrt.obj -L C:/msys64/ucrt64/lib -luser32 -lkernel32
```

链接命令与第 21 章只有两处不同：`--subsystem` 从 `console` 换成 `windows`；库从 `-lkernel32` 换成 `-luser32 -lkernel32`（窗口 API 在 USER32.dll）。**两个导入库都列在引用它们的 `.obj` 之后即可**。本章直接调用 USER32 的窗口 API，也直接调用 KERNEL32 的 `GetModuleHandleW/ExitProcess`，所以两个库都需要；不能用 USER32 的内部实现来推导这里的链接顺序。

### 4.2 objdump 实证

```powershell
objdump -p win_nocrt.exe | Select-String "Subsystem|DLL Name|ImageBase|AddressOfEntryPoint"
objdump -f win_nocrt.exe | Select-String "start address"
```

真实输出：

```text
AddressOfEntryPoint     000000000000103d
ImageBase               0000000140000000
Subsystem               00000002        (Windows GUI)
        DLL Name: KERNEL32.dll
        DLL Name: USER32.dll
start address 0x000000014000103d
```

逐条对应：

- `Subsystem = 2 (Windows GUI)`：`--subsystem windows` 写的就是这个字段。进程启动时**不会**分配控制台。
- 导入表只有 `KERNEL32.dll + USER32.dll`：全程无 CRT 的最终证据——没有 `msvcrt.dll`，没有任何 MinGW 运行时。
- `AddressOfEntryPoint = 0x103d`：本章 `.text` 里 `WndProc` 在前（0x1000 起）、`_start` 在后。`.lst` 里 `_start` 的偏移是 `0000003D`，`0x1000 + 0x3D = 0x103D`，与 PE 头精确吻合。

反汇编 `_start` 开头（`objdump -d win_nocrt.exe` 真实输出）：

```text
000000014000103d <_start>:
14000103d: 48 83 ec 68             sub    $0x68,%rsp        ; 0x68 = 104
140001041: 31 c9                   xor    %ecx,%ecx
140001043: e8 b8 01 00 00          call   140001200 <GetModuleHandleW>
140001048: 48 89 05 39 30 00 00    mov    %rax,0x3039(%rip)  # hinst
14000104f: 31 c9                   xor    %ecx,%ecx
140001051: ba 00 7f 00 00          mov    $0x7f00,%edx       ; 0x7f00 = 32512 = IDC_ARROW
140001056: e8 6d 01 00 00          call   1400011c8 <LoadCursorW>
```

链接器把 `.lst` 里的 `E8(00000000)` 洞全部填成了真实的 IAT 桩相对偏移，与第 21 章的机制完全相同。

### 4.3 `.lst` 摘录

```text
   86 0000003D 4883EC68                    sub     rsp, 104
  ...
  134 000000DE 4889442420                  mov     qword [rsp + 32], rax       ; X
  135 000000E3 4889442428                  mov     qword [rsp + 40], rax       ; Y
  136 000000E8 48C744243080020000          mov     qword [rsp + 48], 640       ; nWidth
  137 000000F1 48C7442438E0010000          mov     qword [rsp + 56], 480       ; nHeight
  138 000000FA 48C744244000000000          mov     qword [rsp + 64], 0         ; hWndParent
  139 00000103 48C744244800000000          mov     qword [rsp + 72], 0         ; hMenu
  141 00000113 4889442450                  mov     qword [rsp + 80], rax       ; hInstance
  142 00000118 48C744245800000000          mov     qword [rsp + 88], 0         ; lpParam
  143 00000121 E8(00000000)                call    CreateWindowExW
  ...
  177 00000185 E8(00000000)                call    ExitProcess
```

看点：

- `4883EC68`：`48` REX.W 前缀，`83 EC 68` = `sub rsp, 0x68`，104 一字不差；
- 8 个栈参正好是连续 8 个 `mov qword [rsp+32+8k]`——`[rsp+32]` 起步是因为前 32 字节是被调方的影子空间；
- `CreateWindowExW` 的 12 个参数里只有前 4 个在寄存器（`ecx/rdx/r8/r9d`），其余全在这 8 条 `mov` 里——**这就是 x64 ABI"前四寄存器、其余走栈"最直观的样板**。

## 5. 代码重点讲解

1. **`sub rsp, 104` 的推导（知识点 3.2）**：32 影子 + 64 栈参 = 96；入口 `RSP%16==8`，减 96 后仍是 `%16==8`，必须再减 8 才到 `%16==0`。若错减 96，`CreateWindowExW` 的 call 点 `%16==8`，USER32 内部一旦用 `movaps` 存 XMM 就 `0xC0000005`（对齐异常）。

2. **`GetModuleHandleW(NULL)` 取 hInstance（知识点 3.2）**：`_start` 的 `RCX` 不是 WinMain 参数，必须自己取得实例句柄。返回值存进 `.bss` 的 `hinst`，后面 `RegisterClassExW` 和 `CreateWindowExW` 都用它。注意本教程以前使用的 `wmain` 第一个参数是 `argc`，同样不能当 hInstance。

3. **`LoadCursorW(NULL, IDC_ARROW)` 填光标**：第 13 章留空也能跑，但光标进入客户区会闪烁，正规程序都显式设。`IDC_ARROW = 32512 = 0x7f00`，机器码 `ba 00 7f 00 00`。

4. **`CreateWindowExW` 的 8 个栈参（知识点 3.1 ①）**：12 参数函数，前 4 进 `RCX/RDX/R8/R9`，后 8 个从 `[rsp+32]` 起连续摆放。`[rsp+32]` 起步而非 `[rsp+0]`，因为前 32 字节是被调方的影子空间。

5. **三条出口全部 `ExitProcess`（知识点 3.2）**：正常退出码 0，注册失败 1，创建窗口失败 2。这样不依赖加载器对入口返回的实现细节，退出码也明确。`WndProc` 处理 `WM_KEYDOWN`：按 ESC 调 `DestroyWindow`，随后走 `WM_DESTROY → PostQuitMessage(0)` → 消息循环退出。

## 6. 常见坑

1. **武断假设 GUI 子系统标准句柄一定无效**：GUI 只表示不自动分配控制台，句柄仍可能继承。本章没有任何标准输出代码；新增日志时应检查实际句柄，并按第 23 章方式选择控制台或字节流写出，也可用 `AllocConsole` 显式建控制台。
2. **把 `_start` 的寄存器当 WinMain 参数**：入口 `RCX` 不是 hInstance。必须 `GetModuleHandleW(NULL)`。
3. **把 `_start` 末尾 `ret` 当标准退出**：它会返回加载器外层，不执行 CRT 的退出路径，也不能由本程序明确控制整个进程的退出状态。当前程序的所有出口统一使用 `ExitProcess`。
4. **栈参写到影子空间里**：`CreateWindowExW` 的第 5 个参数在 `[rsp+32]` 不是 `[rsp+0]`——前 32 字节是影子空间，写了也会被踩掉。
5. **对齐少算 8 字节**：入口 `%16==8`，若 `sub rsp, 96`（只算影子+栈参），call 点 `%16==8`，USER32 内部一旦用 `movaps` 存 XMM 就 `0xC0000005`（对齐异常）。必须是 104。
6. **链接时忘 `-luser32`**：报 `undefined reference to RegisterClassExW` 等一串——窗口 API 不在 kernel32。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item win_nocrt.exe,win_nocrt.obj,win_nocrt.obj.lst`。

## 7. 练习

1. 把 `sub rsp, 104` 改成 `sub rsp, 96`，重新链接，用 GDB 在 `CreateWindowExW` 的 call 点前断下，`p $rsp % 16` 验证对齐被破坏。
2. 删掉 `LoadCursorW` 调用并把 `hCursor` 字段留 0，链接后运行（自己承担弹窗），把鼠标移进客户区观察光标变化。
3. 用 `objdump -d` 找到 `WndProc` 里 `DefWindowProcW` 的调用点，确认 4 个参数原样转发（`rcx/rdx/r8/r9` 未动）。
4. 在 `WndProc` 里加 `WM_CLOSE → DestroyWindow` 分支（仿第 19 章），重新编译，用 `.lst` 核对新增机器码。
5. 把 `--subsystem windows` 改回 `console`，链接后运行：窗口照样弹出，但会多一个控制台窗口——理解子系统字段只影响"控制台分配"，不影响"能否创建窗口"。

## 8. 下一章预览

第 23 章回到控制台，解决一个前两章刻意绕开的问题：

- 没有 CRT 就没有 `strlen/printf/malloc`——自己写 `util_wcslen`、`util_u64_to_wstr`、堆分配包装，组成**多文件**工程（`main.asm + utils.asm`，`extern/global` 跨文件引用）；
- 正面解决第 20 章发现的"管道重定向下 `WriteConsoleW` 失败"：用 `GetConsoleMode` 检测真实控制台，管道场景改走 `WriteFile` + UTF-8 转换；
- ld 多 `.obj` 直连：`ld -e _start --subsystem console -o app.exe main.obj utils.obj ...`。
