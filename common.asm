; ============================================================
; common.asm —— 全项目共享定义
; 只包含预处理指令、常量与宏，不产生任何段/数据。
; 用法：在章节目录中写  %include "../common.asm"
; ============================================================

; ---------- Windows x64 栈约定 ----------
%define SHADOW_SPACE          32      ; 调用前必须预留的影子空间
%define ENTRY_SUB_RSP         40      ; 入口 RSP%16==8 → 减 40 后 %16==0
%define FRAME_SUB_RSP         32      ; push rbp 之后 %16==0 → 再减 32

; ---------- 通用常量 ----------
%define NULL                  0
%define TRUE                  1
%define FALSE                 0
%define WCHAR_SIZE            2       ; UTF-16 码元大小
%define MAX_PATH_W            260

; ---------- 标准设备 ----------
%define STD_OUTPUT_HANDLE     -11
%define STD_ERROR_HANDLE      -12

; ---------- 文件 ----------
%define INVALID_HANDLE_VALUE  -1
%define GENERIC_READ          0x80000000
%define GENERIC_WRITE         0x40000000
%define CREATE_ALWAYS         2
%define OPEN_EXISTING         3
%define FILE_ATTRIBUTE_NORMAL 0x80

; ---------- 错误码 ----------
%define ERROR_FILE_NOT_FOUND  2
%define ERROR_PATH_NOT_FOUND  3
%define ERROR_ACCESS_DENIED   5

; ---------- 代码页 ----------
%define CP_UTF8               65001

; ---------- 堆 ----------
%define HEAP_ZERO_MEMORY      8

; ---------- 宽字符串宏（UTF-16LE） ----------
; WSTR  ：展开为 UTF-16LE 码元，不带结尾 0
; WSTRZ ：展开为 UTF-16LE 码元，并追加一个 0 结尾
%macro WSTR 1
    dw __utf16__(%1)
%endmacro

%macro WSTRZ 1
    dw __utf16__(%1), 0
%endmacro

; ---------- COM 方法调用（第 16 章起） ----------
; 用法：COM_CALL <持有接口指针的寄存器>, <虚表槽位>
; 只破坏 RAX；调用参数必须在宏展开前放进 RCX/RDX/R8/R9 和栈。
; 例：mov rcx, [rel p_rt]  →  rcx = this
;     lea rdx, [rel color]
;     COM_CALL rcx, 47        ; ID2D1RenderTarget::Clear
%macro COM_CALL 2
    mov  rax, [%1]
    call qword [rax + (%2) * 8]
%endmacro

; ---------- 第 12 章：文本统计结构（多个 .asm 共用） ----------
struc TEXT_STATS
    .chars: resd 1
    .lines: resd 1
    .words: resd 1
endstruc

; ============================================================
; 第 13 章起：Win32 窗口与消息
; 常量值全部来自 MinGW 头文件（winuser.h / winbase.h）
; ============================================================

%define WS_OVERLAPPEDWINDOW   0x00CF0000
%define WS_VISIBLE           0x10000000
%define CW_USEDEFAULT        0x80000000
%define CS_VREDRAW           0x0001
%define CS_HREDRAW           0x0002
%define SW_SHOWNORMAL        1
%define SW_SHOW              5
%define IDC_ARROW            32512
%define IDI_APPLICATION      32512
%define COLOR_WINDOW         5
%define COLOR_WINDOWTEXT     8

%define WM_CREATE            0x0001
%define WM_DESTROY           0x0002
%define WM_SIZE              0x0005
%define WM_ACTIVATE          0x0006
%define WM_PAINT             0x000F
%define WM_CLOSE             0x0010
%define WM_ERASEBKGND        0x0014
%define WM_KEYDOWN           0x0100
%define WM_KEYUP             0x0101
%define WM_CHAR              0x0102
%define WM_TIMER             0x0113
%define WM_LBUTTONDOWN       0x0201

%define VK_ESCAPE            0x1B
%define VK_SPACE             0x20
%define VK_LEFT              0x25
%define VK_UP                0x26
%define VK_RIGHT             0x27
%define VK_DOWN              0x28
%define PM_REMOVE            0x0001

