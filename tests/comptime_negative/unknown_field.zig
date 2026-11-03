// Expected: compile error (unknown field 'barr').
comptime {
    const zprogress = @import("zprogress");
    _ = zprogress.Style.parse("{barr:10} {percent}");
}

pub fn main() void {}
