// Regenerates the repo-tree block in docs/STRUCTURE.md between the
// TREE:START / TREE:END markers. Run locally after adding or removing
// a top-level plugin folder or file:
//
//   dart run tool/generate_structure_tree.dart
//
// CI (.github/workflows/ci.yml) runs this into a temp file and diffs
// it against the committed copy, failing the build if they differ.

import 'dart:io';

const _startMarker = '<!-- TREE:START -->';
const _endMarker = '<!-- TREE:END -->';
const _regenerateComment =
    '<!-- Run `dart run tool/generate_structure_tree.dart` to regenerate. -->';

// Empty folders (stray "New folder (n)" clutter, etc.) are filtered out
// by _hasTrackedContent below, so they need no entry here — this list is
// only for real, non-empty paths that shouldn't appear in a
// *plugin-structure* tree (build/tooling metadata, not part of the
// plugin format).
const _excluded = {
  '.git',
  '.dart_tool',
  '.github',
  '.claude',
  'build',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  '.gitattributes',
  '.gitignore',
  'pubspec.lock',
  'pubspec_overrides.yaml',
  'LICENSE',
  'CODE_OF_CONDUCT.md',
  'SECURITY.md',
};

// One-line descriptions for top-level entries worth annotating. Anything
// not listed here (a new plugin folder, for example) still shows up in
// the tree, just without a comment.
const _descriptions = {
  'lib': '~30 bundled plugin implementations — see docs/PLUGINS.md',
  'sample_logger': 'example downloadable plugin — copy this to start one',
  'docs': 'documentation directory — see docs/README.md',
  'test': 'automated tests',
  'tool': 'repo maintenance scripts (this generator)',
  'catalog.json': 'one-tap-install catalog for downloadable plugins',
  'pubspec.yaml': 'package manifest for the bundled-plugins package',
  'README.md': 'start here',
  'CONTRIBUTING.md': 'workflow for contributing to this repo',
};

void main() {
  final repoRoot = Directory.current;
  final entries = repoRoot
      .listSync()
      .where((e) => !_excluded.contains(_basename(e.path)))
      .where((e) => _hasTrackedContent(e))
      .toList()
    ..sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));

  final lines = <String>['Omnis-Plugins/'];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final isLast = i == entries.length - 1;
    final connector = isLast ? '└──' : '├──';
    final name = _basename(entry.path);
    final isDir = entry is Directory;
    final label = isDir ? '$name/' : name;
    final desc = _descriptions[name];
    final padded = desc == null ? label : label.padRight(24);
    lines.add('$connector $padded${desc == null ? '' : '  # $desc'}');
  }

  final treeBlock = '```\n${lines.join('\n')}\n```';
  final newSection =
      '$_startMarker\n$_regenerateComment\n\n$treeBlock\n$_endMarker';

  final structureFile = File('docs/STRUCTURE.md');
  final content = structureFile.readAsStringSync();
  final startIdx = content.indexOf(_startMarker);
  final endIdx = content.indexOf(_endMarker);
  if (startIdx == -1 || endIdx == -1) {
    stderr.writeln('Could not find TREE markers in docs/STRUCTURE.md');
    exit(1);
  }
  final updated = content.replaceRange(
    startIdx,
    endIdx + _endMarker.length,
    newSection,
  );
  structureFile.writeAsStringSync(updated);
  stdout.writeln('docs/STRUCTURE.md tree block updated.');
}

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;

bool _hasTrackedContent(FileSystemEntity entity) {
  if (entity is File) return true;
  if (entity is Directory) {
    return entity
        .listSync(recursive: true)
        .whereType<File>()
        .isNotEmpty;
  }
  return false;
}
