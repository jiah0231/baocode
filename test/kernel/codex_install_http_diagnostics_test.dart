import 'package:baocode/kernel/codex/codex_install_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('metadata failure identifies its original endpoint and quota headers', () {
    final message = HttpCodexPackageSource.failureMessage(
      403,
      Uri.https('api.github.com', '/repos/openai/codex/releases/latest'),
      {
        'x-ratelimit-limit': '60',
        'x-ratelimit-remaining': '0',
        'x-ratelimit-reset': '1793685600',
        'retry-after': '120',
        'x-github-request-id': '1234:ABCD:5678',
      },
    );
    expect(message, contains('HTTP 403'));
    expect(
      message,
      contains('https://api.github.com/repos/openai/codex/releases/latest'),
    );
    for (final detail in [
      'x-ratelimit-limit=60',
      'x-ratelimit-remaining=0',
      'x-ratelimit-reset=1793685600',
      'retry-after=120',
      'x-github-request-id=1234:ABCD:5678',
    ]) {
      expect(message, contains(detail));
    }
  });

  test('asset failure omits credentials, signed queries and other headers', () {
    final message = HttpCodexPackageSource.failureMessage(
      403,
      Uri.parse(
        'https://private-user:private-password@'
        'release-assets.githubusercontent.com/assets/package.tar.gz'
        '?sig=private-signature&token=private-token#private-fragment',
      ),
      {
        'x-github-request-id': 'safe-request-id',
        'authorization': 'Bearer private-authorization',
        'set-cookie': 'session=private-cookie',
        'location': 'https://example.com/?token=private-redirect',
      },
    );
    expect(
      message,
      contains('https://release-assets.githubusercontent.com/assets/package.tar.gz'),
    );
    expect(message, contains('x-github-request-id=safe-request-id'));
    expect(message, isNot(contains('private-')));
    expect(message, isNot(contains('?')));
    expect(message, isNot(contains('#')));
    expect(message, isNot(contains('authorization')));
    expect(message, isNot(contains('set-cookie')));
    expect(message, isNot(contains('location=')));
  });

  test('diagnostic fields are bounded and cannot inject control characters', () {
    final message = HttpCodexPackageSource.failureMessage(
      429,
      Uri.https('api.github.com', '/${'p' * 2000}'),
      {
        'retry-after': '120\r\n\u0000injected',
        'x-github-request-id': '${'r' * 2000}never-printed-tail',
        'x-ratelimit-limit': null,
        'x-ratelimit-remaining': '',
      },
    );
    expect(message, contains('HTTP 429'));
    expect(message, contains('retry-after=120   injected'));
    expect(message, isNot(matches(RegExp(r'[\x00-\x1f\x7f]'))));
    expect(message, isNot(contains('never-printed-tail')));
    expect(message, isNot(contains('x-ratelimit-limit=')));
    expect(message, isNot(contains('x-ratelimit-remaining=')));
    expect(message.length, lessThan(900));
  });

  test('a failure without diagnostic headers still identifies its endpoint', () {
    final message = HttpCodexPackageSource.failureMessage(
      403,
      Uri.https('github.com', '/openai/codex/releases/download/example'),
      const {},
    );
    expect(
      message,
      'Codex download returned HTTP 403 from '
      'https://github.com/openai/codex/releases/download/example.',
    );
  });
}
