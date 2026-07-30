import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:math';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:image_picker/image_picker.dart';

// Global ValueNotifier to manage the theme state
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);
const int baseTierDailyUseLimit = 3;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  
  // Initialize our persistent database before the app runs
  await MockDatabase.instance.init();
  
  runApp(const AIStylistApp());
}

// --- DATA MODEL ---
class ClothingItem {
  final String id;
  String title;
  final String imageUrl;
  final String category; // e.g. 'top', 'bottom', 'dress', 'accessory', 'footwear', 'outerwear'
  bool isDirty;
  final List<String> tags;

  ClothingItem({
    required this.id,
    required this.title,
    required this.imageUrl,
    required this.category,
    this.tags = const [],
    this.isDirty = false,
  });

  // Convert to JSON for saving
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'imageUrl': imageUrl,
        'category': category,
        'tags': tags,
        'isDirty': isDirty,
      };

  // Create from JSON on load
  factory ClothingItem.fromJson(Map<String, dynamic> json) => ClothingItem(
        id: json['id'] as String,
        title: json['title'] as String,
        imageUrl: json['imageUrl'] as String,
        category: (json['category'] as String?) ?? 'top',
        tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
        isDirty: (json['isDirty'] as bool?) ?? false,
      );
}

// --- USER PROFILE MODEL ---
class UserProfile {
  final String email;
  String password; // <-- NEW: Password added to the user profile
  String? username;
  String? profileImageUrl;
  bool isPremium;
  int usesToday;
  DateTime usageDate;
  List<ClothingItem> closet;

  UserProfile({
    required this.email,
    required this.password,
    this.username,
    this.profileImageUrl,
    this.isPremium = false,
    this.usesToday = 0,
    DateTime? usageDate,
    required this.closet,
  }) : usageDate = usageDate ?? DateTime.now();

  void resetDailyUsesIfNeeded({DateTime? now}) {
    final today = now ?? DateTime.now();
    if (usageDate.year == today.year &&
        usageDate.month == today.month &&
        usageDate.day == today.day) {
      return;
    }

    usesToday = 0;
    usageDate = today;
  }

  bool get hasBaseUsesRemaining {
    resetDailyUsesIfNeeded();
    return isPremium || usesToday < baseTierDailyUseLimit;
  }

  int get baseUsesRemaining {
    resetDailyUsesIfNeeded();
    return max(0, baseTierDailyUseLimit - usesToday);
  }

  void recordStylistUse() {
    resetDailyUsesIfNeeded();
    if (!isPremium) {
      usesToday++;
    }
  }

  // Convert to JSON for saving
  Map<String, dynamic> toJson() => {
        'email': email,
        'password': password,
        'username': username,
        'profileImageUrl': profileImageUrl,
        'isPremium': isPremium,
        'usesToday': usesToday,
        'usageDate': usageDate.toIso8601String(),
        'closet': closet.map((e) => e.toJson()).toList(),
      };

  // Create from JSON on load
  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        email: json['email'] as String,
        // Fallback for old data without passwords saved locally
        password: (json['password'] as String?) ?? 'password123', 
        username: (json['username'] as String?),
        profileImageUrl: (json['profileImageUrl'] as String?),
        isPremium: (json['isPremium'] as bool?) ?? false,
        usesToday: (json['usesToday'] as int?) ?? 0,
        usageDate: json['usageDate'] != null ? DateTime.parse(json['usageDate'] as String) : null,
        closet: (json['closet'] as List?)?.map((e) => ClothingItem.fromJson(e as Map<String, dynamic>)).toList() ?? [],
      );
}

bool aiResponseMadeOutfit(
  String responseType,
  List<ClothingItem> matchedItems,
) {
  return responseType == 'outfit' && matchedItems.isNotEmpty;
}

List<ClothingItem> cleanClothesForOutfits(List<ClothingItem> closetItems) {
  return closetItems.where((item) => !item.isDirty).toList();
}

// Helper to build either a network image or local file image depending on the path
Widget _buildClothingImage(String path, {double? width, double? height, BoxFit? fit, bool darken = false}) {
  Widget img;
  if (path.startsWith('http')) {
    img = Image.network(
      path,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => SizedBox(width: width ?? 100, height: height ?? 100, child: const Icon(Icons.broken_image)),
    );
  } else {
    img = Image.file(
      File(path),
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => SizedBox(width: width ?? 100, height: height ?? 100, child: const Icon(Icons.broken_image)),
    );
  }

  if (!darken) return img;

  return Stack(
    fit: StackFit.expand,
    children: [
      img,
      Container(color: Colors.black.withOpacity(0.35)),
    ],
  );
}

