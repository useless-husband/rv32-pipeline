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
SOFTFLOAT_URL := https://github.com/ucb-bar/berkeley-softfloat-3
SOFTFLOAT_SHA := a0c6494cdc11865811dec815d5c0049fba9d82a8
TESTFLOAT_URL := https://github.com/ucb-bar/berkeley-testfloat-3
TESTFLOAT_SHA := a9c849f1b0eb0264b626d9686ffae167d996e3be
TP := build/third_party

RVARCH := --target=riscv32-unknown-elf -march=rv32im_zicsr_zifencei -mabi=ilp32
RVCFLAGS := $(RVARCH) -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -Wall -Isw/runtime -Imodel
# programs for the core with the FPU (core B, FPU=1): hardware double, doubles passed in f registers
RVARCH_FD := --target=riscv32-unknown-elf -march=rv32imfd_zicsr_zifencei -mabi=ilp32d
RVCFLAGS_FD := $(RVARCH_FD) -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -Wall -Isw/runtime -Imodel
RVLDFLAGS := -T sw/runtime/link.ld --gc-sections

.PHONY: all iss sw rvtests clean

all: test

.SECONDARY:

# ----------------------------------------------------------- golden model
ISS_SRC := model/rv_iss.c model/rv_fp.c model/disasm.c
ISS_HDR := model/rv_iss.h model/rv_fp.h model/rv_platform.h
build/rvsim: $(ISS_SRC) model/rvsim.c $(ISS_HDR)
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

sw: build/sw/hello.elf build/sw/demo.elf build/sw/fpdemo.elf

# the same runtime for programs that use the FPU (hardware double ABI)
RT_OBJ_FD := build/sw_fd/crt0.o build/sw_fd/rt.o
build/sw_fd/crt0.o: sw/runtime/crt0.S model/rv_platform.h
	@mkdir -p build/sw_fd
	$(CLANG) $(RVCFLAGS_FD) -c -o $@ $<
build/sw_fd/rt.o: sw/runtime/rt.c sw/runtime/rt.h model/rv_platform.h
	@mkdir -p build/sw_fd
	$(CLANG) $(RVCFLAGS_FD) -c -o $@ $<

clean:
	rm -rf build

# ------------------------------------------------------- riscv-tests (ISA)
# The lists below are the pinned commit's isa/rv32{ui,um,uf,ud}/Makefrag;
# tests/system/test_riscv_tests.py checks they match.  The F and D tests
# need a core with the FPU (and the golden model with --fpu).
RV32UI := simple add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr \
          lb lbu lh lhu lw ld_st lui ma_data or ori sb sh sw st_ld sll slli slt slti sltiu sltu \
          sra srai srl srli sub xor xori
RV32UM := div divu mul mulh mulhsu mulhu rem remu
RV32UF := fadd fdiv fclass fcmp fcvt fcvt_w fmadd fmin ldst move recoding
RV32UD := fadd fdiv fclass fcmp fcvt fcvt_w fmadd fmin ldst recoding
RVTESTS := $(addprefix rv32ui-,$(RV32UI)) $(addprefix rv32um-,$(RV32UM))
RVTESTS_FD := $(addprefix rv32uf-,$(RV32UF)) $(addprefix rv32ud-,$(RV32UD))
RVTEST_ELFS := $(addprefix build/rvtests/,$(addsuffix .elf,$(RVTESTS) $(RVTESTS_FD)))
# rv32uf/rv32ud are assembled with F and D enabled (the integer ABI is kept:
# the tests are assembly and the trap handler is integer-only C)
RVT_MARCH = $(if $(filter f-% d-%,$*),-march=rv32imfd_zicsr_zifencei,)
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
	$(CLANG) $(RVCFLAGS) $(RVT_MARCH) -Itests/env -I$(TP)/riscv-tests/isa/macros/scalar \
	  -c -o build/rvtests/rv32u$*.o $(TP)/riscv-tests/isa/rv32u$(firstword $(subst -, ,$*))/$(lastword $(subst -, ,$*)).S
	$(LLD) $(RVLDFLAGS) -o $@ build/rvtests/rv32u$*.o $(ENV_OBJ)

rvtests: $(RVTEST_ELFS)

