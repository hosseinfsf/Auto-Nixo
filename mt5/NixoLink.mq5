//+------------------------------------------------------------------+
//| NIXO LINK — MT5 EA (socket client, no DLL)                        |
//|                                                                  |
//| The engine is the socket SERVER on 127.0.0.1. This EA is the      |
//| socket CLIENT. Protocol: one message per line, KEY=VALUE pairs    |
//| separated by '|'. First message AUTH with a random token.         |
//| Heartbeat every 2 seconds both ways.                              |
//+------------------------------------------------------------------+
#property copyright "NIXO LITE"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>

//--- inputs
input string InpEngineHost   = "127.0.0.1";
input int    InpEnginePort   = 9123;
input string InpAuthToken    = "nixo-dev-token";
input int    InpHeartbeatSec = 2;
input int    InpReconnectSec = 5;
input int    InpMagicBase    = 700000;

//--- socket
int g_socket = INVALID_HANDLE;
bool g_authed = false;
ENUM_TIMEFRAMES g_tf = PERIOD_M1;

CTrade g_trade;
CSymbolInfo g_symbol;
CPositionInfo g_position;
COrderInfo g_order;

string g_recv_buf = "";

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicBase);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   EventSetTimer(1); // 1s timer drives reconnect + heartbeat
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SocketClose(g_socket);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!SocketIsConnected(g_socket))
      TryReconnect();
   else
   {
      ReceiveData();
      if(g_authed)
         SendHeartbeat();
   }
}

//+------------------------------------------------------------------+
void TryReconnect()
{
   if(g_socket != INVALID_HANDLE)
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
   }
   g_authed = false;

   g_socket = SocketCreate();
   if(g_socket == INVALID_HANDLE)
      return;

   if(!SocketConnect(g_socket, InpEngineHost, InpEnginePort, 3000))
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
      return;
   }

   // AUTH handshake
   string auth = StringFormat("CMD=AUTH|TOKEN=%s\n", InpAuthToken);
   SocketSend(g_socket, auth);
}

//+------------------------------------------------------------------+
void SendHeartbeat()
{
   SocketSend(g_socket, "CMD=HB\n");
}

//+------------------------------------------------------------------+
void ReceiveData()
{
   uchar buffer[];
   uint len = SocketIsReadable(g_socket);
   if(len == 0)
      return;
   if(!SocketReceive(g_socket, buffer, len))
      return;

   string data = CharArrayToString(buffer, 0, len);
   g_recv_buf += data;

   int pos;
   while((pos = StringFind(g_recv_buf, "\n")) >= 0)
   {
      string line = StringSubstr(g_recv_buf, 0, pos);
      g_recv_buf = StringSubstr(g_recv_buf, pos + 1);
      HandleLine(line);
   }
}

//+------------------------------------------------------------------+
void HandleLine(string line)
{
   line = StringTrimLeft(StringTrimRight(line));
   if(line == "")
      return;

   string fields[][2];
   string parts[];
   int n = StringSplit(line, '|', parts);
   for(int i = 0; i < n; i++)
   {
      string kv[];
      if(StringSplit(parts[i], '=', kv) == 2)
      {
         ArrayResize(fields, ArraySize(fields) + 1);
         fields[ArraySize(fields) - 1][0] = kv[0];
         fields[ArraySize(fields) - 1][1] = kv[1];
      }
   }

   string cmd = GetField(fields, "CMD");

   if(cmd == "AUTH_OK")
   {
      g_authed = true;
      SendAccountSnapshot();
      return;
   }
   if(cmd == "AUTH_FAIL")
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
      return;
   }
   if(cmd == "HB")
      return;

   if(!g_authed)
      return;

   string reqId = GetField(fields, "REQ_ID");

   if(cmd == "OPEN")       HandleOpen(fields, reqId);
   else if(cmd == "MODIFY") HandleModify(fields, reqId);
   else if(cmd == "CLOSE")  HandleClose(fields, reqId);
   else if(cmd == "CLOSE_ALL") HandleCloseAll(reqId);
   else if(cmd == "CANCEL")  HandleCancel(fields, reqId);
   else if(cmd == "GET_SYMBOLS") SendSymbols(reqId);
   else if(cmd == "GET_SYMBOL_INFO") SendSymbolInfo(fields, reqId);
   else if(cmd == "GET_ACCOUNT") SendAccountSnapshot(reqId);
   else if(cmd == "GET_POSITIONS") SendPositions(reqId);
   else if(cmd == "GET_RATES") SendRates(fields, reqId);
   else if(cmd == "GET_CALENDAR") SendCalendar(reqId);
}

