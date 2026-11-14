NASM := nasm
CC   := gcc

NASMFLAGS := -f win64
CFLAGS    := -municode

TARGET := fileio.exe
OBJS   := fileio.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst) demo_file.txt

.PHONY: all run clean
