import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class SettingsScreen extends StatefulWidget {
  /// Called when user taps "How to use" → opens scanner.
  /// You can swap this for a dedicated InfoScreen push if you prefer.
  final VoidCallback onGoToScanner;

  const SettingsScreen({super.key, required this.onGoToScanner});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushNotifications = true;
  bool _edgeAiPrecision = true;

  // ── "How to use" bottom sheet ─────────────────────────────────────────────

  void _showHowToUse() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, sc) => SingleChildScrollView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A5568),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text('How to Use MoldiSpora',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              _howToStep(
                '1',
                'Point the camera at a wall',
                'Aim at damp-looking corners, tiles, or surfaces where mold typically grows.',
                Icons.camera_alt_rounded,
              ),
              _howToStep(
                '2',
                'Tap ▶ to start live detection',
                'The Edge AI analyzes textures in real-time without an internet connection.',
                Icons.play_arrow_rounded,
              ),
              _howToStep(
                '3',
                'Watch for bounding boxes',
                'Green = safe, Red = mold detected. The confidence % shows certainty.',
                Icons.crop_free_rounded,
              ),
              _howToStep(
                '4',
                'Save the detection',
                'Tap the save button to record the result to History with a photo.',
                Icons.save_alt_rounded,
              ),
              _howToStep(
                '5',
                'Review your Room Safety Score',
                'The Dashboard score updates based on your saved detection history.',
                Icons.shield_outlined,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onGoToScanner(); // go directly to scanner tab
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C896),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Try it now',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _howToStep(
      String number, String title, String body, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF00C896).withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF00C896), size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(body,
                    style: const TextStyle(
                        color: Color(0xFF8B949E), fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── "Report a bug" bottom sheet ───────────────────────────────────────────

  void _showReportBug() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        // Avoid keyboard overlap
        padding: EdgeInsets.fromLTRB(
            24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A5568),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text('Report a Bug',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Describe what happened and we\'ll look into it.',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLines: 5,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'e.g. App crashed when I tapped the save button...',
                hintStyle: const TextStyle(
                    color: Color(0xFF4A5568), fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF0D1117),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF21262D)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF21262D)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF00C896)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final text = controller.text.trim();
                  Navigator.pop(context);
                  if (text.isNotEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Bug report submitted. Thank you!'),
                        backgroundColor: Color(0xFF00C896),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C896),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Submit Report',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Logout confirmation dialog ─────────────────────────────────────────────

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout Session',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: const Text(
          'All detection data stays saved locally.\nAre you sure you want to log out?',
          style: TextStyle(color: Color(0xFF8B949E), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF8B949E))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: add your actual session-clearing logic here
              // e.g. AuthService.logout() or clear stored token
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Session ended.'),
                  backgroundColor: Color(0xFF21262D),
                ),
              );
            },
            child: const Text('Logout',
                style: TextStyle(
                    color: Color(0xFFFF4444),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Profile & Settings',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 24),
              _buildProfileCard(),
              const SizedBox(height: 20),
              _buildSection('APPLICATION', [
                _buildToggleTile(
                  icon: Icons.notifications_outlined,
                  label: 'Push Notifications',
                  value: _pushNotifications,
                  onChanged: (v) => setState(() => _pushNotifications = v),
                ),
                _buildToggleTile(
                  icon: Icons.memory_rounded,
                  label: 'Edge AI Precision',
                  subtitle: 'Higher accuracy, more battery',
                  value: _edgeAiPrecision,
                  onChanged: (v) => setState(() => _edgeAiPrecision = v),
                ),
              ]),
              const SizedBox(height: 16),
              _buildSection('HELP & SUPPORT', [
                // ── How to use → bottom sheet ─────────────────────────────
                _buildNavTile(
                  icon: Icons.help_outline_rounded,
                  label: 'How to use',
                  onTap: _showHowToUse, // ← WIRED
                ),
                // ── Report a bug → bottom sheet ───────────────────────────
                _buildNavTile(
                  icon: Icons.bug_report_outlined,
                  label: 'Report a bug',
                  onTap: _showReportBug, // ← WIRED
                ),
              ]),
              const SizedBox(height: 24),
              // ── Logout → confirmation dialog ──────────────────────────────
              _buildLogoutButton(),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'MoldiSpora v1.0.0 · Kelompok A11 · AS-POLBAN',
                  style: TextStyle(
                      color: const Color(0xFF4A5568), fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF21262D)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: Color(0xFF00C896),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Text('N',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 14),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Naira Tahira',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text('Student · AS-POLBAN',
                  style: TextStyle(
                      color: Color(0xFF8B949E), fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(title,
              style: const TextStyle(
                  color: Color(0xFF4A5568),
                  fontSize: 11,
                  letterSpacing: 1.2)),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF21262D)),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildToggleTile({
    required IconData icon,
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8B949E), size: 22),
      title: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: subtitle != null
          ? Text(subtitle,
              style: const TextStyle(
                  color: Color(0xFF4A5568), fontSize: 12))
          : null,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFF00C896),
        inactiveThumbColor: const Color(0xFF4A5568),
      ),
    );
  }

  Widget _buildNavTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap, // ← now required
  }) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8B949E), size: 22),
      title: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      trailing: const Icon(Icons.chevron_right_rounded,
          color: Color(0xFF4A5568)),
      onTap: onTap, // ← WIRED
    );
  }

  Widget _buildLogoutButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _showLogoutDialog, // ← WIRED
        icon: const Icon(Icons.logout_rounded,
            color: Color(0xFFFF4444), size: 18),
        label: const Text('Logout Session',
            style: TextStyle(color: Color(0xFFFF4444))),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFFFF4444), width: 1),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}