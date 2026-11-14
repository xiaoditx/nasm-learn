NASM := nasm
CC   := gcc

NASMFLAGS := -f win64
CFLAGS    := -municode
LDLIBS    := -lole32 -lshell32

TARGET := comdemo.exe
OBJS   := comdemo.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all run clean
