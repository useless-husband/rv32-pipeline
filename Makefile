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

# ------------------------------------------------------ Verilator models
# Two simulators built from the same harness: build/vsim_single (core A) and
# build/vsim_pipe (core B).  Verilator writes C++; we compile it directly.
VROOT := $(shell $(VERILATOR) --getenv VERILATOR_ROOT 2>/dev/null)
VDEFS := -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TIMING=0 -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 \
         -DVM_TRACE_SAIF=0
VFLAGS := --cc -O3 --x-assign fast --x-initial fast --noassert -Irtl --prefix Vtop -Wno-fatal
RTL_COMMON := rtl/decoder.sv rtl/alu.sv rtl/regfile.sv rtl/lsu_align.sv rtl/csr_file.sv
RTL_SINGLE := $(RTL_COMMON) rtl/muldiv_comb.sv rtl/core_single.sv
SIM_SINGLE := $(RTL_SINGLE) rtl/sim/sim_top_single.sv
VSIM_CXX = $(CXX) -std=c++17 -O2 -w $(VDEFS) -Imodel -Isim -Ibuild/$(1) -I$(VROOT)/include \
  -I$(VROOT)/include/vltstd build/$(1)/*.cpp $(VROOT)/include/verilated.cpp \
  $(VROOT)/include/verilated_threads.cpp sim/sim_main.cpp build/iss/rv_iss.o build/iss/disasm.o

build/iss/%.o: model/%.c model/rv_iss.h model/rv_platform.h
	@mkdir -p build/iss
	$(CC) -std=c11 -O2 -Wall -c -o $@ $<

build/vsim_single: $(SIM_SINGLE) rtl/rv_defs.svh sim/sim_main.cpp build/iss/rv_iss.o build/iss/disasm.o
	rm -rf build/vm_single
	$(VERILATOR) $(VFLAGS) -Mdir build/vm_single --top-module sim_top_single $(SIM_SINGLE)
	$(call VSIM_CXX,vm_single) -o $@ -lpthread

RTL_PIPE := $(RTL_COMMON) rtl/bpred.sv rtl/divider.sv rtl/mem_arbiter.sv rtl/icache.sv rtl/dcache.sv \
            rtl/core_pipe.sv
SIM_PIPE := $(RTL_PIPE) rtl/sim/mem_model.sv rtl/sim/sim_top_pipe.sv
# extra -G overrides for the pipelined simulator, e.g. PIPE_G="-GMEM_LATENCY=50"
PIPE_G ?=

build/vsim_pipe: $(SIM_PIPE) rtl/rv_defs.svh sim/sim_main.cpp sim/pipeview.inc build/iss/rv_iss.o build/iss/disasm.o
	rm -rf build/vm_pipe
	$(VERILATOR) $(VFLAGS) -Mdir build/vm_pipe --top-module sim_top_pipe $(PIPE_G) $(SIM_PIPE)
	$(call VSIM_CXX,vm_pipe) -DHAVE_PIPEVIEW -o $@ -lpthread

# ------------------------------------------------------------------ lint
lint:
	$(VERILATOR) --lint-only -Wall -Irtl --top-module sim_top_single $(SIM_SINGLE)
	$(VERILATOR) --lint-only -Wall -Irtl --top-module sim_top_pipe $(SIM_PIPE)
	@echo "lint: verilator -Wall clean"

# ----------------------------------------------------------------- tests
.PHONY: lint check-python unit system test random-one venv iss-test
check-python:
	@$(PYTHON) -c "import cocotb, pytest" 2>/dev/null || { \
	  echo "cocotb/pytest not found for $(PYTHON)."; \
	  echo "Run 'make venv' once (creates $(VENV)), or pass PYTHON=/path/to/python."; exit 1; }

SIMS := build/vsim_single build/vsim_pipe
PYENV := CLANG="$(CLANG)" LLD="$(LLD)"

system: check-python $(SIMS) rvtests sw
	rm -rf build/random
	$(PYENV) $(PYTHON) -m pytest -q tests/system

# one random program on one core, e.g. make random-one SEED=17 CORE=pipe
SEED ?= 1
CORE ?= pipe
LENGTH ?= 3000
random-one: build/vsim_$(CORE)
	@mkdir -p build/random
	$(PYTHON) tests/random/rvgen.py --seed $(SEED) --length $(LENGTH) -o build/random/one.S
	$(CLANG) $(RVARCH) -Imodel -c -o build/random/one.o build/random/one.S
	$(LLD) -T sw/runtime/link.ld -o build/random/one.elf build/random/one.o
	./build/vsim_$(CORE) --quiet --stats --trace build/random/one.trace build/random/one.elf

test: lint iss-test unit system

venv:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r requirements-dev.txt
