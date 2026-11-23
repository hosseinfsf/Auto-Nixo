//+------------------------------------------------------------------+
//| NixoLink.mq5  -  NIXO LITE  v2.00                                 |
//|                                                                  |
//| Socket CLIENT (no DLL). The NIXO engine is the SERVER on          |
//| 127.0.0.1. Protocol: one message per line (LF), KEY=VALUE pairs  |
//| separated by '|'. Values are percent-encoded: % | = CR LF.       |
//|                                                                  |
//| SETUP (once):                                                     |
//|  1. Tools > Options > Expert Advisors: tick "Allow algorithmic    |
//|     trading" and add 127.0.0.1 to "Allow WebRequest for listed    |
//|     URL" (needed for socket connections).                         |
//|  2. Put the same long random token in the EA input InpAuthToken   |
//|     and in engine_config.json ("api_token").                      |
//|  3. Attach the EA to ANY one chart (symbol does not matter).      |
//|  4. REAL accounts are blocked unless InpAllowReal = true.         |
//+------------------------------------------------------------------+
#property copyright "NIXO LITE"
#property version   "2.00"
#property description "Executes orders for the NIXO engine over a localhost socket (no DLL)."

#include <Trade/Trade.mqh>

//--- inputs
input string InpEngineHost    = "127.0.0.1";
input int    InpEnginePort    = 9123;
input string InpAuthToken     = "";        // REQUIRED. Set the same new random token as engine_config.json.
input int    InpHeartbeatSec  = 2;         // heartbeat interval
input int    InpReconnectSec  = 2;         // delay between reconnect attempts
input int    InpRxTimeoutSec  = 6;         // no data from engine for this long => reconnect
input int    InpTimerMs       = 20;        // poll period (latency of commands)
input int    InpMagicBase     = 700000;    // used when the engine sends no magic
input bool   InpAllowReal     = false;    // explicit opt-in required for REAL accounts
input bool   InpCloseAllAll   = false;     // CLOSE_ALL scope: false = only NX-tagged trades
input double InpMarginUsePct  = 80.0;      // max share of free margin one order may use
input int    InpMaxTickAgeSec = 180;       // quote older than this => market treated as closed

//--- state
CTrade g_trade;
int    g_socket      = INVALID_HANDLE;
bool   g_authed      = false;
uchar  g_rx[];
ulong  g_nextTry     = 0;
ulong  g_lastRx      = 0;
ulong  g_lastHb      = 0;
ulong  g_connectedAt = 0;
ulong  g_lastErrLog  = 0;

//+------------------------------------------------------------------+
//| Percent-encoding (must match engine protocol.dart)                |
//+------------------------------------------------------------------+
string Enc(string s)
{
   StringReplace(s, "%",  "%25");
   StringReplace(s, "|",  "%7C");
   StringReplace(s, "=",  "%3D");
   StringReplace(s, "\r", "%0D");
   StringReplace(s, "\n", "%0A");
   return(s);
}

int HexVal(const ushort c)
{
   if(c >= '0' && c <= '9') return((int)(c - '0'));
   if(c >= 'A' && c <= 'F') return((int)(c - 'A') + 10);
   if(c >= 'a' && c <= 'f') return((int)(c - 'a') + 10);
   return(-1);
}

string Dec(const string s)
{
   if(StringFind(s, "%") < 0)
      return(s);
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == '%' && i + 2 < n)
      {
         int h = HexVal(StringGetCharacter(s, i + 1));
         int l = HexVal(StringGetCharacter(s, i + 2));
         if(h >= 0 && l >= 0)
         {
            out += ShortToString((ushort)(h * 16 + l));
            i += 2;
            continue;
         }
      }
      out += ShortToString(c);
   }
   return(out);
}

//+------------------------------------------------------------------+
//| Message containers                                                |
//+------------------------------------------------------------------+
class CMsg
{
public:
   string keys[];
   string vals[];
   int    n;
   CMsg() { n = 0; }
   void Add(const string k, const string v)
   {
      ArrayResize(keys, n + 1);
      ArrayResize(vals, n + 1);
      keys[n] = k;
      vals[n] = v;
      n++;
   }
   string Get(const string k)
   {
      for(int i = 0; i < n; i++)
         if(keys[i] == k)
            return(vals[i]);
      return("");
   }
};

class CLine
{
public:
   string s;
   void Add(const string k, const string v)
   {
      if(s != "") s += "|";
      s += k + "=" + Enc(v);
   }
   void AddD(const string k, const double v, const int digits)
   {
      Add(k, DoubleToString(v, digits));
   }
   void AddI(const string k, const long v)
   {
      Add(k, IntegerToString(v));
   }
};

//+------------------------------------------------------------------+
//| Socket I/O                                                        |
//+------------------------------------------------------------------+
void Disconnect(const string why)
{
   if(g_socket != INVALID_HANDLE)
      SocketClose(g_socket);
   g_socket = INVALID_HANDLE;
   g_authed = false;
   ArrayResize(g_rx, 0);
   g_nextTry = GetTickCount64() + (ulong)InpReconnectSec * 1000;
   if(why != "")
      Print("NixoLink: disconnected - ", why);
}

