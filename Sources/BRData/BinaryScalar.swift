#if _endian(big)
#error("BikeRideData artifacts are little-endian and are viewed in place; big-endian hosts are unsupported.")
#endif

/// A fixed-width value stored in artifacts as its little-endian bytes.
///
/// Every supported host is little-endian (enforced at compile time), so a value's in-memory
/// bytes are its wire bytes and arrays can be viewed in place without conversion.
public protocol BinaryScalar: BitwiseCopyable, Sendable {}

extension UInt8: BinaryScalar {}
extension Int8: BinaryScalar {}
extension UInt16: BinaryScalar {}
extension Int16: BinaryScalar {}
extension UInt32: BinaryScalar {}
extension Int32: BinaryScalar {}
extension UInt64: BinaryScalar {}
extension Int64: BinaryScalar {}
extension Float: BinaryScalar {}
extension Double: BinaryScalar {}
