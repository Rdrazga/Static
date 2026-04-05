const static_collections = @import("static_collections");

const InvalidCtx = struct {
    pub fn lessThan(_: @This(), a: u32, b: *const u32) bool {
        _ = a;
        _ = b;
        return false;
    }
};

const Heap = static_collections.min_heap.MinHeap(u32, InvalidCtx);

pub export const sentinel: usize = @sizeOf(Heap);