bool SendRaw(const string s)
{
   if(g_socket == INVALID_HANDLE)
      return(false);
   uchar buf[];
   int n = StringToCharArray(s, buf, 0, WHOLE_ARRAY, CP_UTF8);
   if(n <= 0)
      return(false);
   if(buf[n - 1] == 0)
      n--;                       // never send the NUL terminator
   int sent = 0;
   int tries = 0;
   while(sent < n && tries < 100)
   {
      int rem = n - sent;
      uchar part[];
      ArrayResize(part, rem);
      ArrayCopy(part, buf, 0, sent, rem);
      int r = SocketSend(g_socket, part, (uint)rem);
      if(r < 0)
      {
         Disconnect("send error " + IntegerToString(GetLastError()));
         return(false);
      }
      sent += r;
      tries++;
      if(r == 0)
         Sleep(1);
   }
   return(sent == n);
}

void SendLine(const string line)
{
   SendRaw(line + "\n");
}

string Head(const string cmd, const string req)
{
   CLine h;
   h.Add("CMD", cmd);
   if(req != "")
      h.Add("REQ_ID", req);
   return(h.s);
}

void SendErr(const string req, const string msg, const int retcode = 0)
{
   CLine l;
   l.s = Head("ERROR", req);
   l.Add("MSG", msg);
   if(retcode != 0)
      l.AddI("RETCODE", retcode);
   SendLine(l.s);
}

void TryConnect()
{
   if(GetTickCount64() < g_nextTry)
      return;
   g_socket = SocketCreate();
   if(g_socket == INVALID_HANDLE)
   {
      g_nextTry = GetTickCount64() + (ulong)InpReconnectSec * 1000;
      return;
   }
   if(!SocketConnect(g_socket, InpEngineHost, (uint)InpEnginePort, 250))
   {
      int err = GetLastError();
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
      g_nextTry = GetTickCount64() + (ulong)InpReconnectSec * 1000;
      if(GetTickCount64() - g_lastErrLog > 30000)
      {
         g_lastErrLog = GetTickCount64();
         Print("NixoLink: cannot connect to ", InpEngineHost, ":", InpEnginePort,
               " err=", err, " (engine not running? 127.0.0.1 allowed in Options>Expert Advisors?)");
      }
      return;
   }
   g_authed = false;
   ArrayResize(g_rx, 0);
   g_lastRx = GetTickCount64();
   g_connectedAt = g_lastRx;
   g_lastHb = g_lastRx;
   CLine a;
   a.Add("CMD", "AUTH");
   a.Add("TOKEN", InpAuthToken);
   SendLine(a.s);
}

// Returns false if the connection was dropped while reading.
bool ReadSocket()
{
   int guard = 0;
   uint avail = SocketIsReadable(g_socket);
   while(avail > 0 && guard < 50)
   {
      uchar tmp[];
      int got = SocketRead(g_socket, tmp, avail, 10);
      if(got < 0)
      {
         Disconnect("read error " + IntegerToString(GetLastError()));
         return(false);
      }
      if(got == 0)
         break;
      int old = ArraySize(g_rx);
      ArrayResize(g_rx, old + got);
      ArrayCopy(g_rx, tmp, old, 0, got);
      g_lastRx = GetTickCount64();
      avail = SocketIsReadable(g_socket);
      guard++;
   }
   if(ArraySize(g_rx) > 1048576)
   {
      Disconnect("rx buffer overflow");
      return(false);
   }

   int start = 0;
   int n = ArraySize(g_rx);
   for(int i = 0; i < n; i++)
   {
      if(g_rx[i] != 10)
         continue;
      int len = i - start;
      if(len > 0)
      {
         uchar lb[];
         ArrayResize(lb, len);
         ArrayCopy(lb, g_rx, 0, start, len);
         string line = CharArrayToString(lb, 0, len, CP_UTF8);
         HandleLine(line);
         if(g_socket == INVALID_HANDLE)
            return(false);      // dropped while handling; buffer already reset
      }
      start = i + 1;
   }
   if(start > 0)
   {
      int rem = n - start;
      if(rem > 0)
      {
         uchar r[];
         ArrayResize(r, rem);
         ArrayCopy(r, g_rx, 0, start, rem);
         ArrayResize(g_rx, rem);
         ArrayCopy(g_rx, r, 0, 0, rem);
      }
      else
         ArrayResize(g_rx, 0);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
int VolDigits(const double step)
{
   int d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-10)
   {
      s *= 10.0;
      d++;
   }
   return(d);
}

double FloorToStep(const double v, const double step)
{
   if(step <= 0.0)
      return(v);
   return(NormalizeDouble(MathFloor(v / step + 1e-9) * step, VolDigits(step)));
}

int ParseList(const string s, double &out[])
{
   ArrayResize(out, 0);
   if(s == "")
      return(0);
   string parts[];
   int n = StringSplit(s, ',', parts);
   for(int i = 0; i < n; i++)
   {
      double v = StringToDouble(parts[i]);
      if(v > 0.0)
      {
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = v;
      }
   }
   return(ArraySize(out));
}

bool IsMarketOpen(const string symbol)
{
   long mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return(false);

   datetime srv = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(srv, dt);
   long nowSec = (long)dt.hour * 3600 + (long)dt.min * 60 + (long)dt.sec;
   bool any = false;
   bool inside = false;
   datetime from, to;
   for(uint i = 0; i < 20; i++)
   {
      if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to))
         break;
      any = true;
      if(nowSec >= (long)from && nowSec < (long)to)
      {
         inside = true;
         break;
      }
   }
   if(any && !inside)
      return(false);

   long last = SymbolInfoInteger(symbol, SYMBOL_TIME);
   if(last > 0 && InpMaxTickAgeSec > 0 && ((long)srv - last) > InpMaxTickAgeSec)
      return(false);
   return(true);
}

