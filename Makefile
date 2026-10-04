# rv32-pipeline -- run every target from the repository root.
#
# Every path below is relative on purpose: the checkout may live in a
# directory whose name contains spaces or non-ASCII characters, which GNU make
# (and Verilator's generated makefiles) cannot handle in absolute paths.  For
# the same reason the Verilator models are compiled with direct compiler
# calls instead of Verilator's own makefiles.

SHELL := /bin/bash
VENV ?= .venv
PYTHON ?= $(if $(wildcard $(VENV)/bin/python),$(VENV)/bin/python,python3)
VERILATOR ?= verilator
YOSYS ?= yosys
CC ?= cc
CXX ?= c++

# RISC-V cross compiler: clang with the riscv32 target and lld.  Homebrew's
# LLVM is preferred on macOS (Apple's clang has no RISC-V target).
CLANG ?= $(if $(wildcard /opt/homebrew/opt/llvm/bin/clang),/opt/homebrew/opt/llvm/bin/clang,clang)
LLD ?= $(if $(wildcard /opt/homebrew/opt/lld/bin/ld.lld),/opt/homebrew/opt/lld/bin/ld.lld,ld.lld)

# Third-party sources, fetched at build time at pinned commits (never committed).
RISCV_TESTS_URL := https://github.com/riscv-software-src/riscv-tests
RISCV_TESTS_SHA := bcffa2b3188b040c611f90dc0b6e422f54775a09
COREMARK_URL := https://github.com/eembc/coremark
COREMARK_SHA := 1f483d5b8316753a742cbf5590caf5bd0a4e4777
TP := build/third_party

RVARCH := --target=riscv32-unknown-elf -march=rv32im_zicsr_zifencei -mabi=ilp32
RVCFLAGS := $(RVARCH) -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -Wall -Isw/runtime -Imodel
RVLDFLAGS := -T sw/runtime/link.ld --gc-sections

.PHONY: all iss sw rvtests clean

all: test

.SECONDARY:

# ----------------------------------------------------------- golden model
ISS_SRC := model/rv_iss.c model/disasm.c
build/rvsim: $(ISS_SRC) model/rvsim.c model/rv_iss.h model/rv_platform.h
	@mkdir -p build
	$(CC) -std=c11 -O2 -Wall -Wextra -o $@ $(ISS_SRC) model/rvsim.c

iss: build/rvsim

# ---------------------------------------------------------- bare-metal sw
RT_OBJ := build/sw/crt0.o build/sw/rt.o
build/sw/crt0.o: sw/runtime/crt0.S model/rv_platform.h
	@mkdir -p build/sw
	$(CLANG) $(RVCFLAGS) -c -o $@ $<
build/sw/rt.o: sw/runtime/rt.c sw/runtime/rt.h model/rv_platform.h
	@mkdir -p build/sw
	$(CLANG) $(RVCFLAGS) -c -o $@ $<
build/sw/%.elf: sw/demo/%.c $(RT_OBJ) sw/runtime/link.ld
	$(CLANG) $(RVCFLAGS) -c -o build/sw/$*.o $<
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ) build/sw/$*.o

sw: build/sw/hello.elf

clean:
	rm -rf build

# ------------------------------------------------------- riscv-tests (ISA)
# The lists below are the pinned commit's isa/rv32ui/Makefrag and
# isa/rv32um/Makefrag; tests/system/test_riscv_tests.py checks they match.
RV32UI := simple add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr \
          lb lbu lh lhu lw ld_st lui ma_data or ori sb sh sw st_ld sll slli slt slti sltiu sltu \
          sra srai srl srli sub xor xori
RV32UM := div divu mul mulh mulhsu mulhu rem remu
RVTESTS := $(addprefix rv32ui-,$(RV32UI)) $(addprefix rv32um-,$(RV32UM))
RVTEST_ELFS := $(addprefix build/rvtests/,$(addsuffix .elf,$(RVTESTS)))
ENV_OBJ := build/rvtests/env/trap_entry.o build/rvtests/env/trap.o

$(TP)/riscv-tests/.stamp:
	rm -rf $(TP)/riscv-tests && mkdir -p $(TP)/riscv-tests
	cd $(TP)/riscv-tests && git init -q && git fetch -q --depth 1 $(RISCV_TESTS_URL) $(RISCV_TESTS_SHA) \
	  && git checkout -q FETCH_HEAD
	@touch $@

build/rvtests/env/trap_entry.o: tests/env/trap_entry.S
	@mkdir -p build/rvtests/env
	$(CLANG) $(RVCFLAGS) -c -o $@ $<
build/rvtests/env/trap.o: tests/env/trap.c model/rv_platform.h
	@mkdir -p build/rvtests/env
	$(CLANG) $(RVCFLAGS) -c -o $@ $<

build/rvtests/rv32u%.elf: $(TP)/riscv-tests/.stamp tests/env/riscv_test.h $(ENV_OBJ) sw/runtime/link.ld
	@mkdir -p build/rvtests
	$(CLANG) $(RVCFLAGS) -Itests/env -I$(TP)/riscv-tests/isa/macros/scalar \
	  -c -o build/rvtests/rv32u$*.o $(TP)/riscv-tests/isa/rv32u$(firstword $(subst -, ,$*))/$(lastword $(subst -, ,$*)).S
	$(LLD) $(RVLDFLAGS) -o $@ build/rvtests/rv32u$*.o $(ENV_OBJ)

rvtests: $(RVTEST_ELFS)

# every riscv-test on the golden model alone (the tests check themselves)
iss-test: build/rvsim rvtests
	@pass=0; fail=0; for t in $(RVTESTS); do \
	  if ./build/rvsim --quiet build/rvtests/$$t.elf; then pass=$$((pass+1)); else echo "FAIL $$t"; fail=$$((fail+1)); fi; \
	done; echo "golden model: $$pass passed, $$fail failed"; [ $$fail -eq 0 ]
