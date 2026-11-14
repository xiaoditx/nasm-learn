# 第 22 章：无 CRT 的 GUI 窗口
# ld 直连，子系统换成 windows，库换成 user32 + kernel32
NASM      := nasm
NASMFLAGS := -f win64
LD        := ld

# MinGW 导入库（libuser32.a / libkernel32.a）所在目录
LIBDIR    := C:/msys64/ucrt64/lib

TARGET := win_nocrt.exe
OBJS   := win_nocrt.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(LD) -e _start --subsystem windows -o $@ $^ -L $(LIBDIR) -luser32 -lkernel32

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all clean