bool IsNetting()
{
   return(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_NETTING);
}

bool TradingAllowed(string &reason)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      reason = "algo_trading_disabled";
      return(false);
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      reason = "account_trade_not_allowed";
      return(false);
   }
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !InpAllowReal)
   {
      reason = "real_account_blocked";
      return(false);
   }
   return(true);
}

void PrepTrade(const string symbol, const ulong magic, const int deviation, string filling = "")
{
   g_trade.SetExpertMagicNumber(magic > 0 ? magic : (ulong)InpMagicBase);
   g_trade.SetDeviationInPoints(deviation > 0 ? deviation : 20);
   // Default: the filling mode the broker supports for THIS symbol (not the chart symbol).
   g_trade.SetTypeFillingBySymbol(symbol);
   // Honour the engine request only when the symbol supports it.
   StringToLower(filling);
   long flags = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if(filling == "fok" && (flags & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if(filling == "ioc" && (flags & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
}

//--- idempotency: remember client order id -> first ticket (survives EA restart)
string CidKey(const string cid)
{
   uint h = 5381;
   int n = StringLen(cid);
   for(int i = 0; i < n; i++)
      h = h * 33 + (uint)StringGetCharacter(cid, i);
   return("NX_" + IntegerToString((long)h));
}

double FindCid(const string cid)
{
   string k = CidKey(cid);
   if(GlobalVariableCheck(k))
      return(GlobalVariableGet(k));     // >0=ticket, <0=reserved/pending, 0=free
   return(0.0);
}

// Reserve the deterministic client id BEFORE the first broker-side effect.
// If the terminal/EA crashes after this point, a retry is blocked rather than
// risking a second order. An unresolved negative marker requires reconciliation.
bool ReserveCid(const string cid)
{
   if(cid == "")
      return(true);
   string k = CidKey(cid);
   if(!GlobalVariableCheck(k))
   {
      if(GlobalVariableSet(k, 0.0) == 0)
         return(false);
   }
   if(!GlobalVariableSetOnCondition(k, -1.0, 0.0))
      return(false);
   GlobalVariablesFlush();
   return(true);
}

void RememberCid(const string cid, const ulong ticket)
{
   if(GlobalVariableSet(CidKey(cid), (double)ticket) != 0)
      GlobalVariablesFlush();
}

//+------------------------------------------------------------------+
//| Command handlers                                                  |
//+------------------------------------------------------------------+
void HandleOpen(CMsg &m, const string req)
{
   string symbol  = m.Get("SYMBOL");
   string side    = m.Get("SIDE");
   string otype   = m.Get("TYPE");
   StringToLower(side);
   StringToLower(otype);
   double lots    = StringToDouble(m.Get("LOTS"));
   double entry   = StringToDouble(m.Get("ENTRY"));
   double sl      = StringToDouble(m.Get("SL"));
   string cid     = m.Get("CLIENT_ORDER_ID");
   string comment = m.Get("COMMENT");
   ulong  magic   = (ulong)StringToInteger(m.Get("MAGIC"));
   int    dev     = (int)StringToInteger(m.Get("DEVIATION"));

   // Positive value = existing ticket. Negative = reserved but unresolved.
   if(cid != "")
   {
      double prev = FindCid(cid);
      if(prev > 0.0)
      {
         CLine d;
         d.s = Head("OK", req);
         d.AddI("ORDER_ID", (long)prev);
         d.Add("DUPLICATE", "1");
         SendLine(d.s);
         return;
      }
      if(prev < 0.0)
      {
         SendErr(req, "client_order_id_pending");
         return;
      }
   }

   string why = "";
   if(!TradingAllowed(why))
   {
      SendErr(req, why);
      return;
   }
   if(side != "buy" && side != "sell")
   {
      SendErr(req, "bad_side");
      return;
   }
   if(symbol == "" || !SymbolSelect(symbol, true))
   {
      SendErr(req, "symbol_not_found");
      return;
   }



   if(!IsMarketOpen(symbol))
   {
      SendErr(req, "market_closed");
      return;
   }
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      SendErr(req, "no_quote");
      return;
   }

   double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   int    vd      = VolDigits(step);

   if(lots <= 0.0)
   {
      SendErr(req, "bad_lots");
      return;
   }
   lots = FloorToStep(lots, step);
   if(lots < minLot - 1e-12)
   {
      SendErr(req, "below_min_lot");        // never raised to the minimum
      return;
   }
   if(lots > maxLot + 1e-12)
   {
      SendErr(req, "above_max_lot");
      return;
   }
   if(sl <= 0.0)
   {
      SendErr(req, "missing_sl");           // SL on every order
      return;
   }

   double tps[];
   ParseList(m.Get("TPS"), tps);
   if(ArraySize(tps) != 1)
   {
      SendErr(req, "exactly_one_tp_required");
      return;
   }

   bool isBuy   = (side == "buy");
   bool market  = (otype == "market" || otype == "");
   if(!market && entry <= 0.0)
   {
      SendErr(req, "missing_entry");
      return;
   }
   double ref = market ? (isBuy ? tick.ask : tick.bid) : entry;

   // Order type for pending orders (limit vs stop decided from the live quote).
   ENUM_ORDER_TYPE ordType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!market)
   {
      if(isBuy)
         ordType = (entry < tick.ask) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
      else
         ordType = (entry > tick.bid) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;
   }

   double minDist = (double)MathMax(SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                    SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * point;
   if(!market)
   {
      double mkt = isBuy ? tick.ask : tick.bid;
      if(MathAbs(entry - mkt) < minDist)
      {
         SendErr(req, "pending_too_close");
         return;
      }
   }

   // Geometry and broker distance checks.
   if((isBuy && sl >= ref) || (!isBuy && sl <= ref))
   {
      SendErr(req, "bad_sl_geometry");
      return;
   }
   double riskDistance = MathAbs(ref - sl);
   double rewardDistance = MathAbs(tps[0] - ref);
   if(MathAbs(rewardDistance - 3.0 * riskDistance) > MathMax(point * 1.1, riskDistance * 0.000001))
   {
      SendErr(req, "tp_must_be_exactly_3r");
      return;
   }
   if(MathAbs(ref - sl) < minDist)
   {
      SendErr(req, "sl_too_close");
      return;
   }
   for(int t = 0; t < ArraySize(tps); t++)
   {
      if((isBuy && tps[t] <= ref) || (!isBuy && tps[t] >= ref))
      {
         SendErr(req, "bad_tp_geometry");
         return;
      }
      if(MathAbs(tps[t] - ref) < minDist)
      {
         SendErr(req, "tp_too_close");
         return;
      }
   }

   // Margin check.
   double margin = 0.0;
   ENUM_ORDER_TYPE mt = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(mt, symbol, lots, ref, margin))
   {
      SendErr(req, "margin_calc_failed");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * InpMarginUsePct / 100.0)
   {
      SendErr(req, "insufficient_margin");
      return;
   }

   // Exactly one position and one TP per Nixo order.
   int legs = 1;
   while(legs > 1 && FloorToStep(lots / legs, step) < minLot - 1e-12)
      legs--;
   double per = FloorToStep(lots / legs, step);
   double legLots[];
   ArrayResize(legLots, legs);
   for(int i = 0; i < legs; i++)
      legLots[i] = per;
   double rest = NormalizeDouble(lots - per * legs, vd);
   if(rest > 0.0)
      legLots[legs - 1] = NormalizeDouble(legLots[legs - 1] + rest, vd);

   PrepTrade(symbol, magic, dev, m.Get("FILLING"));

   // Reserve before the first CTrade call; a crash leaves a safe pending marker.
   if(cid != "" && !ReserveCid(cid))
   {
      SendErr(req, "client_order_id_pending");
      return;
   }

   string tickets = "";
   ulong  firstTicket = 0;
   double firstPrice = 0.0;
   int    okCount = 0;
   double okLots = 0.0;
   for(int i = 0; i < legs; i++)
   {
      double tp = (ArraySize(tps) > 0) ? tps[i] : 0.0;
      string c = comment;
      if(StringLen(c) > 24)
         c = StringSubstr(c, 0, 24);
      c += "#" + IntegerToString(i + 1);

      bool ok = false;
      if(market)
      {
         if(isBuy)
            ok = g_trade.Buy(legLots[i], symbol, 0.0, sl, tp, c);
         else
            ok = g_trade.Sell(legLots[i], symbol, 0.0, sl, tp, c);
      }
      else if(ordType == ORDER_TYPE_BUY_LIMIT)
         ok = g_trade.BuyLimit(legLots[i], entry, symbol, sl, tp, ORDER_TIME_GTC, 0, c);
      else if(ordType == ORDER_TYPE_BUY_STOP)
         ok = g_trade.BuyStop(legLots[i], entry, symbol, sl, tp, ORDER_TIME_GTC, 0, c);
      else if(ordType == ORDER_TYPE_SELL_LIMIT)
         ok = g_trade.SellLimit(legLots[i], entry, symbol, sl, tp, ORDER_TIME_GTC, 0, c);
      else
         ok = g_trade.SellStop(legLots[i], entry, symbol, sl, tp, ORDER_TIME_GTC, 0, c);

      if(ok)
      {
         ulong tk = g_trade.ResultOrder();
         if(okCount == 0)
         {
            firstTicket = tk;
            firstPrice = g_trade.ResultPrice();
            if(cid != "")
               RememberCid(cid, tk);       // remember immediately after the first leg
         }
         tickets += (tickets == "" ? "" : ",") + IntegerToString((long)tk);
         okCount++;
         okLots += legLots[i];
      }
      else if(i == 0)
      {
         SendErr(req, "order_failed", (int)g_trade.ResultRetcode());
         return;
      }
      else
         Print("NixoLink: leg ", i + 1, " failed retcode=", g_trade.ResultRetcode());
   }

   CLine r;
   r.s = Head("OK", req);
   r.AddI("ORDER_ID", (long)firstTicket);
   r.Add("ORDER_IDS", tickets);
   r.AddI("LEGS_OK", okCount);
   r.AddI("LEGS_TOTAL", legs);
   r.AddD("LOTS", okLots, vd);
   r.AddD("PRICE", firstPrice, digits);
   if(okCount < legs)
      r.Add("PARTIAL", "1");
   SendLine(r.s);
}

void HandleModify(CMsg &m, const string req)
{
   ulong  ticket = (ulong)StringToInteger(m.Get("ORDER_ID"));
   string slS = m.Get("SL");
   double sl = (slS == "") ? 0.0 : StringToDouble(slS);
   double tps[];
   ParseList(m.Get("TPS"), tps);
   double tp = (ArraySize(tps) > 0) ? tps[0] : 0.0;

   bool ok = false;
   if(PositionSelectByTicket(ticket))
   {
      string symbol = PositionGetString(POSITION_SYMBOL);
      PrepTrade(symbol, (ulong)PositionGetInteger(POSITION_MAGIC), 20);
      if(sl <= 0.0) sl = PositionGetDouble(POSITION_SL);
      if(tp <= 0.0) tp = PositionGetDouble(POSITION_TP);
      ok = g_trade.PositionModify(ticket, sl, tp);
   }
   else if(OrderSelect(ticket))
   {
      string symbol = OrderGetString(ORDER_SYMBOL);
      PrepTrade(symbol, (ulong)OrderGetInteger(ORDER_MAGIC), 20);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      if(sl <= 0.0) sl = OrderGetDouble(ORDER_SL);
      if(tp <= 0.0) tp = OrderGetDouble(ORDER_TP);
      ok = g_trade.OrderModify(ticket, price, sl, tp, ORDER_TIME_GTC, 0);
   }
   else
   {
      SendErr(req, "not_found");
      return;
   }
   if(ok)
      SendLine(Head("OK", req));
   else
      SendErr(req, "modify_failed", (int)g_trade.ResultRetcode());
}

void HandleClose(CMsg &m, const string req)
{
   ulong  ticket = (ulong)StringToInteger(m.Get("ORDER_ID"));
   string lotsS = m.Get("LOTS");
   if(!PositionSelectByTicket(ticket))
   {
      SendErr(req, "not_found");
      return;
   }
   string symbol = PositionGetString(POSITION_SYMBOL);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   PrepTrade(symbol, (ulong)PositionGetInteger(POSITION_MAGIC), 20);

   double lots = (lotsS == "") ? 0.0 : FloorToStep(StringToDouble(lotsS), step);
   bool ok;
   if(lots > 0.0 && lots < vol - 1e-12)
      ok = g_trade.PositionClosePartial(ticket, lots);
   else
      ok = g_trade.PositionClose(ticket);
   if(ok)
      SendLine(Head("OK", req));
   else
      SendErr(req, "close_failed", (int)g_trade.ResultRetcode());
}

void HandleCancel(CMsg &m, const string req)
{
   ulong ticket = (ulong)StringToInteger(m.Get("ORDER_ID"));
   if(!OrderSelect(ticket))
   {
      SendErr(req, "not_found");
      return;
   }
   if(g_trade.OrderDelete(ticket))
      SendLine(Head("OK", req));
   else
      SendErr(req, "cancel_failed", (int)g_trade.ResultRetcode());
}

void HandleCloseAll(const string req)
{
   int closedPos = 0;
   int removed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!InpCloseAllAll && StringFind(PositionGetString(POSITION_COMMENT), "NX") != 0)
         continue;
      PrepTrade(PositionGetString(POSITION_SYMBOL), (ulong)PositionGetInteger(POSITION_MAGIC), 50);
      if(g_trade.PositionClose(t))
         closedPos++;
   }
   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      ulong t = OrderGetTicket(j);
      if(t == 0) continue;
      if(!InpCloseAllAll && StringFind(OrderGetString(ORDER_COMMENT), "NX") != 0)
         continue;
      if(g_trade.OrderDelete(t))
         removed++;
   }
   CLine l;
   l.s = Head("OK", req);
   l.AddI("CLOSED", closedPos);
   l.AddI("REMOVED", removed);
   SendLine(l.s);
}

