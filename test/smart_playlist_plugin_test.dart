import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/smart_playlist_plugin.dart';
import 'package:omnis_plugin_api/smart_playlist_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage-only behavior for the rule-persistence layer (§42) — no
/// `PluginContext` needed here, same as `favorites_plugin_test.dart`.
/// `buildQueueForRule`'s `IRatingsProvider` lookup on a bare, unattached
/// instance is covered separately: it degrades to "rating conditions
/// never match" (see the last test below), and full cross-plugin wiring
/// through a real `PluginContext`/`ServiceRegistry` is exercised in the
/// main Omnis repo's test suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track(String id, {List<String> genres = const [], int? year}) =>
      BaseTrack(
        id: id,
        title: 'T$id',
        artists: const ['Artist'],
        album: 'Album',
        duration: 180,
        type: TrackType.local,
        genres: genres,
        year: year,
      );

  SmartPlaylistRule rule(String id, {List<RuleCondition> conditions = const [
    RuleCondition(
        field: RuleField.genre, operator: RuleOperator.equals, value: 'rock'),
  ]}) =>
      SmartPlaylistRule(
        id: id,
        name: 'Rule $id',
        matchType: RuleMatchType.all,
        conditions: conditions,
      );

  group('savedRules', () {
    test('empty until a rule is saved', () {
      final plugin = SmartPlaylistPlugin();
      expect(plugin.savedRules, isEmpty);
    });

    test('saveRule persists across a fresh instance', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));

      final freshInstance = SmartPlaylistPlugin();
      await freshInstance.storage.initialize();
      expect(freshInstance.savedRules.map((r) => r.id), ['1']);
    });

    test('saveRule with an existing id replaces rather than duplicates',
        () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));
      await plugin.saveRule(SmartPlaylistRule(
        id: '1',
        name: 'Renamed',
        matchType: RuleMatchType.any,
        conditions: const [],
      ));
      expect(plugin.savedRules, hasLength(1));
      expect(plugin.savedRules.single.name, 'Renamed');
    });
  });

  group('deleteRule', () {
    test('removes a saved rule', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));
      await plugin.saveRule(rule('2'));
      await plugin.deleteRule('1');
      expect(plugin.savedRules.map((r) => r.id), ['2']);
    });

    test('deleting an unknown id is a harmless no-op', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));
      await plugin.deleteRule('nonexistent');
      expect(plugin.savedRules, hasLength(1));
    });
  });

  group('corruption resilience', () {
    test('a single malformed saved rule is skipped, not fatal to the '
        'rest', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('good'));
      // Directly corrupt storage alongside the one good, already-saved
      // rule, same "per-entry defensive decode" contract every other
      // JSON-backed store in this app follows.
      final raw = plugin.storage.getString('smart_rules_json')!;
      await plugin.storage.setString(
        'smart_rules_json',
        raw.replaceFirst('[', '[{"not":"a valid rule"},'),
      );
      expect(plugin.savedRules.map((r) => r.id), ['good']);
    });

    test('completely corrupt JSON degrades to "no rules", not a crash',
        () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.storage.setString('smart_rules_json', 'not valid json {{{');
      expect(plugin.savedRules, isEmpty);
    });
  });

  group('buildQueueForRule', () {
    test('evaluates the named rule fresh against the given tracks', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));
      final tracks = [
        track('a', genres: ['Rock']),
        track('b', genres: ['Pop']),
      ];
      expect(
        plugin.buildQueueForRule(tracks, '1').map((t) => t.id),
        ['a'],
      );
    });

    test('an unknown rule id returns an empty list, never throws', () {
      final plugin = SmartPlaylistPlugin();
      expect(plugin.buildQueueForRule([track('a')], 'nonexistent'), isEmpty);
    });

    test('a rating condition never matches on a bare instance with no '
        'registered IRatingsProvider — degrades gracefully rather than '
        'throwing on the missing context', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1', conditions: const [
        RuleCondition(
            field: RuleField.rating,
            operator: RuleOperator.greaterThanOrEqual,
            value: '1'),
      ]));
      expect(plugin.buildQueueForRule([track('a')], '1'), isEmpty);
    });
  });

  group('exportRulesJson / importRulesJson (item 42, import/export)', () {
    test('exportRulesJson exports exactly the currently saved rules', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));
      await plugin.saveRule(rule('2'));

      final json = plugin.exportRulesJson();
      final decoded = importRulesFromJson(json);
      expect(decoded.map((r) => r.id).toSet(), {'1', '2'});
    });

    test('importRulesJson adds new rules and returns the count actually '
        'imported', () async {
      final plugin = SmartPlaylistPlugin();
      final json = exportRulesToJson([rule('a'), rule('b')]);

      final imported = await plugin.importRulesJson(json);

      expect(imported, 2);
      expect(plugin.savedRules.map((r) => r.id).toSet(), {'a', 'b'});
    });

    test('importRulesJson replaces an existing rule with the same id '
        'rather than duplicating it', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('1'));
      final updated = SmartPlaylistRule(
        id: '1',
        name: 'Updated Name',
        matchType: RuleMatchType.any,
        conditions: const [],
      );

      await plugin.importRulesJson(exportRulesToJson([updated]));

      expect(plugin.savedRules, hasLength(1));
      expect(plugin.savedRules.single.name, 'Updated Name');
    });

    test('importRulesJson persists across a fresh instance', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.importRulesJson(exportRulesToJson([rule('1')]));

      final freshInstance = SmartPlaylistPlugin();
      await freshInstance.storage.initialize();
      expect(freshInstance.savedRules.map((r) => r.id), ['1']);
    });

    test('importRulesJson with malformed input imports nothing and '
        'leaves existing saved rules untouched', () async {
      final plugin = SmartPlaylistPlugin();
      await plugin.saveRule(rule('existing'));

      final imported = await plugin.importRulesJson('not valid json {{{');

      expect(imported, 0);
      expect(plugin.savedRules.map((r) => r.id), ['existing']);
    });
  });
}
