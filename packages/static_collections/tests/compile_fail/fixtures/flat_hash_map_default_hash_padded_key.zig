const static_collections = @import("static_collections");

const Key = struct {
    tag: u8,
    value: u32,
};

const Map = static_collections.flat_hash_map.FlatHashMap(Key, u32, struct {});

pub export const sentinel: usize = @sizeOf(Map);