//+------------------------------------------------------------------+
string GetField(string &fields[][2], string key)
{
   for(int i = 0; i < ArraySize(fields); i++)
      if(fields[i][0] == key)
         return(fields[i][1]);
   return("");
}

//+------------------------------------------------------------------+
void SendLine(string line)
{
   if(g_socket != INVALID_HANDLE && SocketIsConnected(g_socket))
      SocketSend(g_socket, line + "\n");
}

//+------------------------------------------------------------------+
void HandleOpen(string &fields[][2], string reqId)
{
   string symbol = GetField(fields, "SYMBOL");
   string side   = GetField(fields, "SIDE");
   string type   = GetField(fields, "TYPE");
   double lots   = StringToDouble(GetField(fields, "LOTS"));
   string entryS = GetField(fields, "ENTRY");
   string slS    = GetField(fields, "SL");
   string tpsS   = GetField(fields, "TPS");
   string magicS = GetField(fields, "MAGIC");
   string comment = GetField(fields, "COMMENT");
   string cid    = GetField(fields, "CLIENT_ORDER_ID");
   string devS   = GetField(fields, "DEVIATION");

   if(!SymbolSelect(symbol, true))
   {
      SendError(reqId, "symbol not found");
      return;
   }

   // Validate lot against broker min/max/step.
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(lots < minLot)
   {
      SendError(reqId, "below min lot");
      return;
   }
   if(lots > maxLot)
      lots = maxLot;
   if(step > 0)
      lots = MathFloor(lots / step) * step;

   double sl = slS == "" ? 0.0 : StringToDouble(slS);
   double entry = entryS == "" ? 0.0 : StringToDouble(entryS);

   // Parse TPs
   double tps[];
   if(tpsS != "")
   {
      string tpParts[];
      int tn = StringSplit(tpsS, ',', tpParts);
      ArrayResize(tps, tn);
      for(int i = 0; i < tn; i++)
         tps[i] = StringToDouble(tpParts[i]);
   }

   ENUM_ORDER_TYPE otype = ORDER_TYPE_BUY;
   if(type == "sell") otype = ORDER_TYPE_SELL;
   if(type == "limit")
      otype = (side == "buy") ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   else if(type == "stop")
      otype = (side == "buy") ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   else
      otype = (side == "buy") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   ulong magic = StringToInteger(magicS);
   if(magic == 0) magic = InpMagicBase;

   int deviation = (int)StringToInteger(devS);
   if(deviation <= 0) deviation = 10;

   bool ok = false;
   if(otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_SELL)
   {
      ok = g_trade.Buy(lots, symbol, 0.0, sl, tps[0], comment, magic, cid);
   }
   else
   {
      if(entry <= 0)
      {
         SendError(reqId, "missing entry for pending order");
         return;
      }
      ok = g_trade.Order(otype, lots, symbol, entry, sl, tps[0], 0, 0, comment, magic, cid);
   }

   if(ok)
   {
      string orderId = (string)g_trade.ResultOrder();
      SendLine(StringFormat("CMD=OK|REQ_ID=%s|ORDER_ID=%s", reqId, orderId));
      // Set up legs (TP ladder) if multiple TPs.
      if(ArraySize(tps) > 1)
         SetupLegs(symbol, orderId, lots, tps, side, magic, cid);
   }
   else
   {
      SendError(reqId, "order failed: " + (string)g_trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
void SetupLegs(string symbol, string orderId, double lots, double &tps[],
               string side, ulong magic, string cid)
{
   // For a market order already opened with TP1, add partial TPs via
   // position modification is not possible; instead we track legs in
   // global variables for the management logic. For simplicity, we send
   // an event back to the engine with the leg plan; actual partial
   // management is handled by the engine's position manager.
   SendLine(StringFormat("CMD=LEGS|ORDER_ID=%s|TPS=%s", orderId, ArrayToString(tps, ",")));
}

//+------------------------------------------------------------------+
void HandleModify(string &fields[][2], string reqId)
{
   string orderId = GetField(fields, "ORDER_ID");
   string slS = GetField(fields, "SL");
   string tpsS = GetField(fields, "TPS");
   double sl = slS == "" ? 0.0 : StringToDouble(slS);
   double tp = 0.0;
   if(tpsS != "")
   {
      string tpParts[];
      if(StringSplit(tpsS, ',', tpParts) > 0)
         tp = StringToDouble(tpParts[0]);
   }

   ulong ticket = StringToInteger(orderId);
   bool ok = g_trade.PositionModify(ticket, sl, tp);
   if(ok)
      SendLine(StringFormat("CMD=OK|REQ_ID=%s", reqId));
   else
      SendError(reqId, "modify failed: " + (string)g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void HandleClose(string &fields[][2], string reqId)
{
   string orderId = GetField(fields, "ORDER_ID");
   string lotsS = GetField(fields, "LOTS");
   ulong ticket = StringToInteger(orderId);
   double lots = lotsS == "" ? 0.0 : StringToDouble(lotsS);

   bool ok;
   if(lots > 0)
      ok = g_trade.PositionClosePartial(ticket, lots);
   else
      ok = g_trade.PositionClose(ticket);

   if(ok)
      SendLine(StringFormat("CMD=OK|REQ_ID=%s", reqId));
   else
      SendError(reqId, "close failed: " + (string)g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void HandleCloseAll(string reqId)
{
   int total = PositionsTotal();
   int closed = 0;
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(g_trade.PositionClose(ticket))
         closed++;
   }
   SendLine(StringFormat("CMD=OK|REQ_ID=%s|CLOSED=%d", reqId, closed));
}

//+------------------------------------------------------------------+
void HandleCancel(string &fields[][2], string reqId)
{
   string orderId = GetField(fields, "ORDER_ID");
   ulong ticket = StringToInteger(orderId);
   bool ok = g_trade.OrderDelete(ticket);
   if(ok)
      SendLine(StringFormat("CMD=OK|REQ_ID=%s", reqId));
   else
      SendError(reqId, "cancel failed: " + (string)g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void SendSymbols(string reqId)
{
   string list = "";
   for(int i = 0; i < SymbolsTotal(true); i++)
   {
      string s = SymbolName(i, true);
      if(list != "") list += ",";
      list += s;
   }
   SendLine(StringFormat("CMD=SYMBOLS|REQ_ID=%s|SYMBOLS=%s", reqId, list));
}

//+------------------------------------------------------------------+
void SendSymbolInfo(string &fields[][2], string reqId)
{
   string symbol = GetField(fields, "SYMBOL");
   if(!SymbolSelect(symbol, true))
   {
      SendError(reqId, "symbol not found");
      return;
   }
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   int spread = (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   int stopsLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   bool marketOpen = (bool)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_CLOSED;

   SendLine(StringFormat(
      "CMD=SYMBOL_INFO|REQ_ID=%s|SYMBOL=%s|BID=%.8f|ASK=%.8f|SPREAD=%d|POINT=%.8f|DIGITS=%d|TICK_SIZE=%.8f|STOPS_LEVEL=%d|MARKET_OPEN=%d",
      reqId, symbol, bid, ask, spread, point, digits, tickSize, stopsLevel, marketOpen ? 1 : 0));
}

//+------------------------------------------------------------------+
void SendAccountSnapshot(string reqId = "")
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   long leverage = AccountInfoInteger(ACCOUNT_LEVERAGE);

   string tradeMode = "demo";
   long tm = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tm == ACCOUNT_TRADE_MODE_REAL) tradeMode = "real";
   else if(tm == ACCOUNT_TRADE_MODE_CONTEST) tradeMode = "contest";

   string marginMode = "hedging";
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_NETTING)
      marginMode = "netting";

   string serverTime = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);

   SendLine(StringFormat(
      "CMD=ACCOUNT|REQ_ID=%s|BALANCE=%.2f|EQUITY=%.2f|MARGIN=%.2f|FREE_MARGIN=%.2f|CURRENCY=%s|LEVERAGE=%d|TRADE_MODE=%s|MARGIN_MODE=%s|SERVER_TIME=%s",
      reqId, balance, equity, margin, freeMargin, currency, leverage, tradeMode, marginMode, serverTime));
}

//+------------------------------------------------------------------+
void SendPositions(string reqId)
{
   string out = "";
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double profit = PositionGetDouble(POSITION_PROFIT);
      long magic = PositionGetInteger(POSITION_MAGIC);
      string type = (POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell";
      string entry = StringFormat("%s|%s|%.2f|%.5f|%.5f|%.5f|%.2f|%d", symbol, type, volume, priceOpen, sl, tp, profit, magic);
      if(out != "") out += ";";
      out += entry;
   }
   SendLine(StringFormat("CMD=POSITIONS|REQ_ID=%s|POSITIONS=%s", reqId, out));
}

//+------------------------------------------------------------------+
void SendRates(string &fields[][2], string reqId)
{
   string symbol = GetField(fields, "SYMBOL");
   int count = (int)StringToInteger(GetField(fields, "COUNT"));
   if(count <= 0) count = 100;
   if(!SymbolSelect(symbol, true))
   {
      SendError(reqId, "symbol not found");
      return;
   }
   MqlRates rates[];
   int got = CopyRates(symbol, g_tf, 0, count, rates);
   string out = "";
   for(int i = 0; i < got; i++)
   {
      if(out != "") out += ",";
      out += DoubleToString(rates[i].close, _Digits);
   }
   SendLine(StringFormat("CMD=RATES|REQ_ID=%s|RATES=%s", reqId, out));
}

//+------------------------------------------------------------------+
void SendCalendar(string reqId)
{
   // MQL5 economic calendar via the terminal's calendar is not directly
   // accessible in MQL5. We report an empty calendar; the engine can use
   // an external source. (Spike S2 verifies availability.)
   SendLine(StringFormat("CMD=CALENDAR|REQ_ID=%s|CALENDAR=", reqId));
}

//+------------------------------------------------------------------+
void SendError(string reqId, string msg)
{
   SendLine(StringFormat("CMD=ERROR|REQ_ID=%s|MSG=%s", reqId, msg));
}

//+------------------------------------------------------------------+
// OnTradeTransaction: report fills/rejections/closed positions to engine.
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(HistoryDealSelect(deal))
      {
         string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
         double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
         double price = HistoryDealGetDouble(deal, DEAL_PRICE);
         double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
         long type = HistoryDealGetInteger(deal, DEAL_TYPE);
         SendLine(StringFormat("CMD=FILL|SYMBOL=%s|VOLUME=%.2f|PRICE=%.5f|PROFIT=%.2f|TYPE=%d", symbol, volume, price, profit, type));

         if(profit != 0.0)
            SendLine(StringFormat("CMD=POSITION_CLOSED|SYMBOL=%s|PROFIT=%.2f", symbol, profit));
      }
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE || trans.type == TRADE_TRANSACTION_ORDER_CANCEL)
   {
      SendLine(StringFormat("CMD=REJECT|ORDER_ID=%d|RETCODE=%d", trans.order, result.retcode));
   }
}
//+------------------------------------------------------------------+
