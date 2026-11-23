import 'package:flutter/material.dart';

class ProxyPage extends StatefulWidget {
  const ProxyPage({super.key});

  @override
  State<ProxyPage> createState() => _ProxyPageState();
}

class _ProxyPageState extends State<ProxyPage> {
  final _proxies = <Map<String, dynamic>>[
    {'name': 'MTProto #1', 'type': 'mtproto', 'status': 'ok', 'latency': 120},
    {'name': 'SOCKS5', 'type': 'socks5', 'status': 'ok', 'latency': 95},
    {'name': 'Direct', 'type': 'direct', 'status': 'ok', 'latency': 0},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Proxy')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addProxy(context),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.vpn_lock),
              title: const Text('Active proxy'),
              subtitle: Text(_proxies.first['name'].toString()),
              trailing: const Chip(label: Text('ACTIVE')),
            ),
          ),
          const SizedBox(height: 16),
          for (final p in _proxies)
            Card(
              child: ListTile(
                leading: Icon(
                  p['type'] == 'direct' ? Icons.public : Icons.vpn_key,
                ),
                title: Text(p['name'].toString()),
                subtitle: Text('${p['type']} · ${p['status']} · '
                    '${p['latency']}ms'),
                trailing: const Icon(Icons.check_circle, color: Colors.green),
              ),
            ),
        ],
      ),
    );
  }

  void _addProxy(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add proxy'),
        content: const Text('Paste MTProto (tg://proxy), SOCKS5, HTTP, or '
            'local proxy (127.0.0.1:port).'),
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
