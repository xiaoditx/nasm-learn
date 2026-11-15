# 第 21 章：ld 直接链接 —— 连 gcc 驱动也拿掉

> 第 20 章用 `gcc -nostartfiles` 去掉了 CRT 启动文件，但 gcc 驱动仍然在背后替我们拼参数、加库。
> 本章把最后这层"代驾"也撤掉：直接调用 `ld`，每一个链接参数都自己写。
> 本章源码：[lddirect.asm](lddirect.asm)
> 构建脚本：[Makefile](Makefile)
> 共享定义：[../common.asm](../common.asm)
> 本章清单：[lddirect.obj.lst](lddirect.obj.lst)

## 1. 本章目标

- 搞清楚 **gcc 驱动程序 ≠ 链接器**：gcc 是个"拼命令行的外壳"，真正干活的是 `collect2`/`ld`；
- 亲手写出最小可用的 ld 命令：`-e _start --subsystem console -L <导入库目录> -lkernel32`；
- 理解 `-l` 找的是**导入库**（`libkernel32.a`），它不含函数实现，只含"DLL 名 + 桩"；
- 看懂 PE 头三个字段：`AddressOfEntryPoint`、`Subsystem`、Import Directory；
- 实际运行验证：退出码 21。

本章程序功能与第 20 章**完全相同**（`_start` + 打印命令行），差异只在链接方式——这样你能把注意力全部放在"链接"这一变量上。

跑通后你应该能回答：

- `gcc -nostartfiles` 之后，gcc 还偷偷链了哪些库？为什么产物里却没有 msvcrt？
- `ld -lkernel32` 里的 `kernel32` 是 DLL 吗？`libkernel32.a` 里装的是什么？
- PE 加载器凭什么找到 `_start`？
- `--subsystem console` 改了 PE 头里哪个字节，影响什么？

## 2. 前置 / 项目结构

前置：第 20 章的 `_start`、系统 API 调用和退出流程。本章保持源码功能不变，只替换链接方式。

```text
nasm-learn/
├── common.asm              与第 20 章相同
└── 21-ld-direct/
    ├── Makefile            LD := ld，直接链接
    ├── lddirect.asm
    ├── README.md
    └── lddirect.obj.lst    make 后生成
```

只有 `.asm` 源码。Makefile 里**不再出现 gcc**。

## 3. 知识点讲解

### 3.1 Windows x64 ABI 四件套（复习）

与第 20 章完全相同的约束，这里只列结论，细节见第 20 章第 3 节：

1. **参数**：`RCX / RDX / R8 / R9`，第 5 个起走栈（`[rsp+32]`，`qword`）。
2. **影子空间**：调用前必须备 32 字节；本章 `sub rsp, 40`（= 32 影子 + 8 栈参槽）。
3. **对齐**：入口 `RSP % 16 == 8`；减 40 后 `% 16 == 0`，之后每个 `call` 点保持。
4. **非易失寄存器**：`RBX/RBP/RDI/RSI/R12~R15/XMM6~15` 是普通被调方必须保存的寄存器。本章 `_start` 最终调用 `ExitProcess`，不会返回后继续执行调用者代码，因此这里使用 `RBX/RSI` 后不恢复；普通函数不能照抄这种简化。

### 3.2 gcc 驱动原来替我们做了多少事

`gcc` 本身**不是**编译器也不是链接器，它是驱动程序：按参数依次调度 `cc1`（编译）、`as`（汇编）、`collect2`（链接）。`gcc -###`（只打印不执行）能看到它最终拼出的链接命令。对第 20 章那条命令实测：

```powershell
gcc -nostartfiles -Wl,-e,_start -o x.exe lddirect.obj -lkernel32 "-###"
```

真实输出的最后一行（collect2 调用，节选）：

```text
collect2.exe -plugin liblto_plugin.dll ... -m i386pep -Bdynamic -o x.exe
  "-LC:/msys64/ucrt64/bin/../lib/gcc/x86_64-w64-mingw32/15.2.0"
  "-LC:/msys64/ucrt64/bin/../lib/gcc"
  ...（共 7 个 -L 搜索路径）
  -e _start lddirect.obj -lkernel32
  -lmingw32 -lgcc -lgcc_eh -lmingwex -lmsvcrt -lkernel32 -lpthread
  -ladvapi32 -lshell32 -luser32 -lkernel32
  -lmingw32 -lgcc -lgcc_eh -lmingwex -lmsvcrt -lkernel32
```

即使给了 `-nostartfiles`，gcc 仍然**自动追加两遍** `mingw32 / gcc / gcc_eh / mingwex / msvcrt / pthread / advapi32 / shell32 / user32`，外加 LTO 插件和 7 条库搜索路径。

那为什么第 20 章的 exe 里没有导入 msvcrt？因为 `.a` 档案的链接规则是**按成员提取**：只有引用了其中符号，对应成员才会被链进来。我们的代码一个 CRT 符号都没用，所以这些库"挂了名但没出货"。这也解释了大小差异：第 20 章产物 10646 字节，本章 10602 字节——差的主要是 gcc 自动带进来的元信息。

