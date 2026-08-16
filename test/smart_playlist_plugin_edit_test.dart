import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, SystemChannels;
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

  // This test environment doesn't wire up a default Clipboard mock the
  // way it does for other platform channels — a real `Clipboard.setData`/
  // `getData` call otherwise hangs forever (no real OS clipboard for a
  // real platform response to come back from) rather than failing fast,
  // confirmed via a minimal standalone repro before writing this fix.
  // Only the Export/Import group below actually touches the clipboard;
  // every other test in this file is unaffected by this handler existing.
  String? mockClipboardText;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockClipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        mockClipboardText = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return {'text': mockClipboardText};
      }
      return null;
    });
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

  group('favorite field (item 39/42)', () {
    testWidgets('switching the field dropdown to Favorite swaps the value '
        'text field for a Favorited/Not favorited dropdown', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorite').last);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Value'), findsNothing);
      expect(find.text('Favorited'), findsOneWidget);
    });

    testWidgets('saving a Favorite condition (default "Favorited") builds '
        'a rule with field: favorite, operator: equals, value: "true"',
        (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorite').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Loved Tracks');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved =
          plugin.savedRules.firstWhere((r) => r.name == 'Loved Tracks');
      expect(saved.conditions.single.field, RuleField.favorite);
      expect(saved.conditions.single.operator, RuleOperator.equals);
      expect(saved.conditions.single.value, 'true');
    });

    testWidgets('switching the value dropdown to "Not favorited" builds a '
        'rule with value: "false"', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorite').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not favorited').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Not Loved');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved =
          plugin.savedRules.firstWhere((r) => r.name == 'Not Loved');
      expect(saved.conditions.single.value, 'false');
    });
  });

  group('thumbUp/thumbDown field (item 36)', () {
    testWidgets('switching the field dropdown to Thumbs up swaps the '
        'value text field for a Thumbed up/Not thumbed up dropdown',
        (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thumbs up').last);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Value'), findsNothing);
      expect(find.text('Thumbed up'), findsOneWidget);
    });

    testWidgets('saving a Thumbs up condition (default "Thumbed up") '
        'builds a rule with field: thumbUp, operator: equals, '
        'value: "true"', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thumbs up').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Liked Tracks');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved =
          plugin.savedRules.firstWhere((r) => r.name == 'Liked Tracks');
      expect(saved.conditions.single.field, RuleField.thumbUp);
      expect(saved.conditions.single.operator, RuleOperator.equals);
      expect(saved.conditions.single.value, 'true');
    });

    testWidgets('switching the value dropdown to "Not thumbed up" builds '
        'a rule with value: "false"', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thumbs up').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not thumbed up').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Not Liked');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved =
          plugin.savedRules.firstWhere((r) => r.name == 'Not Liked');
      expect(saved.conditions.single.value, 'false');
    });

    testWidgets('switching to Thumbs down uses its own field-specific '
        'labels, not "Thumbed up"/"Not thumbed up"', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thumbs down').last);
      await tester.pumpAndSettle();

      expect(find.text('Thumbed down'), findsOneWidget);
      expect(find.text('Thumbed up'), findsNothing);
    });
  });

  group('bpm/duration/bitrate fields (item 42)', () {
    testWidgets('switching the field dropdown to BPM offers the full '
        'numeric comparison set, not just contains/=', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      // BPM sits near the end of the now-longer RuleField list, past
      // what the open dropdown menu's own popup ListView renders
      // without help — a direct drag on that ListView (not just an
      // off-screen scroll, genuinely unbuilt past its cache extent)
      // brings the rest of the list into the tree.
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BPM').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<RuleOperator>));
      await tester.pumpAndSettle();

      expect(find.text('>='), findsWidgets);
      expect(find.text('<='), findsWidgets);
      expect(find.text('contains'), findsNothing);
    });

    testWidgets('saving a BPM condition builds a rule with field: bpm and '
        'the chosen numeric value', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      // BPM sits near the end of the now-longer RuleField list, past
      // what the open dropdown menu's own popup ListView renders
      // without help — a direct drag on that ListView (not just an
      // off-screen scroll, genuinely unbuilt past its cache extent)
      // brings the rest of the list into the tree.
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BPM').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<RuleOperator>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('>=').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Fast Tracks');
      await tester.enterText(find.widgetWithText(TextField, 'Value'), '120');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved =
          plugin.savedRules.firstWhere((r) => r.name == 'Fast Tracks');
      expect(saved.conditions.single.field, RuleField.bpm);
      expect(saved.conditions.single.operator, RuleOperator.greaterThanOrEqual);
      expect(saved.conditions.single.value, '120');
    });
  });

  group('codec field (item 42)', () {
    testWidgets('switching the field dropdown to Format keeps a plain '
        'text Value field, not a boolean dropdown', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      // Same "drag the dropdown's own popup ListView before looking"
      // fix as the BPM group above — Format sits even further down the
      // now-longer RuleField list.
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Format').last);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Value'), findsOneWidget);
    });

    testWidgets('Format only offers "=" in its operator dropdown, not '
        '"contains" — a codec label is categorical, not free text',
        (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      // Same "drag the dropdown's own popup ListView before looking"
      // fix as the BPM group above — Format sits even further down the
      // now-longer RuleField list.
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Format').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<RuleOperator>));
      await tester.pumpAndSettle();

      expect(find.text('='), findsWidgets);
      expect(find.text('contains'), findsNothing);
    });

    testWidgets('saving a Format condition builds a rule with field: '
        'codec, operator: equals, and the entered value', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.byType(DropdownButton<RuleField>));
      await tester.pumpAndSettle();
      // Same "drag the dropdown's own popup ListView before looking"
      // fix as the BPM group above — Format sits even further down the
      // now-longer RuleField list.
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Format').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Lossless Only');
      await tester.enterText(find.widgetWithText(TextField, 'Value'), 'FLAC');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved =
          plugin.savedRules.firstWhere((r) => r.name == 'Lossless Only');
      expect(saved.conditions.single.field, RuleField.codec);
      expect(saved.conditions.single.operator, RuleOperator.equals);
      expect(saved.conditions.single.value, 'FLAC');
    });
  });

  group('import/export (item 42)', () {
    testWidgets('Export is disabled when there are no saved rules at all',
        (tester) async {
      // Deliberately not pumpSettings() — that helper always pre-saves
      // a "Recent Rock" rule, which is exactly the case this test needs
      // to NOT be true.
      final plugin = SmartPlaylistPlugin();
      final widget = plugin.uiSlot('plugin_settings');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: widget as Widget)),
      ));
      await tester.pumpAndSettle();

      final exportButton =
          tester.widget<TextButton>(find.widgetWithText(TextButton, 'Export'));
      expect(exportButton.onPressed, isNull);
    });

    testWidgets('Export shows the saved rule as real JSON, and Copy to '
        'clipboard puts it on the clipboard', (tester) async {
      // pumpSettings() pre-saves a real "Recent Rock" rule — used
      // directly here rather than saving a second one.
      await pumpSettings(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Export'));
      await tester.pumpAndSettle();

      // A bare "Recent Rock" substring also matches an unrelated hint
      // text elsewhere on this same page (the Name field's own
      // `hintText: 'e.g. "Recent Rock"'`) — this substring is unique to
      // the exported JSON itself (jsonEncode's compact, no-space
      // output), so it can only match the dialog's own content.
      expect(find.textContaining('"name":"Recent Rock"'), findsOneWidget);

      await tester.tap(find.text('Copy to clipboard'));
      await tester.pumpAndSettle();

      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      expect(clipboard?.text, contains('Recent Rock'));
      expect(clipboard?.text, contains('"schemaVersion"'));
    });

    testWidgets('Import parses pasted JSON, saves the rule, and reports '
        'how many were imported', (tester) async {
      final plugin = await pumpSettings(tester);
      final payload = exportRulesToJson(const [
        SmartPlaylistRule(
          id: 'imported-1',
          name: 'Imported Rule',
          matchType: RuleMatchType.all,
          conditions: [
            RuleCondition(
                field: RuleField.artist,
                operator: RuleOperator.contains,
                value: 'Queen'),
          ],
        ),
      ]);

      await tester.tap(find.widgetWithText(TextButton, 'Import'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, payload);
      await tester.tap(find.text('Import').last);
      await tester.pumpAndSettle();

      // pumpSettings() itself already saved "existing-rule" — the
      // import adds a second, it doesn't replace the pre-existing one.
      expect(plugin.savedRules.map((r) => r.id).toSet(),
          {'existing-rule', 'imported-1'});
      expect(find.textContaining('Imported 1 smart playlist'), findsOneWidget);
    });

    testWidgets('Import with malformed input reports zero imported and '
        'saves nothing', (tester) async {
      final plugin = await pumpSettings(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Import'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).last, 'not valid json {{{');
      await tester.tap(find.text('Import').last);
      await tester.pumpAndSettle();

      // pumpSettings() itself already saved "existing-rule" — a failed
      // import must leave it untouched, not wipe it.
      expect(plugin.savedRules.map((r) => r.id), ['existing-rule']);
      expect(find.textContaining('No valid smart playlists found'),
          findsOneWidget);
    });

    testWidgets('Cancelling the Import dialog imports nothing', (tester) async {
      final plugin = await pumpSettings(tester);
      final payload = exportRulesToJson(
          const [SmartPlaylistRule(id: '1', name: 'X', matchType: RuleMatchType.all, conditions: [])]);

      await tester.tap(find.widgetWithText(TextButton, 'Import'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, payload);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // pumpSettings() itself already saved "existing-rule" — Cancel
      // must leave it untouched, not wipe it.
      expect(plugin.savedRules.map((r) => r.id), ['existing-rule']);
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
