# SFU 查找表的综合前检查：表缺失、项数、首末项或 SHA-256 与 manifest 不符即报错退出
# manifest 由 gen_luts.py 生成；SHA-256 用 Vivado 自带 tcllib 的 sha256 包计算

package require sha256

proc check_sfu_luts {sfu_dir} {
    set manifest_path [file join $sfu_dir sfu_lut_manifest.tcl]
    if {![file isfile $manifest_path]} {
        error "SFU LUT preflight: missing manifest $manifest_path"
    }
    source $manifest_path

    dict for {name spec} $sfu_lut_manifest {
        set path [file join $sfu_dir $name]
        if {![file isfile $path]} {
            error "SFU LUT preflight: missing $path"
        }

        set fh [open $path r]
        set words {}
        while {[gets $fh line] >= 0} {
            set word [string trim $line]
            if {$word eq ""} { continue }
            if {![regexp -nocase {^[0-9a-f]{8}$} $word]} {
                close $fh
                error "SFU LUT preflight: malformed word in $path: $word"
            }
            lappend words [string tolower $word]
        }
        close $fh

        set expected_count [dict get $spec count]
        if {[llength $words] != $expected_count} {
            error "SFU LUT preflight: $name has [llength $words] words, expected $expected_count"
        }
        if {[lindex $words 0] ne [dict get $spec first] ||
            [lindex $words end] ne [dict get $spec last]} {
            error "SFU LUT preflight: $name endpoint mismatch"
        }

        set actual_sha [string tolower [::sha2::sha256 -hex -filename $path]]
        set expected_sha [dict get $spec sha256]
        if {$actual_sha ne $expected_sha} {
            error "SFU LUT preflight: $name SHA-256 $actual_sha, expected $expected_sha"
        }
        puts "SFU LUT preflight: OK $name ($expected_count words, $actual_sha)"
    }
}
