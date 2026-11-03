// Expected: compile error (non-numeric width 'xx').
comptime {
    const zprogress = @import("zprogress");
    _ = zprogress.Style.parse("{bar:xx}");
}

pub fn main() void {}
