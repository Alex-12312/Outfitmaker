import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Ensure this matches the name in your pubspec.yaml!
import 'package:outfitmaker/main.dart';

void main() {
  // We must mock SharedPreferences for the test environment
  // otherwise it throws an error looking for native device storage.
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('base tier allows 3 free stylist uses per day', () {
    final profile = UserProfile(
      email: 'base@test.com',
      password: 'testpassword', // <-- ADDED required password
      usageDate: DateTime(2026, 7, 9),
      closet: [],
    );

    expect(profile.baseUsesRemaining, 3);
    expect(profile.hasBaseUsesRemaining, isTrue);

    profile.recordStylistUse();
    profile.recordStylistUse();
    profile.recordStylistUse();

    expect(profile.baseUsesRemaining, 0);
    expect(profile.hasBaseUsesRemaining, isFalse);

    profile.resetDailyUsesIfNeeded(now: DateTime(2026, 7, 10));

    expect(profile.baseUsesRemaining, 3);
    expect(profile.hasBaseUsesRemaining, isTrue);
  });

  test('chat responses do not count as made outfits', () {
    final shirt = ClothingItem(
      id: 'shirt-1',
      title: 'White Shirt',
      imageUrl: 'https://example.com/shirt.jpg',
      category: 'top',
      tags: ['white','shirt'],
    );

    expect(aiResponseMadeOutfit('chat', [shirt]), isFalse);
    expect(aiResponseMadeOutfit('outfit', []), isFalse);
    expect(aiResponseMadeOutfit('outfit', [shirt]), isTrue);
  });

  test('clothing item titles can be renamed', () {
    final item = ClothingItem(
      id: 'shirt-1',
      title: 'White Shirt',
      imageUrl: 'https://example.com/shirt.jpg',
      category: 'top',
      tags: ['white','shirt'],
    );

    item.title = 'Linen Button Down';

    expect(item.title, 'Linen Button Down');
  });

  test('dirty clothing items are excluded from outfits', () {
    final cleanShirt = ClothingItem(
      id: 'shirt-1',
      title: 'White Shirt',
      imageUrl: 'https://example.com/shirt.jpg',
      category: 'top',
      tags: ['white','shirt'],
    );
    final dirtyJeans = ClothingItem(
      id: 'jeans-1',
      title: 'Blue Jeans',
      imageUrl: 'https://example.com/jeans.jpg',
      category: 'bottom',
      tags: ['denim','jeans'],
      isDirty: true,
    );

    expect(cleanClothesForOutfits([cleanShirt, dirtyJeans]), [cleanShirt]);

    dirtyJeans.isDirty = false;

    expect(cleanClothesForOutfits([cleanShirt, dirtyJeans]), [
      cleanShirt,
      dirtyJeans,
    ]);
  });

  testWidgets('AI Stylist App basic navigation test', (
    WidgetTester tester,
  ) async {
    // Initialize our MockDatabase explicitly for the widget test
    await MockDatabase.instance.init();

    // Build our app and trigger a frame.
    await tester.pumpWidget(const AIStylistApp());

    // Verify that the app starts on the sign-in screen.
    expect(find.text('AI Stylist'), findsOneWidget);
    
    // The button text was changed from 'Sign In' to 'Continue'
    expect(find.text('Continue'), findsOneWidget);

    // Enter email and password into their respective TextFields
    await tester.enterText(find.byType(TextField).at(0), 'test@test.com');
    await tester.enterText(find.byType(TextField).at(1), 'password123'); // test account password
    
    // Tap the continue button
    await tester.tap(find.text('Continue'));
    
    // Pump and wait for the mock network delay (800ms) to resolve
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    // The test account does not have a username assigned out of the box, 
    // so we get routed to the new UsernameSetupScreen. Let's fill it out.
    expect(find.text('Choose Username'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'TestUser123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Verify that username creation successfully opens the Stylist screen.
    expect(find.text('Ask Your AI Stylist'), findsOneWidget);
    
    // 'Closet' is in the bottom app bar.
    expect(find.text('Closet'), findsOneWidget);

    // Tap the 'Closet' destination in the bottom navigation bar.
    await tester.tap(find.byIcon(Icons.checkroom));

    // Wait for the navigation animation to finish.
    await tester.pumpAndSettle();

    // Verify that we navigated to the Closet screen by checking the App Bar.
    expect(find.text('Add Clothes'), findsOneWidget);
  });
}