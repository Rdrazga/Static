pub const Concurrency = enum(u8) {
    single_threaded,
    spsc,
    mpsc,
    spmc,
    mpmc,
    spmc_registered_fanout,
    mpmc_registered_fanout,
    work_stealing,
};

pub const LenSemantics = enum(u8) {
    exact,
    approximate,
};
