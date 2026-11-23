import 'package:flutter/material.dart';

class LiveFeedPage extends StatefulWidget {
  const LiveFeedPage({super.key});

  @override
  State<LiveFeedPage> createState() => _LiveFeedPageState();
}

class _LiveFeedPageState extends State<LiveFeedPage> {
  final _feed = <Map<String, dynamic>>[
    {
      'ts': '12:04:11',
      'source': 'forex_snip',
      'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
      'decision': 'EXECUTED',
      'reason': 'valid signal',
    },
    {
      'ts': '12:05:33',
      'source': 'signals_fa',
      'text': 'فروش EURUSD حد ضرر 1.0850',
      'decision': 'SHADOW',
      'reason': 'shadow mode',
    },
    {
      'ts': '12:07:01',
      'source': 'forex_snip',
      'text': 'weekly recap: +120 pips',
      'decision': 'SKIPPED',
      'reason': 'recap',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Feed'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Save as sample',
            onPressed: () {},
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _feed.length,
        itemBuilder: (c, i) {
          final item = _feed[i];
          final color = item['decision'] == 'EXECUTED'
              ? Colors.green
              : item['decision'] == 'SHADOW'
                  ? Colors.orange
                  : Colors.grey;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: color.withOpacity(0.2),
                child: Icon(Icons.swap_vert, color: color),
              ),
              title: Text(item['text'].toString()),
              subtitle: Text(
                '${item['ts']} · ${item['source']}',
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item['decision'].toString(),
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    item['reason'].toString(),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