// --- MOCK DATABASE (Now with Persistent Storage & Password checks) ---
class MockDatabase {
  static final MockDatabase instance = MockDatabase._internal();
  MockDatabase._internal();

  late SharedPreferences _prefs;
  
  // Base test account
  final Map<String, UserProfile> _userData = {
    'test@test.com': UserProfile(
      email: 'test@test.com',
      password: 'password123', // Hardcoded password for the test account
      isPremium: false,
      usesToday: 0,
      closet: [
        ClothingItem(
          id: '1',
          title: 'Vintage Band Tee',
          imageUrl: 'https://images.unsplash.com/photo-1503342217505-b0a15ec3261c?w=500&q=80',
          category: 'top',
          tags: ['vintage','graphic'],
        ),
        ClothingItem(
          id: '2',
          title: 'Blue Denim Jeans',
          imageUrl: 'https://images.unsplash.com/photo-1542272604-787c3835535d?w=500&q=80',
          category: 'bottom',
          tags: ['denim','casual'],
        ),
        ClothingItem(
          id: '3',
          title: 'Retro Sunglasses',
          imageUrl: 'https://images.unsplash.com/photo-1511499767150-a48a237f0083?w=500&q=80',
          category: 'accessory',
          tags: ['sunglasses','retro'],
        ),
        ClothingItem(
          id: '4',
          title: 'White Sneakers',
          imageUrl: 'https://images.unsplash.com/photo-1520975917969-3a7c6a1f5f1b?w=500&q=80',
          category: 'footwear',
          tags: ['sneakers','casual'],
        ),
        ClothingItem(
          id: '5',
          title: 'Floral Sundress',
          imageUrl: 'https://images.unsplash.com/photo-1495121605193-b116b5b09f23?w=500&q=80',
          category: 'dress',
          tags: ['floral','summer'],
        ),
        ClothingItem(
          id: '6',
          title: 'Khaki Shorts',
          imageUrl: 'https://images.unsplash.com/photo-1540574163026-643ea20ade25?w=500&q=80',
          category: 'bottom',
          tags: ['shorts','casual'],
        ),
        ClothingItem(
          id: '7',
          title: 'Lightweight Jacket',
          imageUrl: 'https://images.unsplash.com/photo-1520975917969-3a7c6a1f5f1b?w=500&q=80',
          category: 'outerwear',
          tags: ['jacket','layering'],
        ),
      ],
    ),
  };
  
  final Set<String> _takenUsernames = {};
  final List<String> _bannedWords = ['admin', 'root', 'swearword', 'offensive'];

  // Initialize and load saved data
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final savedData = _prefs.getString('app_database');
    
    if (savedData != null) {
      final Map<String, dynamic> decodedData = jsonDecode(savedData);
      decodedData.forEach((emailKey, profileJson) {
        final profile = UserProfile.fromJson(profileJson);
        _userData[emailKey] = profile;
        if (profile.username != null) {
          _takenUsernames.add(profile.username!.toLowerCase());
        }
      });
    }
  }

  // Save current state to device
  Future<void> save() async {
    final encodedData = jsonEncode(
      _userData.map((key, value) => MapEntry(key, value.toJson())),
    );
    await _prefs.setString('app_database', encodedData);
  }

  // --- NEW AUTHENTICATION LOGIC ---
  String? authenticateOrRegister(String email, String password) {
    if (_userData.containsKey(email)) {
      // User exists, verify password
      if (_userData[email]!.password == password) {
        return null; // null means Success
      } else {
        return 'Incorrect password for this email.'; // Error message
      }
    } else {
      // New user, create account
      _userData[email] = UserProfile(email: email, password: password, closet: []);
      save(); // Save the new user to storage
      return null; // null means Success
    }
  }

  UserProfile getProfile(String email) {
    return _userData[email]!; // Safe to use after authenticateOrRegister passes
  }

  bool isUsernameTaken(String username) {
    return _takenUsernames.contains(username.toLowerCase());
  }

  bool isUsernameAppropriate(String username) {
    final lower = username.toLowerCase();
    for (var word in _bannedWords) {
      if (lower.contains(word)) {
        return false;
      }
    }
    return true;
  }

  String? updateUsername(UserProfile profile, String newUsername) {
    final cleanName = newUsername.trim();
    if (cleanName.isEmpty) return 'Username cannot be empty';
    if (cleanName.length < 3) return 'Username must be at least 3 characters';
    
    if (profile.username == cleanName) return null;

    if (profile.username?.toLowerCase() == cleanName.toLowerCase()) {
      profile.username = cleanName;
      save(); // Save changes
      return null;
    }

    if (!isUsernameAppropriate(cleanName)) {
      return 'This username contains inappropriate language.';
    }

    if (isUsernameTaken(cleanName)) {
      return 'This username is already taken.';
    }

    if (profile.username != null) {
      _takenUsernames.remove(profile.username!.toLowerCase());
    }

    profile.username = cleanName;
    _takenUsernames.add(cleanName.toLowerCase());
    save(); // Save changes
    return null;
  }
}

