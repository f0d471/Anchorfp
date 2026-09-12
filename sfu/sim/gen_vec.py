# tb_sfu_golden 的固定激励生成器，输出 vec.hex，共 9500 条
import struct, random
def b(x): return struct.unpack('>I', struct.pack('>f', x))[0]
v = []
# 特殊值
for h in (0x00000000,0x80000000,0x7F800000,0xFF800000,0x7FC00000,0xFFC00000,
          0x7F800001,0x00000001,0x007FFFFF,0x80000001,0x00800000,0x7F7FFFFF,0xFF7FFFFF):
    v.append(h)
# exp：n = x*log2(e) 跨越上溢与下溢阈值的每一步
for i in range(-3600, 3601):
    v.append(b(i/40.0))
# 三角：四象限逐格
for i in range(400):
    v.append(b((i-200)*3.14159265358979/16.0))
# 三角：跨越相位归约支持域边界
for i in range(80):
    v.append(b(16384.0*(i+1)))
# rsqrt：逐个阶码，尾数取三点
for e in range(255):
    for m in (0x000000, 0x7FFFFF, 0x400000):
        v.append((e<<23)|m)
# 固定种子的伪随机补齐
random.seed(20260827)
while len(v) < 9500:
    v.append(random.getrandbits(32))
with open('vec.hex','w') as f:
    for x in v: f.write('%08x\n' % x)
print(len(v))
