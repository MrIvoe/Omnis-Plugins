import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/smart_playlist_plugin.dart';
import 'package:omnis_plugins/smart_playlist_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget-level coverage for smart-playlist rule *editing* (§42's
/// previously-named "delete and recreate only" gap) — genuinely new
/// stateful UI behavior (populating a form from an existing rule,
/// reusing its id on save instead of minting a new one, controller
/// lifecycle across edit/cancel/delete) that a plain unit test on
/// `SmartPlaylistPlugin.saveRule` can't exercise, since the bug class
/// here (stale/disposed controllers, a leaked edit-id after delete)
/// only shows up in the actual `State` object's behavior. The plugin's
/// settings widget (`_SmartPlaylistSettings`) is private to
/// `smart_playlist_plugin.dart`, reached the same way
/// `test/plugin_settings_page_test.dart` reaches any plugin's settings
/// widget in the main Omnis repo: through `uiSlot('plugin_settings')`,
/// typed `dynamic` specifically so a caller never needs the private
/// type name to use the returned widget.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SmartPlaylistPlugin> pumpSettings(WidgetTester tester) async {
    final plugin = SmartPlaylistPlugin();
    await plugin.saveRule(const SmartPlaylistRule(
      id: 'existing-rule',
      name: 'Recent Rock',
      matchType: RuleMatchType.all,
      conditions: [
        RuleCondition(
            field: RuleField.genre,
            operator: RuleOperator.equals,
            value: 'rock'),
      ],
    ));
    final widget = plugin.uiSlot('plugin_settings');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: widget as Widget)),
    ));
    await tester.pumpAndSettle();
    return plugin;
  }

  TextField nameField(WidgetTester tester) =>
      tester.widget<TextField>(find.widgetWithText(TextField, 'Name'));

  testWidgets('tapping Edit populates the form from the existing rule',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(nameField(tester).controller!.text, 'Recent Rock');
    expect(find.text('Edit smart playlist'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('saving after Edit updates the same rule in place — same '
      'id, no duplicate created', (tester) async {
    final plugin = await pumpSettings(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.edit_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Recent Rock (v2)');
    await tester.ensureVisible(find.text('Update'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    final rules = plugin.savedRules;
    expect(rules, hasLength(1));
    expect(rules.single.id, 'existing-rule');
    expect(rules.single.name, 'Recent Rock (v2)');
    // Back to create mode, not still editing.
    expect(find.text('Create a smart playlist'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('Cancel discards in-progress edits and touches no storage',
      (tester) async {
    final plugin = await pumpSettings(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Something Else');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final rules = plugin.savedRules;
    expect(rules, hasLength(1));
    expect(rules.single.name, 'Recent Rock'); // unchanged
    expect(nameField(tester).controller!.text, isEmpty); // form reset
    expect(find.text('Create a smart playlist'), findsOneWidget);
  });

  testWidgets('deleting the rule currently being edited also exits edit '
      'mode, rather than leaving the form pointed at a rule that no '
      "longer exists", (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Update'), findsNothing);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Create a smart playlist'), findsOneWidget);
  });

  group('string-field operator choice (item 42)', () {
    testWidgets('a string field (the default, Artist) offers both '
        '"contains" and "=" in its operator dropdown, not just "contains"',
        (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleOperator>));
      await tester.pumpAndSettle();

      expect(find.text('contains'), findsWidgets);
      expect(find.text('='), findsWidgets);
    });

    testWidgets('selecting "=" and saving builds a rule whose condition '
        'actually uses RuleOperator.equals, not contains', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleOperator>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('=').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Exact Queen');
      await tester.enterText(find.widgetWithText(TextField, 'Value'), 'Queen');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = plugin.savedRules.firstWhere((r) => r.name == 'Exact Queen');
      expect(saved.conditions.single.field, RuleField.artist);
      expect(saved.conditions.single.operator, RuleOperator.equals);
      expect(saved.conditions.single.value, 'Queen');
    });

    testWidgets('an "=" condition on a string field behaves as an exact, '
        'case-insensitive match in a real playback build, genuinely '
        'different from "contains" — proves the UI wiring reaches real '
        'matching behavior, not just that the value round-trips',
        (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleOperator>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('=').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Exact Queen');
      await tester.enterText(find.widgetWithText(TextField, 'Value'), 'queen');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = plugin.savedRules.firstWhere((r) => r.name == 'Exact Queen');
      final exactMatch = _track(id: '1', artists: const ['Queen']);
      final partialOnly = _track(id: '2', artists: const ['Queen tribute band']);
      final matched = saved.apply([exactMatch, partialOnly]);
      expect(matched.map((t) => t.id), ['1']);
    });
  });
}

BaseTrack _track({required String id, List<String> artists = const []}) =>
    BaseTrack(
      id: id,
      title: 'T$id',
      artists: artists,
      album: 'Album',
      duration: 180,
      type: TrackType.local,
    );
