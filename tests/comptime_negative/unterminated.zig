// Expected: compile error (unterminated '{').
comptime {
    const zprogress = @import("zprogress");
    _ = zprogress.Style.parse("{bar:10 {percent}");
}

pub fn main() void {}
