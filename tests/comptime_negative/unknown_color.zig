// Expected: compile error (unknown color 'redd').
comptime {
    const zprogress = @import("zprogress");
    _ = zprogress.Style.parse("{bar:10.redd}");
}

pub fn main() void {}
