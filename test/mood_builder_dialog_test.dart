import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugins/mood_builder_dialog.dart';

void main() {
  testWidgets('create: Save is disabled until a name is entered',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push<CustomMood>(
            MaterialPageRoute(builder: (context) => const MoodBuilderPage()),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('New mood'), findsOneWidget);

    final saveButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));
    expect(saveButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'Late Night Drive');
    await tester.pump();

    final saveButtonAfter =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));
    expect(saveButtonAfter.onPressed, isNotNull);
  });

  testWidgets('create: selecting genre/mood chips and saving returns a '
      'fully-populated CustomMood', (tester) async {
    CustomMood? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            saved = await Navigator.of(context).push<CustomMood>(
              MaterialPageRoute(
                builder: (context) => const MoodBuilderPage(
                  knownGenres: ['Rock', 'Synthwave'],
                  knownMoodTags: [],
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Late Night Drive');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilterChip, 'Rock'));
    await tester.tap(find.widgetWithText(FilterChip, 'Dark'));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.name, 'Late Night Drive');
    expect(saved!.genres, contains('Rock'));
    expect(saved!.moodTags, contains('Dark'));
  });

  testWidgets('edit: prefills every field from the existing mood',
      (tester) async {
    const existing = CustomMood(
      id: 'm1',
      name: 'Focus',
      genres: ['Ambient'],
      moodTags: ['Focused'],
      minBpm: 90,
      maxBpm: 110,
      ratingFloor: 3,
      icon: CustomMoodIcon.work,
    );
    CustomMood? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            saved = await Navigator.of(context).push<CustomMood>(
              MaterialPageRoute(
                builder: (context) => const MoodBuilderPage(
                  existing: existing,
                  knownGenres: ['Ambient'],
                  knownMoodTags: ['Focused'],
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Edit mood'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);

    final ambientChip =
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Ambient'));
    expect(ambientChip.selected, isTrue);
    final focusedChip =
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Focused'));
    expect(focusedChip.selected, isTrue);

    // Saving unchanged should keep the same id and every field.
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.id, 'm1');
    expect(saved!.name, 'Focus');
    expect(saved!.minBpm, 90);
    expect(saved!.maxBpm, 110);
    expect(saved!.ratingFloor, 3);
  });
}
