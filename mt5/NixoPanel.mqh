//+------------------------------------------------------------------+
//| NixoPanel.mqh - NIXO read-only on-chart monitor                  |
//| Uses MetaQuotes Standard Library Controls; no trade operations.  |
//+------------------------------------------------------------------+
#ifndef NIXO_PANEL_MQH
#define NIXO_PANEL_MQH

#include <Controls\Dialog.mqh>
#include <Controls\Label.mqh>

class CNixoPanel : public CAppDialog
{
private:
   CLabel  m_title;
   CLabel  m_engine;
   CLabel  m_rx;
   CLabel  m_account;
   CLabel  m_money;
   CLabel  m_external;
   CLabel  m_notice;
   ulong   m_last_refresh;
   string  m_cache_engine;
   string  m_cache_rx;
   string  m_cache_account;
   string  m_cache_money;

   bool CreateLine(CLabel &label,const string key,const string text,
                   const int y,const color ink,const int font_size)
   {
      if(!label.Create(m_chart_id,m_name+key,m_subwin,12,y,350,y+20))
         return(false);
      if(!label.Text(text))
         return(false);
      label.Font("Segoe UI");
      label.FontSize(font_size);
      label.Color(ink);
      return(Add(label));
   }

   bool RefreshDue(void)
   {
      ulong now=GetTickCount64();
      if(m_last_refresh>0 && now-m_last_refresh<500)
         return(false);
      m_last_refresh=now;
      return(true);
   }

   string AccountText(void)
   {
      long mode=AccountInfoInteger(ACCOUNT_TRADE_MODE);
      string kind="DEMO";
      if(mode==ACCOUNT_TRADE_MODE_REAL) kind="REAL";
      else if(mode==ACCOUNT_TRADE_MODE_CONTEST) kind="CONTEST";
      return("ACCOUNT  "+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"  |  "+kind);
   }

   string MoneyText(void)
   {
      string currency=AccountInfoString(ACCOUNT_CURRENCY);
      return("BALANCE  "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+"  "+currency+
             "     EQUITY  "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+"  "+currency);
   }

   bool SetTextIfChanged(CLabel &label,string &cache,const string value)
   {
      if(cache==value)
         return(false);
      cache=value;
      label.Text(value);
      return(true);
   }

public:
   CNixoPanel(void)
   {
      m_last_refresh=0;
      m_cache_engine="";
      m_cache_rx="";
      m_cache_account="";
      m_cache_money="";
   }

   bool CreatePanel(const long chart,const string name,const int subwin,
                    const int x1,const int y1,const int x2,const int y2)
   {
      if(!CAppDialog::Create(chart,name,subwin,x1,y1,x2,y2))
         return(false);
      ColorBackground(C'26,39,49');
      ColorBorder(C'57,217,138');
      if(!CreateLine(m_title,"Title","NIXO  |  LINK MONITOR",8,C'57,217,138',12)) return(false);
      if(!CreateLine(m_engine,"Engine","ENGINE: waiting for status",34,C'231,237,242',10)) return(false);
      if(!CreateLine(m_rx,"Rx","LAST ENGINE RX: --",57,C'156,174,186',9)) return(false);
      if(!CreateLine(m_account,"Account","ACCOUNT: --",80,C'231,237,242',10)) return(false);
      if(!CreateLine(m_money,"Money","BALANCE / EQUITY: --",103,C'231,237,242',9)) return(false);
      if(!CreateLine(m_external,"External","TELEGRAM / PING RTT: not exposed by current protocol",129,C'255,176,32',9)) return(false);
      if(!CreateLine(m_notice,"Notice","READ-ONLY  |  TRADE CONTROLS NOT ENABLED",152,C'156,174,186',9)) return(false);
      return(true);
   }

   void Refresh(const bool authenticated,const ulong last_rx)
   {
      if(!RefreshDue())
         return;
      string engine=authenticated ? "ENGINE: AUTHENTICATED" : "ENGINE: DISCONNECTED";
      string rx="LAST ENGINE RX: --";
      if(last_rx>0)
         rx="LAST ENGINE RX: "+IntegerToString((long)((GetTickCount64()-last_rx)/1000))+" s ago";
      bool changed=false;
      if(SetTextIfChanged(m_engine,m_cache_engine,engine)) changed=true;
      if(SetTextIfChanged(m_rx,m_cache_rx,rx)) changed=true;
      if(SetTextIfChanged(m_account,m_cache_account,AccountText())) changed=true;
      if(SetTextIfChanged(m_money,m_cache_money,MoneyText())) changed=true;
      if(changed)
         ChartRedraw(m_chart_id);
   }

   bool ForwardChartEvent(const int id,const long &lparam,
                          const double &dparam,const string &sparam)
   {
      return(CAppDialog::ChartEvent(id,lparam,dparam,sparam));
   }
};

#endif // NIXO_PANEL_MQH
