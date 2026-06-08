# Makefile for adacomp - Minimal self-hosting Ada compiler
# Bootstrapping chain: C bootstrap -> stage1 -> stage2 (self-hosting proof)

CC = gcc
CFLAGS = -O2 -Wall -Wno-unused-function
RUNTIME = runtime

.PHONY: all clean bootstrap stage1 stage2 test verify

all: bootstrap test

# Step 0: Build the C bootstrap compiler
bootstrap: build/bootstrap
build/bootstrap: bootstrap/adacomp.c | build
	$(CC) $(CFLAGS) -o $@ $<

# Step 1: Use bootstrap to compile the Ada compiler -> stage1
stage1: build/stage1
build/stage1: build/bootstrap src/adacomp.adb | build
	./build/bootstrap src/adacomp.adb build/adacomp_stage1.c
	$(CC) $(CFLAGS) -I$(RUNTIME) -o $@ build/adacomp_stage1.c

# Step 2: Use stage1 to compile the Ada compiler -> stage2 (self-hosting!)
stage2: build/stage2
build/stage2: build/stage1 src/adacomp.adb | build
	./build/stage1 src/adacomp.adb build/adacomp_stage2.c
	$(CC) $(CFLAGS) -I$(RUNTIME) -o $@ build/adacomp_stage2.c

# Verify self-hosting: stage1 and stage2 should produce identical C output
verify: build/stage1 build/stage2
	./build/stage1 src/adacomp.adb build/verify_s1.c
	./build/stage2 src/adacomp.adb build/verify_s2.c
	diff build/verify_s1.c build/verify_s2.c && echo "SELF-HOSTING VERIFIED: stage1 and stage2 produce identical output!"

# Test with sample programs
test: build/bootstrap
	@echo "=== Compiling hello.adb ==="
	./build/bootstrap test/hello.adb build/hello.c
	$(CC) $(CFLAGS) -I$(RUNTIME) -o build/hello build/hello.c
	./build/hello
	@echo ""
	@echo "=== Compiling factorial.adb ==="
	./build/bootstrap test/factorial.adb build/factorial.c
	$(CC) $(CFLAGS) -I$(RUNTIME) -o build/factorial build/factorial.c
	./build/factorial

build:
	mkdir -p build

clean:
	rm -rf build
