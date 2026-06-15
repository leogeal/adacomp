# Makefile for adacomp - Minimal self-hosting Ada compiler
# Bootstrapping chain: C bootstrap -> stage1 -> stage2 (self-hosting proof)

CC = gcc
CFLAGS = -O2 -Wall -Wno-unused-function
RUNTIME = runtime

.PHONY: all clean bootstrap stage1 stage2 test test-stage1 \
        test-multifile test-multifile-stage1 verify

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

# Run the .adb / .expected fixture suite under test/.
test: build/bootstrap
	@./test/run.sh

# Same suite, but against the self-hosted stage1 binary. Useful for
# catching divergence between the C bootstrap and the Ada self-host.
test-stage1: build/stage1
	@COMPILER=stage1 ./test/run.sh

# Separate-compilation demo: a package spec/body compiled to .h/.c and a
# main unit linked against it (the multi-file analogue of `test`).
test-multifile: build/bootstrap
	@./test/run_multifile.sh

test-multifile-stage1: build/stage1
	@COMPILER=stage1 ./test/run_multifile.sh

build:
	mkdir -p build

clean:
	rm -rf build
