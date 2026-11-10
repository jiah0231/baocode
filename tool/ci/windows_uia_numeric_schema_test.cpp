#include "windows_uia_numeric_schema.h"

#include <array>
#include <cstdlib>
#include <iostream>

namespace {
void require(bool condition, const char* description) {
  if (!condition) {
    std::cerr << "FAIL: " << description << '\n';
    std::exit(EXIT_FAILURE);
  }
}
}
int main() {
  using namespace uia_numeric_schema;
  static_assert(find(521)->bytes == 12);
  static_assert(find(522)->field_count == 3);
  static_assert(find(544)->bytes == 24);
  static_assert(find(545)->bytes == 12);
  static_assert(find(546)->bytes == 16);
  static_assert(find(547)->bytes == 16);
  static_assert(find(520) == nullptr);
  static_assert(find(548) == nullptr);
  static_assert(matches_tdh_type(Kind::Boolean, 13, 13));
  static_assert(matches_tdh_type(Kind::UInt32, 8, 8));
  static_assert(matches_tdh_type(Kind::HexInt32, 20, 18));
  static_assert(!matches_tdh_type(Kind::HexInt32, 20, 20));
  static_assert(!matches_tdh_type(Kind::UInt32, 8, 0));
  static_assert(!matches_tdh_type(Kind::UInt32, 7, 8));
  static_assert(!matches_tdh_type(static_cast<Kind>(99), 8, 8));
  for (const auto& schema : kSchemas) {
    require(validate_header(schema, 0, schema.bytes), "reviewed header");
    require(!validate_header(schema, 1, schema.bytes), "wrong version");
    require(!validate_header(schema, 0, schema.bytes - 1), "short payload");
    require(!validate_header(schema, 0, schema.bytes + 4), "extra payload");
    std::array<FieldMetadata, 7> fields{};
    std::array<std::uint32_t, 7> values{};
    for (std::size_t i = 0; i < schema.field_count; ++i) {
      fields[i] = {schema.fields[i].name, schema.fields[i].kind, 0, 1, 0};
      values[i] = schema.fields[i].kind == Kind::Boolean ? 1 : 0xffffffffU;
    }
    require(validate_metadata(schema, fields.data(), schema.field_count), "valid metadata");
    require(validate_values(schema, values.data(), schema.field_count), "valid values");
    require(!validate_metadata(schema, fields.data(), schema.field_count + 1), "extra field");
    require(!validate_metadata(schema, fields.data(), schema.field_count - 1), "missing field");
    require(!validate_metadata(schema, nullptr, schema.field_count), "null metadata");
    require(!validate_values(schema, nullptr, schema.field_count), "null values");
    require(!validate_values(schema, values.data(), schema.field_count + 1), "extra values");
    for (std::size_t i = 0; i < schema.field_count; ++i) {
      const auto saved = fields[i];
      fields[i].name = L"Unreviewed";
      require(!validate_metadata(schema, fields.data(), schema.field_count), "wrong name");
      fields[i] = saved;
      fields[i].kind = saved.kind == Kind::Boolean ? Kind::UInt32 : Kind::Boolean;
      require(!validate_metadata(schema, fields.data(), schema.field_count), "wrong kind");
      fields[i] = saved;
      for (unsigned bit = 0; bit < 32; ++bit) {
        fields[i].flags = std::uint32_t{1} << bit;
        require(!validate_metadata(schema, fields.data(), schema.field_count), "any flag");
      }
      fields[i] = saved;
      for (const auto count : {0, 2, 65535}) {
        fields[i].count = static_cast<std::uint16_t>(count);
        require(!validate_metadata(schema, fields.data(), schema.field_count), "non-scalar count");
      }
      fields[i] = saved;
      for (const auto length : {1, 2, 3, 5, 8, 65535}) {
        fields[i].length = static_cast<std::uint16_t>(length);
        require(!validate_metadata(schema, fields.data(), schema.field_count), "bad field length");
      }
      fields[i].length = 4;
      require(validate_metadata(schema, fields.data(), schema.field_count), "explicit natural width");
      fields[i] = saved;
      if (saved.kind == Kind::Boolean) {
        for (const auto value : {2U, 0xffffffffU}) {
          values[i] = value;
          require(!validate_values(schema, values.data(), schema.field_count), "invalid Boolean");
        }
        values[i] = 0;
        require(validate_values(schema, values.data(), schema.field_count), "false Boolean");
        values[i] = 1;
      }
    }
    const auto first = fields[0];
    fields[0] = fields[1];
    fields[1] = first;
    require(!validate_metadata(schema, fields.data(), schema.field_count), "reordered fields");
  }
  require(peers_are_pair(100, 200, 100, 200), "forward pair");
  require(peers_are_pair(200, 100, 100, 200), "reverse pair");
  require(!peers_are_pair(100, 300, 100, 200), "unselected peer");
  require(!peers_are_pair(300, 100, 100, 200), "unselected source");
  require(!peers_are_pair(100, 100, 100, 200), "self pair");
  require(!peers_are_pair(100, 100, 100, 100), "duplicate selected PIDs");
  require(!peers_are_pair(0, 200, 0, 200), "zero first PID");
  require(!peers_are_pair(100, 0, 100, 0), "zero second PID");
  std::cout << "UIA numeric schema policy: PASS\n";
}