void SendSymbols(const string req)
{
   string list = "";
   int total = SymbolsTotal(true);
   for(int i = 0; i < total; i++)
   {
      if(list != "") list += ",";
      list += SymbolName(i, true);
   }
   CLine l;
   l.s = Head("SYMBOLS", req);
   l.Add("SYMBOLS", list);
   SendLine(l.s);
}

void SendSymbolInfo(CMsg &m, const string req)
{
   string symbol = m.Get("SYMBOL");
   MqlTick tick;
   if(symbol == "" || !SymbolSelect(symbol, true) || !SymbolInfoTick(symbol, tick))
   {
      SendErr(req, "symbol_not_found");
      return;
   }
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   int    spread = (point > 0.0) ? (int)MathRound((tick.ask - tick.bid) / point) : 0;
   long   last   = SymbolInfoInteger(symbol, SYMBOL_TIME);

   CLine l;
   l.s = Head("SYMBOL_INFO", req);
   l.Add("SYMBOL", symbol);
   l.AddD("BID", tick.bid, digits);
   l.AddD("ASK", tick.ask, digits);
   l.AddI("SPREAD", spread);
   l.AddD("POINT", point, 10);
   l.AddI("DIGITS", digits);
   l.AddD("TICK_SIZE", SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE), 10);
   l.AddD("TICK_VALUE", SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE), 10);
   l.AddD("CONTRACT", SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE), 4);
   l.AddI("STOPS_LEVEL", SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL));
   l.AddI("FREEZE_LEVEL", SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   l.AddD("VOL_MIN", SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN), 8);
   l.AddD("VOL_MAX", SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), 8);
   l.AddD("VOL_STEP", SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP), 8);
   l.AddI("MARKET_OPEN", IsMarketOpen(symbol) ? 1 : 0);
   l.AddI("TICK_AGE", (last > 0) ? ((long)TimeTradeServer() - last) : -1);
   SendLine(l.s);
}

