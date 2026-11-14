# 第 21 章：ld 直接链接
# 不再经过 gcc 驱动，自己把入口、子系统、库路径讲清楚
NASM      := nasm
NASMFLAGS := -f win64
LD        := ld

# MinGW 导入库（libkernel32.a 等）所在目录
LIBDIR    := C:/msys64/ucrt64/lib

TARGET := lddirect.exe
OBJS   := lddirect.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(LD) -e _start --subsystem console -o $@ $^ -L $(LIBDIR) -lkernel32

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all clean
