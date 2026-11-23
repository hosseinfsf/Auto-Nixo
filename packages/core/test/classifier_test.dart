import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  final c = Classifier();

  group('classifier', () {
    test('detects English signal', () {
      final r = c.classify('BUY XAUUSD entry 4050 sl 4030 tp1 4080');
      expect(r.kind, SignalKind.signal);
    });

    test('detects Persian signal', () {
      final r = c.classify('خرید طلا حد ضرر 4030 حد سود 4080');
      expect(r.kind, SignalKind.signal);
    });

    test('detects management update', () {
      final r = c.classify('move sl to 4040');
      expect(r.kind, SignalKind.management);
      expect(r.action, ManagementAction.moveSl);
    });

    test('detects break-even', () {
      final r = c.classify('move to breakeven');
      expect(r.kind, SignalKind.management);
      expect(r.action, ManagementAction.breakEven);
    });

    test('detects recap', () {
      final r = c.classify('weekly recap: +120 pips closed with profit');
      expect(r.kind, SignalKind.recap);
    });

    test('noise for empty', () {
      final r = c.classify('');
      expect(r.kind, SignalKind.noise);
    });

    test('avoids false positive on "be"', () {
      final r = c.classify('this will be a nice day');
      expect(r.kind, SignalKind.noise);
    });
  });
}
