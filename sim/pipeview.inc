// Pipeline-occupancy recorder, included by sim_main.cpp for the pipelined
// core only.  For every cycle in the window it writes which fetch sequence
// number sits in each stage plus the stall/flush reasons; tools/pipeview.py
// turns that into the HTML viewer.
//
// dbg_why bits: 0 I-cache miss (IF has no instruction), 1 load-use or CSR
// drain hazard in ID, 2 divider busy in EX, 3 MEM stalled (D-cache or
// FENCE.I), 4 redirect from EX, 5 redirect from MEM.
#include <cstdio>
#include <string>

class PipeView {
  public:
    PipeView(const std::string &path, uint64_t from, uint64_t cycles) : from_(from), cycles_(cycles)
    {
        if (!path.empty()) {
            f_ = std::fopen(path.c_str(), "w");
            if (!f_) std::fprintf(stderr, "vsim: cannot write %s\n", path.c_str());
            else std::fprintf(f_, "{\"from\": %llu, \"cycles\": [\n", (unsigned long long)from);
        }
    }

    void sample(const Vtop *t, uint64_t cycle, const rv_iss *)
    {
        if (!f_ || cycle < from_ || cycle >= from_ + cycles_) return;
        char dis[64];
        rv_disasm(t->dbg_d_pc, t->dbg_d_insn, dis, sizeof dis);
        std::fprintf(f_, "%s[%llu,%u,\"%08x\",%u,%u,\"%08x\",\"%s\",%u,%u,%u,%u,%u,%u,%u]", n_ ? ",\n" : "",
                     (unsigned long long)cycle, (unsigned)t->dbg_f_seq, (unsigned)t->dbg_f_pc,
                     (unsigned)t->dbg_d_valid, (unsigned)t->dbg_d_seq, (unsigned)t->dbg_d_pc, dis,
                     (unsigned)t->dbg_e_valid, (unsigned)t->dbg_e_seq, (unsigned)t->dbg_m_valid,
                     (unsigned)t->dbg_m_seq, (unsigned)t->dbg_w_valid, (unsigned)t->dbg_w_seq,
                     (unsigned)t->dbg_why);
        n_++;
    }

    void finish()
    {
        if (!f_) return;
        std::fprintf(f_, "\n]}\n");
        std::fclose(f_);
        f_ = nullptr;
    }

  private:
    FILE *f_ = nullptr;
    uint64_t from_, cycles_, n_ = 0;
};