// Start a Stripe Checkout session via backend and open the hosted Checkout page
Future<void> startCheckout(BuildContext context, String email) async {
  // If a simple Payment Link is configured in the app .env, open it directly (no backend needed).
  final paymentLink = dotenv.env['STRIPE_PAYMENT_LINK'];
  if (paymentLink != null && paymentLink.isNotEmpty) {
    final launched = await launchUrlString(paymentLink);
    if (!launched) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not launch payment link')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Opened payment link — complete the purchase in your browser.')));
    }
    return;
  }

  final backendUrl = dotenv.env['STRIPE_BACKEND_URL'];
  if (backendUrl == null || backendUrl.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Missing STRIPE_BACKEND_URL in .env — set it to your backend URL or STRIPE_PAYMENT_LINK.'),
    ));
    return;
  }

  try {
    final resp = await http.post(
      Uri.parse('$backendUrl/create-checkout-session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      final url = data['url'] as String?;
      if (url != null && url.isNotEmpty) {
        // Open the hosted Stripe Checkout page in the external browser
        final launched = await launchUrlString(url);
        if (!launched) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not launch checkout URL')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Opened checkout — complete the purchase in your browser.')));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backend did not return a checkout URL')));
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create checkout session: ${resp.statusCode}')));
    }
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error: $e')));
  }
}

class AIStylistApp extends StatelessWidget {
  const AIStylistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          title: 'AI Stylist',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: currentMode,
          home: const SignInScreen(),
        );
      },
    );
  }
}

// Reusable toggle button for the AppBars
class ThemeToggleAction extends StatelessWidget {
  const ThemeToggleAction({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        final isLight = currentMode == ThemeMode.light;
        return IconButton(
          icon: Icon(isLight ? Icons.dark_mode : Icons.light_mode),
          tooltip: 'Toggle Theme',
          onPressed: () {
            themeNotifier.value = isLight ? ThemeMode.dark : ThemeMode.light;
          },
        );
      },
    );
  }
}

// Reusable logout action
void performLogout(BuildContext context) {
  showDialog(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: const Text('Sign Out'),
        content: const Text(
          'Are you sure you want to sign out of your closet?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const SignInScreen()),
                (Route<dynamic> route) => false,
              );
            },
            child: const Text('Sign Out'),
          ),
        ],
      );
    },
  );
}

// Reusable Paywall Sheet UI component
void showPaywall(
  BuildContext context,
  String email,
  VoidCallback onPurchaseSuccess,
) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            const Icon(Icons.auto_awesome, size: 64, color: Colors.amber),
            const SizedBox(height: 16),
            const Text(
              'Upgrade to Premium',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Unlock unlimited daily styling matches generated by AI.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.primaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.check, color: Colors.green),
                      title: Text('Unlimited AI requests (No limits)'),
                    ),
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.check, color: Colors.green),
                      title: Text('Priority fast-track outfit generation'),
                    ),
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.check, color: Colors.green),
                      title: Text('Ad-free experience'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await startCheckout(context, email);
                },
                child: const Text(
                  'Unlock Unlimited — \$15.00 / USD',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Maybe Later'),
            ),
          ],
        ),
      );
    },
  );
}

