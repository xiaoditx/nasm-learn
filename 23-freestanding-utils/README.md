# 第 23 章：无 CRT 工具库 —— 自己造"标准库"的轮子

> 没有 CRT，就没有 `wcslen`、`_ui64tow`、`printf`、`malloc`。本章把这 4 件最常用的东西自己写出来，
> 组成第一个**多文件**纯汇编工程，并顺手解决第 20 章发现的老问题：管道重定向下输出消失。
> 本章源码：[main.asm](main.asm) [utils.asm](utils.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[main.obj.lst](main.obj.lst) [utils.obj.lst](utils.obj.lst)

## 1. 本章目标

- 建立**多文件**纯汇编工程：`main.asm + utils.asm`，`global` 导出 / `extern` 引用，ld 一次链接；
- 手写 4 个"CRT 替代品"：

| 工具函数 | 替代的 CRT 函数 | 思路 |
|---|---|---|
| `util_wcslen` | `wcslen` | 逐码元扫描到 NUL |
| `util_u64_to_wstr` | `_ui64tow` | 反复 `div 10`，余数倒序成文 |
| `util_print_wstr` | `wprintf`（极简版） | `GetConsoleMode` 分流：控制台走 `WriteConsoleW`，管道走 `WriteFile` |
| `util_alloc/free` | `malloc/free` | `GetProcessHeap + HeapAlloc/HeapFree` |

- 正面解决第 20 章的坑：**管道重定向下 `WriteConsoleW` 失败**（`ERROR_INVALID_FUNCTION`），本章用 `GetConsoleMode` 检测，重定向时改走 `WriteFile + UTF-8`；
- **实际运行**验证：在 PowerShell 管道捕获场景下（第 20 章输出全丢的场景）完整看到 5 行输出，退出码 0。

跑通后你应该能回答：

- `global`/`extern` 在 `.obj` 层面到底发生了什么？链接器怎么把两个文件缝起来？
- 为什么 `div r10` 前必须 `xor edx, edx`？
- `GetConsoleMode` 凭什么能区分"真控制台"和"管道"？
- CRT 的 `malloc` 和 `HeapAlloc` 是什么关系？

## 2. 前置 / 项目结构

```text
masm-learn/
├── common.asm                与之前各章相同
└── 23-freestanding-utils/
    ├── Makefile              OBJS = main.obj utils.obj
    ├── main.asm              _start，演示程序
    ├── utils.asm             4 个工具函数（global 导出）
    ├── README.md
    ├── main.obj.lst          make 后生成
    └── utils.obj.lst         make 后生成
```

`utils.asm` 用 `global util_xxx` 导出符号；`main.asm` 用 `extern util_xxx` 引用。**这与 C 的"头文件声明 + 跨文件定义"完全同构**，只是汇编没有头文件，靠两边手写同名声明。

链接顺序即 `OBJS` 顺序：

```text
ld -e _start --subsystem console -o freestanding.exe main.obj utils.obj -L C:/msys64/ucrt64/lib -lkernel32
```

`main.obj` 里的未解析符号 `util_print_wstr` 等，由紧随其后的 `utils.obj` 提供——和 `-lkernel32` 一样，**引用在前、定义在后**。

## 3. 知识点讲解

### 3.1 Windows x64 ABI 四件套

1. **参数**：`RCX / RDX / R8 / R9`，第 5 个起走栈。本章栈参最多的是 `WideCharToMultiByte`（8 参，后 4 个走栈，`[rsp+32..56]`）。
2. **影子空间**：每次 `call` 前 32 字节。`util_wcslen`/`util_u64_to_wstr` 不调 API，是叶子函数，不需要影子空间；其余函数都有标准栈帧。
3. **对齐**：`call` 点 `RSP % 16 == 0`。`util_print_wstr` 的帧推导：32 影子 + 32 栈参（4 个 qword）+ 16 本地 = **80**（16 的倍数，push rbp 后保持对齐）。注意本地变量 `[rbp-8]/[rbp-16]` 不能与 `[rsp+32..56]` 重叠——`rsp = rbp-80` 时 `rsp+56 = rbp-24`，刚好错开。
4. **非易失寄存器**：工具函数是被调方，要守规矩；本章 util 函数只用了 `RAX/RCX/RDX/R8-R11`（全易失）+ 序言保护的 `RBP`，`util_u64_to_wstr` 用到的 `RSI` 是易失寄存器，无需保存。

### 3.2 多文件工程：global / extern

纯汇编的多文件工程机制与 C 完全同构：

| 角色 | 汇编关键字 | C 对应物 | 作用 |
|---|---|---|---|
| 定义方（utils.asm） | `global util_wcslen` | 函数定义 | 把符号标记为"可被外部引用"，写进 `.obj` 的符号表 |
| 使用方（main.asm） | `extern util_wcslen` | 头文件声明 | 告诉汇编器"这个符号在别处"，生成未解析引用 |
| 链接器 | ld | 链接器 | 扫描所有 `.obj`，把未解析引用与定义配对 |

链接顺序必须"引用在前、定义在后"：`main.obj utils.obj`。若反过来写成 `utils.obj main.obj`，ld 扫描到 `utils.obj` 时还没人引用它的符号（全部丢弃），扫到 `main.obj` 时再找 `util_wcslen` 已经找不到了，报 `undefined reference`。这与 `-lkernel32` 必须放在 `.obj` 之后是同一规则。

### 3.3 `div` 的正确打开方式

`div r10` 做的是 **128 位 ÷ 64 位**（`RDX:RAX ÷ r10`），商在 `RAX`，余数在 `RDX`。三个要点：

1. **`xor edx, edx` 不能省**：若 `RDX` 残留垃圾，轻则商错，重则商溢出触发 `#DE` 异常（进程直接崩溃）。每次循环都要清。
2. **余数是"个位在前"**：`1844...` 的第一个余数是 `5`（个位），所以先存栈上，最后倒序拷贝到目标缓冲。
3. **do-while 而非 while**：值 `0` 也要生成 `'0'`，先执行再判断。

### 3.4 GetConsoleMode 分流：解决第 20 章的老问题

第 20 章的实证结论：`WriteConsoleW` 的句柄被重定向到管道时返回 0、`GetLastError = ERROR_INVALID_FUNCTION`——控制台 API 只认"真控制台"。

`GetConsoleMode(hOut, &mode)` 是完美的探针：**只有真控制台句柄才能成功**。本章据此把输出分两条路：

```text
GetStdHandle(STD_OUTPUT_HANDLE)
        │
GetConsoleMode(h, &mode)
   ┌────┴────┐
 成功        失败
 真控制台    管道/文件
WriteConsoleW   WideCharToMultiByte(CP_UTF8) → WriteFile
```

- 真控制台：`WriteConsoleW` 直接收 UTF-16，最自然；
- 管道/文件：`WriteFile` 写的是**字节流**，不能塞 UTF-16（下游按 ANSI/UTF-8 读会乱码），先 `WideCharToMultiByte(CP_UTF8, ...)` 转成 UTF-8 字节再写。

检测结果缓存在 `.bss`（`out_kind`），只探测一次。这正是 CRT `wprintf` 内部做的事——本章把它显式化了。

### 3.5 malloc 的真身：HeapAlloc

CRT 的 `malloc` 在 Windows 上最终就是调 `HeapAlloc(GetProcessHeap(), ...)`（外加 CRT 自己的簿记）。没有 CRT，直接调正主：

```text
util_alloc(rcx = 字节数):
    r8  = rcx                  ; 第 3 参 dwBytes
    call GetProcessHeap        ; rax = 默认堆句柄
    rcx = rax                  ; 第 1 参 hHeap
    edx = 0                    ; 第 2 参 dwFlags
    call HeapAlloc             ; rax = 分配到的内存
```

进程创建时系统就送一个默认堆，`GetProcessHeap` 只是取它的句柄。`util_free` 对称地调 `HeapFree`。`HeapAlloc` 的内存不自动清零（`dwFlags=0` 时），要清零传 `HEAP_ZERO_MEMORY`。

## 4. 实践用例

本章 [main.asm](main.asm) 是演示程序，依次调用 [utils.asm](utils.asm) 里的 4 个工具函数；`utils.asm` 是工具库。

### 4.1 构建与运行

```powershell
make
.\freestanding.exe
Write-Host "EXIT=$LASTEXITCODE"
```

真实输出（注意：这是在 PowerShell 管道捕获下——第 20 章同场景输出全丢！）：

```text
nasm -f win64 -l main.obj.lst -o main.obj main.asm
nasm -f win64 -l utils.obj.lst -o utils.obj utils.asm
ld -e _start --subsystem console -o freestanding.exe main.obj utils.obj -L C:/msys64/ucrt64/lib -lkernel32
freestanding utils demo (no CRT)
u64 0        = 0
u64 max      = 18446744073709551615
wcslen(count)= 10
heap 2^40    = 1099511627776
EXIT=0
```

5 行输出全部可见，说明 `GetConsoleMode` 检测失败 → 走了 `WriteFile` 路径且转换、写出全部成功：

- `u64 0 = 0`：do-while 正确处理零值；
- `u64 max = 18446744073709551615`：20 位全对，`div` 循环无误；
- `wcslen(count)= 10`：`"0123456789"` 正好 10 个码元；
- `heap 2^40 = 1099511627776`：`HeapAlloc` 的 64 字节真实可用，`2^40 = 1099511627776`；
- `EXIT=0`：正常 `ExitProcess(0)`。

### 4.2 objdump 实证

```powershell
objdump -p freestanding.exe | Select-String "Subsystem|DLL Name|AddressOfEntryPoint"
```

真实输出：

```text
AddressOfEntryPoint     0000000000001000
Subsystem               00000003        (Windows CUI)
        DLL Name: KERNEL32.dll
```

- 入口 `0x1000`：`OBJS` 里 `main.obj` 在前，`_start` 正好在 `.text` 偏移 0；
- 全部功能（含堆分配、代码页转换）只用了 **KERNEL32.dll** 一个 DLL——`WideCharToMultiByte`、`HeapAlloc` 都在 kernel32，不需要 CRT 也不需要别的系统库。

### 4.3 `.lst` 摘录

`div` 循环（`utils.obj.lst`）：

```text
   72 0000002A 49F7F2                      div     r10
```

`49 F7 F2`：`49` = REX.WB（64 位操作 + r10 需要 B 位），`F7 /2` = `div r/m64`。

`WideCharToMultiByte` 的 4 个栈参与写出：

```text
  164 0000012C 48C744243800000000          mov     qword [rsp + 56], 0   ; lpUsedDefaultChar
  165 00000135 E8(00000000)                call    WideCharToMultiByte
  166 0000013A 85C0                        test    eax, eax
  167 0000013C 7426                        jz      .done
  ...
  172 0000014C 4189C0                      mov     r8d, eax              ; 转换出的字节数 → WriteFile 第 3 参
  175 0000015F E8(00000000)                call    WriteFile
```

`85 C0`（`test eax,eax`）+ `74 26`（`jz`）：`WideCharToMultiByte` 返回 0 表示失败；非 0 时 `EAX` 就是 UTF-8 字节数，直接接力给 `WriteFile` 的第 3 参——**一次调用、零拷贝接力**。

## 5. 代码重点讲解

1. **`global` / `extern` 跨文件（知识点 3.2）**：`utils.asm` 用 `global util_wcslen` 导出，`main.asm` 用 `extern util_wcslen` 引用。链接器扫描 `main.obj utils.obj` 时把未解析引用与定义配对。链接顺序必须"引用在前、定义在后"，否则报 `undefined reference`。

2. **`util_wcslen`：最小的叶子函数**：不调 API、不用栈、只碰易失寄存器（`RAX/RCX`）。`cmp word [rcx + rax*2], 0` 按 UTF-16 码元扫描到 NUL。这类"纯计算叶子函数"是汇编里最高效的存在，CRT 的 `strlen` 本质也是这个循环（加 SIMD 优化）。

3. **`util_u64_to_wstr` 的 `div` 循环（知识点 3.3）**：核心是 `mov rax, r8; xor edx, edx; div r10`。`xor edx, edx` 每次循环都要清，否则 128 位被除数含垃圾，商溢出触发 `#DE`。余数倒序存栈上临时缓冲（`[rbp-40..rbp-1]`，20 个码元刚好装下 u64 最大值），最后倒序拷贝到目标缓冲。

4. **`util_print_wstr` 的 GetConsoleMode 分流（知识点 3.4）**：先 `GetConsoleMode(hOut, &mode)` 探测句柄类型。成功走 `WriteConsoleW`（直接 UTF-16）；失败走 `WideCharToMultiByte(CP_UTF8) + WriteFile`（字节流）。检测结果缓存到 `.bss` 的 `out_kind`，只探测一次。

5. **`util_alloc` 的 HeapAlloc 链（知识点 3.5）**：`GetProcessHeap` 取默认堆句柄 → `HeapAlloc(hHeap, 0, dwBytes)`。CRT 的 `malloc` 最终就是这两步（外加簿记）。`dwFlags=0` 不清零，本章缓冲随后被完整覆写所以无所谓。

6. **`WideCharToMultiByte` 返回值零拷贝接力**：`test eax, eax` 判断成功后，`EAX` 里的 UTF-8 字节数直接 `mov r8d, eax` 当作 `WriteFile` 的第 3 参——一次调用、无需额外存储。

## 6. 常见坑

1. **`div` 前不清 `RDX`**：`div r10` 是 128÷64，`RDX` 残留会让商溢出，直接 `#DE` 异常崩溃。每次循环都要 `xor edx, edx`。
2. **管道里塞 UTF-16**：`WriteFile` 写的是字节流；把 UTF-16 原样写进管道，PowerShell/文件重定向按 ANSI 解读就是"每个字符后面跟个 NUL"的乱码。必须 `WideCharToMultiByte`。
3. **`GetConsoleMode` 判据误用**：它成功 = 句柄是真控制台。不要反过来用 `GetLastError == ERROR_INVALID_HANDLE` 当判据——句柄无效时 `GetStdHandle` 本身就返回 `NULL` 了。
4. **栈参与本地变量重叠**：`util_print_wstr` 若只开 64 字节帧，`[rsp+56]`（第 8 参）会砸到 `[rbp-8]`（保存的字符串指针）。推导帧大小时"影子 + 最大栈参 + 本地"一项都不能少，见知识点 3.1。
5. **`global` 忘写 / `extern` 拼错**：忘 `global` → 链接报 `undefined reference`；拼错 `extern` 名字 → 同样报 undefined，但错误信息里的符号名能帮你定位是哪边写错。
6. **`HeapAlloc` 的内存不自动清零**（`dwFlags=0` 时）：要清零传 `HEAP_ZERO_MEMORY`（`common.asm` 已定义）。本章缓冲随后被 `util_u64_to_wstr` 完整覆写，所以不需要。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item freestanding.exe,main.obj,utils.obj,main.obj.lst,utils.obj.lst`。

## 7. 练习

1. 给 `util_u64_to_wstr` 加 `i64` 版本：负数先输出 `'-'`，再对绝对值转换（注意 `-2^63` 取负会溢出，先转成 u64 再处理）。
2. 写 `util_wstr_to_u64`（`wcstoull` 的反面）：跳过前导空白，逐码元 `acc = acc*10 + digit`，在 main 里和 `util_u64_to_wstr` 对拍验证。
3. 把 `util_print_wstr` 的 UTF-8 缓冲改成 `util_alloc` 动态申请（按 `WideCharToMultiByte` 先查长度再申请的两遍调用法），去掉 4096 字节上限。
4. 在 `detect_out` 里加第三路：`out_kind == 2` 且 `GetFileType(h) == FILE_TYPE_DISK` 时也走 WriteFile——用 `GetFileType` 区分管道与文件，打印不同提示。
5. 把 `OBJS` 顺序改成 `utils.obj main.obj`，重新 make，记录 ld 的报错原文，验证"引用在前、定义在后"。

## 8. 下一章预览

第 24 章（批次 D 收官）：把第 19 章的 Direct2D 综合窗口改造成**纯汇编小游戏**——弹球打砖块：

- `_start` + `WndProc + WM_TIMER` 游戏循环，全程零 CRT；
- `ld --subsystem windows -luser32 -lkernel32 -ld2d1` 三库直连；
- 方向键控板、球与砖块碰撞、`D2DERR_RECREATE_TARGET` 设备丢失重建；
- 用 objdump 最终验证：一个游戏，只需要 3 个 DLL。
