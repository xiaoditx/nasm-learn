# 第 23 章：无 CRT 工具库（多文件工程）
# 两个 .asm 各自汇编成 .obj，ld 一次性链接
NASM      := nasm
NASMFLAGS := -f win64
LD        := ld

LIBDIR    := C:/msys64/ucrt64/lib

TARGET := freestanding.exe
OBJS   := main.obj utils.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(LD) -e _start --subsystem console -o $@ $^ -L $(LIBDIR) -lkernel32

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all clean
