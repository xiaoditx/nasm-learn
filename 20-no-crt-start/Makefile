# 第 20 章：_start 入口
# 关键：-nostartfiles 去掉 CRT 启动文件，-Wl,-e,_start 显式指定入口
NASM      := nasm
NASMFLAGS := -f win64

TARGET := start.exe
OBJS   := start.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	gcc -nostartfiles -Wl,-e,_start -o $@ $^ -lkernel32

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all clean
