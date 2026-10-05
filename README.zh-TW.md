# rv32-pipeline

**從零用 SystemVerilog 寫的兩顆 RISC-V 處理器：一顆單週期參考核心，一顆有快取、分支預測器、
還可以加上浮點運算器（RV32IMFD）的五級管線核心；再加上證明它們正確的驗證：
兩顆核心完成的每一條指令，都在執行當下和黃金模型逐指令比對。**

這是模仿 MIT 6.1910（Computation Structures，前身 6.004）處理器專題的**學習用重做**：
課程裡學生先做單週期 RISC-V 核心，再做管線化核心。這裡沒有新發明，重點在核心以外的工程：
可執行的規格（黃金模型）、三層測試、證明測試抓得到錯的突變測試、附指令的實際量測、
以及針對真實 FPGA 型號的合成。全部都在模擬器上執行，**沒有**放到實體板子上跑過。

0.2.0 版替管線核心加上 F、D 兩個浮點擴充，做法是計算機結構課專題（MIT 6.5900、Berkeley CS 152）的路線：
先寫 IEEE 754 的黃金模型，再寫硬體，兩者都用 Berkeley TestFloat 驗證，最後量出浮點運算器換來什麼
（雙精度運算約快 19 倍）、花掉什麼（約 6,700 個 LUT）。
細節在[報告的浮點運算器一章](docs/report.md#12-floating-point-unit-f-and-d-extensions)。

[English](README.md) · [設計說明](docs/DESIGN.md) · [專題報告（6.1910 格式）](docs/report.md) ·
[初學者導讀](docs/導讀.zh-TW.md) · [合成報告](synth/report.md)

![核心 B：五級管線](docs/pipeline.svg)

## 內容

* **核心 A**（`rtl/core_single.sv`）：單週期 RV32IM，CPI 剛好 1，指令和資料記憶體是組合邏輯讀取
  （課程第一個處理器實驗的「魔法記憶體」）。架構圖：[docs/single_cycle.svg](docs/single_cycle.svg)。
* **核心 B**（`rtl/core_pipe.sv`）：IF / ID / EX / MEM / WB，從 MEM 和 WB 轉送、load-use 停一個週期、
  分支在 EX 決定（猜錯損失 2 週期）、預測器（128 項 BTB、256 個 2 位元計數器、8 層返回地址堆疊）、
  迭代除法器（每週期一個商位元，在 EX 停 34 週期）、精確例外，以及會先寫回 D-cache、再清空 I-cache 的 FENCE.I。
* **浮點運算器 FPU**（`rtl/fpu.sv`，核心 B 把參數設成 `FPU=1` 才有；預設 `FPU=0` 就是原本的 RV32IM 核心）：
  完整的 RV32F 和 RV32D、五種捨入模式、精確的例外旗標、`fcsr` 和 `mstatus.FS`。
  加、減、乘、四種融合乘加（FMA）和「轉成浮點數」共用一條乘加資料路徑（5 週期）；
  除法和開根號是迭代式，每週期算 2 個位元（雙精度 32 週期）；FLD/FSD 拆成兩次 32 位元存取。
  它是「多週期」單元：浮點指令會像除法一樣停在 EX 等結果。
* **快取**：4 KiB 直接映射 I-cache；4 KiB 2 路 LRU、write-back、write-allocate 的 D-cache，
  帶 store 到 load 的旁路；兩者都是 16 位元組的 line，陣列同步讀取（會對應到 block RAM）。
  兩個快取透過仲裁器共用一條記憶體匯流排；模擬記憶體的延遲可以設定（預設 10 週期）。
* **黃金模型**（`model/rv_iss.c`）：C 寫的指令集模擬器，每條指令輸出一筆 commit 紀錄
  （pc、指令、暫存器寫入、記憶體寫入、例外），也可以單獨當模擬器用（`build/rvsim`）。
  它的浮點運算（`model/rv_fp.c`）只用整數運算寫成，所以在任何電腦上算出來的位元都一樣。
* **機器模式**：Zicsr、Zifencei、ECALL/EBREAK/MRET、非法指令和未對齊存取的例外、
  `mcycle`、`minstret` 和十個硬體事件計數器（快取未命中、猜錯、load-use 停頓…）。
  完整清單在 [docs/DESIGN.md](docs/DESIGN.md#2-isa-what-is-and-is-not-implemented)。
* **軟體**：裸機執行環境（crt0、linker script、console 和結束暫存器、printf）、示範程式、
  在建置時從固定 commit 下載、用 clang/lld 編譯的 CoreMark 和 Dhrystone，
  以及一個同時編成「軟體浮點」和「硬體浮點」兩種版本的浮點效能測試。
* **管線檢視器**：`make pipeview` 把模擬結果變成一個靜態網頁，顯示每個週期每條指令在哪一站。
* **合成**：用 Yosys 把兩顆核心、以及加了 FPU 的核心 B 合成到 Spartan-7 XC7S50（Real Digital Urbana 板，和同系列專案 raycast-fpga 相同）。

## 結果

以下數字都在這台機器上量測（Apple M5、macOS，和其他工作共用；結果是模擬的週期數，不受機器負載影響），
附上產生它的指令。

| 項目 | 指令 | 結果 |
|---|---|---|
| 官方 riscv-tests rv32ui + rv32um + rv32uf + rv32ud（固定 commit），只跑黃金模型 | `make iss-test` | 71 / 71 通過 |
| rv32ui + rv32um 在核心 A、核心 B、加了 FPU 的核心 B 上；rv32uf + rv32ud 在加了 FPU 的核心 B 上；全部和模型 lockstep | `make system` | 171 / 171 通過 |
| 專門製造危障的隨機程式，seed 1-100，同樣三顆核心，lockstep | `make system` | 300 / 300 通過 |
| 含浮點指令的隨機程式，seed 1-100，加了 FPU 的核心 B，lockstep | `make system` | 100 / 100 通過 |
| 以上兩種，seed 1-1000（長時間測試） | `make random-soak` | 4,000 / 4,000 通過 |
| 黃金模型的 IEEE 754 運算對 Berkeley TestFloat：每種運算、兩種格式、五種捨入模式，結果和旗標都要相同 | `make fp-model-test` | 64,478,064 組，0 組不同 |
| RTL 的 FPU 跑同一批 TestFloat 測資，再和模型比 2,000,000 次隨機運算 | `make fpu-unit` | 64,478,064 + 2,000,000 組，0 組不同 |
| cocotb 單元測試（ALU、暫存器、解碼器、乘除法、除法器、預測器、I-cache、D-cache、CSR） | `make unit` | 11 / 11 通過 |
| RTL 和模型的單行突變（整數 16 個、浮點 21 個） | `make mutants` | 37 / 37 被抓到 |
| 核心 A、核心 B、加了 FPU 的核心 B、FPU 單獨的 `verilator --lint-only -Wall` | `make lint` | 無警告 |

效能（`make bench`，完整表格在 [docs/benchmarks.md](docs/benchmarks.md)）：

| 核心 | CoreMark 測試程式，40 次迭代 | Dhrystone，500 次 |
|---|---|---|
| A，單週期 | 10,362,422 週期，CPI 1.000，每百萬週期 3.86 次迭代 | 每次 519 週期，1.10 DMIPS/MHz |
| B，管線（預設） | 12,201,403 週期，CPI 1.177，每百萬週期 3.28 次迭代 | 每次 726 週期，0.78 DMIPS/MHz |
| B，I-cache 改 8 KiB | 12,114,455 週期，CPI 1.169 | 每次 571 週期，1.00 DMIPS/MHz |

核心 B 的條件分支猜對率：CoreMark 91.7%、Dhrystone 91.9%；跳躍和 return：97.2% 和 91.4%。
管線核心需要的週期數其實**比較多**（CoreMark 是 1.18 倍），它比較快只因為時脈可以快很多。
Yosys 只算邏輯延遲的估計（`make sta`，[synth/timing.md](synth/timing.md)，沒有繞線、不是 timing sign-off）：核心 A 最長路徑 56.2 ns
（經過組合邏輯除法器），核心 B 7.8 ns（經過單週期乘法器），換算 CoreMark 大約快 6 倍。
這個估計能說明什麼、不能說明什麼，寫在 [docs/report.md](docs/report.md#7-performance)。

浮點效能（`make fp-bench`，完整表格在 [docs/fp-benchmarks.md](docs/fp-benchmarks.md)）：同一份雙精度運算程式，
一次編成 RV32IM＋compiler-rt 的軟體浮點函式，一次編成 RV32IMFD，都在核心 B 上跑，週期數由核心自己的計數器讀出。
兩種版本算出的結果每個位元都相同。

| 測試 | 軟體浮點（週期） | 硬體 FPU（週期） | 加速 | 再開融合乘加 |
|---|---:|---:|---:|---:|
| n-body（8 個星體、12 步） | 3,789,153 | 126,950 | 29.8 倍 | 35.5 倍 |
| LU 分解 20 x 20 | 1,502,339 | 87,627 | 17.1 倍 | 21.7 倍 |
| Horner 多項式 | 1,263,836 | 54,159 | 23.3 倍 | 39.4 倍 |
| 曼德博集合 | 4,865,792 | 212,639 | 22.9 倍 | 25.9 倍 |
| FIR 濾波器（單精度） | 2,183,820 | 224,946 | 9.7 倍 | 13.8 倍 |
| 五個合計 | 13,624,530 | 723,846 | **18.8 倍** | 23.8 倍 |

FPU 的延遲（指令停在 EX 的週期數）：符號搬移、最大最小、比較、分類、搬移是 1；浮點轉整數是 2；
加、減、乘、融合乘加、轉成浮點數是 5；除法和開根號是 18（單精度）或 32（雙精度）。

**這些不是官方分數。** CoreMark 測試程式的 CRC 驗證通過，但那是在模擬器上用假想的 1 MHz 時脈跑的，
用的是下載的原始碼加上我們自己的移植層。Dhrystone 是 riscv-tests 版本，用 clang -O2 編譯。
這些數字只適合拿來比較兩顆核心。

CoreMark® 是 EEMBC® 的註冊商標。這個專案只是把未修改的 CoreMark 原始碼當成測試程式，
放在模擬器裡跑；上面的數字是模擬出來的週期數，不是 CoreMark 分數，也沒有經過 EEMBC 認證或送審。

合成到 XC7S50（`make synth`，[synth/report.md](synth/report.md)）：

| | LUT | 正反器 | Block RAM | DSP48E1 | 最長路徑，只算邏輯（`make sta`） |
|---|---:|---:|---:|---:|---:|
| 核心 A | 4,224（13.0%） | 960 | 0 | 4 | 56.2 ns |
| 核心 B | 9,305（28.5%） | 3,759 | 6.5 | 4 | 7.8 ns |
| 核心 B 加 FPU | 16,047（49.2%） | 5,308 | 6.5 | 16 | 8.0 ns |

FPU 多用 6,742 個 LUT、1,549 個正反器、12 個 DSP，整個設計仍然只佔晶片的一半。
加了 FPU 之後最長的路徑還是整數乘法器那一條，比沒加時長 0.2 ns（它前面的轉送多工器多了一層 LUT）；
FPU 裡面沒有比它更長的路徑，這正是 FPU 要做成多週期的原因（光是 53 x 53 位元的乘法就要 10.0 ns，`make sta-blocks`）。
`FPU=0` 時，正反器、block RAM、DSP 的數量和每個程式的週期數都和加 FPU 之前一樣。

## 示範

在 Finder 雙擊 `跑跑看.command`，或手動執行同樣的步驟：

```
$ make build/vsim_pipe build/sw/demo.elf
$ ./build/vsim_pipe --stats build/sw/demo.elf
rv32-pipeline demo: three small programs, each measured by the core's counters

[sieve] cycles=331474 instret=150493 CPI=2.203
[sieve] icache_misses=38 dcache_accesses=27014 dcache_misses=7199 dcache_writebacks=6808 branches=38216 ...
primes below 10000: 1229 (expected 1229)

[quicksort] cycles=48173 instret=42322 CPI=1.138
[quicksort] icache_misses=19 dcache_accesses=7966 dcache_misses=1 dcache_writebacks=0 branches=7355 ...
sorted 400 numbers: ok
...
cycles 817979  instret 577714  CPI 1.4159
```

篩法的 CPI 2.2 是 D-cache 造成的：它的 10 KB 陣列放不進 4 KiB，大部分 store 都會擠掉一條被改過的 line。
核心和模型答案不同時，執行會停在第一個不同的地方。下面是故意弄壞的核心 B
（拿掉 MEM 到 EX 的轉送，`make mutants` 會產生的突變之一）跑同一個示範程式：
`addi sp, sp, -132` 需要前一條 `auipc` 剛算出的 `sp`，沒有轉送就讀到舊值 0：

```
LOCKSTEP MISMATCH at commit 35, cycle 155
  last matching commits:
    ...
    8000007c 00002197 auipc gp, 0x2                x3 =8000207c
    80000080 f5818193 addi gp, gp, -168            x3 =80001fd4
    80000084 00100117 auipc sp, 0x100              x2 =80100084
  core : 80000088 f7c10113 addi sp, sp, -132            x2 =ffffff7c
  model: 80000088 f7c10113 addi sp, sp, -132            x2 =80100000
```

浮點示範（`make fpdemo`，也是 `跑跑看.command` 的最後一步）在加了 FPU 的核心 B 上跑，一樣逐指令和模型比對：

```
$ make fpdemo
1) 0.1 + 0.2 is not 0.3
   0.1       = 0x3fb999999999999a = 0.10000000000000000555
   0.2       = 0x3fc999999999999a = 0.20000000000000001110
   0.1 + 0.2 = 0x3fd3333333333334 = 0.30000000000000004440
   0.3       = 0x3fd3333333333333 = 0.29999999999999998889
   equal? no
2) 1/3 in the five rounding modes
   nearest-even +1/3 = 0x3fd5555555555555  -1/3 = 0xbfd5555555555555
   down         +1/3 = 0x3fd5555555555555  -1/3 = 0xbfd5555555555556
   up           +1/3 = 0x3fd5555555555556  -1/3 = 0xbfd5555555555555
   ...
3) special values
   1/0       = 0x7ff0000000000000 (infinity)
   flags: divide-by-zero
   sqrt(-1)  = 0x7ff8000000000000 (NaN)
   flags: invalid
   ...
```

`make pipeview` 產生 `build/pipeview.html`：示範程式 quicksort 中的 200 個週期，
每列一條指令、每欄一個週期；小寫字母是停頓，刪除線的列是猜錯路徑上被沖掉的指令：

![管線檢視器](docs/media/pipeview.png)

## 驗證怎麼做

1. **黃金模型**：`model/rv_iss.c` 照規格實作 ISA，和 RTL 互相獨立；它自己先通過全部 71 個 riscv-tests。
2. **Lockstep**：兩顆核心都有 commit port（精神上類似 RVFI），每完成一條指令輸出一筆紀錄。
   Verilator 模擬主程式（`sim/sim_main.cpp`）每收到一筆就讓模型做一條，比對 pc、指令、暫存器寫入、
   記憶體寫入和例外原因。只有週期計數器的讀值會由核心提供給模型，因為它本來就和時序有關。
3. **riscv-tests** 在固定 commit 下載，搭配我們自己的 `riscv_test.h` 編譯（riscv-tests 本來就要求每個平台自己提供）。
   我們的 trap handler 用軟體模擬未對齊的 load/store（OpenSBI 在真機上也這樣做），這是 `ma_data` 需要的。
4. **隨機程式**（`tests/random/rvgen.py`，固定 seed，失敗時印出 seed 和重現指令）專攻管線容易出錯的地方：
   相依鏈、load-use、分支後面跟著有事要做的指令、每 2 KiB 一個、會撞同一個 D-cache set 的存取、
   除法邊界值、CSR 和計數器、例外、I/O，以及用 FENCE.I 生效的自我修改程式碼。
5. **單元測試**（cocotb + Icarus）把每個模組和照 ISA 寫的 Python 模型比對，
   包括快取的未命中與寫回次數要完全相同、預測器每一次預測都要相同。
6. **浮點**也用同樣三層來驗證。先拿模型的運算去對 Berkeley TestFloat（它的產生器會寫出運算元、
   正確結果和正確旗標）；再讓 RTL 的 FPU 在 Verilator 測試平台（`tests/fp/`）跑同樣的 6,400 萬組，
   TestFloat 沒有涵蓋的部分（符號搬移、最大最小、分類、搬移、沒有 NaN-boxing 的單精度數）則用隨機運算和模型比。
   系統層是 rv32uf/rv32ud 和含浮點指令的隨機程式，全部 lockstep；commit 紀錄帶著這條指令寫了哪個 f 暫存器、
   舉了哪些例外旗標，所以旗標錯了會在舉旗的那一條指令當場被抓到。
   模型和 RTL 用的是不同的演算法（128 位元對齊相加對固定乘積視窗、長除法對每週期兩位元的遞迴），
   兩邊算出一樣的答案才有意義。
7. **突變測試**（`tools/mutate.py`）證明測試會失敗。其中兩個是功能測試看不到的效能錯誤
   （LRU 位元不更新、分支計數器卡住）：單元測試抓到兩個，CoreMark 效率下限也抓到第二個。

## 快速開始

需要 Verilator 5（測過 5.052，CI 用 5.020）、Icarus Verilog 12 以上、Yosys（本機 0.69，CI 0.33）、
有 RISC-V target 的 clang 和 ld.lld（macOS 用 Homebrew 的 LLVM，蘋果內建 clang 不支援 RISC-V）、
Python 3.10 以上、C++17 編譯器。第一次執行會把 riscv-tests、CoreMark、Berkeley SoftFloat/TestFloat，
以及（`make fp-bench` 才需要的）LLVM compiler-rt，從固定 commit 下載到 `build/third_party`。

```sh
brew install verilator icarus-verilog yosys llvm lld   # macOS
make venv          # 第一次：建立有 cocotb、pytest 的 .venv
make test          # lint + 模型 + TestFloat + 單元 + 系統測試，約 1.5 分鐘
make bench         # 兩顆核心和五種核心 B 變體的效能，約 3 分鐘
make fp-bench      # 軟體浮點對硬體 FPU，寫出 build/fp-bench.md
make fpdemo        # 在加了 FPU 的核心 B 上跑浮點示範
make pipeview      # build/pipeview.html
make synth         # 三種設定的 Yosys 合成，寫出 synth/report.md
make sta           # 只算邏輯延遲的時序估計，寫出 synth/timing.md
make mutants       # 突變測試，約 10 分鐘
make random-one SEED=17 CORE=pipe   # 跑一個隨機程式並輸出 commit trace
make random-one SEED=17 CORE=pipe_fd FP=1   # 同上，含浮點指令，在加了 FPU 的核心上
```

所有指令都在專案根目錄執行。路徑可以有空白和中文：Makefile 只用相對路徑。

## 目錄

```
rtl/            解碼器、ALU、暫存器、CSR、兩顆核心、快取、預測器、除法器
rtl/fp*.sv      浮點運算器（fpu.sv 和它的各個方塊）、f 暫存器、浮點指令解碼器
rtl/sim/        模擬用的頂層和記憶體模型（不可合成）
model/          黃金模型（C）：rv_iss.c、IEEE 754 運算 rv_fp.c、反組譯器
sim/            Verilator 主程式：lockstep 比對、統計、管線紀錄
sw/runtime/     crt0、linker script、console/exit、printf、計數器
sw/demo/        示範程式；sw/bench/：CoreMark 移植層、Dhrystone 銜接
tests/env/      官方 riscv-tests 用的 riscv_test.h 和 trap handler
tests/random/   隨機程式產生器；tests/unit/：cocotb；tests/system/：pytest
tests/fp/       TestFloat 驅動程式、模型比對程式、FPU 的 Verilator 測試平台
tools/          管線檢視器、效能量測、突變測試、合成報告
synth/          Yosys 腳本、合成用外殼、報告
```

## 限制

* 只在模擬器上執行。沒有上板、沒有時序收斂；延遲估計不含繞線，不是 sign-off。
* RV32IM，核心 B 可以再加 F、D：沒有壓縮指令、原子操作、中斷、使用者模式、虛擬記憶體、PMP。
  未對齊的 load/store 會觸發例外（規格允許），由軟體模擬。
* FPU 是多週期、不是管線化的：一次只做一個浮點運算，加法或乘法要 5 個週期，所以浮點密集的程式 CPI 接近 3。
  除法和開根號是 radix-2、每週期 2 個位元。核心 A 沒有 FPU。沒有半精度和四倍精度。FLD/FSD 的位址要對齊 4。
  詳見[報告 12.7](docs/report.md#127-limitations-of-the-fpu)。
* 返回地址堆疊和預測器在 EX 更新，不是在取指令時推測更新，所以連續的 return 可能猜錯。
* 記憶體模型在固定延遲後一次搬完整條 16 位元組 line；真實 DRAM 有 burst、refresh 和 row 的效應。
* 核心 A 的記憶體是組合邏輯讀取，在 FPGA 上代表分散式 RAM 和非常長的時脈週期；它是參考，不是實用設計。
* 效能分數不是官方分數（見上）。
* 沒有跑 riscv-tests 的 rv32mi（機器模式）測試；它會測的例外和 CSR 行為，改由隨機程式和單元測試對照黃金模型驗證。

## 相關專案

* **MIT 6.1910 / 6.191 Computation Structures**：學生用 Minispec 做單週期和管線化的 RISC-V 處理器。
  本專案用 SystemVerilog 走同樣的路線；這不是課程教材。
* **riscv-sodor**（UC Berkeley）：用 Chisel 寫的教學用 RV32I 核心，有 1、2、3、5 級；精神上最接近的既有專案。
* **PicoRV32**（YosysHQ）：以面積為優先、非管線化的 RV32IMC Verilog 核心，README 寫每條指令約 4 週期、0.516 DMIPS/MHz。
* **VexRiscv**（SpinalHDL）：可設定 2 到 5 級以上的管線；README 寫「full max perf」設定（8 KiB 快取）為
  1.38 DMIPS/MHz、2.57 CoreMark/MHz。
* **riscv-formal / RVFI**（YosysHQ）：透過每條指令退休時的介面，用形式驗證對照 ISA 模型；
  這裡的 commit port 在模擬中扮演同樣角色，但沒有形式證明。
* **riscv-tests**（riscv-software-src）：這裡使用的官方 ISA 測試。
* **Berkeley SoftFloat 和 TestFloat**（John Hauser）：IEEE 754 的參考軟體實作和它的測資產生器。
  這裡用 TestFloat 當裁判；黃金模型的浮點運算是另外寫的、小得多的純整數實作（兩種格式、32 位元整數），
  拿去和它比對，不是抄 SoftFloat。
* **Berkeley HardFloat**（Chisel）：Rocket 和 BOOM 的 FPU。它在內部把數字轉成多一個指數位元的「recoded」格式，
  讓各個運算單元不必特別處理 subnormal，本身也用 TestFloat 測試。這裡的 FPU 保留 IEEE 的位元樣式，
  在 subnormal 出現的地方才處理。
* **FPnew / CVFPU**（OpenHW Group，SystemVerilog）：CVA6 和 CV32E40P 的 FPU，格式和管線深度都可以設定。
  這裡的乘加資料路徑和它的 `fpnew_fma` 是同一種教科書做法（乘積固定不動、加數在 3p+4 位元的視窗裡對齊，
  加法和乘法也走同一條路徑）；FPnew 是管線化、多格式的，這裡是固定五步、兩種格式的多週期單元。
* **VexRiscv 的 FPU**（SpinalHDL）：F，可選 D；README 寫加、乘、FMA 可以每週期出一個結果，除法是 radix 4，
  64/32 位元版本在 Artix-7 上用 3,336 個 LUT、3,033 個正反器。它比這裡的 FPU 小、吞吐量高好幾倍；
  這裡的每個浮點運算都讓管線停下來等，寫它是為了看得懂、驗證得完整，不是為了比快。

其他核心的效能數字是用不同的編譯器、記憶體和規則量的，只能當背景參考，不是排名。

## 授權

MIT（見 LICENSE）。riscv-tests（加州大學董事會的 BSD 式授權）、CoreMark（Apache-2.0，
另有 EEMBC 對 CoreMark 名稱的商標授權）、Berkeley SoftFloat 和 TestFloat（BSD 3-clause）、
LLVM compiler-rt（Apache-2.0 with LLVM exceptions）都在建置時下載，不屬於這個儲存庫。CoreMark® 是 EEMBC® 的註冊商標。
