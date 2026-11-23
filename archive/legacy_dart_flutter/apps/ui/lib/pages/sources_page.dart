import 'package:flutter/material.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  final _sources = <Map<String, dynamic>>[
    {
      'name': 'forex_snip',
      'type': 'telegram_source',
      'enabled': true,
      'mode': 'SHADOW',
      'risk': '1.0%',
      'tp_policy': 'signal',
      'sl_policy': 'signal',
      'tp_rr': 3.0,
      'validity_seconds': 180,
    },
    {
      'name': 'signals_fa',
      'type': 'telegram_source',
      'enabled': true,
      'mode': 'CONFIRM',
      'risk': '0.5%',
      'tp_policy': 'defaultRR',
      'sl_policy': 'signal',
      'tp_rr': 3.0,
      'validity_seconds': 180,
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sources')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addSource(context),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final s in _sources)
            Card(
              child: ExpansionTile(
                leading: Icon(
                  s['type'] == 'telegram_source'
                      ? Icons.send
                      : Icons.webhook,
                ),
                title: Text(s['name'].toString()),
                subtitle: Text(
                  '${s['mode']} · risk ${s['risk']}',
                ),
                trailing: Switch(
                  value: s['enabled'] as bool,
                  onChanged: (v) => setState(() => s['enabled'] = v),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _field('Mode', s['mode'].toString()),
                        _field('Risk %', s['risk'].toString()),
                        _field('TP Policy', s['tp_policy'].toString()),
                        _field('SL Policy', s['sl_policy'].toString()),
                        _field('TP RR', s['tp_rr'].toString()),
                        _field('Validity', '${s['validity_seconds']}s'),
                        _field('Allowed symbols', 'Any'),
                        _field('Roulette', 'OFF'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(String label, String value) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(value),
    );
  }

  void _addSource(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add source'),
        content: const Text('Enter Telegram channel @username, t.me link, '
            'or numeric id.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
