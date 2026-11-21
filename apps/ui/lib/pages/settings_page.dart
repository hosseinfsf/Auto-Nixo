import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _dark = false;
  String _language = 'English';
  bool _autostart = false;
  bool _preventSleep = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Dark mode'),
            value: _dark,
            onChanged: (v) => setState(() => _dark = v),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: const Text('Language'),
            trailing: DropdownButton<String>(
              value: _language,
              items: const [
                DropdownMenuItem(value: 'English', child: Text('English')),
                DropdownMenuItem(value: 'فارسی', child: Text('فارسی')),
              ],
              onChanged: (v) => setState(() => _language = v!),
            ),
          ),
          SwitchListTile(
            title: const Text('Autostart at logon'),
            value: _autostart,
            onChanged: (v) => setState(() => _autostart = v),
          ),
          SwitchListTile(
            title: const Text('Prevent sleep while armed'),
            value: _preventSleep,
            onChanged: (v) => setState(() => _preventSleep = v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text('Notifications'),
            subtitle: const Text('Windows toast on uncertain signals'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('NIXO LITE v0.1.0'),
          ),
        ],
      ),
    );
  }
}
