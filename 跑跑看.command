#!/bin/bash
# ============================================================
#  跑跑看：在 Mac 上讓「自己設計的 CPU」跑一個 C 程式
#
#  這個檔案在 Finder 裡雙擊就會打開「終端機」來執行。
#  它會做五件事：
#    1. 用 Verilator 把 rtl/ 資料夾裡的 CPU 電路（SystemVerilog）
#       翻譯成 C++，再編譯成一個「模擬器」（第一次大約 20 秒）。
#    2. 用 clang 把 sw/demo/demo.c 編譯成 RISC-V 機器碼。
#    3. 讓「五級管線」版本的 CPU 執行這個程式，並且同時用
#       「黃金模型」逐指令對答案：只要有一條指令的結果不同，
#       就會立刻停下來告訴你哪裡錯。
#       程式會印出質數個數、排序結果和一張曼德博集合（文字圖），
#       每一段後面附上 CPU 自己數的「週期數、指令數、CPI」。
#    4. 產生「管線檢視器」網頁並用瀏覽器打開：每一列是一條指令，
#       每一欄是一個時脈週期，可以看到指令怎麼一級一級往前走。
#    5. 換成「加了浮點運算器（FPU）」的 CPU，跑 sw/demo/fpdemo.c：
#       親眼看 0.1 + 0.2 為什麼不等於 0.3、五種捨入方式、無限大和 NaN，
#       以及加、乘、除、開根號各要讓管線等幾個週期。
#
#  需要先裝好：
#    Xcode Command Line Tools（提供 make、c++）：xcode-select --install
#    verilator、llvm、lld（brew install verilator llvm lld）
#  （蘋果內建的 clang 不能編譯 RISC-V，所以要用 Homebrew 的 llvm。）
# ============================================================

# 先切換到這個檔案所在的資料夾。資料夾名稱有空白和中文，
# 所以 "$(dirname "$0")" 一定要用雙引號包起來。
cd "$(dirname "$0")" || exit 1

pause_and_exit() {
  read -r -p "按 Enter 關閉視窗..."
  exit "$1"
}

# 檢查需要的工具有沒有裝
for tool in make c++ verilator python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "找不到 $tool。"
    echo "  make、c++：在終端機執行 xcode-select --install"
    echo "  verilator：在終端機執行 brew install verilator"
    pause_and_exit 1
  fi
done
if [ ! -x /opt/homebrew/opt/llvm/bin/clang ] && ! clang -print-targets 2>/dev/null | grep -q riscv32; then
  echo "找不到能編譯 RISC-V 的 clang。請在終端機執行：brew install llvm lld"
  pause_and_exit 1
fi
if [ ! -x /opt/homebrew/opt/lld/bin/ld.lld ] && ! command -v ld.lld >/dev/null 2>&1; then
  echo "找不到 ld.lld（RISC-V 的連結器）。請在終端機執行：brew install lld"
  pause_and_exit 1
fi

echo "== 1/4 編譯 CPU 模擬器和示範程式（只有第一次或改過檔案才會花時間）..."
if ! make -s build/vsim_pipe build/sw/demo.elf; then
  echo "編譯失敗，上面的訊息會說明原因。"
  pause_and_exit 1
fi

echo
echo "== 2/4 在五級管線 CPU 上執行 sw/demo/demo.c（同時和黃金模型逐指令比對）"
echo
./build/vsim_pipe --stats build/sw/demo.elf
status=$?
echo
if [ $status -eq 0 ]; then
  echo "程式正常結束，而且每一條指令都和黃金模型的答案一樣。"
  echo "（上面 cycles 是整個程式花的時脈週期數，CPI = 週期數 / 指令數，"
  echo "  越接近 1 代表管線越少停頓。）"
else
  echo "結束代碼 $status：2 = CPU 和黃金模型答案不同，其他 = 程式本身回報錯誤。"
fi

echo
echo "== 3/4 產生管線檢視器網頁"
if make -s pipeview; then
  open build/pipeview.html
  echo "已用瀏覽器打開 build/pipeview.html。"
fi

echo
echo "== 4/4 加了浮點運算器（FPU）的 CPU：執行 sw/demo/fpdemo.c（第一次要再編譯約 30 秒）"
echo
if make -s build/vsim_pipe_fd build/sw/fpdemo.elf; then
  if ./build/vsim_pipe_fd build/sw/fpdemo.elf; then
    echo
    echo "上面每一個數字都是 CPU 裡的浮點運算器算的，也都和黃金模型逐指令對過答案。"
    echo "（0x 開頭的 16 位數是這個小數在記憶體裡真正的 64 個位元；說明在 docs/導讀.zh-TW.md 第 9 節。）"
  else
    echo "浮點示範沒有正常結束（結束代碼 $?）。"
  fi
else
  echo "編譯失敗，上面的訊息會說明原因。"
fi
pause_and_exit $status
