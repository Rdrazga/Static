//! `static_ecs`: world-local typed ECS building blocks.
//!
//! The first implementation slice is intentionally narrow:
//!
//! - `WorldConfig` carries explicit hard bounds for the world-local core;
//! - `Entity` and `EntityPool` own bounded identity allocation and stale-id rejection;
//! - `World(comptime Components)` anchors the typed component-universe direction;
//! - typed query descriptors and chunk-batch `View` now expose the first
//!   contiguous hot-path iteration surface over the structural store;
//! - `CommandBuffer(comptime Components)` now stages bounded structural work in
//!   deterministic apply order, while typed insert/remove helpers keep new
//!   value-component columns initialized.
//!
//! Deferred surfaces such as runtime-erased queries, import/export, and
//! spatial adapters remain outside this first typed
//! world-local slice.

pub const world_config = @import("ecs/world_config.zig");
pub const entity = @import("ecs/entity.zig");
pub const entity_pool = @import("ecs/entity_pool.zig");
pub const component_registry = @import("ecs/component_registry.zig");
pub const archetype_key = @import("ecs/archetype_key.zig");
pub const chunk = @import("ecs/chunk.zig");
pub const archetype_store = @import("ecs/archetype_store.zig");
pub const query = @import("ecs/query.zig");
pub const view = @import("ecs/view.zig");
pub const command_buffer = @import("ecs/command_buffer.zig");
pub const world = @import("ecs/world.zig");

pub const WorldConfig = world_config.WorldConfig;
pub const Entity = entity.Entity;
pub const EntityPool = entity_pool.EntityPool;
pub const ComponentTypeId = component_registry.ComponentTypeId;
pub const ComponentRegistry = component_registry.ComponentRegistry;
pub const ArchetypeKey = archetype_key.ArchetypeKey;
pub const Chunk = chunk.Chunk;
pub const ArchetypeStore = archetype_store.ArchetypeStore;
pub const AccessMode = query.AccessMode;
pub const Read = query.Read;
pub const Write = query.Write;
pub const OptionalRead = query.OptionalRead;
pub const OptionalWrite = query.OptionalWrite;
pub const With = query.With;
pub const Exclude = query.Exclude;
pub const Query = query.Query;
pub const View = view.View;
pub const CommandBuffer = command_buffer.CommandBuffer;
pub const World = world.World;

test {
    _ = world_config;
    _ = entity;
    _ = entity_pool;
    _ = component_registry;
    _ = archetype_key;
    _ = chunk;
    _ = archetype_store;
    _ = query;
    _ = view;
    _ = command_buffer;
    _ = world;
}