# every riscv-test on the golden model alone (the tests check themselves)
iss-test: build/rvsim rvtests
	@pass=0; fail=0; for t in $(RVTESTS); do \
	  if ./build/rvsim --quiet build/rvtests/$$t.elf; then pass=$$((pass+1)); else echo "FAIL $$t"; fail=$$((fail+1)); fi; \
	done; for t in $(RVTESTS_FD); do \
	  if ./build/rvsim --fpu --quiet build/rvtests/$$t.elf; then pass=$$((pass+1)); else echo "FAIL $$t"; fail=$$((fail+1)); fi; \
	done; echo "golden model: $$pass passed, $$fail failed"; [ $$fail -eq 0 ]

# ------------------------------------------- Berkeley TestFloat (IEEE 754)
# SoftFloat and TestFloat are fetched and built at pinned commits (never
# committed); only testfloat_gen, the vector generator, is used.  SoftFloat
# is built with its RISC-V specialisation (canonical NaNs, RISC-V integer
# results for invalid conversions).  Their generic "Linux-x86_64-GCC" build
# directory also works on arm64 and on macOS.
TFDIR := build/Linux-x86_64-GCC
TFGEN := $(TP)/berkeley-testfloat-3/$(TFDIR)/testfloat_gen
$(TFGEN):
	rm -rf $(TP)/berkeley-softfloat-3 $(TP)/berkeley-testfloat-3
	mkdir -p $(TP)/berkeley-softfloat-3 $(TP)/berkeley-testfloat-3
	cd $(TP)/berkeley-softfloat-3 && git init -q && git fetch -q --depth 1 $(SOFTFLOAT_URL) $(SOFTFLOAT_SHA) \
	  && git checkout -q FETCH_HEAD
	cd $(TP)/berkeley-testfloat-3 && git init -q && git fetch -q --depth 1 $(TESTFLOAT_URL) $(TESTFLOAT_SHA) \
	  && git checkout -q FETCH_HEAD
	$(MAKE) -C $(TP)/berkeley-softfloat-3/$(TFDIR) SPECIALIZE_TYPE=RISCV softfloat.a > $(TP)/softfloat.log 2>&1
	$(MAKE) -C $(TP)/berkeley-testfloat-3/$(TFDIR) SPECIALIZE_TYPE=RISCV testfloat_gen > $(TP)/testfloat.log 2>&1

build/fp_check: tests/fp/fp_check.c model/rv_fp.c model/rv_fp.h
	@mkdir -p build
	$(CC) -std=c11 -O2 -Wall -Wextra -Imodel -o $@ tests/fp/fp_check.c model/rv_fp.c

# the golden model's arithmetic against TestFloat: every operation, both
# formats, all five rounding modes (about 62 million vectors, under a minute)
.PHONY: fp-model-test
fp-model-test: build/fp_check $(TFGEN)
	python3 tests/fp/testfloat.py --gen $(TFGEN) --check build/fp_check | tee build/fp-model-test.md

# ------------------------------------------------------ Verilator models
# Two simulators built from the same harness: build/vsim_single (core A) and
# build/vsim_pipe (core B).  Verilator writes C++; we compile it directly.
VROOT := $(shell $(VERILATOR) --getenv VERILATOR_ROOT 2>/dev/null)
VDEFS := -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TIMING=0 -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 \
         -DVM_TRACE_SAIF=0
VFLAGS := --cc -O3 --x-assign fast --x-initial fast --noassert -Irtl --prefix Vtop -Wno-fatal
FPU_RTL := rtl/fp_unpack.sv rtl/fp_roundup.sv rtl/fp_denorm.sv rtl/fp_round.sv rtl/fp_f2i.sv rtl/fp_misc.sv rtl/fp_ds_step.sv \
           rtl/fp_divsqrt.sv rtl/fp_fma.sv rtl/fpu.sv
