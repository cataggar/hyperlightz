const hyperlight = @import("hyperlight");

var counter: i32 = 0;

fn increment(amount: i32) i32 {
    counter += amount;
    return counter;
}

fn get() i32 {
    return counter;
}

comptime {
    hyperlight.guest.exportFunctions(.{
        .Increment = increment,
        .Get = get,
    });
}
