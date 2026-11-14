NASM := nasm
CC   := gcc

NASMFLAGS := -f win64
CFLAGS    := -municode

TARGET := args.exe
OBJS   := args.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

run: $(TARGET)
	./$(TARGET) alpha beta

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all run clean