// --- AUTHENTICATION: SIGN IN SCREEN ---
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _signIn() async {
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an email and password.')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    await Future.delayed(const Duration(milliseconds: 800)); // Mock network delay

    if (!mounted) return;
    
    setState(() {
      _isLoading = false;
    });

    // Check credentials against the mock database
    final errorMessage = MockDatabase.instance.authenticateOrRegister(email, password);

    if (errorMessage != null) {
      // If error message is not null, the password was wrong
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
      );
      return;
    }

    // Success! Get the profile.
    final profile = MockDatabase.instance.getProfile(email);

    if (profile.username == null || profile.username!.isEmpty) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => UsernameSetupScreen(userEmail: email)),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => MainNavigation(userEmail: email)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(actions: const [ThemeToggleAction()]),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.auto_awesome,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'AI Stylist',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in or create a new account',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _isLoading ? null : _signIn,
                  child: _isLoading
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Continue', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- USERNAME SETUP SCREEN ---
class UsernameSetupScreen extends StatefulWidget {
  final String userEmail;
  const UsernameSetupScreen({super.key, required this.userEmail});

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final TextEditingController _usernameController = TextEditingController();
  String? _errorMessage;

  void _submitUsername() {
    final profile = MockDatabase.instance.getProfile(widget.userEmail);
    final error = MockDatabase.instance.updateUsername(profile, _usernameController.text);

    if (error != null) {
      setState(() {
        _errorMessage = error;
      });
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => MainNavigation(userEmail: widget.userEmail)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose Username')),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.account_circle, size: 80, color: Colors.deepPurple),
            const SizedBox(height: 24),
            Text(
              'Welcome!',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Pick a unique username to get started.'),
            const SizedBox(height: 32),
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(
                labelText: 'Username',
                prefixIcon: const Icon(Icons.alternate_email),
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: _submitUsername,
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- MAIN NAVIGATION ---
class MainNavigation extends StatefulWidget {
  final String userEmail;
  const MainNavigation({super.key, required this.userEmail});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;
  late UserProfile _userProfile;

  @override
  void initState() {
    super.initState();
    _userProfile = MockDatabase.instance.getProfile(widget.userEmail);
  }

  void _deleteItem(String id) {
    setState(() {
      _userProfile.closet.removeWhere((item) => item.id == id);
      MockDatabase.instance.save(); // Save after deleting
    });
  }

  void _renameItem(String id, String title) {
    setState(() {
      final item = _userProfile.closet.firstWhere((item) => item.id == id);
      item.title = title;
      MockDatabase.instance.save(); // Save after renaming
    });
  }

  void _toggleDirtyItem(String id) {
    setState(() {
      final item = _userProfile.closet.firstWhere((item) => item.id == id);
      item.isDirty = !item.isDirty;
      MockDatabase.instance.save(); // Save after toggling dirtiness
    });
  }

  // Show options to add clothes: Upload from gallery or open Camera
  void _showAddClothesOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Upload from Gallery'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Camera'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickFromCamera();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickFromCamera() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
      if (picked == null) return; // user cancelled

      final newItem = ClothingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: picked.name.isNotEmpty ? picked.name : 'Camera Photo',
        imageUrl: picked.path,
        category: 'top', // default: user may rename or change category later
        tags: [],
      );

      setState(() {
        _userProfile.closet.add(newItem);
        MockDatabase.instance.save();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (picked == null) return; // user cancelled

      final newItem = ClothingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: picked.name.isNotEmpty ? picked.name : 'Uploaded Photo',
        imageUrl: picked.path,
        category: 'top',
        tags: [],
      );

      setState(() {
        _userProfile.closet.add(newItem);
        MockDatabase.instance.save();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      StylistScreen(userProfile: _userProfile),
      ClosetScreen(
        closetItems: _userProfile.closet,
        onDelete: _deleteItem,
        onRename: _renameItem,
        onToggleDirty: _toggleDirtyItem,
        onAdd: _showAddClothesOptions,
      ),
      ProfileScreen(
        userProfile: _userProfile,
        onStateChanged: () => setState(() {}),
      ),
    ];

    return Scaffold(
      body: screens[_currentIndex],
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.auto_awesome),
                label: 'Stylist',
              ),
              NavigationDestination(icon: Icon(Icons.checkroom), label: 'Closet'),
              NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
            ],
          ),
          if (!_userProfile.isPremium)
            const AdBannerWidget(),
        ],
      ),
    );
  }
}

// --- SCREEN 1: THE AI STYLIST ---
class StylistScreen extends StatefulWidget {
  final UserProfile userProfile;
  const StylistScreen({super.key, required this.userProfile});