结论：**用 ld 直连，得到的是完全可预测的链接过程**——没有插件、没有隐藏库、没有两遍扫描。

### 3.3 ld 命令逐项拆解

本章的完整链接命令：

```text
ld -e _start --subsystem console -o lddirect.exe lddirect.obj -L C:/msys64/ucrt64/lib -lkernel32
```

| 参数 | 作用 | 不给会怎样 |
|---|---|---|
| `-e _start` | PE 头 `AddressOfEntryPoint` 指向符号 `_start` | 默认入口 `mainCRTStartup` 找不到 → 警告并指向 `.text` 开头（碰巧能跑，不可依赖） |
| `--subsystem console` | PE 头 `Subsystem = 3 (Windows CUI)` | 默认也是 console；但 GUI 程序必须显式 `windows`（第 22 章） |
| `-o lddirect.exe` | 输出文件名 | 默认 `a.exe` |
| `lddirect.obj` | 输入目标文件 | —— |
| `-L C:/msys64/ucrt64/lib` | 追加库搜索目录 | `ld` 的内置搜索路径里没有 MinGW 导入库目录，会报 `cannot find -lkernel32` |
| `-lkernel32` | 链接 `libkernel32.a` | 4 个 API 全部 unresolved |

#### 3.3.1 `-lkernel32` 找到的是什么

`C:/msys64/ucrt64/lib/libkernel32.a` 是**导入库**（import library）：里面没有 `ExitProcess` 的机器码，只有一张张"名片"——

```text
函数名 WriteConsoleW → 位于 KERNEL32.dll 导出表
```

链接器见到我们 `.obj` 里的未解析符号 `WriteConsoleW`，就在导入库里生成一小段**跳转桩**（`jmp qword [rip+IAT槽]`），并在 exe 的导入目录里登记"需要 KERNEL32.dll"。运行时 Windows 加载器映射 KERNEL32.dll，把真实地址填进 IAT，桩才生效。

所以"链接 `-lkernel32`"和"依赖 KERNEL32.dll"是因果关系：前者在链接期登记，后者在运行期加载。

#### 3.3.2 子系统字段的两个常用值

| `--subsystem` | PE 头值 | 效果 |
|---|---|---|
| `console` | 3 (Windows CUI) | 从控制台启动就复用该控制台；从资源管理器启动会自动附一个控制台窗口 |
| `windows` | 2 (Windows GUI) | 不自动分配控制台；标准句柄是否存在取决于继承与启动环境（第 22 章） |

### 3.4 汇编器留洞，链接器填

`.obj` 里所有对外部符号的 `call` 都写成 `E8(00000000)`——`E8` 是 `call rel32`，需要一个"到下一条指令末尾的相对距离"，但目标地址只有链接器知道。括号里的 `(00000000)` 是重定位占位。

链接后（`objdump -d` 实测）可以看到洞被填上了真实的 rel32。同一个 `.obj`，gcc 链是这些字节，ld 链也是这些字节——**第 20、21 章的全部差异都在 exe 的 PE 头与导入表元数据里，不在代码段**。

## 4. 实践用例

本章 [lddirect.asm](lddirect.asm) 与第 20 章 `start.asm` 逐指令对应，仅两处刻意不同：问候文本改为 `hello from _start (linked by ld directly)`；退出码改为 `21`。这本身就是教学点：**汇编器生成的 `.obj` 与链接方式无关**。

### 4.1 构建与运行

```powershell
make
.\lddirect.exe
Write-Host "EXIT=$LASTEXITCODE"
```

真实输出：

```text
nasm -f win64 -l lddirect.obj.lst -o lddirect.obj lddirect.asm
ld -e _start --subsystem console -o lddirect.exe lddirect.obj -L C:/msys64/ucrt64/lib -lkernel32
EXIT=21
```

与第 20 章一样：退出码 21 证明流程走通；文字输出在管道场景不可见（`WriteConsoleW` 对重定向句柄失败，`ERROR_INVALID_FUNCTION`，见第 20 章知识点 3.3），真实控制台窗口中可看到：

```text
cmdline: 21-ld-direct\lddirect.exe
hello from _start (linked by ld directly)
```

### 4.2 objdump 实证

```powershell
objdump -p lddirect.exe | Select-String "Subsystem|DLL Name|ImageBase|AddressOfEntryPoint"
objdump -f lddirect.exe | Select-String "start address"
```

真实输出：

```text
AddressOfEntryPoint     0000000000001000
ImageBase               0000000140000000
Subsystem               00000003        (Windows CUI)
        DLL Name: KERNEL32.dll
start address 0x0000000140001000
```

逐条对应：