void SendAccountSnapshot(const string req = "")
{
   string tradeMode = "demo";
   long tm = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tm == ACCOUNT_TRADE_MODE_REAL)         tradeMode = "real";
   else if(tm == ACCOUNT_TRADE_MODE_CONTEST) tradeMode = "contest";

   CLine l;
   l.s = Head("ACCOUNT", req);
   l.AddD("BALANCE", AccountInfoDouble(ACCOUNT_BALANCE), 2);
   l.AddD("EQUITY", AccountInfoDouble(ACCOUNT_EQUITY), 2);
   l.AddD("MARGIN", AccountInfoDouble(ACCOUNT_MARGIN), 2);
   l.AddD("FREE_MARGIN", AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2);
   l.Add("CURRENCY", AccountInfoString(ACCOUNT_CURRENCY));
   l.AddI("LEVERAGE", AccountInfoInteger(ACCOUNT_LEVERAGE));
   l.Add("TRADE_MODE", tradeMode);
   l.Add("MARGIN_MODE", IsNetting() ? "netting" : "hedging");
   l.AddI("LOGIN", AccountInfoInteger(ACCOUNT_LOGIN));
   l.AddI("SERVER_TIME", (long)TimeTradeServer());
   l.AddI("GMT_TIME", (long)TimeGMT());
   l.AddI("ALGO_TRADING", (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED)) ? 1 : 0);
   l.AddI("REAL_ALLOWED", InpAllowReal ? 1 : 0);
   SendLine(l.s);
}