  @override
  State<StylistScreen> createState() => _StylistScreenState();
}

class _StylistScreenState extends State<StylistScreen> {
  final TextEditingController _promptController = TextEditingController();
  bool _isLoading = false;
  String _generatedOutfitMessage = "Tell me what you're dressing for!";
  List<ClothingItem> _recommendedItems = [];

  Future<void> _generateOutfit() async {
    final userPrompt = _promptController.text.trim();
    if (userPrompt.isEmpty) return;

    widget.userProfile.resetDailyUsesIfNeeded();

    setState(() {
      _isLoading = true;
      _recommendedItems = [];
    });

    final apiKey = dotenv.env['OPENAI_API_KEY'];
    final cleanClosetItems = cleanClothesForOutfits(widget.userProfile.closet);
    final closetInventory = cleanClosetItems.isNotEmpty
        ? cleanClosetItems.map((item) => 'ID: ${item.id}, Name: ${item.title}, Category: ${item.category}${item.tags.isNotEmpty ? ', Tags: ${item.tags.join(", ")}' : ''}').join(' | ')
        : "No clean clothes available right now.";

    final systemPrompt = """
      You are an expert AI fashion stylist.
      The user has these clean, available items: $closetInventory.
      The user said: '$userPrompt'.

      GUIDELINES (follow in order):
      1. Analyze the user's request for occasion, weather, vibe, and formality before selecting items.
      2. If the user requests an outfit, select the most stylish combination from the INVENTORY ONLY.
      3. Apply real fashion principles: consider color coordination, proportions, layering, and contrast — do not pick random items.
      4. If the user is just chatting or asking for general advice without requesting a specific outfit, act as a friendly consultant and leave item_ids empty.

      Rules when creating an outfit (APPLY STRICTLY):
      - Use ONLY items listed above (by ID).
      - If you include any item with Category 'dress' in item_ids, DO NOT include any item with Category 'top' or 'bottom'.
      - Otherwise, include EXACTLY ONE bottom (Category 'bottom') which must be pants, shorts or skirt.
      - Otherwise, include EXACTLY ONE top (Category 'top').
      - Include EXACTLY ONE accessory (Category 'accessory').
      - Include EXACTLY ONE footwear (Category 'footwear').
      - You MAY include at most ONE outerwear (Category 'outerwear') optionally.

      When returning an outfit, prefer complementary colors/occasion/season and briefly explain your choices in the message field.

      Return ONLY a JSON object in this shape:
      {"response_type": "outfit" or "chat", "message": "Your reply.", "item_ids": ["id1", "id2"]}
    """;

    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini',
          'response_format': {'type': 'json_object'},
          'messages': [{'role': 'system', 'content': systemPrompt}],
          'temperature': 0.7,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final aiOutput = jsonDecode(data['choices'][0]['message']['content']);
        final responseType = aiOutput['response_type'] == 'outfit' ? 'outfit' : 'chat';
        final String message = aiOutput['message'] ?? (responseType == 'outfit' ? "Here is your outfit!" : "I'm here.");
        final List<String> selectedIds = List<String>.from(aiOutput['item_ids'] ?? []);

        final matchedItems = cleanClosetItems.where((item) => selectedIds.contains(item.id)).toList();
        final madeOutfit = aiResponseMadeOutfit(responseType, matchedItems);

        if (madeOutfit && !widget.userProfile.hasBaseUsesRemaining) {
          setState(() {
            _generatedOutfitMessage = "You've used your 3 free AI styling requests for today. Upgrade for unlimited matches or come back tomorrow.";
            _recommendedItems = [];
          });
          showPaywall(context, widget.userProfile.email, () => setState(() {}));
          return;
        }

        setState(() {
          if (madeOutfit) {
             widget.userProfile.recordStylistUse();
             MockDatabase.instance.save(); // Save incremented usage limit
          }
          _generatedOutfitMessage = message;
          _recommendedItems = madeOutfit ? matchedItems : [];
        });
      }
    } catch (e) {
      setState(() {
        _generatedOutfitMessage = "Network error. Please try again.";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final usesRemaining = widget.userProfile.baseUsesRemaining;

    return Scaffold(
      appBar: AppBar(title: const Text('Ask Your AI Stylist')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (!widget.userProfile.isPremium)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Base Tier: $usesRemaining/3 requests left today', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                    TextButton(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () => showPaywall(context, widget.userProfile.email, () => setState(() {})),
                      child: const Text('Get Unlimited', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: _promptController,
              decoration: InputDecoration(
                hintText: 'Ask for an outfit or chat about your style',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _isLoading ? null : _generateOutfit),
              ),
              onSubmitted: (_) => _isLoading ? null : _generateOutfit(),
            ),
            const SizedBox(height: 32),
            if (_isLoading)
              const CircularProgressIndicator()
            else
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_recommendedItems.isEmpty) const Icon(Icons.style, size: 64, color: Colors.deepPurple),
                        const SizedBox(height: 16),
                        Text(_generatedOutfitMessage, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
                        if (_recommendedItems.isNotEmpty) ...[
                          const SizedBox(height: 32),
                          const Divider(),
                          const SizedBox(height: 16),
                          Text(
                            'Your Visual Outfit',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            alignment: WrapAlignment.center,
                            children: _recommendedItems.map((item) {
                              return Column(
                                children: [
                                  Card(
                                    elevation: 4,
                                    clipBehavior: Clip.antiAlias,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    child: _buildClothingImage(item.imageUrl, width: 100, height: 100, fit: BoxFit.cover),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(width: 100, child: Text(item.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis)),
                                ],
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- SCREEN 2: THE CLOSET ---
class ClosetScreen extends StatefulWidget {
  final List<ClothingItem> closetItems;
  final Function(String id) onDelete;
  final Function(String id, String title) onRename;
  final Function(String id) onToggleDirty;
  final VoidCallback onAdd;

  const ClosetScreen({
    super.key,
    required this.closetItems,
    required this.onDelete,
    required this.onRename,
    required this.onToggleDirty,
    required this.onAdd,
  });

  @override
  State<ClosetScreen> createState() => _ClosetScreenState();
}

class _ClosetScreenState extends State<ClosetScreen> {
  Future<void> _showRenameDialog(ClothingItem item) async {
    var draftTitle = item.title;
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename Item'),
          content: TextFormField(
            initialValue: item.title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Item name', border: OutlineInputBorder()),
            textInputAction: TextInputAction.done,
            onChanged: (value) => draftTitle = value,
            onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(draftTitle), child: const Text('Save')),
          ],
        );
      },
    );

    if (!mounted) return;
    final trimmedTitle = newTitle?.trim();
    if (trimmedTitle == null || trimmedTitle.isEmpty) return;
    widget.onRename(item.id, trimmedTitle);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Closet')),
      body: widget.closetItems.isEmpty
          ? const Center(child: Text('Your closet is empty. Add some clothes!'))
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16),
              itemCount: widget.closetItems.length,
              itemBuilder: (context, index) {
                final item = widget.closetItems[index];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  elevation: 4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildClothingImage(item.imageUrl, fit: BoxFit.cover, darken: item.isDirty),
                      if (item.isDirty)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: Colors.brown.withOpacity(0.9), borderRadius: BorderRadius.circular(12)),
                            child: const Text('Dirty', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          color: Colors.black.withOpacity(0.6),
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                          child: Text(item.title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Material(
                          color: Colors.black.withOpacity(0.5),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: PopupMenuButton<String>(
                            tooltip: 'Clothing item menu',
                            icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
                            onSelected: (value) {
                              if (value == 'rename') _showRenameDialog(item);
                              else if (value == 'dirty') widget.onToggleDirty(item.id);
                              else if (value == 'remove') widget.onDelete(item.id);
                            },
                            padding: EdgeInsets.zero,
                            itemBuilder: (context) => [
                              const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit), title: Text('Rename'))),
                              PopupMenuItem(value: 'dirty', child: ListTile(leading: Icon(item.isDirty ? Icons.checkroom : Icons.local_laundry_service), title: Text(item.isDirty ? 'Mark as clean' : 'Mark as dirty'))),
                              const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Remove'))),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: widget.onAdd,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('Add Clothes'),
      ),
    );
  }
}

// --- SCREEN 3: PROFILE SCREEN ---
class ProfileScreen extends StatefulWidget {
  final UserProfile userProfile;
  final VoidCallback onStateChanged;

  const ProfileScreen({
    super.key,
    required this.userProfile,
    required this.onStateChanged,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Future<void> _showEditProfileDialog() async {
    final usernameController = TextEditingController(text: widget.userProfile.username);
    final picController = TextEditingController(text: widget.userProfile.profileImageUrl);
    String? localError;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Profile'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: usernameController,
                      decoration: InputDecoration(
                        labelText: 'Username',
                        errorText: localError,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (localError != null) setDialogState(() => localError = null);
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: picController,
                      decoration: const InputDecoration(
                        labelText: 'Profile Picture Image URL',
                        hintText: 'https://example.com/image.jpg',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final error = MockDatabase.instance.updateUsername(widget.userProfile, usernameController.text);
                    if (error != null) {
                      setDialogState(() => localError = error);
                      return;
                    }
                    
                    widget.userProfile.profileImageUrl = picController.text.trim().isEmpty ? null : picController.text.trim();
                    MockDatabase.instance.save(); // Save after updating profile picture
                    Navigator.pop(context);
                    widget.onStateChanged();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(24.0),
        children: [
          Center(
            child: Column(
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CircleAvatar(
                      radius: 50,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      backgroundImage: widget.userProfile.profileImageUrl != null
                          ? NetworkImage(widget.userProfile.profileImageUrl!)
                          : null,
                      onBackgroundImageError: widget.userProfile.profileImageUrl != null ? (_, __) {} : null,
                      child: widget.userProfile.profileImageUrl == null
                          ? Text(
                              widget.userProfile.username != null && widget.userProfile.username!.isNotEmpty
                                  ? widget.userProfile.username![0].toUpperCase()
                                  : '?',
                              style: const TextStyle(fontSize: 40, color: Colors.white),
                            )
                          : null,
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.edit, size: 16, color: Colors.white),
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(),
                        onPressed: _showEditProfileDialog,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '@${widget.userProfile.username ?? 'Unknown'}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.userProfile.email,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${widget.userProfile.closet.length} items',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer, fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: widget.userProfile.isPremium ? Colors.amber[800] : Colors.grey[700],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        widget.userProfile.isPremium ? '💎 Premium' : 'Base Edition',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
          if (!widget.userProfile.isPremium) ...[
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text('Running low on requests?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text('Get unlimited visual styling outputs matching items instantly.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        // Make the primary upgrade button expand to avoid overflow on small screens.
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => showPaywall(context, widget.userProfile.email, widget.onStateChanged),
                            icon: const Icon(Icons.bolt),
                            label: const Text('Upgrade for \$15.00'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Wrap the refresh button to its intrinsic size
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 40),
                          child: OutlinedButton(
                            onPressed: () async {
                              final backendUrl = dotenv.env['STRIPE_BACKEND_URL'];
                              if (backendUrl == null || backendUrl.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Missing STRIPE_BACKEND_URL in .env')));
                                return;
                              }

                              try {
                                final resp = await http.get(Uri.parse('$backendUrl/subscription-status?email=${Uri.encodeQueryComponent(widget.userProfile.email)}'));
                                if (resp.statusCode == 200) {
                                  final data = jsonDecode(resp.body);
                                  final active = data['isActive'] == true;
                                  if (active) {
                                    widget.userProfile.isPremium = true;
                                    MockDatabase.instance.save();
                                    widget.onStateChanged();
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscription active — Premium enabled')));
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No active subscription found for this account')));
                                  }
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to check subscription: ${resp.statusCode}')));
                                }
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error: $e')));
                              }
                            },
                            child: const Text('Refresh'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          const Divider(),
          const SizedBox(height: 16),

          Text(
            'Settings',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),

          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (_, ThemeMode currentMode, __) {
              final isDark = currentMode == ThemeMode.dark;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dark_mode),
                title: const Text('Dark Mode'),
                trailing: Switch(
                  value: isDark,
                  onChanged: (value) {
                    themeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
                  },
                ),
              );
            },
          ),
          
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit),
            title: const Text('Edit Profile & Avatar'),
            onTap: _showEditProfileDialog,
          ),

          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('Sign Out', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => performLogout(context),
          ),
        ],
      ),
    );
  }
}

// --- MOCK AD BANNER WIDGET ---
class AdBannerWidget extends StatelessWidget {
  const AdBannerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Container(
        height: 50,
        width: double.infinity,
        color: isDark ? Colors.grey[800] : Colors.grey[300],
        alignment: Alignment.center,
        child: Text(
          'ADVERTISEMENT',
          style: TextStyle(
            color: isDark ? Colors.grey[400] : Colors.grey[600],
            fontWeight: FontWeight.bold,
            letterSpacing: 2.0,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}