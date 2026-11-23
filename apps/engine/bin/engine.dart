#!/usr/bin/env dart
/// NIXO LITE engine entrypoint.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:nixo_core/nixo_core.dart';

import 'package:nixo_engine/src/config.dart';
import 'package:nixo_engine/src/db.dart';
import 'package:nixo_engine/src/http_api.dart';
import 'package:nixo_engine/src/input_registry.dart';
import 'package:nixo_engine/src/mt5/link_server.dart';
import 'package:nixo_engine/src/pipeline.dart';

import 'package:nixo_engine/src/telegram/telegram_source.dart';
import 'package:nixo_engine/src/watchdog.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c', defaultsTo: 'engine_config.json')
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('self-test', negatable: false);

  final results = parser.parse(args);
  if (results['help'] as bool) {
    print(parser.usage);
    return;
  }

  if (results['self-test'] as bool) {
    await _selfTest();
    return;
  }

  final config = EngineConfig.load(path: results['config'] as String);
  if (config.apiToken.length < 32 ||
      config.apiToken == 'nixo-dev-token' ||
      config.apiToken == 'CHANGE-ME') {
    stderr.writeln('[NIXO] Set api_token to a new random value of at least 32 characters in engine_config.json.');
    exitCode = 2;
    return;
  }
  await _run(config);
}

Future<void> _run(EngineConfig config) async {
  // Ensure data dir.
  Directory(config.dataDir).createSync(recursive: true);

  final db = Database.open(config.dbPath);
  // Dry Run remains on until explicitly disabled by the user.
  if (db.getSetting('mt5_dry_run') == null) {
    db.setSetting('mt5_dry_run', '1');
  }
  db.audit('info', 'engine starting');

  // MT5 link server.
  final link = Mt5LinkServer(
    host: config.mt5Host,
    port: config.mt5Port,
    token: config.apiToken,
  );
  await link.start();

  // Pipeline components.
  final classifier = Classifier();
  final parser = TextParser();
  final validator = SignalValidator();
  final sizer = Sizer();
  final slTp = SlTpResolver();
  final limits = LimitsManager();
  final perInputLimits = PerInputLimitsManager();
  final roulette = RouletteManager(
    config: RouletteConfig(),
    accountTrigger: AccountRouletteTrigger(
      baselineEquity:
          double.tryParse(db.getSetting('roulette_baseline_equity') ?? '') ?? 0,
      triggerPct: 3.0,
      activated: db.getSetting('roulette_account_activated') == '1',
    ),
    persist: (state) => db.upsertRouletteState({
      'source_id': state.sourceId,
      'model': state.model.name,
      'step': state.step,
      'max_step': state.maxStep,
      'activated': state.activated,
      'last_updated': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }),
  );

  // Restore persisted per-source roulette states (survive restart).
  for (final row in db.listRouletteStates()) {
    roulette.restore(row['source_id'] as String, RouletteState(
      sourceId: row['source_id'] as String,
      model: RouletteModel.values.firstWhere(
        (m) => m.name == row['model'],
        orElse: () => RouletteModel.volume,
      ),
      step: row['step'] as int,
      maxStep: row['max_step'] as int,
      activated: row['activated'] == 1,
    ));
  }

  // Reconcile open positions after restart (avoid duplicate execution).
  try {
    final openTickets = await link.reconcilePositions();
    db.audit('info', 'reconciled ${openTickets.length} open positions on startup');
    for (final ticket in openTickets) {
      db.audit('info', 'open position ticket=$ticket');
    }
  } catch (e) {
    db.audit('warn', 'position reconciliation failed: $e');
  }

  // Recover unfinished signals (signals without a decision).
  try {
    final unfinished = db.unfinishedSignals();
    if (unfinished.isNotEmpty) {
      db.audit('info', 'found ${unfinished.length} unfinished signals on startup');
    }
  } catch (e) {
    db.audit('warn', 'unfinished signal recovery failed: $e');
  }

  final pipeline = Pipeline(
    db: db,
    executor: link,
    classifier: classifier,
    parser: parser,
    validator: validator,
    sizer: sizer,
    slTp: slTp,
    limits: limits,
    perInputLimits: perInputLimits,
    roulette: roulette,
    config: PipelineConfig(validitySeconds: config.validitySeconds),
  );

  // Input registry.
  final registry = InputRegistry(db: db);

  // Telegram is managed by the separately started Python/Telethon Listener.
  // Do not create a second account session or auto-start TDLib here.
  // Listener queue delivery into Pipeline is implemented in a separate phase.
  final telegramSources = <TelegramSource>[];
  await registry.startAll();

  // Watchdog.
  final watchdog = Watchdog(link: link, telegramSources: telegramSources);
  watchdog.start();

  // HTTP API.
  final api = HttpApi(
    host: config.apiHost,
    port: config.apiPort,
    token: config.apiToken,
    db: db,
    pipeline: pipeline,
    webhookToken: 'nixo-webhook',
    webhookPassphrase: 'nixo-passphrase',
    webDir: 'web',
  );
  api.onKill = () {
    db.audit('warn', 'kill switch activated');
    registry.stopAll();
  };
  await api.start();

  print('[engine] NIXO LITE engine running on ${config.apiHost}:${config.apiPort}');
  print('[engine] MT5 link listening on ${config.mt5Host}:${config.mt5Port}');
  print('[engine] Press Ctrl+C to stop.');

  // Keep alive.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    db.audit('info', 'engine stopping');
    watchdog.stop();
    api.stop();
    link.stop();
    registry.stopAll();
    db.close();
    done.complete();
  });
  await done.future;
}

Future<void> _selfTest() async {
  print('[self-test] Running engine self-test...');
  final classifier = Classifier();
  final c1 = classifier.classify('BUY XAUUSD entry 4050 sl 4030 tp1 4080');
  print('classify signal: ${c1.kind}');
  final c2 = classifier.classify('move sl to 4040');
  print('classify management: ${c2.kind} ${c2.action}');
  final p = TextParser();
  final r = p.parse('BUY XAUUSD entry 4050 sl 4030 tp1 4080 tp2 4110');
  if (r.signal != null) {
    print('parse: ${r.signal!.symbol} ${r.signal!.side} entry=${r.signal!.entryLow} sl=${r.signal!.sl} tps=${r.signal!.tps}');
  } else {
    print('parse error: ${r.error}');
  }
  print('[self-test] done');
}