void SendPositions(const string req)
{
   string out = "";
   string tickets = "";
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      string e = IntegerToString((long)t) + "," + symbol + "," +
                 ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell") + "," +
                 DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "," +
                 DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits) + "," +
                 DoubleToString(PositionGetDouble(POSITION_SL), digits) + "," +
                 DoubleToString(PositionGetDouble(POSITION_TP), digits) + "," +
                 DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "," +
                 IntegerToString(PositionGetInteger(POSITION_MAGIC));
      out += (out == "" ? "" : ";") + e;
      if(StringFind(PositionGetString(POSITION_COMMENT), "NX") == 0)      // positions opened by NIXO
         tickets += (tickets == "" ? "" : ",") + IntegerToString((long)t);
   }
   string orders = "";
   for(int j = 0; j < OrdersTotal(); j++)
   {
      ulong ot = OrderGetTicket(j);
      if(ot == 0) continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), "NX") == 0)
         orders += (orders == "" ? "" : ",") + IntegerToString((long)ot);
   }
   CLine l;
   l.s = Head("POSITIONS", req);
   l.Add("POSITIONS", out);
   l.Add("TICKETS", tickets);
   l.Add("ORDERS", orders);
   SendLine(l.s);
}

ENUM_TIMEFRAMES TfFromString(string tf)
{
   StringToUpper(tf);
   if(tf == "M5")  return(PERIOD_M5);
   if(tf == "M15") return(PERIOD_M15);
   if(tf == "H1")  return(PERIOD_H1);
   return(PERIOD_M1);
}

