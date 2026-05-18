`default_nettype none

module tt_um_tron_game  (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ==========================================
    // VGA SYNC
    // ==========================================
    wire hsync, vsync, display_on;
    wire [9:0] hpos, vpos;
    hvsync_generator hvsync_gen (
        .clk(clk), .reset(~rst_n),
        .hsync(hsync), .vsync(vsync),
        .display_on(display_on),
        .hpos(hpos), .vpos(vpos)
    );

    // ==========================================
    // CONSTANTS — REDUCED GRID
    // ==========================================
    // Grid: 32 cols x 24 rows
    //   Each cell = 640/(32*1) ... we use hpos/vpos halving then /10 or
    //   simpler: use shift-based mapping for power-of-2 friendly cells.
    //   With halving: effective 320x240 pixel space.
    //   32 cols × 10px = 320, 24 rows × 10px = 240. Perfect fit.
    //
    //   Playable area: cols 1–30, rows 1–22 (walls at 0,31 and 0,23)

    localparam GRID_COLS = 32;          // 5-bit column index
    localparam GRID_ROWS = 24;          // 5-bit row index
    localparam CELL_W    = 10;          // pixels per cell (in halved coords)
    localparam CELL_H    = 10;

    localparam MAX_LEN   = 32;           // Trail length
    localparam LEN_BITS  = 5;           // ceil(log2(32))

    // Shared direction encoding
    localparam DIR_UP    = 2'd0;
    localparam DIR_DOWN  = 2'd1;
    localparam DIR_LEFT  = 2'd2;
    localparam DIR_RIGHT = 2'd3;

    // ==========================================
    // INPUTS
    // ==========================================
    wire btn_up_1    = ui_in[0];
    wire btn_down_1  = ui_in[1];
    wire btn_left_1  = ui_in[2];
    wire btn_right_1 = ui_in[3];
    wire btn_up_2    = ui_in[4];
    wire btn_down_2  = ui_in[5];
    wire btn_left_2  = ui_in[6];
    wire btn_right_2 = ui_in[7];

    // ==========================================
    // TIMING
    // ==========================================
    wire frame_tick = (vpos == 10'd479) && (hpos == 10'd639);

    reg [3:0] frame_cnt;
    wire game_tick = frame_tick && (frame_cnt == 4'd7);

    always @(posedge clk) begin
        if (~rst_n)
            frame_cnt <= 4'd0;
        else if (frame_tick)
            frame_cnt <= (frame_cnt == 4'd7) ? 4'd0 : frame_cnt + 4'd1;
    end

    // ==========================================
    // TRAIL BUFFERS — now 5-bit col, 5-bit row, depth 8
    // Saves: (6-5)*8*2 + (5-5)*8*2 cols + halved depth = significant
    // ==========================================
    reg [4:0] seg_col_1 [0:MAX_LEN-1];
    reg [4:0] seg_row_1 [0:MAX_LEN-1];
    reg [LEN_BITS-1:0] head_ptr_1;

    reg [4:0] seg_col_2 [0:MAX_LEN-1];
    reg [4:0] seg_row_2 [0:MAX_LEN-1];
    reg [LEN_BITS-1:0] head_ptr_2;

    wire [4:0] head_col_1 = seg_col_1[head_ptr_1];
    wire [4:0] head_row_1 = seg_row_1[head_ptr_1];
    wire [4:0] head_col_2 = seg_col_2[head_ptr_2];
    wire [4:0] head_row_2 = seg_row_2[head_ptr_2];

    // ==========================================
    // DIRECTION CONTROL
    // ==========================================
    reg [1:0] direction_1, next_dir_1;
    reg [1:0] direction_2, next_dir_2;

    always @(posedge clk) begin
        if (~rst_n) begin
            next_dir_1 <= DIR_RIGHT;
            next_dir_2 <= DIR_LEFT;
        end else begin
            if      (btn_up_1    && direction_1 != DIR_DOWN)  next_dir_1 <= DIR_UP;
            else if (btn_down_1  && direction_1 != DIR_UP)    next_dir_1 <= DIR_DOWN;
            else if (btn_left_1  && direction_1 != DIR_RIGHT) next_dir_1 <= DIR_LEFT;
            else if (btn_right_1 && direction_1 != DIR_LEFT)  next_dir_1 <= DIR_RIGHT;

            if      (btn_up_2    && direction_2 != DIR_DOWN)  next_dir_2 <= DIR_UP;
            else if (btn_down_2  && direction_2 != DIR_UP)    next_dir_2 <= DIR_DOWN;
            else if (btn_left_2  && direction_2 != DIR_RIGHT) next_dir_2 <= DIR_LEFT;
            else if (btn_right_2 && direction_2 != DIR_LEFT)  next_dir_2 <= DIR_RIGHT;
        end
    end

    // ==========================================
    // NEXT HEAD POSITIONS
    // ==========================================
    reg [4:0] nxt_col_1, nxt_col_2;
    reg [4:0] nxt_row_1, nxt_row_2;

    always @(*) begin
        nxt_col_1 = head_col_1; nxt_row_1 = head_row_1;
        case (next_dir_1)
            DIR_UP:    nxt_row_1 = head_row_1 - 5'd1;
            DIR_DOWN:  nxt_row_1 = head_row_1 + 5'd1;
            DIR_LEFT:  nxt_col_1 = head_col_1 - 5'd1;
            DIR_RIGHT: nxt_col_1 = head_col_1 + 5'd1;
        endcase
    end

    always @(*) begin
        nxt_col_2 = head_col_2; nxt_row_2 = head_row_2;
        case (next_dir_2)
            DIR_UP:    nxt_row_2 = head_row_2 - 5'd1;
            DIR_DOWN:  nxt_row_2 = head_row_2 + 5'd1;
            DIR_LEFT:  nxt_col_2 = head_col_2 - 5'd1;
            DIR_RIGHT: nxt_col_2 = head_col_2 + 5'd1;
        endcase
    end

    // ==========================================
    // WALL COLLISION (32x24 boundaries)
    // ==========================================
    wire wall_hit_1 = (nxt_col_1 == 5'd0)  || (nxt_col_1 == 5'd31) ||
                      (nxt_row_1 == 5'd0)  || (nxt_row_1 == 5'd23);
    wire wall_hit_2 = (nxt_col_2 == 5'd0)  || (nxt_col_2 == 5'd31) ||
                      (nxt_row_2 == 5'd0)  || (nxt_row_2 == 5'd23);

    // ==========================================
    // TRAIL COLLISION
    // ==========================================
    genvar gc;
    wire [MAX_LEN-1:0] self_match_1, self_match_2;
    wire [MAX_LEN-1:0] cross_1to2,   cross_2to1;
 
    generate
        for (gc = 0; gc < MAX_LEN; gc = gc + 1) begin : col_chk
            assign self_match_1[gc] = (seg_col_1[gc] == nxt_col_1) && (seg_row_1[gc] == nxt_row_1);
            assign self_match_2[gc] = (seg_col_2[gc] == nxt_col_2) && (seg_row_2[gc] == nxt_row_2);
            assign cross_1to2[gc]   = (seg_col_2[gc] == nxt_col_1) && (seg_row_2[gc] == nxt_row_1);
            assign cross_2to1[gc]   = (seg_col_1[gc] == nxt_col_2) && (seg_row_1[gc] == nxt_row_2);
        end
    endgenerate

    wire self_hit_1    = |self_match_1;
    wire self_hit_2    = |self_match_2;
    wire cross_hit_1   = |cross_1to2;
    wire cross_hit_2   = |cross_2to1;
    wire head_collide  = (nxt_col_1 == nxt_col_2) && (nxt_row_1 == nxt_row_2);

    wire any_hit = wall_hit_1 | self_hit_1 | cross_hit_1 |
                   wall_hit_2 | self_hit_2 | cross_hit_2 | head_collide;

    // ==========================================
    // GAME STATE & RESET
    // ==========================================
    reg game_over;
    integer i;

    task do_reset;
        integer j;
        begin
            for (j = 0; j < MAX_LEN; j = j + 1) begin
                seg_col_1[j] <= 5'd0; seg_row_1[j] <= 5'd0;
                seg_col_2[j] <= 5'd0; seg_row_2[j] <= 5'd0;
            end

            // J1 starts left side (col 3), centered (row 11), moving RIGHT
            seg_col_1[0] <= 5'd1;  seg_row_1[0] <= 5'd11;
            seg_col_1[1] <= 5'd2;  seg_row_1[1] <= 5'd11;
            seg_col_1[2] <= 5'd3;  seg_row_1[2] <= 5'd11;
            seg_col_1[3] <= 5'd4;  seg_row_1[3] <= 5'd11;
            head_ptr_1   <= {LEN_BITS{1'b0}} + 3;
            direction_1  <= DIR_RIGHT;

            // J2 starts right side (col 28), centered (row 11), moving LEFT
            seg_col_2[0] <= 5'd30; seg_row_2[0] <= 5'd11;
            seg_col_2[1] <= 5'd29; seg_row_2[1] <= 5'd11;
            seg_col_2[2] <= 5'd28; seg_row_2[2] <= 5'd11;
            seg_col_2[3] <= 5'd27; seg_row_2[3] <= 5'd11;
            head_ptr_2   <= {LEN_BITS{1'b0}} + 3;
            direction_2  <= DIR_LEFT;

            game_over    <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (~rst_n) begin
            do_reset;
        end else if (game_over) begin
            if (|ui_in) do_reset;
        end else if (game_tick) begin
            direction_1 <= next_dir_1;
            direction_2 <= next_dir_2;
            if (any_hit) begin
                game_over <= 1'b1;
            end else begin
                // Update Head J1
                head_ptr_1 <= (head_ptr_1 == (MAX_LEN-1)) ? {LEN_BITS{1'b0}} : head_ptr_1 + 1'b1;
                seg_col_1[(head_ptr_1 == (MAX_LEN-1)) ? {LEN_BITS{1'b0}} : head_ptr_1 + 1'b1] <= nxt_col_1;
                seg_row_1[(head_ptr_1 == (MAX_LEN-1)) ? {LEN_BITS{1'b0}} : head_ptr_1 + 1'b1] <= nxt_row_1;

                // Update Head J2
                head_ptr_2 <= (head_ptr_2 == (MAX_LEN-1)) ? {LEN_BITS{1'b0}} : head_ptr_2 + 1'b1;
                seg_col_2[(head_ptr_2 == (MAX_LEN-1)) ? {LEN_BITS{1'b0}} : head_ptr_2 + 1'b1] <= nxt_col_2;
                seg_row_2[(head_ptr_2 == (MAX_LEN-1)) ? {LEN_BITS{1'b0}} : head_ptr_2 + 1'b1] <= nxt_row_2;
            end
        end
    end

    // ==========================================
    // PIXEL MAPPING - CONTROLLERS & COORDINATES - 32x24 grid, 10x10 cells
    // ==========================================
    // Halved coordinates: vx = 0..319, vy = 0..239
    wire [8:0] vx = hpos[9:1];
    wire [7:0] vy = vpos[9:1];

    // Division by 10 via reciprocal: floor(x * 205 / 2048) works for x < 320
    // This avoids a hardware divider.
    wire [17:0] col_prod = vx * 9'd205;
    wire [4:0]  pcol     = col_prod[17:11];   // >> 11 = / 2048

    wire [16:0] row_prod = vy * 8'd205;
    wire [4:0]  prow     = row_prod[16:11];

    // Intra-cell coordinates (mod 10) via subtraction
    // pcol*10 and prow*10 reconstructed at full width, then truncated
    wire [8:0] cell_origin_x = {4'd0, pcol} * 9'd10;
    wire [7:0] cell_origin_y = {3'd0, prow} * 8'd10;
    wire [3:0] cx = vx[3:0] - cell_origin_x[3:0]; // only low 4 bits matter
    wire [3:0] cy = vy[3:0] - cell_origin_y[3:0];

    // Border
    wire is_border = (pcol == 5'd0) || (pcol == 5'd31) ||
                     (prow == 5'd0) || (prow == 5'd23);
    wire border_checker = (cx[2] ^ cy[2]) & is_border;

    // ==========================================
    // DRAW HIT TESTS
    // ==========================================
    
    genvar g;
    wire [MAX_LEN-1:0] seg_hit_1, seg_hit_2;
    generate
        for (g = 0; g < MAX_LEN; g = g + 1) begin : draw_chk
            assign seg_hit_1[g] = (seg_col_1[g] == pcol) && (seg_row_1[g] == prow);
            assign seg_hit_2[g] = (seg_col_2[g] == pcol) && (seg_row_2[g] == prow);
        end
    endgenerate

    wire is_snake_1 = |seg_hit_1;
    wire is_snake_2 = |seg_hit_2;
    wire is_head_1  = (pcol == head_col_1) && (prow == head_row_1);
    wire is_head_2  = (pcol == head_col_2) && (prow == head_row_2);

    // ==========================================
    // SPRITE GENERATOR (adapted to 10x10 cells)
    // ==========================================
    reg is_cycle_body_1, is_cycle_glow_1;
    reg is_cycle_body_2, is_cycle_glow_2;

    always @(*) begin
        is_cycle_body_1 = 1'b0;
        is_cycle_glow_1 = 1'b0;
        if (direction_1 == DIR_LEFT || direction_1 == DIR_RIGHT) begin
            is_cycle_body_1 = (cy >= 4'd2 && cy <= 4'd7);
            if (direction_1 == DIR_RIGHT)
                is_cycle_glow_1 = (cy >= 4'd4 && cy <= 4'd5) && (cx >= 4'd6 && cx <= 4'd8);
            else
                is_cycle_glow_1 = (cy >= 4'd4 && cy <= 4'd5) && (cx >= 4'd1 && cx <= 4'd3);
        end else begin
            is_cycle_body_1 = (cx >= 4'd2 && cx <= 4'd7);
            if (direction_1 == DIR_DOWN)
                is_cycle_glow_1 = (cx >= 4'd4 && cx <= 4'd5) && (cy >= 4'd6 && cy <= 4'd8);
            else
                is_cycle_glow_1 = (cx >= 4'd4 && cx <= 4'd5) && (cy >= 4'd1 && cy <= 4'd3);
        end
    end

    always @(*) begin
        is_cycle_body_2 = 1'b0;
        is_cycle_glow_2 = 1'b0;
        if (direction_2 == DIR_LEFT || direction_2 == DIR_RIGHT) begin
            is_cycle_body_2 = (cy >= 4'd2 && cy <= 4'd7);
            if (direction_2 == DIR_RIGHT)
                is_cycle_glow_2 = (cy >= 4'd4 && cy <= 4'd5) && (cx >= 4'd6 && cx <= 4'd8);
            else
                is_cycle_glow_2 = (cy >= 4'd4 && cy <= 4'd5) && (cx >= 4'd1 && cx <= 4'd3);
        end else begin
            is_cycle_body_2 = (cx >= 4'd2 && cx <= 4'd7);
            if (direction_2 == DIR_DOWN)
                is_cycle_glow_2 = (cx >= 4'd4 && cx <= 4'd5) && (cy >= 4'd6 && cy <= 4'd8);
            else
                is_cycle_glow_2 = (cx >= 4'd4 && cx <= 4'd5) && (cy >= 4'd1 && cy <= 4'd3);
        end
    end

    // ==========================================
    // TRAIL MASK (adapted to 10-pixel cells)
    // ==========================================
    wire trail_mask_1 = (direction_1 == DIR_LEFT || direction_1 == DIR_RIGHT)
                        ? (cy == 4'd4 || cy == 4'd5)
                        : (cx == 4'd4 || cx == 4'd5);
    wire trail_mask_2 = (direction_2 == DIR_LEFT || direction_2 == DIR_RIGHT)
                        ? (cy == 4'd4 || cy == 4'd5)
                        : (cx == 4'd4 || cx == 4'd5);

    wire draw_glow_1 = is_head_1 && is_cycle_glow_1 && !is_border;
    wire draw_head_1 = is_head_1 && is_cycle_body_1 && !is_cycle_glow_1 && !is_border;
    wire draw_body_1 = is_snake_1 && !is_head_1 && trail_mask_1 && !is_border;

    wire draw_glow_2 = is_head_2 && is_cycle_glow_2 && !is_border;
    wire draw_head_2 = is_head_2 && is_cycle_body_2 && !is_cycle_glow_2 && !is_border;
    wire draw_body_2 = is_snake_2 && !is_head_2 && trail_mask_2 && !is_border;

    // ==========================================
    // COLOR OUTPUT MIXER (unchanged logic)
    // ==========================================
    reg [1:0] r_out, g_out, b_out;

    always @(*) begin
        if (!display_on) begin
            r_out = 2'd0; g_out = 2'd0; b_out = 2'd0;
        end else if (game_over && (is_snake_1 || is_snake_2) && !is_border) begin
            r_out = 2'd3; g_out = 2'd0; b_out = 2'd0;
        end else if (draw_glow_1) begin
            r_out = 2'd3; g_out = 2'd3; b_out = 2'd1;
        end else if (draw_head_1) begin
            r_out = 2'd2; g_out = 2'd1; b_out = 2'd0;
        end else if (draw_body_1) begin
            r_out = 2'd3; g_out = 2'd1; b_out = 2'd0;
        end else if (draw_glow_2) begin
            r_out = 2'd1; g_out = 2'd3; b_out = 2'd3;
        end else if (draw_head_2) begin
            r_out = 2'd0; g_out = 2'd1; b_out = 2'd2;
        end else if (draw_body_2) begin
            r_out = 2'd0; g_out = 2'd3; b_out = 2'd3;
        end else if (is_border) begin
            r_out = {1'b0, border_checker};
            g_out = {1'b0, border_checker};
            b_out = 2'd1;
        end else begin
            r_out = 2'd0; g_out = 2'd0; b_out = 2'd0;
        end
    end

    // ==========================================
    // PIN ASSIGNMENTS
    // ==========================================
    assign uo_out  = {hsync, b_out[0], g_out[0], r_out[0],
                      vsync, b_out[1], g_out[1], r_out[1]};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire _unused = &{ena, uio_in};

endmodule