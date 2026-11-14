NASM := nasm
CC   := gcc

NASMFLAGS := -f win64
CFLAGS    := -municode -mwindows
LDLIBS    := -luser32 -ld2d1

TARGET := d2d_target.exe
OBJS   := d2d_target.obj

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

%.obj: %.asm ../common.asm
	$(NASM) $(NASMFLAGS) -l $@.lst -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS) $(OBJS:.obj=.obj.lst)

.PHONY: all clean