// GET_RATES: close prices only (kept for compatibility).
void SendRates(CMsg &m, const string req)
{
   string symbol = m.Get("SYMBOL");
   int count = (int)StringToInteger(m.Get("COUNT"));
   if(count <= 0 || count > 5000) count = 100;
   if(symbol == "" || !SymbolSelect(symbol, true))
   {
      SendErr(req, "symbol_not_found");
      return;
   }
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   MqlRates rates[];
   int got = CopyRates(symbol, TfFromString(m.Get("TF")), 0, count, rates);
   string out = "";
   for(int i = 0; i < got; i++)
      out += (out == "" ? "" : ",") + DoubleToString(rates[i].close, digits);
   CLine l;
   l.s = Head("RATES", req);
   l.Add("RATES", out);
   SendLine(l.s);
}

// GET_BARS: time:open:high:low:close per bar, separated by ',' (for the outcome tracker).
void SendBars(CMsg &m, const string req)
{
   string symbol = m.Get("SYMBOL");
   int count = (int)StringToInteger(m.Get("COUNT"));
   if(count <= 0 || count > 5000) count = 100;
   if(symbol == "" || !SymbolSelect(symbol, true))
   {
      SendErr(req, "symbol_not_found");
      return;
   }
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   MqlRates rates[];
   int got = CopyRates(symbol, TfFromString(m.Get("TF")), 0, count, rates);
   string out = "";
   for(int i = 0; i < got; i++)
   {
      string b = IntegerToString((long)rates[i].time) + ":" +
                 DoubleToString(rates[i].open, digits) + ":" +
                 DoubleToString(rates[i].high, digits) + ":" +
                 DoubleToString(rates[i].low, digits) + ":" +
                 DoubleToString(rates[i].close, digits);
      out += (out == "" ? "" : ",") + b;
   }
   CLine l;
   l.s = Head("BARS", req);
   l.Add("BARS", out);
   SendLine(l.s);
}

void SendCalendar(const string req)
{
   // Calendar support is checked in spike S2; empty for now.
   CLine l;
   l.s = Head("CALENDAR", req);
   l.Add("CALENDAR", "");
   SendLine(l.s);
}

// GET_RISK_PER_LOT: monetary risk of 1.0 lot between ENTRY and SL (authoritative).
void HandleRiskPerLot(CMsg &m, const string req)
{
   string symbol = m.Get("SYMBOL");
   string side   = m.Get("SIDE");
   StringToLower(side);
   double entry  = StringToDouble(m.Get("ENTRY"));
   double sl     = StringToDouble(m.Get("SL"));
   if(symbol == "" || !SymbolSelect(symbol, true))
   {
      SendErr(req, "symbol_not_found");
      return;
   }
   if(entry <= 0.0 || sl <= 0.0)
   {
      SendErr(req, "invalid_entry_sl");
      return;
   }
   ENUM_ORDER_TYPE ot = (side == "sell") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double profit = 0.0;
   if(!OrderCalcProfit(ot, symbol, 1.0, entry, sl, profit))
   {
      SendErr(req, "order_calc_profit_failed", GetLastError());
      return;
   }
   double risk = MathAbs(profit);
   if(risk <= 0.0)
   {
      SendErr(req, "risk_per_lot_zero");
      return;
   }
   CLine l;
   l.s = Head("OK", req);
   l.AddD("RISK_PER_LOT", risk, 8);
   SendLine(l.s);
}

//+------------------------------------------------------------------+
//| Line dispatcher                                                   |
//+------------------------------------------------------------------+
void HandleLine(string line)
{
   StringTrimLeft(line);
   StringTrimRight(line);
   if(line == "")
      return;

   CMsg m;
   string parts[];
   int n = StringSplit(line, '|', parts);
   for(int i = 0; i < n; i++)
   {
      int p = StringFind(parts[i], "=");
      if(p > 0)
         m.Add(StringSubstr(parts[i], 0, p), Dec(StringSubstr(parts[i], p + 1)));
   }

   string cmd = m.Get("CMD");
   string req = m.Get("REQ_ID");

   if(cmd == "AUTH_OK")
   {
      g_authed = true;
      Print("NixoLink: authenticated with engine");
      SendAccountSnapshot();
      return;
   }
   if(cmd == "AUTH_FAIL")
   {
      Print("NixoLink: AUTH_FAIL - InpAuthToken does not match engine api_token");
      Disconnect("auth failed");
      g_nextTry = GetTickCount64() + 10000;
      return;
   }
   if(cmd == "HB")
      return;
   if(!g_authed)
      return;

   if(cmd == "OPEN")                  HandleOpen(m, req);
   else if(cmd == "MODIFY")           HandleModify(m, req);
   else if(cmd == "CLOSE")            HandleClose(m, req);
   else if(cmd == "CLOSE_ALL")        HandleCloseAll(req);
   else if(cmd == "CANCEL")           HandleCancel(m, req);
   else if(cmd == "GET_SYMBOLS")      SendSymbols(req);
   else if(cmd == "GET_SYMBOL_INFO")  SendSymbolInfo(m, req);
   else if(cmd == "GET_ACCOUNT")      SendAccountSnapshot(req);
   else if(cmd == "GET_POSITIONS")    SendPositions(req);
   else if(cmd == "GET_RATES")        SendRates(m, req);
   else if(cmd == "GET_BARS")         SendBars(m, req);
   else if(cmd == "GET_CALENDAR")     SendCalendar(req);
   else if(cmd == "GET_RISK_PER_LOT") HandleRiskPerLot(m, req);
   else if(req != "")                 SendErr(req, "unknown_command");
}