%define TRANSPARENT          1
%define DT_LEFT              0
%define DT_TOP               0
%define DT_CENTER            0x0001
%define DT_SINGLELINE        0x0020

; WNDCLASSEXW：winuser.h:897-910。x64 下 sizeof == 80。
; 注意 cbClsExtra(16) 与 cbWndExtra(20) 之间没有填充，
; 但 hInstance 位于 24，正好是 8 字节对齐，所以这里不需要手工补位。
struc WNDCLASSEXW
    .cbSize:        resd 1      ; +0
    .style:         resd 1      ; +4
    .lpfnWndProc:   resq 1      ; +8
    .cbClsExtra:    resd 1      ; +16
    .cbWndExtra:    resd 1      ; +20
    .hInstance:     resq 1      ; +24
    .hIcon:         resq 1      ; +32
    .hCursor:       resq 1      ; +40
    .hbrBackground: resq 1      ; +48
    .lpszMenuName:  resq 1      ; +56
    .lpszClassName: resq 1      ; +64
    .hIconSm:       resq 1      ; +72
endstruc                        ; = 80

; MSG：winuser.h:955-961。x64 下 sizeof == 48。
; message 之后有 4 字节隐式填充（wParam 必须 8 对齐），
; 末尾 pt 之后还有 4 字节尾部填充。NASM 的 struc 不会自动补，
; 所以显式写 .pad0 / .pad1。
struc MSG
    .hwnd:      resq 1          ; +0
    .message:   resd 1          ; +8
    .pad0:      resd 1          ; +12  隐式填充
    .wParam:    resq 1          ; +16
    .lParam:    resq 1          ; +24
    .time:      resd 1          ; +32
    .pt_x:      resd 1          ; +36
    .pt_y:      resd 1          ; +40
    .pad1:      resd 1          ; +44  尾部填充
endstruc                        ; = 48

; PAINTSTRUCT：winuser.h:1823-1830。x64 下 sizeof == 72。
struc PAINTSTRUCT
    .hdc:           resq 1      ; +0
    .fErase:        resd 1      ; +8
    .rcPaint_left:  resd 1      ; +12
    .rcPaint_top:   resd 1      ; +16
    .rcPaint_right: resd 1      ; +20
    .rcPaint_bottom:resd 1      ; +24
    .fRestore:      resd 1      ; +28
    .fIncUpdate:    resd 1      ; +32
    .rgbReserved:   resb 32     ; +36
    .pad:           resb 4      ; +68  补齐到 8 的倍数
endstruc                        ; = 72

; RECT：windef.h，4 个 LONG，共 16 字节
struc RECT
    .left:   resd 1
    .top:    resd 1
    .right:  resd 1
    .bottom: resd 1
endstruc                        ; = 16

; ============================================================
; 第 17 章起：Direct2D 结构体
; 布局来自 MinGW：d2d1.h / dcommon.h / d2dbasetypes.h
; ============================================================

%define D2D1_FACTORY_TYPE_SINGLE_THREADED  0
%define D2D1_FACTORY_TYPE_MULTI_THREADED   1

%define D2D1_RENDER_TARGET_TYPE_DEFAULT    0
%define D2D1_RENDER_TARGET_TYPE_HARDWARE   1
%define D2D1_RENDER_TARGET_TYPE_SOFTWARE   2

%define D2D1_ALPHA_MODE_UNKNOWN            0
%define D2D1_ALPHA_MODE_PREMULTIPLIED      1
%define D2D1_ALPHA_MODE_STRAIGHT           2
%define D2D1_ALPHA_MODE_IGNORE             3

%define DXGI_FORMAT_UNKNOWN                 0
%define DXGI_FORMAT_B8G8R8A8_UNORM          87

%define D2D1_PRESENT_OPTIONS_NONE           0
%define D2D1_PRESENT_OPTIONS_RETAIN_CONTENTS 1
%define D2D1_PRESENT_OPTIONS_IMMEDIATELY    2

%define D2D1_WINDOW_STATE_NONE              0
%define D2D1_WINDOW_STATE_OCCLUDED          1
%define D2D1_WINDOW_STATE_HIDDEN            2

