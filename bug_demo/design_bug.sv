// ===== BUG-INJECTION COPY of design.sv: the round-robin pointer never moves, =====
// ===== so requester 0 always has top priority (fixed priority). Used to prove  =====
// ===== the scoreboard catches the bug (GRANT MISMATCH + STARVATION errors).    =====
// ============================================================
// DUT: Parameterized round-robin arbiter with a simple
//      read/write interface to a small shared memory.
//
//  - N requesters. Each one can ask (req) to read or write.
//  - Every cycle the arbiter grants AT MOST ONE requester.
//  - Round robin: after requester i is served, requester i+1
//    gets the highest priority next time (wraps around).
//  - The winner's read or write goes to a 2**AW-entry memory.
//  - gnt and rdata are combinational (same cycle);
//    the memory write and the pointer move happen on the clock.
// ============================================================
module rr_arbiter #(
  parameter int N  = 4,   // number of requesters
  parameter int AW = 4,   // address width -> 2**AW = 16 locations
  parameter int DW = 8    // data width
)(
  input  logic                 clk,
  input  logic                 rst_n,   // active-low reset

  input  logic [N-1:0]         req,     // req[i]   = requester i wants access
  input  logic [N-1:0]         wr_en,   // wr_en[i] = 1 write, 0 read
  input  logic [N-1:0][AW-1:0] addr,    // addr[i]  = address of requester i
  input  logic [N-1:0][DW-1:0] wdata,   // wdata[i] = write data of requester i

  output logic [N-1:0]         gnt,     // one-hot: who won this cycle
  output logic [DW-1:0]        rdata    // read data for the winner
);

  localparam int PW = (N > 1) ? $clog2(N) : 1;   // pointer width

  logic [PW-1:0] ptr;          // requester with the highest priority now
  logic [PW-1:0] win;          // index of this cycle's winner
  logic          found;        // 1 if anyone won this cycle
  logic [DW-1:0] mem [2**AW];  // the shared memory

  // ---------- 1. Pick the winner (combinational) ----------
  // Look at ptr, then ptr+1, ptr+2 ... wrapping around.
  // The first requester that is asking wins.
  always_comb begin
    gnt   = '0;
    win   = '0;
    found = 1'b0;
    for (int i = 0; i < N; i++) begin
      if (!found && req[(ptr + i) % N]) begin
        found              = 1'b1;
        win                = (ptr + i) % N;
        gnt[(ptr + i) % N] = 1'b1;
      end
    end
  end

  // ---------- 2. Read data for the winner (combinational) ----------
  assign rdata = (found && !wr_en[win]) ? mem[addr[win]] : '0;

  // ---------- 3. Write + move the pointer (on the clock) ----------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptr <= '0;
      for (int j = 0; j < 2**AW; j++) mem[j] <= '0;
    end
    else if (found) begin
      if (wr_en[win])
        mem[addr[win]] <= wdata[win];
      ptr <= '0;   // BUG (on purpose): pointer always goes back to 0 -> fixed priority
    end
  end

endmodule