//+------------------------------------------------------------------+
//| Events                                                            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!g_authed)
      return;

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(!HistoryDealSelect(trans.deal))
         return;
      long dtype = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL)
         return;                                   // balance/credit etc.
      ulong  magic   = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      string comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
      if(magic == 0 && StringFind(comment, "NX") != 0)
         return;                                   // manual trades are not ours

      string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      double swap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
      double comm   = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      long   posId  = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      bool   closing = (entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY ||
                        entryType == DEAL_ENTRY_INOUT);

      CLine f;
      f.Add("CMD", "FILL");
      f.AddI("TICKET", posId);
      f.AddI("ORDER", HistoryDealGetInteger(trans.deal, DEAL_ORDER));
      f.Add("SYMBOL", symbol);
      f.Add("TYPE", dtype == DEAL_TYPE_BUY ? "buy" : "sell");
      f.Add("ENTRY", closing ? "out" : "in");
      f.AddD("VOLUME", HistoryDealGetDouble(trans.deal, DEAL_VOLUME), 2);
      f.AddD("PRICE", HistoryDealGetDouble(trans.deal, DEAL_PRICE), digits);
      f.AddD("PROFIT", profit, 2);
      f.AddD("SWAP", swap, 2);
      f.AddD("COMMISSION", comm, 2);
      f.AddI("MAGIC", (long)magic);
      f.Add("COMMENT", comment);
      f.AddI("TIME", HistoryDealGetInteger(trans.deal, DEAL_TIME));
      SendLine(f.s);

      if(closing)
      {
         CLine c;
         c.Add("CMD", "POSITION_CLOSED");
         c.AddI("TICKET", posId);
         c.Add("SYMBOL", symbol);
         c.AddD("PROFIT", profit + swap + comm, 2);
         c.AddI("MAGIC", (long)magic);
         c.Add("COMMENT", comment);
         c.AddI("TIME", HistoryDealGetInteger(trans.deal, DEAL_TIME));
         SendLine(c.s);
      }
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      CLine d;
      d.Add("CMD", "ORDER_REMOVED");
      d.AddI("ORDER_ID", (long)trans.order);
      SendLine(d.s);
   }
}

//+------------------------------------------------------------------+
//| Lifecycle                                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpAuthToken == "" || InpAuthToken == "nixo-dev-token")
   {
      Alert("NixoLink: set InpAuthToken to the long random token from engine_config.json (api_token).");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(StringLen(InpAuthToken) < 16)
      Print("NixoLink: WARNING - token is short; use at least 16 random characters.");

   GlobalVariablesDeleteAll("NX_", TimeCurrent() - 86400 * 2);   // drop old idempotency keys
   g_trade.SetAsyncMode(false);
   g_nextTry = 0;
   if(!EventSetMillisecondTimer(InpTimerMs))
   {
      Print("NixoLink: cannot set millisecond timer");
      return(INIT_FAILED);
   }
   Print("NixoLink v2.00 started. Real accounts allowed: ", InpAllowReal ? "YES" : "NO");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_socket != INVALID_HANDLE)
      SocketClose(g_socket);
   g_socket = INVALID_HANDLE;
}

void OnTimer()
{
   ulong now = GetTickCount64();
   if(g_socket == INVALID_HANDLE || !SocketIsConnected(g_socket))
   {
      if(g_socket != INVALID_HANDLE)
         Disconnect("socket closed by engine");
      TryConnect();
      return;
   }
   if(!ReadSocket())
      return;
   if(!g_authed)
   {
      if(now - g_connectedAt > 3000)
         Disconnect("auth timeout");
      return;
   }
   if(now - g_lastRx > (ulong)InpRxTimeoutSec * 1000)
   {
      Disconnect("heartbeat timeout");
      return;
   }
   if(now - g_lastHb >= (ulong)InpHeartbeatSec * 1000)
   {
      g_lastHb = now;
      SendLine("CMD=HB");
   }
}
//+------------------------------------------------------------------+