; 虚表槽位（d2d1.h 中 ID2D1RenderTargetVtbl / ID2D1HwndRenderTargetVtbl 的顺序）
%define D2D1_RT_CREATE_SOLID_COLOR_BRUSH    8
%define D2D1_RT_DRAW_RECTANGLE              16
%define D2D1_RT_FILL_RECTANGLE              17
%define D2D1_RT_FILL_ELLIPSE                21
%define D2D1_RT_CLEAR                       47
%define D2D1_RT_BEGIN_DRAW                  48
%define D2D1_RT_END_DRAW                    49
%define D2D1_HWND_RT_RESIZE                 58
%define D2D1_FACTORY_CREATE_HWND_RT         14
%define IUNKNOWN_QUERY_INTERFACE            0
%define IUNKNOWN_ADD_REF                    1
%define IUNKNOWN_RELEASE                    2

; HRESULT 成功码的常用判断值
%define S_OK                                0
%define D2DERR_RECREATE_TARGET              0x8899000C

; D2D1_PIXEL_FORMAT：dcommon.h:68-71，8 字节
struc D2D1_PIXEL_FORMAT
    .format:    resd 1          ; DXGI_FORMAT
    .alphaMode: resd 1          ; D2D1_ALPHA_MODE
endstruc                        ; = 8

; D2D1_RENDER_TARGET_PROPERTIES：d2d1.h:453-460，28 字节
; 全部填 0 就是“默认硬件渲染目标 + 未知像素格式”
struc D2D1_RENDER_TARGET_PROPERTIES
    .type:                  resd 1   ; +0
    .pixelFormat_format:    resd 1   ; +4
    .pixelFormat_alphaMode: resd 1   ; +8
    .dpiX:                  resd 1   ; +12
    .dpiY:                  resd 1   ; +16
    .usage:                 resd 1   ; +20
    .minLevel:              resd 1   ; +24
endstruc                              ; = 28

; D2D1_HWND_RENDER_TARGET_PROPERTIES：d2d1.h:420-424，24 字节
struc D2D1_HWND_RENDER_TARGET_PROPERTIES
    .hwnd:           resq 1      ; +0
    .pixelSize_width:  resd 1    ; +8
    .pixelSize_height: resd 1    ; +12
    .presentOptions: resd 1      ; +16
    .pad:            resd 1      ; +20  尾部填充
endstruc                          ; = 24

; D2D1_COLOR_F == D3DCOLORVALUE，4 个 FLOAT，16 字节
struc D2D1_COLOR_F
    .r: resd 1
    .g: resd 1
    .b: resd 1
    .a: resd 1
endstruc                        ; = 16

; D2D1_RECT_F == D2D_RECT_F，4 个 FLOAT，16 字节
struc D2D1_RECT_F
    .left:   resd 1
    .top:    resd 1
    .right:  resd 1
    .bottom: resd 1
endstruc                        ; = 16

; D2D1_SIZE_U，2 个 UINT32，8 字节
struc D2D1_SIZE_U
    .width:  resd 1
    .height: resd 1
endstruc                        ; = 8

; D2D1_ELLIPSE：d2d1.h:405，point + radiusX + radiusY，16 字节
struc D2D1_ELLIPSE
    .point_x: resd 1            ; +0
    .point_y: resd 1            ; +4
    .radiusX: resd 1            ; +8
    .radiusY: resd 1            ; +12
endstruc                        ; = 16

; D2D1_FACTORY_OPTIONS：d2d1.h:411-413，4 字节
struc D2D1_FACTORY_OPTIONS
    .debugLevel: resd 1
endstruc                        ; = 4

; D2D1_BRUSH_PROPERTIES：d2d1.h:392-395，28 字节
struc D2D1_BRUSH_PROPERTIES
    .opacity: resd 1            ; +0
    .m11: resd 1                ; +4
    .m12: resd 1                ; +8
    .m21: resd 1                ; +12
    .m22: resd 1                ; +16
    .m31: resd 1                ; +20
    .m32: resd 1                ; +24
endstruc                        ; = 28
