# 第 24 章：纯汇编 D2D 小游戏（零 CRT）
# 三个系统库直连：user32（窗口/消息/定时器）+ kernel32（入口/退出）+ d2d1（渲染）
NASM      := nasm
NASMFLAGS := -f win64
LD        := ld

LIBDIR    := C:/msys64/ucrt64/lib

TARGET := breakout.exe
OBJS   := breakout.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(LD) -e _start --subsystem windows -o $@ $^ -L $(LIBDIR) -luser32 -lkernel32 -ld2d1

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all clean
