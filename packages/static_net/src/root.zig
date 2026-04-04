//! `static_net` package root.
//!
//! OS-free networking value types and bounded frame codecs.

pub const core = @import("static_core");
pub const serial = @import("static_serial");

pub const errors = @import("net/errors.zig");
pub const address = @import("net/address.zig");
pub const endpoint = @import("net/endpoint.zig");
pub const frame_config = @import("net/frame_config.zig");
pub const frame_encode = @import("net/frame_encode.zig");
pub const frame_decode = @import("net/frame_decode.zig");

pub const Address = address.Address;
pub const Ipv4Address = address.Ipv4Address;
pub const Ipv6Address = address.Ipv6Address;
pub const AddressParseError = errors.AddressParseError;
pub const AddressFormatError = errors.AddressFormatError;
pub const Endpoint = endpoint.Endpoint;
pub const Ipv4Endpoint = endpoint.Ipv4Endpoint;
pub const Ipv6Endpoint = endpoint.Ipv6Endpoint;
pub const Port = endpoint.Port;
pub const EndpointParseError = errors.EndpointParseError;
pub const EndpointFormatError = errors.EndpointFormatError;

pub const FrameConfig = frame_config.Config;
pub const ChecksumMode = frame_config.ChecksumMode;
pub const FrameEncodeError = errors.FrameEncodeError;
pub const FrameDecodeError = errors.FrameDecodeError;
pub const Decoder = frame_decode.Decoder;
pub const DecodeStep = frame_decode.DecodeStep;
pub const DecodeStatus = frame_decode.DecodeStatus;
pub const FrameInfo = frame_decode.FrameInfo;

test {
    _ = core;
    _ = serial;
    _ = errors;
    _ = address;
    _ = endpoint;
    _ = frame_config;
    _ = frame_encode;
    _ = frame_decode;
}
