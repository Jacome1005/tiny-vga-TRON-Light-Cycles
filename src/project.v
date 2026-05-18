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
    // CONSTANTS
    // ==========================================
    // Grid: 40 cols x 30 rows, playable cols 1-38, rows 1-28
    // MAX_LEN: max trail length per player (reduce to save area)

    localparam MAX_LEN  = 16;           // reducido de 32 a 16
    localparam LEN_BITS = 4;            // ceil(log2(MAX_LEN))

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
    // TRAIL BUFFERS
    // En Tron la cola NUNCA se borra: head_ptr avanza,
    // tail_ptr se queda fijo (o solo avanza al alcanzar MAX_LEN)
    // ==========================================
    reg [5:0] seg_col_1 [0:MAX_LEN-1];
    reg [4:0] seg_row_1 [0:MAX_LEN-1];
    reg [LEN_BITS-1:0] head_ptr_1;

    reg [5:0] seg_col_2 [0:MAX_LEN-1];
    reg [4:0] seg_row_2 [0:MAX_LEN-1];
    reg [LEN_BITS-1:0] head_ptr_2;

    wire [5:0] head_col_1 = seg_col_1[head_ptr_1];
    wire [4:0] head_row_1 = seg_row_1[head_ptr_1];
    wire [5:0] head_col_2 = seg_col_2[head_ptr_2];
    wire [4:0] head_row_2 = seg_row_2[head_ptr_2];

    // ==========================================
    // DIRECTION CONTROL (ambos jugadores, lógica unificada)
    // ==========================================
    reg [1:0] direction_1, next_dir_1;
    reg [1:0] direction_2, next_dir_2;

    always @(posedge clk) begin
        if (~rst_n) begin
            next_dir_1 <= DIR_RIGHT;
            next_dir_2 <= DIR_RIGHT;
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
    reg [5:0] nxt_col_1, nxt_col_2;
    reg [4:0] nxt_row_1, nxt_row_2;

    always @(*) begin
        nxt_col_1 = head_col_1; nxt_row_1 = head_row_1;
        case (next_dir_1)
            DIR_UP:    nxt_row_1 = head_row_1 - 5'd1;
            DIR_DOWN:  nxt_row_1 = head_row_1 + 5'd1;
            DIR_LEFT:  nxt_col_1 = head_col_1 - 6'd1;
            DIR_RIGHT: nxt_col_1 = head_col_1 + 6'd1;
        endcase
    end

    always @(*) begin
        nxt_col_2 = head_col_2; nxt_row_2 = head_row_2;
        case (next_dir_2)
            DIR_UP:    nxt_row_2 = head_row_2 - 5'd1;
            DIR_DOWN:  nxt_row_2 = head_row_2 + 5'd1;
            DIR_LEFT:  nxt_col_2 = head_col_2 - 6'd1;
            DIR_RIGHT: nxt_col_2 = head_col_2 + 6'd1;
        endcase
    end

    // ==========================================
    // WALL COLLISION
    // ==========================================
    wire wall_hit_1 = (nxt_col_1 == 6'd0)  || (nxt_col_1 == 6'd39) ||
                      (nxt_row_1 == 5'd0)  || (nxt_row_1 == 5'd29);
    wire wall_hit_2 = (nxt_col_2 == 6'd0)  || (nxt_col_2 == 6'd39) ||
                      (nxt_row_2 == 5'd0)  || (nxt_row_2 == 5'd29);

    // ==========================================
    // TRAIL COLLISION: J1 vs propia trail + trail de J2
    // J2 vs propia trail + trail de J1
    // Nota: slots no usados quedan en (0,0) = borde → nunca
    // coinciden con posiciones jugables interiores.
    // ==========================================
    genvar g;
    wire [MAX_LEN-1:0] self_match_1, self_match_2;
    wire [MAX_LEN-1:0] cross_1to2,   cross_2to1;

    generate
        for (g = 0; g < MAX_LEN; g = g + 1) begin : col_chk
            assign self_match_1[g] = (seg_col_1[g] == nxt_col_1) && (seg_row_1[g] == nxt_row_1);
            assign self_match_2[g] = (seg_col_2[g] == nxt_col_2) && (seg_row_2[g] == nxt_row_2);
            assign cross_1to2[g]   = (seg_col_2[g] == nxt_col_1) && (seg_row_2[g] == nxt_row_1);
            assign cross_2to1[g]   = (seg_col_1[g] == nxt_col_2) && (seg_row_1[g] == nxt_row_2);
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
    // GAME STATE
    // ==========================================
    reg game_over;
    integer i;

    // Macro de reset para no duplicar código
    task do_reset;
        integer j;
        begin
            for (j = 0; j < MAX_LEN; j = j + 1) begin
                seg_col_1[j] <= 6'd0; seg_row_1[j] <= 5'd0;
                seg_col_2[j] <= 6'd0; seg_row_2[j] <= 5'd0;
            end
            // J1 comienza en fila 14, moviéndose a la derecha
            seg_col_1[0] <= 6'd4; seg_row_1[0] <= 5'd14;
            seg_col_1[1] <= 6'd5; seg_row_1[1] <= 5'd14;
            seg_col_1[2] <= 6'd6; seg_row_1[2] <= 5'd14;
            seg_col_1[3] <= 6'd7; seg_row_1[3] <= 5'd14;
            head_ptr_1   <= {LEN_BITS{1'b0}} + 3;
            direction_1  <= DIR_RIGHT;
            // J2 comienza en fila 15, moviéndose a la derecha
            seg_col_2[0] <= 6'd4; seg_row_2[0] <= 5'd15;
            seg_col_2[1] <= 6'd5; seg_row_2[1] <= 5'd15;
            seg_col_2[2] <= 6'd6; seg_row_2[2] <= 5'd15;
            seg_col_2[3] <= 6'd7; seg_row_2[3] <= 5'd15;
            head_ptr_2   <= {LEN_BITS{1'b0}} + 3;
            direction_2  <= DIR_RIGHT;
            game_over    <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (~rst_n) begin
            do_reset;
        end else if (game_over) begin
            if (|ui_in) do_reset;   // cualquier botón reinicia
        end else if (game_tick) begin
            direction_1 <= next_dir_1;
            direction_2 <= next_dir_2;
            if (any_hit) begin
                game_over <= 1'b1;
            end else begin
                // Avanzar head J1 (buffer circular, el trail queda en slots anteriores)
                head_ptr_1 <= (head_ptr_1 + {{(LEN_BITS-1){1'b0}}, 1'b1});
                seg_col_1[(head_ptr_1 + {{(LEN_BITS-1){1'b0}}, 1'b1}) & {LEN_BITS{1'b1}}] <= nxt_col_1;
                seg_row_1[(head_ptr_1 + {{(LEN_BITS-1){1'b0}}, 1'b1}) & {LEN_BITS{1'b1}}] <= nxt_row_1;

                // Avanzar head J2
                head_ptr_2 <= (head_ptr_2 + {{(LEN_BITS-1){1'b0}}, 1'b1});
                seg_col_2[(head_ptr_2 + {{(LEN_BITS-1){1'b0}}, 1'b1}) & {LEN_BITS{1'b1}}] <= nxt_col_2;
                seg_row_2[(head_ptr_2 + {{(LEN_BITS-1){1'b0}}, 1'b1}) & {LEN_BITS{1'b1}}] <= nxt_row_2;
            end
        end
    end

    // ==========================================
    // PIXEL DRAWING
    // ==========================================
    wire [8:0] vx   = hpos[9:1];
    wire [7:0] vy   = vpos[9:1];
    wire [5:0] pcol = {1'b0, vx[8:3]};
    wire [4:0] prow = vy[7:3];
    wire [2:0] cx   = vx[2:0];
    wire [2:0] cy   = vy[2:0];

    // Border
    wire is_border = (pcol == 6'd0) || (pcol == 6'd39) ||
                     (prow == 5'd0) || (prow == 5'd29);
    wire border_checker = (cx[2] ^ cy[2]) & is_border;

    // Snake segment hit tests
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

    wire cell_fill = (cx > 3'd0) && (cx < 3'd7) &&
                     (cy > 3'd0) && (cy < 3'd7);

    // Ojos: dos puntos en la cabeza
    wire eye_pixel = ((cx == 3'd2) || (cx == 3'd5)) && (cy == 3'd2);

    wire draw_eye_1  = is_head_1 && eye_pixel && !is_border;
    wire draw_head_1 = is_head_1 && cell_fill  && !is_border && !eye_pixel;
    wire draw_body_1 = is_snake_1 && !is_head_1 && cell_fill && !is_border;

    wire draw_eye_2  = is_head_2 && eye_pixel && !is_border;
    wire draw_head_2 = is_head_2 && cell_fill  && !is_border && !eye_pixel;
    wire draw_body_2 = is_snake_2 && !is_head_2 && cell_fill && !is_border;

    // ==========================================
    // COLOR OUTPUT
    // ==========================================
    reg [1:0] r_out, g_out, b_out;

    always @(*) begin
        if (!display_on) begin
            r_out = 2'd0; g_out = 2'd0; b_out = 2'd0;
        end else if (game_over && (is_snake_1 || is_snake_2) && cell_fill && !is_border) begin
            r_out = 2'd3; g_out = 2'd0; b_out = 2'd0;
        end else if (draw_eye_1 || draw_eye_2) begin
            r_out = 2'd3; g_out = 2'd3; b_out = 2'd3;
        end else if (draw_head_1) begin
            r_out = 2'd3; g_out = 2'd2; b_out = 2'd0; // Naranja J1
        end else if (draw_body_1) begin
            r_out = 2'd2; g_out = 2'd1; b_out = 2'd0;
        end else if (draw_head_2) begin
            r_out = 2'd0; g_out = 2'd3; b_out = 2'd3; // Cian J2
        end else if (draw_body_2) begin
            r_out = 2'd0; g_out = 2'd1; b_out = 2'd2;
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
