# Round-Robin Arbiter — UVM Verification

A parameterized round-robin arbiter that shares one small memory between N requesters,
verified with a UVM testbench.

## The design (`design.sv`)

`rr_arbiter #(N, AW, DW)`

- **N requesters** (default 4). Each one can ask (`req[i]`) to read or write (`wr_en[i]`)
  an address (`addr[i]`) with write data (`wdata[i]`).
- **At most one grant per cycle** (`gnt` is one-hot).
- **Round robin:** a pointer holds the requester with top priority. The search starts at
  the pointer and wraps around; the first requester asking wins. After a grant the pointer
  moves to *winner + 1*, so whoever was just served goes to the back.
- The winner's **write** goes into a 2^AW-entry memory on the clock edge; a **read** returns
  `rdata` in the same cycle. `rdata` is 0 when nobody reads.
- Worst-case wait for a requester that keeps asking: **N − 1 cycles** (no starvation).
- Active-low reset clears the pointer and the memory.

## The testbench (`testbench.sv`)

| Component | What it does |
| --- | --- |
| `arb_if` | Interface with clocking blocks (`drv_cb`: drive `#1` after the edge; `mon_cb`: sample `#1step` before it) |
| `arb_item` | One transaction = what all N requesters do in one cycle |
| Sequences | `arb_random_seq`, `arb_all_req_seq`, `arb_hold_seq` |
| `arb_driver` | Drives one item per cycle, writes the grant back into the item |
| `arb_monitor` | Sends one item per cycle (including reset cycles) to the scoreboard |
| `arb_scoreboard` | Reference model (own pointer + memory copy, same round-robin search). Checks the exact grant vector, read data, and a starvation limit every cycle |
| Tests | `arb_random_test`, `arb_fairness_test`, `arb_hold_test`, `arb_reset_test` |

## Tests

| Test | Traffic | What it proves |
| --- | --- | --- |
| `arb_random_test` | Random requests, every 8th cycle idle, 70% low addresses | Grants, reads and writes correct in a wide mix; pointer doesn't move on idle cycles |
| `arb_fairness_test` | Everyone requests every cycle (3 × N cycles) | Strict rotation, equal grant counts, no starvation |
| `arb_hold_test` | A requester that loses repeats the same request until granted | Correct behaviour under a "hold until granted" protocol |
| `arb_reset_test` | Random traffic with a 2-cycle reset in the middle | DUT and model restart cleanly mid-traffic |

## Test plan

| # | Feature | Test(s) | Check |
| --- | --- | --- | --- |
| 1 | At most one grant per cycle | All | Exact `gnt` compare |
| 2 | Grant only to a requester that asks | All | Exact `gnt` compare |
| 3 | Round-robin order | Fairness, random | Predicted winner |
| 4 | Pointer moves only on a grant | Random (idle cycles) | Winner in the next cycle |
| 5 | Wrap-around after the last requester | Fairness | Predicted winner |
| 6 | No starvation (wait ≤ N−1) | Fairness, hold | Starvation counter |
| 7 | Write stores the winner's data | Random, hold | Later read compare |
| 8 | Read returns the stored data | Random, hold | Read compare |
| 9 | Never-written address reads 0 | Random, reset | Read compare |
| 10 | Idle cycle: no grant, `rdata = 0` | Random | Exact compare |
| 11 | Reset in the middle of traffic | Reset | Model reset + checks after |
| 12 | Request held until granted | Hold | Compare + starvation |
| 13 | Works for N = 2, 3, 4, 8 | All, with `+define` | All checks |
| 14 | Whole address range used | Random | Read/write compare |
| 15 | Functional coverage | — | Planned |

## How to run (Synopsys VCS)

```sh
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps design.sv testbench.sv
./simv +UVM_TESTNAME=arb_random_test        # or arb_fairness_test / arb_hold_test / arb_reset_test
```

Number of requesters (default 4):

```sh
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps +define+NUM_REQ_DEF=8 design.sv testbench.sv
```

More messages: add `+UVM_VERBOSITY=UVM_HIGH` to the `./simv` line.

**A pass:** `UVM_ERROR : 0`, `UVM_FATAL : 0`, and the scoreboard's `TOTAL:` line shows a
non-zero number of cycles checked (in the fairness test, equal grants per requester).

## Bug-injection demo (`bug_demo/design_bug.sv`)

A copy of the design where the pointer never moves, so it behaves like a **fixed-priority**
arbiter. Compile it instead of `design.sv`; the fairness and random tests report
`GRANT MISMATCH` and `STARVATION` errors, which proves the scoreboard really catches
arbitration bugs.

```sh
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps bug_demo/design_bug.sv testbench.sv
./simv +UVM_TESTNAME=arb_fairness_test
```

## Possible extensions

- Functional coverage (winner × pointer, request patterns, wait length) and assertions
  (`$onehot0(gnt)`, no grant without a request)
- One UVM agent per requester (each requester as an independent master)
- Back-pressure (`ready` from the memory side), weighted round robin
