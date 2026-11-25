// ============================================================
// UVM testbench for the round-robin arbiter (rr_arbiter)
//
// Order: parameters -> interface -> transaction -> sequences ->
//        sequencer -> driver -> monitor -> agent -> scoreboard ->
//        env -> tests -> top module
//
// Tests (pick one with +UVM_TESTNAME=<name>):
//   arb_random_test   random traffic, idle cycles, full address range
//   arb_fairness_test everyone requests every cycle
//   arb_hold_test     requesters keep req high until they are granted
//   arb_reset_test    random traffic with a reset in the middle
// Number of requesters: +define+NUM_REQ_DEF=8 (default 4)
// ============================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

// ------------------------------------------------------------
// 0. PARAMETERS
// ------------------------------------------------------------
`ifndef NUM_REQ_DEF
  `define NUM_REQ_DEF 4          // override with +define+NUM_REQ_DEF=8
`endif

package arb_params_pkg;
  parameter int NUM_REQ = `NUM_REQ_DEF;  // number of requesters
  parameter int ADDR_W  = 4;             // address width (16 locations)
  parameter int DATA_W  = 8;             // data width
endpackage
import arb_params_pkg::*;

// ------------------------------------------------------------
// 1. INTERFACE: wires between testbench and DUT, plus timing
// ------------------------------------------------------------
interface arb_if (input logic clk);
  logic                           rst_n;
  logic [NUM_REQ-1:0]             req;
  logic [NUM_REQ-1:0]             wr_en;
  logic [NUM_REQ-1:0][ADDR_W-1:0] addr;
  logic [NUM_REQ-1:0][DATA_W-1:0] wdata;
  logic [NUM_REQ-1:0]             gnt;
  logic [DATA_W-1:0]              rdata;

  // Driver timing: drive 1 time unit AFTER the rising edge,
  // and read back gnt (sampled just before the edge)
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output req, wr_en, addr, wdata;
    input  gnt;
  endclocking

  // Monitor timing: sample just BEFORE the rising edge (#1step)
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, req, wr_en, addr, wdata, gnt, rdata;
  endclocking
endinterface

