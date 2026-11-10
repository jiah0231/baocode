#ifndef BAOCODE_WINDOWS_UIA_NUMERIC_SCHEMA_H_
#define BAOCODE_WINDOWS_UIA_NUMERIC_SCHEMA_H_

// Portable, deliberately closed allowlist for reviewed UIAutomationCore events.
// C++17; no Windows includes and no trace capture. Each payload field is 32 bits.
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace uia_numeric_schema {
enum class Kind { Boolean, UInt32, HexInt32 };
struct Field { std::wstring_view name; Kind kind; };
struct Schema {
  std::uint16_t id;
  std::uint8_t version;
  std::size_t bytes;
  std::size_t field_count;
  const Field* fields;
};
inline constexpr Field kConnection[] = {
    {L"IsChannelConnection", Kind::Boolean},
    {L"IsCrossMachine", Kind::Boolean}, {L"RequestId", Kind::UInt32}};
inline constexpr Field k544[] = {
    {L"RequestId", Kind::UInt32}, {L"PeerProcessId", Kind::UInt32},
    {L"IsCrossMachine", Kind::Boolean}, {L"BytesWritten", Kind::UInt32},
    {L"RequestTimeout", Kind::UInt32}, {L"HRESULT", Kind::HexInt32}};
inline constexpr Field k545[] = {
    {L"RequestId", Kind::UInt32}, {L"PeerProcessId", Kind::UInt32},
    {L"BytesReceived", Kind::UInt32}};
inline constexpr Field k546[] = {
    {L"RequestId", Kind::UInt32}, {L"PeerProcessId", Kind::UInt32},
    {L"BytesWritten", Kind::UInt32}, {L"HRESULT", Kind::HexInt32}};
inline constexpr Field k547[] = {
    {L"RequestId", Kind::UInt32}, {L"PeerProcessId", Kind::UInt32},
    {L"IsCrossMachine", Kind::Boolean}, {L"BytesReceived", Kind::UInt32}};
inline constexpr Schema kSchemas[] = {
    {521, 0, 12, 3, kConnection}, {522, 0, 12, 3, kConnection},
    {544, 0, 24, 6, k544}, {545, 0, 12, 3, k545},
    {546, 0, 16, 4, k546}, {547, 0, 16, 4, k547}};

constexpr const Schema* find(std::uint16_t id) {
  for (const auto& schema : kSchemas) {
    if (schema.id == id) return &schema;
  }
  return nullptr;
}
constexpr bool validate_header(const Schema& schema, std::uint8_t version,
                               std::size_t bytes) {
  return version == schema.version && bytes == schema.bytes;
}
// Exact TDH_INTYPE / TDH_OUTTYPE enum values in the Windows SDK (tdh.h).
// A HexInt32 has *different* input (20) and output (18) codes.
constexpr bool matches_tdh_type(Kind kind, std::uint16_t in_type,
                                std::uint16_t out_type) {
  switch (kind) {
    case Kind::Boolean: return in_type == 13 && out_type == 13;
    case Kind::UInt32: return in_type == 8 && out_type == 8;
    case Kind::HexInt32: return in_type == 20 && out_type == 18;
  }
  return false;
}
struct FieldMetadata {
  std::wstring_view name;
  Kind kind;
  std::uint32_t flags;
  std::uint16_t count;
  std::uint16_t length;
};
// The caller must first validate both raw TDH types with matches_tdh_type.
// TDH count=1 means scalar. With flags=0, a fixed primitive's length can be
// unspecified (0) or its natural byte width (4). Both describe the same scalar;
// the checked event byte length still requires exactly 4 bytes per field.
// Reject every flag, including structs, parameterized/fixed counts and lengths,
// custom schemas, tags and future flags. Do not interpret union members when
// flags are set. Even a flagged array of one is outside this reviewed schema.
constexpr bool validate_metadata(const Schema& schema,
                                 const FieldMetadata* fields,
                                 std::size_t count) {
  if (fields == nullptr || count != schema.field_count) return false;
  for (std::size_t i = 0; i < count; ++i) {
    if (fields[i].name != schema.fields[i].name ||
        fields[i].kind != schema.fields[i].kind || fields[i].flags != 0 ||
        fields[i].count != 1 ||
        (fields[i].length != 0 && fields[i].length != 4)) return false;
  }
  return true;
}
constexpr bool validate_values(const Schema& schema,
                               const std::uint32_t* values,
                               std::size_t count) {
  if (values == nullptr || count != schema.field_count) return false;
  for (std::size_t i = 0; i < count; ++i) {
    if (schema.fields[i].kind == Kind::Boolean && values[i] > 1) return false;
  }
  return true;
}
// Include peer-bearing events only if both endpoints are the two explicitly
// selected processes. This does not attribute events that lack a peer PID.
constexpr bool peers_are_pair(std::uint32_t source_pid, std::uint32_t peer_pid,
                              std::uint32_t first_pid, std::uint32_t second_pid) {
  return first_pid != 0 && second_pid != 0 && first_pid != second_pid &&
      ((source_pid == first_pid && peer_pid == second_pid) ||
       (source_pid == second_pid && peer_pid == first_pid));
}
}  // namespace uia_numeric_schema
#endif  // BAOCODE_WINDOWS_UIA_NUMERIC_SCHEMA_H_
