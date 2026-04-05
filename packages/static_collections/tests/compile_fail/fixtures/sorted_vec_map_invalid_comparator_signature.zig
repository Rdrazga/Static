const static_collections = @import("static_collections");

const InvalidCmp = struct {
    pub fn less(a: u32, b: *const u32) bool {
        _ = a;
        _ = b;
        return false;
    }
};

const Map = static_collections.sorted_vec_map.SortedVecMap(u32, u32, InvalidCmp);

pub export const sentinel: usize = @sizeOf(Map);