// ------------------------------------------------------------
// 2. TRANSACTION: what ALL requesters do in ONE clock cycle
// ------------------------------------------------------------
class arb_item extends uvm_sequence_item;
  `uvm_object_utils(arb_item)

  // inputs: randomised by the sequence
  rand bit [NUM_REQ-1:0] req;           // who is asking
  rand bit [NUM_REQ-1:0] wr_en;         // 1 = write, 0 = read
  rand bit [ADDR_W-1:0]  addr  [NUM_REQ];
  rand bit [DATA_W-1:0]  wdata [NUM_REQ];

  // outputs: filled in by the driver (gnt) or the monitor (all)
  bit [NUM_REQ-1:0] gnt;
  bit [DATA_W-1:0]  rdata;
  bit               rst;                // monitor: 1 = DUT was in reset

  // 70% of addresses in 0..3 (so reads often hit earlier writes),
  // 30% anywhere in 4..15 (so the whole memory gets used)
  constraint c_addr {
    foreach (addr[i]) addr[i] dist { [0:3] :/ 70, [4:(2**ADDR_W)-1] :/ 30 };
  }

  function new(string name = "arb_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("req=%b wr_en=%b gnt=%b rdata=%0d", req, wr_en, gnt, rdata);
  endfunction
endclass

// ------------------------------------------------------------
// 3a. SEQUENCE: random traffic, every 8th cycle is idle
// ------------------------------------------------------------
class arb_random_seq extends uvm_sequence #(arb_item);
  `uvm_object_utils(arb_random_seq)

  int num_items = 40;

  function new(string name = "arb_random_seq");
    super.new(name);
  endfunction

  task body();
    arb_item item;
    bit      ok;
    for (int n = 0; n < num_items; n++) begin
      item = arb_item::type_id::create("item");
      start_item(item);                       // wait until driver is ready
      if (n % 8 == 7)
        ok = item.randomize() with { req == '0; };   // guaranteed idle cycle
      else
        ok = item.randomize();
      if (!ok) `uvm_error("SEQ", "Randomization failed")
      finish_item(item);                      // send, wait for item_done
    end
  endtask
endclass

// ------------------------------------------------------------
// 3b. SEQUENCE: everyone requests every cycle -> checks fairness
// ------------------------------------------------------------
class arb_all_req_seq extends uvm_sequence #(arb_item);
  `uvm_object_utils(arb_all_req_seq)

  function new(string name = "arb_all_req_seq");
    super.new(name);
  endfunction

  task body();
    arb_item item;
    repeat (3 * NUM_REQ) begin
      item = arb_item::type_id::create("item");
      start_item(item);
      if (!item.randomize() with { req == '1; })   // force every req bit to 1
        `uvm_error("SEQ", "Randomization failed")
      finish_item(item);
    end
  endtask
endclass

// ------------------------------------------------------------
// 3c. SEQUENCE: like real hardware, a requester that was NOT
//     granted keeps exactly the same request until it is granted
// ------------------------------------------------------------
class arb_hold_seq extends uvm_sequence #(arb_item);
  `uvm_object_utils(arb_hold_seq)

  function new(string name = "arb_hold_seq");
    super.new(name);
  endfunction

  task body();
    arb_item          item, prev;
    bit [NUM_REQ-1:0] pending = '0;           // asked last cycle, not granted

    repeat (40) begin
      item = arb_item::type_id::create("item");
      start_item(item);
      if (!item.randomize())
        `uvm_error("SEQ", "Randomization failed")
      // waiting requesters repeat their previous request unchanged
      for (int i = 0; i < NUM_REQ; i++) begin
        if (pending[i]) begin
          item.req[i]   = 1'b1;
          item.wr_en[i] = prev.wr_en[i];
          item.addr[i]  = prev.addr[i];
          item.wdata[i] = prev.wdata[i];
        end
      end
      finish_item(item);                      // driver fills in item.gnt
      pending = item.req & ~item.gnt;
      prev    = item;
    end
  endtask
endclass

// ------------------------------------------------------------
// 4. SEQUENCER: passes items from sequence to driver
// ------------------------------------------------------------
typedef uvm_sequencer #(arb_item) arb_sequencer;

// ------------------------------------------------------------
// 5. DRIVER: turns a transaction into pin values, one per cycle
// ------------------------------------------------------------
class arb_driver extends uvm_driver #(arb_item);
  `uvm_component_utils(arb_driver)

  virtual arb_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif))
      `uvm_fatal("DRV", "Could not get virtual interface")
  endfunction

  task run_phase(uvm_phase phase);
    arb_item                        item;
    bit [NUM_REQ-1:0][ADDR_W-1:0]   addr_bus;    // packed copies for the bus
    bit [NUM_REQ-1:0][DATA_W-1:0]   wdata_bus;

    // nobody requests until reset is over
    vif.drv_cb.req   <= '0;
    vif.drv_cb.wr_en <= '0;
    vif.drv_cb.addr  <= '0;
    vif.drv_cb.wdata <= '0;
    wait (vif.rst_n === 1'b1);
    @(vif.drv_cb);                            // line up with a clock edge

    forever begin
      seq_item_port.get_next_item(item);      // 1. get item from sequencer
      for (int i = 0; i < NUM_REQ; i++) begin
        addr_bus[i]  = item.addr[i];
        wdata_bus[i] = item.wdata[i];
      end
      vif.drv_cb.req   <= item.req;           // 2. drive (changes just after this edge)
      vif.drv_cb.wr_en <= item.wr_en;
      vif.drv_cb.addr  <= addr_bus;
      vif.drv_cb.wdata <= wdata_bus;
      @(vif.drv_cb);                          // 3. next edge: the cycle is over
      item.gnt = vif.drv_cb.gnt;              //    tell the sequence who won
      seq_item_port.item_done();              // 4. tell sequencer: done
    end
  endtask
endclass

// ------------------------------------------------------------
// 6. MONITOR: watches the pins every cycle, sends what it sees
// ------------------------------------------------------------
class arb_monitor extends uvm_monitor;
  `uvm_component_utils(arb_monitor)

  virtual arb_if vif;
  uvm_analysis_port #(arb_item) ap;           // broadcast port

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif))
      `uvm_fatal("MON", "Could not get virtual interface")
  endfunction

  task run_phase(uvm_phase phase);
    arb_item item;
    forever begin
      @(vif.mon_cb);                          // values sampled just before the edge
      item = arb_item::type_id::create("item");
      item.rst = (vif.mon_cb.rst_n !== 1'b1); // tell the scoreboard about reset
      if (!item.rst) begin
        item.req   = vif.mon_cb.req;
        item.wr_en = vif.mon_cb.wr_en;
        for (int i = 0; i < NUM_REQ; i++) begin
          item.addr[i]  = vif.mon_cb.addr[i];
          item.wdata[i] = vif.mon_cb.wdata[i];
        end
        item.gnt   = vif.mon_cb.gnt;
        item.rdata = vif.mon_cb.rdata;
      end
      ap.write(item);                         // send to all listeners
    end
  endtask
endclass

// ------------------------------------------------------------
// 7. AGENT: groups sequencer + driver + monitor
// ------------------------------------------------------------
class arb_agent extends uvm_agent;
  `uvm_component_utils(arb_agent)

  arb_sequencer seqr;
  arb_driver    drv;
  arb_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    seqr = arb_sequencer::type_id::create("seqr", this);
    drv  = arb_driver   ::type_id::create("drv",  this);
    mon  = arb_monitor  ::type_id::create("mon",  this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(seqr.seq_item_export);   // driver <-> sequencer
  endfunction
endclass

// ------------------------------------------------------------
// 8. SCOREBOARD: a reference model of the arbiter + memory.
//    Works out what SHOULD happen and compares with the DUT.
// ------------------------------------------------------------
class arb_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(arb_scoreboard)

  uvm_analysis_imp #(arb_item, arb_scoreboard) imp;   // receives from monitor

  // reference model state
  int              ptr = 0;                   // who has top priority
  bit [DATA_W-1:0] mem_model [2**ADDR_W];     // copy of the memory
  int              wait_cycles [NUM_REQ];     // cycles each requester has waited
  // statistics
  int              gnt_count [NUM_REQ];       // DUT grants per requester
  int              cycle_count = 0;           // cycles checked
  int              error_count = 0;
  int              reset_count = 0;           // resets seen
  bit              in_reset    = 0;           // 1 while the DUT is in reset

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    imp = new("imp", this);
  endfunction

  // reset the model exactly like the DUT resets
  function void reset_model();
    ptr = 0;
    foreach (mem_model[j])   mem_model[j]   = '0;
    foreach (wait_cycles[i]) wait_cycles[i] = 0;
  endfunction

  // called automatically every time the monitor does ap.write(item)
  function void write(arb_item t);
    int               winner    = -1;
    bit [NUM_REQ-1:0] exp_gnt   = '0;
    bit [DATA_W-1:0]  exp_rdata = '0;

    // 0. Reset: clear the model, nothing to check
    if (t.rst) begin
      if (!in_reset) reset_count++;
      in_reset = 1;
      reset_model();
      return;
    end
    in_reset = 0;
    cycle_count++;

    // 1. Who SHOULD win? Search from ptr, wrapping around.
    for (int i = 0; i < NUM_REQ; i++) begin
      if (t.req[(ptr + i) % NUM_REQ]) begin
        winner = (ptr + i) % NUM_REQ;
        break;
      end
    end

    // 2. What SHOULD happen?
    if (winner != -1) begin
      exp_gnt[winner] = 1'b1;
      if (t.wr_en[winner])
        mem_model[t.addr[winner]] = t.wdata[winner];   // write
      else
        exp_rdata = mem_model[t.addr[winner]];         // read
      ptr = (winner + 1) % NUM_REQ;                    // next priority
    end

    // count what the DUT actually granted (shows fairness at the end)
    for (int i = 0; i < NUM_REQ; i++)
      if (t.gnt[i]) gnt_count[i]++;

    // 3. Compare with what the DUT did
    if (t.gnt !== exp_gnt) begin
      error_count++;
      `uvm_error("SCB", $sformatf("GRANT MISMATCH: req=%b expected gnt=%b got gnt=%b",
                                  t.req, exp_gnt, t.gnt))
    end
    else if (winner != -1 && !t.wr_en[winner] && t.rdata !== exp_rdata) begin
      error_count++;
      `uvm_error("SCB", $sformatf("READ MISMATCH: req%0d addr=%0d expected=%0d got=%0d",
                                  winner, t.addr[winner], exp_rdata, t.rdata))
    end
    else if (winner == -1)
      `uvm_info("SCB", $sformatf("PASS: req=%b gnt=%b (idle)", t.req, t.gnt), UVM_LOW)
    else if (t.wr_en[winner])
      `uvm_info("SCB", $sformatf("PASS: req=%b gnt=%b WRITE by req%0d addr=%0d data=%0d",
                                 t.req, t.gnt, winner, t.addr[winner], t.wdata[winner]), UVM_LOW)
    else
      `uvm_info("SCB", $sformatf("PASS: req=%b gnt=%b READ  by req%0d addr=%0d data=%0d",
                                 t.req, t.gnt, winner, t.addr[winner], t.rdata), UVM_LOW)

    // 4. No starvation: a requester that keeps asking must be granted
    //    within NUM_REQ-1 cycles of waiting
    for (int i = 0; i < NUM_REQ; i++) begin
      if (t.req[i] && !t.gnt[i]) begin
        wait_cycles[i]++;
        if (wait_cycles[i] >= NUM_REQ) begin
          error_count++;
          `uvm_error("SCB", $sformatf("STARVATION: req%0d has waited %0d cycles",
                                      i, wait_cycles[i]))
        end
      end
      else
        wait_cycles[i] = 0;
    end
  endfunction

  function void report_phase(uvm_phase phase);
    string s = "";
    for (int i = 0; i < NUM_REQ; i++)
      s = {s, $sformatf(" req%0d=%0d", i, gnt_count[i])};
    `uvm_info("SCB", $sformatf("Grants per requester:%s", s), UVM_NONE)
    `uvm_info("SCB", $sformatf("TOTAL: %0d cycles checked, %0d errors, %0d resets seen",
                               cycle_count, error_count, reset_count), UVM_NONE)
  endfunction
endclass

// ------------------------------------------------------------
// 9. ENVIRONMENT: holds the agent and scoreboard, connects them
// ------------------------------------------------------------
class arb_env extends uvm_env;
  `uvm_component_utils(arb_env)

  arb_agent      agent;
  arb_scoreboard scb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = arb_agent     ::type_id::create("agent", this);
    scb   = arb_scoreboard::type_id::create("scb",   this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(scb.imp);            // monitor -> scoreboard
  endfunction
endclass

// ------------------------------------------------------------
// 10a. BASE TEST: builds the env. Other tests extend it.
// ------------------------------------------------------------
class arb_base_test extends uvm_test;
  `uvm_component_utils(arb_base_test)

  arb_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = arb_env::type_id::create("env", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    uvm_root::get().print_topology();         // prints the TB tree
  endfunction
endclass

// ------------------------------------------------------------
// 10b. RANDOM TEST: random traffic, idle cycles, all addresses
// ------------------------------------------------------------
class arb_random_test extends arb_base_test;
  `uvm_component_utils(arb_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    arb_random_seq seq;
    phase.raise_objection(this);              // "don't end the test yet"
    seq = arb_random_seq::type_id::create("seq");
    seq.start(env.agent.seqr);
    #20;                                      // let the last cycles be checked
    phase.drop_objection(this);               // "I'm done"
  endtask
endclass

// ------------------------------------------------------------
// 10c. FAIRNESS TEST: everyone requests all the time
// ------------------------------------------------------------
class arb_fairness_test extends arb_base_test;
  `uvm_component_utils(arb_fairness_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    arb_all_req_seq seq;
    phase.raise_objection(this);
    seq = arb_all_req_seq::type_id::create("seq");
    seq.start(env.agent.seqr);
    #20;
    phase.drop_objection(this);
  endtask
endclass

// ------------------------------------------------------------
// 10d. HOLD TEST: requesters hold req until granted
// ------------------------------------------------------------
class arb_hold_test extends arb_base_test;
  `uvm_component_utils(arb_hold_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    arb_hold_seq seq;
    phase.raise_objection(this);
    seq = arb_hold_seq::type_id::create("seq");
    seq.start(env.agent.seqr);
    #20;
    phase.drop_objection(this);
  endtask
endclass

// ------------------------------------------------------------
// 10e. RESET TEST: reset the DUT in the middle of traffic
// ------------------------------------------------------------
class arb_reset_test extends arb_base_test;
  `uvm_component_utils(arb_reset_test)

  virtual arb_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif))
      `uvm_fatal("TEST", "Could not get virtual interface")
  endfunction

  task run_phase(uvm_phase phase);
    arb_random_seq seq;
    phase.raise_objection(this);
    seq = arb_random_seq::type_id::create("seq");
    seq.num_items = 60;
    fork
      seq.start(env.agent.seqr);              // traffic keeps running...
      begin                                   // ...while we reset the DUT
        repeat (25) @(posedge vif.clk);
        `uvm_info("TEST", "Applying reset in the middle of traffic", UVM_LOW)
        vif.rst_n <= 1'b0;
        repeat (2) @(posedge vif.clk);
        vif.rst_n <= 1'b1;
      end
    join
    #20;
    phase.drop_objection(this);
  endtask
endclass

// ------------------------------------------------------------
// 11. TOP MODULE: clock, reset, interface, DUT, start UVM
// ------------------------------------------------------------
module tb_top;
  logic clk;

  initial clk = 0;
  always #5 clk = ~clk;                       // 10 ns clock

  arb_if intf (clk);                          // the real interface

  rr_arbiter #(.N(NUM_REQ), .AW(ADDR_W), .DW(DATA_W)) dut (
    .clk   (clk),
    .rst_n (intf.rst_n),
    .req   (intf.req),
    .wr_en (intf.wr_en),
    .addr  (intf.addr),
    .wdata (intf.wdata),
    .gnt   (intf.gnt),
    .rdata (intf.rdata)
  );

  // reset for 2 clock cycles at the start
  initial begin
    intf.rst_n = 1'b0;
    repeat (2) @(negedge clk);
    intf.rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(virtual arb_if)::set(null, "*", "vif", intf);
    run_test("arb_random_test");   // or +UVM_TESTNAME=<another test>
  end
endmodule
