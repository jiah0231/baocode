// The private fork's update authority is fixed at build time, never supplied
// by a manifest, environment override, or user setting.
import 'dart:convert';

abstract final class CustomUpdateChannel {
  static const enabled = bool.fromEnvironment('BAOCODE_CUSTOM_UPDATES');
  static const publicKey = String.fromEnvironment('BAOCODE_CUSTOM_UPDATE_KEY');
  static const repository = 'jiah0231/baocode';
  static const releases = 'https://github.com/$repository/releases';
  static const manifestUrl = '$releases/download/custom-stable/latest.json';

  static bool validPublicKey(String value) {
    try {
      return base64.decode(value).length == 32;
    } on FormatException {
      return false;
    }
  }

  static bool allowsRedirect(Uri uri) =>
      uri.scheme == 'https' &&
      !uri.hasPort &&
      uri.userInfo.isEmpty &&
      uri.host == 'release-assets.githubusercontent.com';

  static bool allowsAsset(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final parts = uri.pathSegments;
    return parts.length == 6 &&
        parts[0] == 'jiah0231' &&
        parts[1] == 'baocode' &&
        parts[2] == 'releases' &&
        parts[3] == 'download' &&
        parts[4].startsWith('custom-v') &&
        RegExp(r'^custom-v[0-9A-Za-z.+-]+$').hasMatch(parts[4]) &&
        RegExp(r'^BaoCode-[0-9A-Za-z.+-]+-setup(?:-arm64)?\.exe$')
            .hasMatch(parts[5]);
  }
}
