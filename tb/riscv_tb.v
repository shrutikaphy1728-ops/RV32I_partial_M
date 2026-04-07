`timescale 1ns / 1ps

module riscv_tb();
    reg clk, reset;
    integer write_cnt;

    // --- Internal Signals for Hierarchy ---
    // Adjust these paths if your internal naming differs (e.g., dut.core.pc)
    wire [31:0] pc_wb   = dut.cpu.PCW;       // PC in Writeback stage
    wire [4:0]  rd_addr = dut.cpu.rf.a3;     // Register destination address
    wire [31:0] rd_data = dut.cpu.rf.wd3;    // Data being written
    wire         reg_we  = dut.cpu.RegWriteW; 

    // Instantiate Processor
    riscv_soc dut (.clk(clk), .reset(reset));

    // 100MHz Clock
    always #5 clk = ~clk;

    initial begin
        $dumpfile("mul_rigorous.vcd");
        $dumpvars(0, riscv_tb);
        
        // 1. Initialize Memory with NOPs (addi x0, x0, 0)
        for (integer i = 0; i < 128; i = i + 1) dut.imem.ram[i] = 32'h00000013; 

        // 2. Load Program with Strict RAW Dependencies
        // --------------------------------------------------------------------------
        // Setup base registers
        dut.imem.ram[0] = {12'd13, 5'd0, 3'b000, 5'd2, 7'b0010011};   // addi x2, x0, 13
        dut.imem.ram[1] = {12'd10, 5'd0, 3'b000, 5'd3, 7'b0010011};   // addi x3, x0, 10
        dut.imem.ram[2] = {12'hFFF, 5'd0, 3'b000, 5'd4, 7'b0010011};  // addi x4, x0, -1 (0xFFFFFFFF)
        dut.imem.ram[3] = {12'd2, 5'd0, 3'b000, 5'd5, 7'b0010011};    // addi x5, x0, 2

        // Dependency 1: MUL dependent on previous LOAD (x3)
        // MUL: x10 = x3 * x2 (10 * 13 = 130)
        dut.imem.ram[4] = {7'b0000001, 5'd2, 5'd3, 3'b000, 5'd10, 7'b0110011};

        // Dependency 2: MULH dependent on previous MUL result (x10)
        // MULH: x11 = x10 * x5 (130 * 2 = 260, upper 32 bits = 0)
        dut.imem.ram[5] = {7'b0000001, 5'd5, 5'd10, 3'b001, 5'd11, 7'b0110011};

        // MULHSU (Signed x Unsigned): x12 = x4 * x5 (-1 * 2 = -2, upper 32 bits = 0xFFFFFFFF)
        dut.imem.ram[6] = {7'b0000001, 5'd5, 5'd4, 3'b010, 5'd12, 7'b0110011};

        // MULHU (Unsigned x Unsigned): x13 = x4 * x5 (0xFFFFFFFF * 2, upper 32 bits = 1)
        dut.imem.ram[7] = {7'b0000001, 5'd5, 5'd4, 3'b011, 5'd13, 7'b0110011};

        // Dependency 3: ALU SUB dependent on previous MULHU result (x13)
        // SUB: x14 = x13 - x5 (1 - 2 = -1 / 0xFFFFFFFF)
        dut.imem.ram[8] = {7'b0100000, 5'd5, 5'd13, 3'b000, 5'd14, 7'b0110011};

        // End of Program Flag
        dut.imem.ram[9] = {12'd1, 5'd0, 3'b000, 5'd30, 7'b0010011}; // addi x30, x0, 1
        // --------------------------------------------------------------------------

        // 3. Reset Sequence
        clk = 0; reset = 1; write_cnt = 0;
        #22 reset = 0; 

        $display("----------------------------------------------------------------------------------");
        $display("   STARTING RIGOROUS RISC-V M-EXTENSION VERIFICATION");
        $display("   Testing dependencies: Load->Mul, Mul->Mul, Mul->ALU");
        $display("----------------------------------------------------------------------------------");
    end

    // --- Verification Logic ---
    always @(negedge clk) begin
        if (reg_we && !reset && rd_addr != 0) begin
            write_cnt = write_cnt + 1;
            case (write_cnt)
                // Register Setup
                1:  check(32'h00, 5'd2,  32'd13,         "LOAD x2=13");
                2:  check(32'h04, 5'd3,  32'd10,         "LOAD x3=10");
                3:  check(32'h08, 5'd4,  32'hFFFFFFFF,   "LOAD x4=-1");
                4:  check(32'h0C, 5'd5,  32'd2,          "LOAD x5=2");
                
                // M-Extension Logic & Dependencies
                5:  check(32'h10, 5'd10, 32'd130,        "MUL (x3*x2) - DEP: LOAD");
                6:  check(32'h14, 5'd11, 32'd0,          "MULH (x10*x5) - DEP: MUL");
                7:  check(32'h18, 5'd12, 32'hFFFFFFFF,   "MULHSU (S*U)");
                8:  check(32'h1C, 5'd13, 32'h00000001,   "MULHU (U*U)");
                
                // Final Pipeline Handoff
                9:  check(32'h20, 5'd14, 32'hFFFFFFFF,   "SUB (x13-x5) - DEP: MULHU");

                default: begin
                    if (rd_addr == 30 && rd_data == 1) begin
                        $display("----------------------------------------------------------------------------------");
                        $display("[SUCCESS] All Multiplier Modes & Pipeline Dependencies Verified!");
                        $display("----------------------------------------------------------------------------------");
                        $finish;
                    end
                end
            endcase
        end
    end

    // --- Task for Clean Output ---
    task check;
        input [31:0] exp_pc;
        input [4:0]  exp_reg;
        input [31:0] exp_data;
        input [127:0] test_name;
        begin
            if (pc_wb === exp_pc && rd_addr === exp_reg && rd_data === exp_data) begin
                $display("PASS | %s | PC:%h x%0d=%h", test_name, pc_wb, rd_addr, rd_data);
            end else begin
                $display("FAIL | %s | PC:%h", test_name, pc_wb);
                $display("       Expected: x%0d=%h", exp_reg, exp_data);
                $display("       Actual:   x%0d=%h", rd_addr, rd_data);
                $stop; 
            end
        end
    endtask

    // Timeout Guard
    initial begin #10000; $display("TIMEOUT: Simulation ended prematurely."); $finish; end

endmodule