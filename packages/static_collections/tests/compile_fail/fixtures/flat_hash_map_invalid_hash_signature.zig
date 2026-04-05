const static_collections = @import("static_collections");

const InvalidCtx = struct {
    pub fn hash(key: u32, seed: u32) u64 {
        _ = key;
        _ = seed;
        return 0;
    }
};

const Map = static_collections.flat_hash_map.FlatHashMap(u32, u32, InvalidCtx);

pub export const sentinel: usize = @sizeOf(Map);
