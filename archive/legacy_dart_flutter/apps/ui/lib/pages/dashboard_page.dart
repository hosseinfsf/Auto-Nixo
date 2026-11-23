import 'package:flutter/material.dart';

import '../api/engine_api.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.api});

  final EngineApi api;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic>? _status;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.status();
      setState(() {
        _status = s;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _kill() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Kill Switch'),
        content: const Text('Stop intake and close all trades?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('KILL'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.api.kill();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kill switch activated')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NIXO LITE — Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            tooltip: 'Kill switch',
            onPressed: _kill,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : _DashboardBody(status: _status ?? {}),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48),
          const SizedBox(height: 12),
          Text('Cannot reach engine: $message'),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final inputs = (status['inputs'] as List? ?? []);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('Engine'),
            subtitle: Text('Running — ${inputs.length} input(s)'),
            trailing: const Chip(label: Text('ON')),
          ),
        ),
        const SizedBox(height: 16),
        Text('Inputs', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final input in inputs)
          Card(
            child: ListTile(
              leading: Icon(
                input['type'] == 'telegram_source'
                    ? Icons.send
                    : Icons.webhook,
              ),
              title: Text(input['name']?.toString() ?? ''),
              subtitle: Text(
                '${input['status'] ?? 'unknown'} · last: '
                '${input['last_message_at'] ?? '—'}',
              ),
              trailing: Switch(
                value: input['enabled'] == 1,
                onChanged: (_) {},
              ),
            ),
          ),
      ],
    );
  }
}
