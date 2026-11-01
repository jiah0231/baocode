import 'package:baocode/kernel/codex/codex_skills.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  Map<String, Object?> skill(String name, String path, {bool enabled = true}) =>
      {
        'name': name,
        'path': path,
        'description': 'Use $name',
        'enabled': enabled,
      };

  test('only enabled skills from this cwd, preserving scope order', () {
    final result = CodexSkill.fromResponse({
      'data': [
        {
          'cwd': '/project',
          'skills': [
            skill('docs', '/project/.agents/skills/docs/SKILL.md'),
            skill('docs', '/home/user/.agents/skills/docs/SKILL.md'),
            skill('off', '/off', enabled: false),
            skill('review', '/reserved'),
            skill('invalid name', '/invalid'),
            skill('empty', ''),
          ],
        },
        {
          'cwd': '/elsewhere',
          'skills': [skill('other', '/other')],
        },
      ],
    }, cwd: '/project');
    expect(result.map((s) => s.name), ['docs']);
    expect(result.single.input, {
      'type': 'skill',
      'name': 'docs',
      'path': '/project/.agents/skills/docs/SKILL.md',
    });
  });

  test('normalizes Windows separators, case and trailing separators', () {
    final result = CodexSkill.fromResponse(
      {
        'data': [
          {
            'cwd': r'c:\Users\Test\Project',
            'skills': [skill('docs', r'C:\Users\Test\Project\SKILL.md')],
          },
          {
            'cwd': r'C:\Users\Test\Other',
            'skills': [skill('other', r'C:\Users\Test\Other\SKILL.md')],
          },
        ],
      },
      cwd: 'C:/users/test/project/',
      paths: p.windows,
    );
    expect(result.map((s) => s.name), ['docs']);
  });

  test('normalizes POSIX paths without folding remote case', () {
    final result = CodexSkill.fromResponse(
      {
        'data': [
          {
            'cwd': '/home/user/project',
            'skills': [skill('docs', '/home/user/project/SKILL.md')],
          },
          {
            'cwd': '/home/user/Project',
            'skills': [skill('other', '/home/user/Project/SKILL.md')],
          },
        ],
      },
      cwd: '/home/user/project/./',
      paths: p.posix,
    );
    expect(result.map((s) => s.name), ['docs']);
  });

  test('only an exact explicit prefix selects a skill', () {
    const skills = [
      CodexSkill('docs', 'Documentation', '/remote/docs/SKILL.md'),
    ];
    expect(CodexSkill.invoked('/docs fix it', skills), skills.single);
    expect(CodexSkill.invoked(r'$docs fix it', skills), skills.single);
    expect(CodexSkill.invoked('  /docs', skills), skills.single);
    for (final text in ['', 'use /docs', '/docs-other', '/unknown']) {
      expect(CodexSkill.invoked(text, skills), isNull);
    }
  });

  test('empty and older server responses do not advertise skills', () {
    expect(CodexSkill.fromResponse({}, cwd: null), isEmpty);
  });
}