- `AddressOfEntryPoint = 0x1000`：`_start` 在 `.text` 偏移 0，`.text` 的 RVA 是 0x1000 → 入口 = `ImageBase + 0x1000 = 0x140001000`，正是 `-e _start` 指定的符号。
- `Subsystem = 3`：`--subsystem console` 写的就是这个字段。
- 导入表只有 `KERNEL32.dll`：`-lkernel32` 登记的唯一依赖。

### 4.3 `.lst` 摘录：汇编器留洞，链接器填

```text
   46 00000009 E8(00000000)                call    GetStdHandle
   ...
  103 000000DE E8(00000000)                call    ExitProcess
```

与第 20 章的机器码**逐字节相同**——这正说明 `.obj` 与链接器无关。括号里的 `(00000000)` 是重定位占位。

链接后（`objdump -d lddirect.exe` 实测）可以看到洞被填上了：

```text
140001009:   e8 de 00 00 00          call   1400010ec <GetStdHandle>
```

`e8 de 00 00 00`：`de 00 00 00` 就是链接器算出的 rel32 = 0xDE；`0x14000100e`（下一条指令）+ 0xDE = `0x1400010ec`，正是 `GetStdHandle` 的 IAT 桩。

## 5. 代码重点讲解

1. **`-e _start` 指定 PE 入口（知识点 3.3）**：PE 头 `AddressOfEntryPoint` 字段由 `-e` 写入。不给 `-e`，ld 默认找 `mainCRTStartup`，找不到就警告并指向 `.text` 开头（碰巧能跑，不可依赖）。

2. **`-L C:/msys64/ucrt64/lib`（知识点 3.3）**：ld 的内置搜索路径不含 MinGW 导入库目录。少了这条就报 `cannot find -lkernel32`。

3. **`-lkernel32` 链接的是导入库（知识点 3.3.1）**：`libkernel32.a` 里没有函数体，只有"DLL 名 + 桩"。链接器据此生成 IAT 跳转桩并在导入表登记 KERNEL32.dll。

4. **`--subsystem console` 写入 PE 头（知识点 3.3.2）**：PE 头 `Subsystem` 字段值为 3（Windows CUI）。第 22 章会换成 `windows`（值 2）。

5. **汇编器留洞、链接器填（知识点 3.4）**：`.lst` 里 `E8(00000000)` 的括号占位，在链接后变成 `e8 de 00 00 00` 这样的真实 rel32。`.obj` 本身与链接器无关——这正是为什么第 20、21 章代码段机器码逐字节相同。

## 6. 常见坑

1. **`cannot find -lkernel32`**：忘了 `-L C:/msys64/ucrt64/lib`。ld 的内置搜索路径不含 MinGW 导入库目录。
2. **`-e` 写成 `--entry=_start` 以外的错拼**：`--entry` 也合法；但 `-e_main`、`-e start` 都会静默指错位置，用 `objdump -f` 核对 `start address`。
3. **把 `libkernel32.a` 当静态库**：它只是导入库；真正的实现在 `C:\Windows\System32\KERNEL32.dll`。
4. **子系统写错**：GUI 程序链成 console，启动时可能多一个控制台窗口；console 程序链成 windows 则不会自动分配控制台，输出是否仍可见还取决于继承句柄与写出方式。
5. **库顺序**：`ld` 按顺序扫描，`-lkernel32` 要放在引用它的 `.obj` **之后**（本章命令的顺序）。
6. **以为 `ld` 认得 gcc 的 `-municode/-mwindows`**：那是 gcc 驱动层的选项，ld 不认识；对应物是 `--subsystem windows`。
7. **`make clean` 依赖 `rm`**：PowerShell 下用 `Remove-Item lddirect.exe,lddirect.obj,lddirect.obj.lst`。

## 7. 练习

1. 删掉 `-e _start` 重新链接，记录警告原文，再用 `objdump -f` 看 `start address` 指到哪。
2. 把 `--subsystem console` 改成 `windows`，链接运行，用第 20 章的 GDB 方法观察 `GetStdHandle` 返回值与 `WriteConsoleW` 失败码。
3. 用 `objdump -x lddirect.exe` 找到 Import Directory 的 RVA，再用 `objdump -s -j .idata` 对照看 `KERNEL32.dll` 字符串。
4. 故意把 `-lkernel32` 放到 `lddirect.obj` 前面，观察 `undefined reference` 报错，理解 ld 的顺序扫描。
5. 对比 `size start.exe lddirect.exe`（第 20、21 章产物），用 `objdump -h` 找出差异来自哪个节。

## 8. 下一章预览

第 22 章把这套"ld 直连"用到 GUI 程序：

- `--subsystem windows` + `-luser32 -lkernel32`；
- `_start` 里注册窗口类、建窗口、跑消息循环——全程无 CRT；
- 用 `objdump -p` 验证 `Subsystem = 2 (Windows GUI)`；
- 同时回顾第 13 章的窗口代码，看看哪些"看似当然"的步骤其实由 CRT 悄悄提供过。
