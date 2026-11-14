NASM := nasm
CC   := gcc

NASMFLAGS := -f win64
CFLAGS    := -municode

TARGET := heap_structs.exe
OBJS   := heap_structs.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all run clean
