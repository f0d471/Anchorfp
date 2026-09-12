# 由 gen_luts.py 生成，不要手改
set sfu_lut_manifest [dict create \
  "exp_lut.mem" [dict create count 1024 first "3f800b18" last "3fffe9d3" sha256 "168745fe2e5d1bb11011b703db602149ff2311870bb4c36a3967bb2220e6539e"] \
  "sin_lut.mem" [dict create count 1024 first "00000000" last "3f800000" sha256 "7113194c6c55f62bc89a710635b9ea4a80444311df1e271caf41450b02ad64dd"] \
  "rsqrt_even_lut.mem" [dict create count 1024 first "3f800000" last "3f351045" sha256 "0b6bed8e32837b22cd5e8520b112d96449bc64952412b53278e163230fd6fbb4"] \
  "rsqrt_odd_lut.mem" [dict create count 1024 first "3f3504f3" last "3f000801" sha256 "0adbe1f86e088d2b997cced14f1528f87a5ff481303b62cd75ccf099a011e23c"]
]