RTL_COMMON := rtl/decoder.sv rtl/fp_decoder.sv rtl/alu.sv rtl/regfile.sv rtl/lsu_align.sv rtl/csr_file.sv
RTL_SINGLE := $(RTL_COMMON) rtl/muldiv_comb.sv rtl/core_single.sv
SIM_SINGLE := $(RTL_SINGLE) rtl/sim/sim_top_single.sv
VSIM_CXX = $(CXX) -std=c++17 -O2 -w $(VDEFS) -Imodel -Isim -Ibuild/$(1) -I$(VROOT)/include \
  -I$(VROOT)/include/vltstd build/$(1)/*.cpp $(VROOT)/include/verilated.cpp \
  $(VROOT)/include/verilated_threads.cpp sim/sim_main.cpp build/iss/rv_iss.o build/iss/rv_fp.o build/iss/disasm.o

ISS_OBJ := build/iss/rv_iss.o build/iss/rv_fp.o build/iss/disasm.o
build/iss/%.o: model/%.c $(ISS_HDR)
	@mkdir -p build/iss
	$(CC) -std=c11 -O2 -Wall -c -o $@ $<

build/vsim_single: $(SIM_SINGLE) rtl/rv_defs.svh sim/sim_main.cpp $(ISS_OBJ)
	rm -rf build/vm_single
	mkdir -p build/vm_single
	$(VERILATOR) $(VFLAGS) -Mdir build/vm_single --top-module sim_top_single $(SIM_SINGLE)
	$(call VSIM_CXX,vm_single) -o $@ -lpthread

RTL_PIPE := $(RTL_COMMON) rtl/bpred.sv rtl/divider.sv rtl/mem_arbiter.sv rtl/icache.sv rtl/dcache.sv \
            $(FPU_RTL) rtl/fp_regfile.sv rtl/core_pipe.sv
SIM_PIPE := $(RTL_PIPE) rtl/sim/mem_model.sv rtl/sim/sim_top_pipe.sv
# extra -G overrides for the pipelined simulator, e.g. PIPE_G="-GMEM_LATENCY=50"
PIPE_G ?=

build/vsim_pipe: $(SIM_PIPE) rtl/rv_defs.svh sim/sim_main.cpp sim/pipeview.inc $(ISS_OBJ)
	rm -rf build/vm_pipe
	mkdir -p build/vm_pipe
	$(VERILATOR) $(VFLAGS) -Mdir build/vm_pipe --top-module sim_top_pipe $(PIPE_G) $(SIM_PIPE)
	$(call VSIM_CXX,vm_pipe) -DHAVE_PIPEVIEW -o $@ -lpthread

# ------------------------------------------------- FPU unit testbench
# rtl/fpu.sv alone under Verilator, against TestFloat vectors and against
# the golden model's arithmetic on random operands (tests/fp/fpu_tb.cpp).
build/fpu_tb: $(FPU_RTL) rtl/rv_defs.svh tests/fp/fpu_tb.cpp build/iss/rv_fp.o
	rm -rf build/vm_fpu
	mkdir -p build/vm_fpu
	$(VERILATOR) --cc -O3 --x-assign fast --x-initial fast --noassert -Irtl --prefix Vfpu -Wno-fatal \
	  -Mdir build/vm_fpu --top-module fpu $(FPU_RTL)
	$(CXX) -std=c++17 -O2 -w $(VDEFS) -Imodel -Ibuild/vm_fpu -I$(VROOT)/include -I$(VROOT)/include/vltstd \
	  build/vm_fpu/*.cpp $(VROOT)/include/verilated.cpp $(VROOT)/include/verilated_threads.cpp \
	  tests/fp/fpu_tb.cpp build/iss/rv_fp.o -o $@ -lpthread

# every TestFloat vector the model is checked with, through the RTL (a few
# minutes), then two million random operations of every kind
FPU_RANDOM ?= 2000000
.PHONY: fpu-unit
fpu-unit: build/fpu_tb $(TFGEN)
	python3 tests/fp/testfloat.py --gen $(TFGEN) --check build/fpu_tb | tee build/fpu-unit.md
	./build/fpu_tb --random $(FPU_RANDOM) 1 | tee -a build/fpu-unit.md

# core B with the FPU (RV32IMFD): the same sources, FPU = 1
build/vsim_pipe_fd: $(SIM_PIPE) rtl/rv_defs.svh sim/sim_main.cpp sim/pipeview.inc $(ISS_OBJ)
	rm -rf build/vm_pipe_fd
	mkdir -p build/vm_pipe_fd
	$(VERILATOR) $(VFLAGS) -Mdir build/vm_pipe_fd --top-module sim_top_pipe -GFPU=1 $(PIPE_G) $(SIM_PIPE)
	$(call VSIM_CXX,vm_pipe_fd) -DHAVE_PIPEVIEW -o $@ -lpthread

# ------------------------------------------------------------------ lint
lint:
	$(VERILATOR) --lint-only -Wall -Irtl --top-module sim_top_single $(SIM_SINGLE)
	$(VERILATOR) --lint-only -Wall -Irtl --top-module sim_top_pipe $(SIM_PIPE)
	$(VERILATOR) --lint-only -Wall -Irtl --top-module sim_top_pipe -GFPU=1 $(SIM_PIPE)
	$(VERILATOR) --lint-only -Wall -Irtl --top-module fpu $(FPU_RTL)
	@echo "lint: verilator -Wall clean"

# ----------------------------------------------------------------- tests
.PHONY: lint check-python unit system test random-one random-soak venv iss-test
check-python:
	@$(PYTHON) -c "import cocotb, pytest" 2>/dev/null || { \
	  echo "cocotb/pytest not found for $(PYTHON)."; \
	  echo "Run 'make venv' once (creates $(VENV)), or pass PYTHON=/path/to/python."; exit 1; }

unit: check-python
	$(PYTHON) -m pytest -q tests/unit

SIMS := build/vsim_single build/vsim_pipe build/vsim_pipe_fd
PYENV := CLANG="$(CLANG)" LLD="$(LLD)"

system: check-python $(SIMS) rvtests sw benchmarks
	rm -rf build/random
	$(PYENV) $(PYTHON) -m pytest -q tests/system

# one random program on one core, e.g. make random-one SEED=17 CORE=pipe
# (with F and D instructions: make random-one SEED=17 CORE=pipe_fd FP=1)
SEED ?= 1
CORE ?= pipe
LENGTH ?= 3000
FP ?=
random-one: build/vsim_$(CORE)
	@mkdir -p build/random
	$(PYTHON) tests/random/rvgen.py --seed $(SEED) --length $(LENGTH) $(if $(FP),--fp) -o build/random/one.S
	$(CLANG) $(RVARCH) $(if $(FP),-march=rv32imfd_zicsr_zifencei) -Imodel -c -o build/random/one.o build/random/one.S
	$(LLD) -T sw/runtime/link.ld -o build/random/one.elf build/random/one.o
	./build/vsim_$(CORE) --quiet --stats --trace build/random/one.trace build/random/one.elf

# longer soak: 1000 integer programs on each core and 1000 F/D programs on the FPU core
random-soak: check-python $(SIMS)
	RANDOM_SEEDS=1000 $(PYENV) $(PYTHON) -m pytest -q tests/system/test_random.py

test: lint iss-test fp-model-test fpu-unit unit system

venv:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r requirements-dev.txt

# ------------------------------------------------------------ benchmarks
# CoreMark and Dhrystone are fetched at build time, unmodified; only the
# port layer (sw/bench) is ours.  Neither result is an official score: see
# docs/report.md section 7 for how they differ from the run rules.
CM_SRC := core_list_join.c core_main.c core_matrix.c core_state.c core_util.c
CM_FLAGS = $(RVCFLAGS) -Isw/bench/coremark -I$(TP)/coremark -DPERFORMANCE_RUN=1 \
           -DITERATIONS=$(1) -DFLAGS_STR='"-O2 (clang, rv32im)"'

$(TP)/coremark/.stamp:
	rm -rf $(TP)/coremark && mkdir -p $(TP)/coremark
	cd $(TP)/coremark && git init -q && git fetch -q --depth 1 $(COREMARK_URL) $(COREMARK_SHA) \
	  && git checkout -q FETCH_HEAD
	@touch $@

# coremark.elf: 10 iterations (tests); coremark-bench.elf: 40 iterations, which
# is just over 10 million cycles on either core (make bench)
build/sw/coremark.elf: ITER := 10
build/sw/coremark-bench.elf: ITER := 40
build/sw/coremark.elf build/sw/coremark-bench.elf: $(TP)/coremark/.stamp sw/bench/coremark/core_portme.c \
    sw/bench/coremark/core_portme.h $(RT_OBJ)
	@mkdir -p build/sw/$(basename $(notdir $@))
	for f in $(CM_SRC); do $(CLANG) $(call CM_FLAGS,$(ITER)) -c -o build/sw/$(basename $(notdir $@))/$${f%.c}.o \
	  $(TP)/coremark/$$f || exit 1; done
	$(CLANG) $(call CM_FLAGS,$(ITER)) -c -o build/sw/$(basename $(notdir $@))/core_portme.o sw/bench/coremark/core_portme.c
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ) build/sw/$(basename $(notdir $@))/*.o

DHRY_FLAGS := $(RVCFLAGS) -std=gnu89 -Isw/bench/include -Wno-implicit-int -Wno-implicit-function-declaration \
              -Wno-return-type -Wno-strict-prototypes -Wno-deprecated-non-prototype

build/sw/dhrystone.elf: $(TP)/riscv-tests/.stamp sw/bench/bench_support.c sw/bench/include/util.h $(RT_OBJ)
	@mkdir -p build/sw/dhrystone
	$(CLANG) $(DHRY_FLAGS) -c -o build/sw/dhrystone/dhrystone.o $(TP)/riscv-tests/benchmarks/dhrystone/dhrystone.c
	$(CLANG) $(DHRY_FLAGS) -c -o build/sw/dhrystone/dhrystone_main.o $(TP)/riscv-tests/benchmarks/dhrystone/dhrystone_main.c
	$(CLANG) $(RVCFLAGS) -Isw/bench/include -c -o build/sw/dhrystone/bench_support.o sw/bench/bench_support.c
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ) build/sw/dhrystone/*.o

benchmarks: build/sw/coremark.elf build/sw/dhrystone.elf

# -------------------------------------------- floating-point benchmark
# sw/bench/fpbench is built three ways: software floating point for RV32IM
# (compiler-rt's routines, fetched at a pinned LLVM commit, never committed),
# hardware floating point, and hardware with fused multiply-add contraction.
CRT_URL := https://github.com/llvm/llvm-project
CRT_SHA := 85ac560262434c9ccfc0c183ec22d4138ed647fb
CRT_DIR := $(TP)/llvm/compiler-rt/lib/builtins
CRT_FUNCS := adddf3 subdf3 muldf3 divdf3 comparedf2 fixdfsi floatsidf floatunsidf addsf3 subsf3 mulsf3 divsf3 \
             comparesf2 floatsisf floatunsisf fixsfsi extendsfdf2 truncdfsf2 clzsi2 clzdi2 fp_mode
CRT_OBJ := $(addprefix build/crt/,$(addsuffix .o,$(CRT_FUNCS)))

$(TP)/llvm/.stamp:
	rm -rf $(TP)/llvm && mkdir -p $(TP)/llvm
	cd $(TP)/llvm && git init -q && git remote add origin $(CRT_URL) \
	  && git config core.sparseCheckout true \
	  && git sparse-checkout set --no-cone compiler-rt/lib/builtins/ compiler-rt/LICENSE.TXT \
	  && git fetch -q --depth 1 --filter=blob:none origin $(CRT_SHA) && git checkout -q FETCH_HEAD
	@touch $@

build/crt/%.o: $(TP)/llvm/.stamp
	@mkdir -p build/crt
	$(CLANG) $(RVARCH) -O2 -ffreestanding -nostdlib -fno-pic -w -I$(CRT_DIR) -c -o $@ $(CRT_DIR)/$*.c

# a small floating-point demonstration for the core with the FPU
build/sw/fpdemo.elf: sw/demo/fpdemo.c $(RT_OBJ_FD) sw/runtime/link.ld
	$(CLANG) $(RVCFLAGS_FD) -fno-math-errno -c -o build/sw_fd/fpdemo.o sw/demo/fpdemo.c
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ_FD) build/sw_fd/fpdemo.o

.PHONY: fpdemo
fpdemo: build/vsim_pipe_fd build/sw/fpdemo.elf
	./build/vsim_pipe_fd --stats build/sw/fpdemo.elf

FPB_SRC := sw/bench/fpbench/fpbench.c
build/sw/fpbench-soft.elf: $(FPB_SRC) $(RT_OBJ) $(CRT_OBJ) sw/runtime/link.ld
	$(CLANG) $(RVCFLAGS) -ffp-contract=off -c -o build/sw/fpbench-soft.o $(FPB_SRC)
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ) build/sw/fpbench-soft.o $(CRT_OBJ)
build/sw/fpbench-hard.elf: $(FPB_SRC) $(RT_OBJ_FD) sw/runtime/link.ld
	$(CLANG) $(RVCFLAGS_FD) -fno-math-errno -ffp-contract=off -c -o build/sw_fd/fpbench-hard.o $(FPB_SRC)
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ_FD) build/sw_fd/fpbench-hard.o
build/sw/fpbench-fma.elf: $(FPB_SRC) $(RT_OBJ_FD) sw/runtime/link.ld
	$(CLANG) $(RVCFLAGS_FD) -fno-math-errno -ffp-contract=fast -c -o build/sw_fd/fpbench-fma.o $(FPB_SRC)
	$(LLD) $(RVLDFLAGS) -o $@ $(RT_OBJ_FD) build/sw_fd/fpbench-fma.o

FPB_ELFS := build/sw/fpbench-soft.elf build/sw/fpbench-hard.elf build/sw/fpbench-fma.elf
.PHONY: fp-bench
fp-bench: build/vsim_pipe build/vsim_pipe_fd build/fpu_tb $(FPB_ELFS)
	python3 tools/fpbench.py | tee build/fp-bench.md

# pipelined-core variants for the measurements (each is its own Verilator build)
G_nobp := -GBP_ENABLE=0
G_noras := -GRAS_DEPTH=0
G_ic8k := -GICACHE_SETS=512
G_lat1 := -GMEM_LATENCY=1
G_lat30 := -GMEM_LATENCY=30
VARIANTS := nobp noras ic8k lat1 lat30

build/vsim_pipe-%: $(SIM_PIPE) rtl/rv_defs.svh sim/sim_main.cpp sim/pipeview.inc $(ISS_OBJ)
	rm -rf build/vm_pipe-$*
	mkdir -p build/vm_pipe-$*
	$(VERILATOR) $(VFLAGS) -Mdir build/vm_pipe-$* --top-module sim_top_pipe $(G_$*) $(SIM_PIPE)
	$(call VSIM_CXX,vm_pipe-$*) -DHAVE_PIPEVIEW -o $@ -lpthread

.PHONY: bench benchmarks
bench: $(SIMS) $(addprefix build/vsim_pipe-,$(VARIANTS)) build/sw/coremark-bench.elf build/sw/dhrystone.elf
	python3 tools/bench.py | tee build/bench.md

# --------------------------------------------------------- pipeline viewer
# Default window: 200 cycles inside the demo's quicksort (calls, returns,
# data-dependent branches, load-use pairs).  Any window works:
#   make pipeview PV_PROG=build/sw/coremark.elf PV_FROM=500000 PV_CYCLES=300
PV_PROG ?= build/sw/demo.elf
PV_FROM ?= 382600
PV_CYCLES ?= 200
# the FPU core works too:  make pipeview PV_SIM=build/vsim_pipe_fd PV_PROG=build/sw/fpdemo.elf PV_FROM=20000
PV_SIM ?= build/vsim_pipe
.PHONY: pipeview
pipeview: $(PV_SIM) $(PV_PROG)
	./$(PV_SIM) --quiet --pipeview build/pipeview.json --pv-from $(PV_FROM) --pv-cycles $(PV_CYCLES) $(PV_PROG)
	python3 tools/pipeview.py build/pipeview.json -o build/pipeview.html \
	  --title "$(notdir $(PV_PROG)), cycles $(PV_FROM)-$$(($(PV_FROM)+$(PV_CYCLES)-1)), pipelined core."
	@echo "open build/pipeview.html in a browser"

# ------------------------------------------------------------- synthesis
.PHONY: synth sta
synth:
	mkdir -p build/synth/single build/synth/pipe build/synth/pipe_fd
	$(YOSYS) -q -l build/synth/single/yosys.log synth/synth_single.ys
	$(YOSYS) -q -l build/synth/pipe/yosys.log synth/synth_pipe.ys
	$(YOSYS) -q -l build/synth/pipe_fd/yosys.log synth/synth_pipe_fd.ys
	python3 tools/synth_report.py --check > synth/report.md
	@cat synth/report.md

# logic-only timing estimate (needs Yosys' sta pass; the report says what it is not)
sta:
	mkdir -p build/synth/single build/synth/pipe build/synth/pipe_fd
	$(YOSYS) -q -l build/synth/single/sta.log synth/sta_single.ys
	$(YOSYS) -q -l build/synth/pipe/sta.log synth/sta_pipe.ys
	$(YOSYS) -q -l build/synth/pipe_fd/sta.log synth/sta_pipe_fd.ys
	python3 tools/synth_report.py --timing > synth/timing.md
	@cat synth/timing.md

# what fits in one cycle: a 53 x 53 multiplier, a 53 x 17 one, a 165-bit adder
.PHONY: sta-blocks
sta-blocks:
	mkdir -p build/synth/blocks
	@for m in mul53x53 mul53x17 add165; do \
	  $(YOSYS) -q -l build/synth/blocks/$$m.log synth/sta_blk_$$m.ys || exit 1; \
	  echo "$$m: $$(sed -n "s/^Latest arrival time in .* is \([0-9]*\):/\1/p" build/synth/blocks/$$m.txt) ps"; \
	done

# ------------------------------------------------------ mutation checks
# needs the riscv-tests and random programs from `make system`
.PHONY: mutants
mutants: check-python $(TFGEN)
	$(PYTHON) tools/mutate.py | tee build/mutants.md
