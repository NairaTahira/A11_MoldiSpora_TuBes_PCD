import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:get_it/get_it.dart';

import 'models/detection_result.dart';
import 'services/hive_service.dart';
import 'services/inference_service.dart';
import 'services/camera_service.dart';
import 'screens/dashboard_screen.dart';
import 'screens/scanner_screen.dart';
import 'screens/history_screen.dart';
import 'screens/info_screen.dart';
import 'screens/settings_screen.dart';
import 'services/connectivity_service.dart';
import 'services/mongo_service.dart';

final GetIt locator = GetIt.instance;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await dotenv.load(fileName: '.env');

  await Hive.initFlutter();
  Hive.registerAdapter(DetectionResultAdapter());

  try {
    await Hive.deleteBoxFromDisk('scan_history');
  } catch (_) {}
  await Hive.openBox<DetectionResult>('scan_history');

  locator.registerSingleton<HiveService>(HiveService());
  locator.registerSingleton<InferenceService>(InferenceService());
  locator.registerSingleton<CameraService>(CameraService());

  await locator<InferenceService>().init();

  final connectivity = ConnectivityService();
  connectivity.initialize();

  runApp(const MoldiSporaApp());

  if (connectivity.isConnected.value) {
    await MongoService.connect();
    await locator<HiveService>().syncPendingResults();
  }

  connectivity.isConnected.addListener(() async {
    if (connectivity.isConnected.value) {
      await MongoService.connect();
      locator<HiveService>().syncPendingResults();
    }
  });
}

class MoldiSporaApp extends StatelessWidget {
  const MoldiSporaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MoldiSpora',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C896),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        fontFamily: 'SF Pro Display',
      ),
      home: const MainShell(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MainShell
// ─────────────────────────────────────────────────────────────────────────────

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final _camera = GetIt.I<CameraService>();

  // Scanner tab index
  static const _scannerTab = 1;

  void _goToTab(int index) {
    if (index == _currentIndex) return;

    // When LEAVING scanner tab, stop any active stream
    if (_currentIndex == _scannerTab) {
      _camera.stopImageStream();
    }

    // When ENTERING scanner tab, reinit camera so preview is fresh
    if (index == _scannerTab) {
      _camera.reinit(); // fire-and-forget; ScannerScreen also calls this in initState
    }

    setState(() => _currentIndex = index);
  }

  List<Widget> get _screens => [
        DashboardScreen(
          onGoToScanner: () => _goToTab(1),
          onGoToHistory: () => _goToTab(2),
        ),
        const ScannerScreen(),
        const HistoryScreen(),
        const InfoScreen(),
        SettingsScreen(
          onGoToScanner: () => _goToTab(1),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    const activeColor = Color(0xFF00C896);
    const inactiveColor = Color(0xFF4A5568);
    const bgColor = Color(0xFF161B22);

    return Container(
      decoration: const BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: Color(0xFF21262D), width: 1)),
      ),
      child: SafeArea(
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(Icons.home_rounded, 'Home', 0, activeColor, inactiveColor),
              _navItem(Icons.camera_alt_rounded, 'Scan', 1, activeColor, inactiveColor),
              _navItem(Icons.history_rounded, 'History', 2, activeColor, inactiveColor),
              _navItem(Icons.info_outline_rounded, 'Info', 3, activeColor, inactiveColor),
              _navItem(Icons.person_outline_rounded, 'Profile', 4, activeColor, inactiveColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index, Color active, Color inactive) {
    final isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () => _goToTab(index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: isSelected ? active : inactive, size: 24),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? active : inactive,
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}