`timescale 1ns / 1ps

module fp32_div (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input      [31:0] b,
    input             in_valid,
    input             flush,
    output reg        out_valid,
    output reg [31:0] result
);

//影子流水,和fp别的逻辑一致
reg [12:0] val;

//处理out_valid逻辑
always @(posedge clk or negedge rst_n) begin
    if(!rst_n || flush) begin
        val       <= 0;
        out_valid <= 1'b0;
    end
    else begin
        val       <= {val[11:0], in_valid};
        out_valid <= val[12];
    end
end

//传说中的拆包
wire as = a[31];
wire bs = b[31];
wire [ 7:0] ae = a[30:23];
wire [ 7:0] be = b[30:23];
wire [22:0] af = a[22: 0];
wire [22:0] bf = b[22: 0];

wire re_s = as ^ bs;

//spec里要求的，DAZ，所以直接判断指数是0就行
wire a_is_zero = (ae == 0);
wire b_is_zero = (be == 0);
//处理是否为特殊值
wire a_is_nan = (ae == 8'hff) && (af != 0);
wire b_is_nan = (be == 8'hff) && (bf != 0);
wire a_is_inf = (ae == 8'hff) && (af == 0); 
wire b_is_inf = (be == 8'hff) && (bf == 0); 

wire a_is_norm = ~a_is_inf && ~a_is_nan && ~a_is_zero;
wire b_is_norm = ~b_is_inf && ~b_is_nan && ~b_is_zero;

wire one_nan   = a_is_nan  || b_is_nan;
wire both_inf  = a_is_inf  && b_is_inf;
wire both_zero = a_is_zero && b_is_zero;

wire re_nan  = one_nan || both_inf || both_zero;
wire re_inf  = (a_is_norm && b_is_zero) || (a_is_inf && b_is_norm) || (a_is_inf && b_is_zero);
wire re_zero = (a_is_zero && b_is_norm) || (a_is_norm && b_is_inf) || (a_is_inf && b_is_zero);

wire [1:0] spec_kind = re_nan  ? 2'b00 :
                       re_inf  ? 2'b01 :
                       re_zero ? 2'b10 : 2'b11;

//正常数处理逻辑开始           
wire [23:0] A = {1'b1, af};
wire [23:0] B = {1'b1, bf};
wire [24:0] B_ext = {1'b0, B};//统一为25位，方便计算

//声明流水线数组
reg [24:0] R_s [0:12];//预处理级的余数寄存器
reg [23:0] Q_s [0:12];//spec要求的，Q 初值为 0
reg [24:0] B_s [0:12];
reg signed [9:0] E_pipe [0:12];//因为八位加减法的范围是[-127, 380]，所以必须十位有符号数才能包下
reg sign [0:12];
reg [1:0] kind_s [0:12];

//流水线第一级 ： 预处理级
always @(posedge clk or negedge rst_n) begin
    if(~rst_n) begin
        R_s[0]    <= 0;
        Q_s[0]    <= 0;
        B_s[0]    <= 0;
        sign[0]   <= 0;
        kind_s[0] <= 0;
        E_pipe[0] <= 0;
    end
    else if(flush) begin//按照spec要求，flush时候对数据不做处理，处理valid就可以
    end
    else if(in_valid) begin
        B_s[0]    <= B_ext;
        sign[0]   <= re_s;
        kind_s[0] <= spec_kind;
        if(A >= B) begin
            E_pipe[0] <= $signed({1'b0,ae}) - $signed({1'b0,be}) + 127;
            R_s[0] <= {1'b0, A};
        end
        else begin
            E_pipe[0] <= $signed({1'b0,ae}) - $signed({1'b0,be}) + 126;
            R_s[0] <= {1'b0, A} << 1;
        end
    end
end

//开始12级流水线计算: 长除法
genvar i;
generate
    for (i = 0; i < 12; i = i + 1) begin : gen_div_stage
//优化策略：把一个比较器加一个减法器合并，统一换成一个减法器，比较借位
        wire [24:0] R_in  = R_s[i];
        wire [24:0] B_in  = B_s[i];
        wire [23:0] Q_in  = Q_s[i];
        wire        en    = val[i];
        wire        is_12 = (i == 11);

//换成补码
        wire [25:0] B_neg = ~{1'b0,B_in} + 1'b1;
        wire [25:0] re    = {1'b0, R_in} + B_neg;
        wire        bit0  = ~re[25];
        wire [24:0] R0    = bit0 ? re[24:0] : R_in;
        wire [23:0] Q0    = {Q_in[22:0], bit0};

        wire [24:0] R_shift1 = R0 << 1;
        wire [25:0] re_1   = {1'b0, R_shift1} + B_neg;

        wire        bit1 = ~re_1[25];
        wire [24:0] R1   = bit1 ? re_1[24:0] : R_shift1;
        wire [23:0] Q1   = {Q0[22:0], bit1};

        wire [24:0] R_shift2 = is_12 ? R1 : (R1 << 1);

        always @(posedge clk or negedge rst_n) begin
            if(~rst_n) begin
                Q_s[i+1] <= 0;
                R_s[i+1] <= 0;
            end
            else begin
                if(en) begin
                    Q_s[i+1] <= Q1;
                    R_s[i+1] <= R_shift2;
                end
            end
        end

        always @(posedge clk or negedge rst_n) begin
            if(~rst_n) begin
                B_s[i+1]    <= 0;
                sign[i+1]   <= 0;
                E_pipe[i+1] <= 0;
                kind_s[i+1] <= 0;
            end
            else if (flush) begin
            end
            else if (val[i]) begin
                B_s[i+1]    <= B_s[i];
                sign[i+1]   <= sign[i];
                E_pipe[i+1] <= E_pipe[i];
                kind_s[i+1] <= kind_s[i];
            end
        end
    end
endgenerate

//第十四级，规格化浮点数
//RNE，舍入判断
wire [24:0] Q_13 = {1'b0, Q_s[12]};
wire [25:0] R_double  = {R_s[12], 1'b0};
wire [25:0] B_ext_ext = {1'b0, B_s[12]};

wire rne_need = (R_double >  B_ext_ext) || (R_double == B_ext_ext && Q_13[0] == 1);
wire [24:0] Q_temp = Q_13 + {24'b0, rne_need};

//判断商
wire [23:0] Q_end = Q_temp[24] ? Q_temp[24:1] : Q_temp[23:0];

//判断阶码,输出FTZ
wire result_zero = $signed(E_pipe[12]) <= 10'sd0;
wire result_inf  = $signed(E_pipe[12]) >  10'sd254;
wire [9:0] E_temp = E_pipe[12];

wire [ 7:0] E_end = result_inf  ? 8'hff :
                    result_zero ? 8'h00 : 
                    Q_temp[24]  ? (E_temp[7:0] + 8'b1) : E_temp[7:0];
wire [22:0] F_end = (result_zero || result_inf) ? 23'd0 : Q_end[22:0];
wire [31:0] result_norm = {sign[12], E_end, F_end};

wire [31:0] zero = {sign[12], 31'b0};
wire [31:0] nan  = 32'h7FC00000;
wire [31:0] inf  = {sign[12], 8'hff, 23'h0};

wire [31:0] result_really = (kind_s[12] == 2'b00) ? nan  :
                            (kind_s[12] == 2'b01) ? inf  :
                            (kind_s[12] == 2'b10) ? zero : result_norm;


always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        result <= 0;
    end
    else if(flush) begin
    end
    else if(val[12]) begin
        result <= result_really;
    end
end


endmodule
