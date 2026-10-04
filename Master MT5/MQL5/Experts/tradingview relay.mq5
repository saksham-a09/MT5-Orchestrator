//+------------------------------------------------------------------+
//|                                     TradingViewRelayClient.mq5   |
//|                 Copyright 2026, TradingView Webhook Relay Project |
//|                                       Minimal Latency Multi-EA   |
//+------------------------------------------------------------------+
#property copyright "TradingView Relay Project"
#property link      "https://github.com/user/webhook-relay"
#property version   "2.00"
#property description "High-Performance Multi-EA Client for TradingView Webhook Relay Server"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

// NOTE: This EA uses MT5's built-in WebRequest() for HTTP — cross-platform (Windows & Linux/Wine).
// You MUST whitelist the server URL under:
//   Tools → Options → Expert Advisors → Allow WebRequest for listed URL
// Add your relay server URL, e.g.: http://127.0.0.1:8000

//--- Input Parameters
input group "=== Server Configuration ==="
input string   InpServerURL        = "http://127.0.0.1:8000"; // Python Relay Server URL
input string   InpClientID         = "AUTO";                  // Client ID ("AUTO" uses Account Login)
string   InpAuthToken        = "";                      // Shared Webhook Authorization Token
int      InpPollTimeoutSec   = 20;                      // Long-Poll Timeout (Seconds)
int      InpMaxSignalAgeSec  = 30;                      // Max Signal Age to Execute (Seconds)

input group "=== Trading Settings ==="
input double   InpRiskPercent                = 1.0;    // Risk Percentage per Trade (% of Balance)
input double   InpDefaultVolume              = 0.01;   // Default Lot Size (Fallback if SL missing)
input double   InpMaxVolume                  = 2.0;   // Maximum Allowed Lot Size (0 = Broker Max)
input int      InpMinSLPoints                = 0;      // Minimum Required SL in Points (0 = Auto Broker Level)
input ulong    InpMagicNumber                = 123456; // Magic Number for EA Orders
input ulong    InpSlippage                   = 30;     // Allowed Slippage in Points
input int      InpPendingOrderThresholdPoints = 50;     // Points from Market Price to Auto-Place Pending Order (0 = always market unless signal forces pending)
input double   InpMaxTargetConsumedPercent   = 25.0;   // Max % of Entry-to-TP distance crossed before "Price Lost" (0 = disable)
input int      InpPriceCrossedFallbackPoints = 50;     // Fallback Max Points crossed from Entry if TP is 0 (0 = disable)
input bool     InpDrawPriceLostLabel         = true;   // Draw "Price Lost" label on candle when trade is cancelled
input string   InpSymbolMap                  = "";     // Symbol Mapping (TV:MT5)

input group "=== Dashboard Display ==="
input bool     InpShowDashboard    = true;                    // Display On-Chart Status Panel
input color    InpPanelBgColor     = C'20,24,35';             // Panel Background Color
input color    InpTextColor        = C'230,235,245';          // Panel Text Color

//--- Global Variables
CTrade         ExtTrade;
CSymbolInfo    ExtSymbol;
CPositionInfo  ExtPosition;

string         ExtClientID         = "";
datetime       ExtLastHeartbeat    = 0;
int            ExtTotalExecuted    = 0;
int            ExtTotalFailed      = 0;
int            ExtLastPingMS       = 0;
string         ExtStatusText       = "Initializing...";
datetime       ExtLastSignalTime   = 0;

//+------------------------------------------------------------------+
//| Expert Initialization Function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Determine Client ID
   if(InpClientID == "AUTO" || StringLen(InpClientID) == 0)
      ExtClientID = "MT5_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   else
      ExtClientID = InpClientID;

   // Configure Trade object
   ExtTrade.SetExpertMagicNumber(InpMagicNumber);
   ExtTrade.SetDeviationInPoints(InpSlippage);
   ExtTrade.SetTypeFilling(ORDER_FILLING_FOK);

   // Start timer for fast polling (100 ms)
   EventSetTimer(1); // 1-second background pulse, OnTimer handles async long-polling

   if(InpShowDashboard)
      CreateDashboard();

   PrintFormat("[EA Init] TradingView Relay Client started. Client ID: %s | Server: %s", ExtClientID, InpServerURL);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert Deinitialization Function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(InpShowDashboard)
      DestroyDashboard();
   Print("[EA Deinit] Relay Client stopped.");
}

//+------------------------------------------------------------------+
//| Expert Timer Function                                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeCurrent();

   // Periodic Heartbeat every 15 seconds
   if(now - ExtLastHeartbeat >= 15)
   {
      SendHeartbeat();
      ExtLastHeartbeat = now;
   }

   // Poll server for pending signals
   PollPendingTrades();

   if(InpShowDashboard)
      UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Helper: MT5 Native WebRequest (cross-platform: Windows & Linux)  |
//| Requires: Tools → Options → Expert Advisors →                    |
//|           Allow WebRequest for listed URL → add InpServerURL     |
//+------------------------------------------------------------------+
bool HttpRequest(const string method, const string endpoint, const string postData, string &outResponse, int &outCode)
{
   outCode     = -1;
   outResponse = "";

   string url = InpServerURL;
   // Strip trailing slash from base URL
   if(StringLen(url) > 0 && StringGetCharacter(url, StringLen(url)-1) == '/')
      url = StringSubstr(url, 0, StringLen(url)-1);
   url += endpoint;

   // --- Build request headers ---
   string hdrs = "Content-Type: application/json\r\n";
   if(StringLen(InpAuthToken) > 0)
      hdrs += "X-Token: " + InpAuthToken + "\r\n";

   // --- Prepare body bytes (UTF-8, no null terminator) ---
   uchar body[];
   if(StringLen(postData) > 0)
   {
      int bodyLen = StringToCharArray(postData, body, 0, WHOLE_ARRAY, CP_UTF8);
      // StringToCharArray appends a null terminator — remove it
      if(bodyLen > 0 && body[bodyLen-1] == 0)
         ArrayResize(body, bodyLen - 1);
   }

   uchar resultBody[];
   string resultHeaders;
   int timeout = (InpPollTimeoutSec + 5) * 1000; // ms; a bit longer than poll timeout

   uint startTick = GetTickCount();
   int httpStatus = WebRequest(method, url, hdrs, timeout, body, resultBody, resultHeaders);
   ExtLastPingMS  = (int)(GetTickCount() - startTick);

   outCode = httpStatus;

   if(httpStatus == -1)
   {
      int err = GetLastError();
      // ERR_WEBREQUEST_INVALID_ADDRESS (4014) = URL not whitelisted
      if(err == 4014)
         ExtStatusText = "WebRequest blocked: add " + InpServerURL + " to Tools→Options→Expert Advisors→Allow WebRequest";
      else
         ExtStatusText = StringFormat("WebRequest failed (err=%d)", err);
      return false;
   }

   if(httpStatus == 200 || httpStatus == 201)
   {
      outResponse = CharArrayToString(resultBody, 0, WHOLE_ARRAY, CP_UTF8);
      return true;
   }

   outResponse = CharArrayToString(resultBody, 0, WHOLE_ARRAY, CP_UTF8);
   ExtStatusText = "HTTP Error " + IntegerToString(httpStatus);
   return false;
}

//+------------------------------------------------------------------+
//| Send Heartbeat to Python Server                                  |
//+------------------------------------------------------------------+
void SendHeartbeat()
{
   string json = StringFormat(
      "{\"client_id\":\"%s\",\"account_login\":\"%s\",\"broker\":\"%s\",\"server\":\"%s\",\"magic_number\":%d,\"ping_ms\":%d}",
      ExtClientID,
      IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)),
      AccountInfoString(ACCOUNT_COMPANY),
      AccountInfoString(ACCOUNT_SERVER),
      InpMagicNumber,
      ExtLastPingMS
   );

   string response;
   int code;
   HttpRequest("POST", "/api/v1/clients/heartbeat", json, response, code);
}

//+------------------------------------------------------------------+
//| Poll Pending Trades from Python Queue                            |
//+------------------------------------------------------------------+
void PollPendingTrades()
{
   string endpoint = StringFormat("/api/v1/trades/pending?client_id=%s&timeout=%d", ExtClientID, InpPollTimeoutSec);
   string response;
   int code;

   if(HttpRequest("GET", endpoint, "", response, code))
   {
      ExtStatusText = "Connected (OK)";
      if(StringFind(response, "\"trades\":[") >= 0 && StringFind(response, "\"trade_id\"") >= 0)
      {
         ProcessTradesResponse(response);
      }
   }
}

//+------------------------------------------------------------------+
//| Process Trades JSON Response                                     |
//+------------------------------------------------------------------+
void ProcessTradesResponse(const string json)
{
   // Locate the "trades" array
   int tradesIdx = StringFind(json, "\"trades\":[");
   if(tradesIdx < 0) return;

   int start = tradesIdx + 10;
   int end = StringFind(json, "]", start);
   if(end <= start) return;

   string arrayContent = StringSubstr(json, start, end - start);
   if(StringLen(arrayContent) < 5) return; // empty array []

   // Extract individual trade objects delimited by { ... }
   int pos = 0;
   while(pos < StringLen(arrayContent))
   {
      int objStart = StringFind(arrayContent, "{", pos);
      if(objStart < 0) break;

      int objEnd = StringFind(arrayContent, "}", objStart);
      if(objEnd < 0) break;

      string tradeObj = StringSubstr(arrayContent, objStart, objEnd - objStart + 1);
      ExecuteTradePayload(tradeObj);

      pos = objEnd + 1;
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on Account Risk % and Stop Loss Distance|
//+------------------------------------------------------------------+
double CalculateRiskLotSize(const string symbol, double price, double slPrice)
{
   if(slPrice <= 0 || price <= 0 || InpRiskPercent <= 0)
      return InpDefaultVolume;

   double slDistance = MathAbs(price - slPrice);
   if(slDistance <= 0)
      return InpDefaultVolume;

   double tickSize = ExtSymbol.TickSize();
   double tickValue = ExtSymbol.TickValue();

   if(tickSize <= 0 || tickValue <= 0)
      return InpDefaultVolume;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0)
      balance = AccountInfoDouble(ACCOUNT_EQUITY);

   double riskAmount = balance * (InpRiskPercent / 100.0);
   double riskPerLot = (slDistance / tickSize) * tickValue;

   if(riskPerLot <= 0)
      return InpDefaultVolume;

   double lot = riskAmount / riskPerLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Helper: Hash Strategy Name into Deterministic 31-bit Magic Number|
//+------------------------------------------------------------------+
ulong HashStrategyNameToMagic(const string str)
{
   if(StringLen(str) == 0) return 0;
   ulong hash = 5381;
   for(int i = 0; i < StringLen(str); i++)
   {
      ushort c = StringGetCharacter(str, i);
      hash = ((hash << 5) + hash) + c; // hash * 33 + c
   }
   ulong magic = (hash & 0x7FFFFFFF); // Keep within positive 31-bit integer for MT5
   if(magic == 0) magic = 1;
   return magic;
}

//+------------------------------------------------------------------+
//| Helper: Check if Position/Order Matches Specific Strategy/Symbol |
//+------------------------------------------------------------------+
bool IsStrategyMatch(ulong itemMagic, const string itemComment, const string itemSymbol, ulong targetMagic, const string targetStrategy, const string targetResolvedSymbol, const string targetRawSymbol)
{
   // 1. Check Symbol match (if target symbol specified and not ALL / wildcard)
   if(StringLen(targetResolvedSymbol) > 0 || (StringLen(targetRawSymbol) > 0 && targetRawSymbol != "ALL" && targetRawSymbol != "*" && targetRawSymbol != "ANY"))
   {
      bool symMatch = false;
      if(StringLen(targetResolvedSymbol) > 0 && itemSymbol == targetResolvedSymbol)
         symMatch = true;
      else if(StringLen(targetRawSymbol) > 0 && itemSymbol == targetRawSymbol)
         symMatch = true;

      if(!symMatch)
         return false;
   }

   // 2. Check Magic Number match if targetMagic > 0
   if(targetMagic > 0 && itemMagic == targetMagic)
      return true;

   // 3. Check Strategy Name in Comment match
   if(StringLen(targetStrategy) > 0)
   {
      string itemCommentUpper = itemComment;
      StringToUpper(itemCommentUpper);
      string targetStratUpper = targetStrategy;
      StringToUpper(targetStratUpper);

      if(StringFind(itemCommentUpper, targetStratUpper) >= 0)
         return true;
   }

   // 4. Default fallback: If targetMagic == 0 and targetStrategy is empty, match InpMagicNumber if configured
   if(targetMagic == 0 && StringLen(targetStrategy) == 0 && InpMagicNumber > 0 && itemMagic == InpMagicNumber)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Draw "Price Lost" Label on Chart Candle                          |
//+------------------------------------------------------------------+
void DrawPriceLostLabel(const string symbol, const string textMsg, bool isBuy, double entryPrice, double currentPrice)
{
   long targetChart = -1;
   long cId = ChartFirst();
   while(cId >= 0)
   {
      if(ChartSymbol(cId) == symbol)
      {
         targetChart = cId;
         break;
      }
      cId = ChartNext(cId);
   }

   if(targetChart < 0)
   {
      if(ChartSymbol(0) == symbol)
         targetChart = 0;
      else
         return; // Skip if no chart open for this symbol to avoid misplaced label
   }

   ENUM_TIMEFRAMES tf = (targetChart >= 0) ? ChartPeriod(targetChart) : _Period;
   datetime barTime = iTime(symbol, tf, 0);
   if(barTime == 0) barTime = TimeCurrent();

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) point = 0.0001;

   double candleHigh = iHigh(symbol, tf, 0);
   double candleLow  = iLow(symbol, tf, 0);
   double labelPrice = isBuy ? ((candleHigh > 0) ? candleHigh + (5 * point) : currentPrice)
                             : ((candleLow > 0)  ? candleLow  - (5 * point) : currentPrice);

   string objName = "TV_PriceLost_" + symbol + "_" + IntegerToString((long)barTime) + "_" + IntegerToString(GetTickCount());
   if(ObjectCreate(targetChart, objName, OBJ_TEXT, 0, barTime, labelPrice))
   {
      ObjectSetString(targetChart, objName, OBJPROP_TEXT, " " + textMsg);
      ObjectSetInteger(targetChart, objName, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(targetChart, objName, OBJPROP_FONTSIZE, 9);
      ObjectSetString(targetChart, objName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(targetChart, objName, OBJPROP_ANCHOR, isBuy ? ANCHOR_LOWER : ANCHOR_UPPER);
      ObjectSetString(targetChart, objName, OBJPROP_TOOLTIP, StringFormat("%s | Req: %.5f | Mkt: %.5f", textMsg, entryPrice, currentPrice));
      ChartRedraw(targetChart);
   }
}

//+------------------------------------------------------------------+
//| Execute Order with Up to 5 Retry Attempts                       |
//| orderKind: "Buy","Sell","BuyLimit","SellLimit","BuyStop","SellStop"|
//| Returns true only when retcode == TRADE_RETCODE_DONE            |
//+------------------------------------------------------------------+
bool ExecuteOrderWithRetry(const string tradeID,
                           const string orderKind,
                           double       vol,
                           double       orderPrice,
                           const string symbol,
                           double       sl,
                           double       tp,
                           const string comment)
{
   int MAX_TRIES = 5;
   bool ok = false;

   for(int attempt = 1; attempt <= MAX_TRIES; attempt++)
   {
      ResetLastError();

      // Refresh rates before every attempt so price is fresh
      if(attempt > 1)
      {
         ExtSymbol.RefreshRates();
         // For pure market orders refresh price each retry
         if(orderKind == "Buy")
            orderPrice = ExtSymbol.Ask();
         else if(orderKind == "Sell")
            orderPrice = ExtSymbol.Bid();
      }

      if(orderKind == "Buy")
         ok = ExtTrade.Buy(vol, symbol, orderPrice, sl, tp, comment);
      else if(orderKind == "Sell")
         ok = ExtTrade.Sell(vol, symbol, orderPrice, sl, tp, comment);
      else if(orderKind == "BuyLimit")
         ok = ExtTrade.BuyLimit(vol, orderPrice, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(orderKind == "SellLimit")
         ok = ExtTrade.SellLimit(vol, orderPrice, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(orderKind == "BuyStop")
         ok = ExtTrade.BuyStop(vol, orderPrice, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(orderKind == "SellStop")
         ok = ExtTrade.SellStop(vol, orderPrice, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else
      {
         PrintFormat("[EA Retry] Unknown orderKind '%s' — aborting.", orderKind);
         return false;
      }

      uint retcode  = ExtTrade.ResultRetcode();
      string errMsg = ExtTrade.ResultComment();

      if(ok && retcode == TRADE_RETCODE_DONE)
      {
         if(attempt > 1)
            PrintFormat("[EA Retry] %s %s SUCCESS on attempt %d/%d | retcode=%u",
               orderKind, symbol, attempt, MAX_TRIES, retcode);
         return true;
      }

      // Log each failed attempt with retcode and broker message
      PrintFormat("[EA Retry] %s %s FAILED attempt %d/%d | retcode=%u | reason: %s | price=%.5f sl=%.5f tp=%.5f vol=%.2f",
         orderKind, symbol, attempt, MAX_TRIES, retcode, errMsg, orderPrice, sl, tp, vol);

      // No sleep between retries — MT5 retryable errors (requote, price_off)
      // resolve in microseconds; a delay only adds latency.
   }

   return false; // all 5 attempts exhausted
}

//+------------------------------------------------------------------+
//| Execute Single Trade Object                                      |
//+------------------------------------------------------------------+
void ExecuteTradePayload(const string tradeJson)
{
   string tradeID = JsonExtractString(tradeJson, "trade_id");
   string rawSymbol = JsonExtractString(tradeJson, "symbol");
   if(StringLen(rawSymbol) == 0)
      rawSymbol = JsonExtractString(tradeJson, "ticker");

   string side = JsonExtractString(tradeJson, "side");
   string action = JsonExtractString(tradeJson, "action");
   string sigType = JsonExtractString(tradeJson, "signal_type");
   string typeStr = JsonExtractString(tradeJson, "type");
   string comment = JsonExtractString(tradeJson, "comment");

   string strategy = JsonExtractString(tradeJson, "strategy");
   if(StringLen(strategy) == 0) strategy = JsonExtractString(tradeJson, "strategy_name");
   if(StringLen(strategy) == 0) strategy = JsonExtractString(tradeJson, "strategy_id");

   ulong tradeMagic = (ulong)JsonExtractDouble(tradeJson, "magic_number");
   if(tradeMagic == 0) tradeMagic = (ulong)JsonExtractDouble(tradeJson, "magic");
   if(tradeMagic == 0) tradeMagic = (ulong)JsonExtractDouble(tradeJson, "magic_id");
   if(tradeMagic == 0 && StringLen(strategy) > 0) tradeMagic = HashStrategyNameToMagic(strategy);
   if(tradeMagic == 0) tradeMagic = InpMagicNumber;

   double qty = JsonExtractDouble(tradeJson, "quantity");
   if(qty <= 0) qty = JsonExtractDouble(tradeJson, "volume");
   if(qty <= 0) qty = JsonExtractDouble(tradeJson, "contracts");

   double sl = JsonExtractDouble(tradeJson, "sl");
   if(sl <= 0) sl = JsonExtractDouble(tradeJson, "stop_loss");

   double tp = JsonExtractDouble(tradeJson, "tp_main");
   if(tp <= 0) tp = JsonExtractDouble(tradeJson, "tp");
   if(tp <= 0) tp = JsonExtractDouble(tradeJson, "take_profit");

   // Build comment tagging strategy identifier if available
   if(StringLen(comment) == 0)
   {
      if(StringLen(strategy) > 0)
         comment = strategy + " " + tradeID;
      else
         comment = "TV Relay " + tradeID;
   }
   else if(StringLen(strategy) > 0 && StringFind(comment, strategy) < 0)
   {
      comment = strategy + " " + comment;
   }

   // Keep within MT5 31-character comment limit
   if(StringLen(comment) > 31)
      comment = StringSubstr(comment, 0, 31);

   string sideUpper = side; StringToUpper(sideUpper);
   string actionUpper = action; StringToUpper(actionUpper);
   string sigTypeUpper = sigType; StringToUpper(sigTypeUpper);
   string typeUpper = typeStr; StringToUpper(typeUpper);
   string commentUpper = comment; StringToUpper(commentUpper);

   bool isCloseAllPositions = (actionUpper == "CLOSE_ALL" || actionUpper == "CLOSE_ALL_POSITIONS" || actionUpper == "CLOSE ALL POSITIONS" || actionUpper == "CLOSE_POSITIONS" || actionUpper == "CLOSE POSITIONS" || sideUpper == "CLOSE_ALL" || sideUpper == "CLOSE_ALL_POSITIONS" || actionUpper == "CLOSE ALL" || actionUpper == "FLATTEN");
   bool isCloseAllOrders = (actionUpper == "CLOSE_ALL" || actionUpper == "CLOSE_ALL_ORDERS" || actionUpper == "CLOSE ALL ORDERS" || actionUpper == "CANCEL_ALL" || actionUpper == "CANCEL_ORDERS" || actionUpper == "CANCEL_ALL_ORDERS" || actionUpper == "CANCEL ALL ORDERS" || actionUpper == "CANCEL ORDERS" || actionUpper == "CANCEL_PENDING" || actionUpper == "CANCEL PENDING" || sideUpper == "CANCEL_ALL" || sideUpper == "CANCEL_ALL_ORDERS" || actionUpper == "CLOSE ALL" || actionUpper == "FLATTEN");

   bool isExit = (!isCloseAllPositions && !isCloseAllOrders && (sideUpper == "EXIT" || sideUpper == "CLOSE" || actionUpper == "CLOSE" || actionUpper == "EXIT" || sigTypeUpper == "EXIT" || typeUpper == "EXIT" || StringFind(commentUpper, "SL") >= 0 || StringFind(commentUpper, "TP") >= 0));
   bool isBuy  = (!isCloseAllPositions && !isCloseAllOrders && !isExit && (sideUpper == "LONG" || sideUpper == "BUY" || actionUpper == "BUY" || actionUpper == "LONG" || sigTypeUpper == "BUY" || sigTypeUpper == "LONG" || typeUpper == "BUY" || typeUpper == "LONG"));
   bool isSell = (!isCloseAllPositions && !isCloseAllOrders && !isExit && (sideUpper == "SHORT" || sideUpper == "SELL" || actionUpper == "SELL" || actionUpper == "SHORT" || sigTypeUpper == "SELL" || sigTypeUpper == "SHORT" || typeUpper == "SELL" || typeUpper == "SHORT"));

   ExtLastSignalTime = TimeCurrent();

   if(isCloseAllPositions || isCloseAllOrders)
   {
      if(isCloseAllPositions) ClosePositionsForStrategy(tradeID, rawSymbol, strategy, tradeMagic);
      if(isCloseAllOrders) CancelOrdersForStrategy(tradeID, rawSymbol, strategy, tradeMagic);
      return;
   }

   if(isExit)
   {
      ClosePositionsForStrategy(tradeID, rawSymbol, strategy, tradeMagic);
      return;
   }

   // Resolve Symbol Name
   string symbol = ResolveSymbol(rawSymbol);
   if(StringLen(symbol) == 0)
   {
      PrintFormat("[EA Error] Symbol mapping failed for '%s'", rawSymbol);
      SendACK(tradeID, "error", 0, 0, rawSymbol, 0, 0, "Symbol not found on MT5 broker");
      ExtTotalFailed++;
      return;
   }

   if(!isBuy && !isSell)
   {
      PrintFormat("[EA Ignored] Signal %s does not specify Buy/Sell/Exit action", tradeID);
      SendACK(tradeID, "ignored", 0, 0, symbol, 0, 0, "Payload missing buy/sell action");
      return;
   }

   // Prepare Symbol Info
   if(!ExtSymbol.Name(symbol) || !ExtSymbol.RefreshRates())
   {
      PrintFormat("[EA Error] Could not refresh symbol rates for %s", symbol);
      SendACK(tradeID, "error", 0, 0, symbol, 0, 0, "Symbol refresh rates failed");
      ExtTotalFailed++;
      return;
   }

   // Set Dynamic Filling Mode according to Symbol capabilities
   uint fillingMode = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      ExtTrade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      ExtTrade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      ExtTrade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Configure trade instance with specific magic number & slippage
   ExtTrade.SetExpertMagicNumber(tradeMagic);
   ExtTrade.SetDeviationInPoints(InpSlippage);

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = isBuy ? ExtSymbol.Ask() : ExtSymbol.Bid();

   double reqPrice = JsonExtractDouble(tradeJson, "entry_price");
   if(reqPrice <= 0) reqPrice = JsonExtractDouble(tradeJson, "price");

   // --- Signal-level order_type override ---
   // Accepted values: "market", "pending", "limit", "stop"
   // "market"  -> always execute at market price (ignore entry_price distance)
   // "pending" -> always place a pending order using entry_price (BuyLimit/BuyStop etc.)
   // "limit"   -> force Buy/SellLimit (price must be provided)
   // "stop"    -> force Buy/SellStop  (price must be provided)
   // ""        -> auto-decide based on InpPendingOrderThresholdPoints (default behaviour)
   string orderTypeRaw = JsonExtractString(tradeJson, "order_type");
   StringToLower(orderTypeRaw);
   StringTrimLeft(orderTypeRaw);
   StringTrimRight(orderTypeRaw);

   bool forceMarket  = (orderTypeRaw == "market");
   bool forcePending = (orderTypeRaw == "pending" || orderTypeRaw == "limit" || orderTypeRaw == "stop");
   bool forceLimit   = (orderTypeRaw == "limit");
   bool forceStop    = (orderTypeRaw == "stop");

   // Auto-decide using threshold when no explicit order_type is given
   bool autoPending = (!forceMarket && !forcePending)
                   && (InpPendingOrderThresholdPoints > 0)
                   && (reqPrice > 0)
                   && (MathAbs(reqPrice - price) > (InpPendingOrderThresholdPoints * ExtSymbol.Point()));

   bool usePending = forcePending || autoPending;
   
   double riskEntryPrice = price;
   if(!forceMarket && usePending && reqPrice > 0)
   {
      riskEntryPrice = reqPrice;
   }

   // Determine Lot Size: Calculate from input risk % if SL is available, otherwise use quantity or default lot
   if(InpRiskPercent > 0 && sl > 0)
   {
      qty = CalculateRiskLotSize(symbol, riskEntryPrice, sl);
   }
   else if(qty <= 0)
   {
      qty = InpDefaultVolume;
   }

   // Normalize Volume with Broker Limits and InpMaxVolume
   double minVol = ExtSymbol.LotsMin();
   double brokerMaxVol = ExtSymbol.LotsMax();
   double maxVol = (InpMaxVolume > 0.0) ? MathMin(brokerMaxVol, InpMaxVolume) : brokerMaxVol;
   double stepVol = ExtSymbol.LotsStep();
   qty = MathMax(minVol, MathMin(maxVol, qty));
   if(stepVol > 0)
      qty = MathRound(qty / stepVol) * stepVol;

   // Validate & Auto-Adjust Stop Loss to satisfy minimum required SL distance (InpMinSLPoints & Broker Stops Level)
   int brokerStopsLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int minSLPointsRequired = MathMax(InpMinSLPoints, brokerStopsLevel);
   double point = ExtSymbol.Point();
   int digits = ExtSymbol.Digits();

   if(sl > 0 && minSLPointsRequired > 0 && point > 0)
   {
      double minSLDistPrice = minSLPointsRequired * point;
      if(isBuy)
      {
         if(riskEntryPrice - sl < minSLDistPrice)
         {
            double oldSL = sl;
            sl = NormalizeDouble(riskEntryPrice - minSLDistPrice, digits);
            PrintFormat("[EA SL Adjust] Buy SL on %s adjusted from %.5f to %.5f to meet min %d points", symbol, oldSL, sl, minSLPointsRequired);
         }
      }
      else
      {
         if(sl - riskEntryPrice < minSLDistPrice)
         {
            double oldSL = sl;
            sl = NormalizeDouble(riskEntryPrice + minSLDistPrice, digits);
            PrintFormat("[EA SL Adjust] Sell SL on %s adjusted from %.5f to %.5f to meet min %d points", symbol, oldSL, sl, minSLPointsRequired);
         }
      }
   }

   if(sl > 0) sl = NormalizeDouble(sl, digits);
   if(tp > 0) tp = NormalizeDouble(tp, digits);

   // -----------------------------------------------------------------------
   // Fill Order — with spread-range clamping and 5-attempt retry logic
   // -----------------------------------------------------------------------
   ResetLastError();
   bool success = false;

   if(!forceMarket && usePending)
   {
      // Use reqPrice if available, fall back to current price
      double pendingPrice = (reqPrice > 0) ? reqPrice : price;

      double askPrice  = ExtSymbol.Ask();
      double bidPrice  = ExtSymbol.Bid();
      double spread    = askPrice - bidPrice;
      if(spread <= 0) spread = point; // safety floor

      bool tradeCancelled = false;
      string cancelReason = "";

      if(isBuy)
      {
         if(forceLimit)
         {
            // BUY LIMIT: entry below current Ask
            if(pendingPrice < bidPrice)
            {
               // Clearly below bid — normal pending limit
               success = ExecuteOrderWithRetry(tradeID, "BuyLimit", qty, pendingPrice, symbol, sl, tp, comment);
            }
            else if(pendingPrice <= askPrice)
            {
               // Price is inside the spread — clamp to Ask (best executable buy price)
               double clampedPrice = NormalizeDouble(askPrice, digits);
               PrintFormat("[EA Spread Clamp] Buy Limit %.5f is inside spread [%.5f-%.5f] - clamped to Ask %.5f and executed as MARKET",
                  pendingPrice, bidPrice, askPrice, clampedPrice);
               success = ExecuteOrderWithRetry(tradeID, "Buy", qty, clampedPrice, symbol, sl, tp, comment);
            }
            else
            {
               // Ask <= pendingPrice: limit already crossed — execute at market
               PrintFormat("[EA Limit Crossed] Buy Limit at %.5f crossed by current Ask %.5f - executing as MARKET order", pendingPrice, askPrice);
               success = ExecuteOrderWithRetry(tradeID, "Buy", qty, askPrice, symbol, sl, tp, comment);
            }
         }
         else // BuyStop
         {
            if(pendingPrice > askPrice)
            {
               // Normal: price has not yet reached stop level
               success = ExecuteOrderWithRetry(tradeID, "BuyStop", qty, pendingPrice, symbol, sl, tp, comment);
            }
            else if(pendingPrice >= bidPrice)
            {
               // Price is inside the spread — clamp to Ask (best executable price)
               double clampedPrice = NormalizeDouble(askPrice, digits);
               PrintFormat("[EA Spread Clamp] Buy Stop %.5f is inside spread [%.5f-%.5f] - clamped to Ask %.5f and executed as MARKET",
                  pendingPrice, bidPrice, askPrice, clampedPrice);
               success = ExecuteOrderWithRetry(tradeID, "Buy", qty, clampedPrice, symbol, sl, tp, comment);
            }
            else
            {
               // Price HAS CROSSED below bid — check TP / threshold
               if(tp > 0 && askPrice >= tp)
               {
                  tradeCancelled = true;
                  cancelReason = StringFormat("Buy Ask %.5f already reached/exceeded TP %.5f - Price Lost", askPrice, tp);
               }
               else
               {
                  double slippage = askPrice - pendingPrice;
                  bool withinThreshold = false;
                  double pctConsumed = 0.0;

                  if(tp > 0 && (tp - pendingPrice) > 0)
                  {
                     pctConsumed = (slippage / (tp - pendingPrice)) * 100.0;
                     withinThreshold = (InpMaxTargetConsumedPercent <= 0) || (pctConsumed <= InpMaxTargetConsumedPercent);
                  }
                  else
                  {
                     double maxPtsDist = (InpPriceCrossedFallbackPoints > 0) ? (InpPriceCrossedFallbackPoints * point) : 0;
                     withinThreshold = (maxPtsDist <= 0) || (slippage <= maxPtsDist);
                  }

                  if(withinThreshold)
                  {
                     PrintFormat("[EA Price Crossed] Buy Stop at %.5f crossed by Ask %.5f (consumed %.1f%% of TP / %.1f pts) - Triggering MARKET order",
                        pendingPrice, askPrice, pctConsumed, (point > 0 ? (slippage / point) : slippage));
                     success = ExecuteOrderWithRetry(tradeID, "Buy", qty, askPrice, symbol, sl, tp, comment);
                  }
                  else
                  {
                     tradeCancelled = true;
                     cancelReason = StringFormat("Buy Stop at %.5f crossed by Ask %.5f beyond threshold (consumed %.1f%% > max %.1f%%) - Price Lost",
                        pendingPrice, askPrice, pctConsumed, InpMaxTargetConsumedPercent);
                  }
               }
            }
         }
      }
      else // isSell
      {
         if(forceLimit)
         {
            // SELL LIMIT: entry above current Bid
            if(pendingPrice > askPrice)
            {
               // Clearly above ask — normal pending sell limit
               success = ExecuteOrderWithRetry(tradeID, "SellLimit", qty, pendingPrice, symbol, sl, tp, comment);
            }
            else if(pendingPrice >= bidPrice)
            {
               // Price is inside the spread — clamp to Bid (best executable sell price)
               double clampedPrice = NormalizeDouble(bidPrice, digits);
               PrintFormat("[EA Spread Clamp] Sell Limit %.5f is inside spread [%.5f-%.5f] - clamped to Bid %.5f and executed as MARKET",
                  pendingPrice, bidPrice, askPrice, clampedPrice);
               success = ExecuteOrderWithRetry(tradeID, "Sell", qty, clampedPrice, symbol, sl, tp, comment);
            }
            else
            {
               // Bid >= pendingPrice: limit already crossed — execute at market
               PrintFormat("[EA Limit Crossed] Sell Limit at %.5f crossed by current Bid %.5f - executing as MARKET order", pendingPrice, bidPrice);
               success = ExecuteOrderWithRetry(tradeID, "Sell", qty, bidPrice, symbol, sl, tp, comment);
            }
         }
         else // SellStop
         {
            if(pendingPrice < bidPrice)
            {
               // Normal: price has not yet reached stop level
               success = ExecuteOrderWithRetry(tradeID, "SellStop", qty, pendingPrice, symbol, sl, tp, comment);
            }
            else if(pendingPrice <= askPrice)
            {
               // Price is inside the spread — clamp to Bid
               double clampedPrice = NormalizeDouble(bidPrice, digits);
               PrintFormat("[EA Spread Clamp] Sell Stop %.5f is inside spread [%.5f-%.5f] - clamped to Bid %.5f and executed as MARKET",
                  pendingPrice, bidPrice, askPrice, clampedPrice);
               success = ExecuteOrderWithRetry(tradeID, "Sell", qty, clampedPrice, symbol, sl, tp, comment);
            }
            else
            {
               // Price HAS CROSSED above ask — check TP / threshold
               if(tp > 0 && bidPrice <= tp)
               {
                  tradeCancelled = true;
                  cancelReason = StringFormat("Sell Bid %.5f already reached/exceeded TP %.5f - Price Lost", bidPrice, tp);
               }
               else
               {
                  double slippage = pendingPrice - bidPrice;
                  bool withinThreshold = false;
                  double pctConsumed = 0.0;

                  if(tp > 0 && (pendingPrice - tp) > 0)
                  {
                     pctConsumed = (slippage / (pendingPrice - tp)) * 100.0;
                     withinThreshold = (InpMaxTargetConsumedPercent <= 0) || (pctConsumed <= InpMaxTargetConsumedPercent);
                  }
                  else
                  {
                     double maxPtsDist = (InpPriceCrossedFallbackPoints > 0) ? (InpPriceCrossedFallbackPoints * point) : 0;
                     withinThreshold = (maxPtsDist <= 0) || (slippage <= maxPtsDist);
                  }

                  if(withinThreshold)
                  {
                     PrintFormat("[EA Price Crossed] Sell Stop at %.5f crossed by Bid %.5f (consumed %.1f%% of TP / %.1f pts) - Triggering MARKET order",
                        pendingPrice, bidPrice, pctConsumed, (point > 0 ? (slippage / point) : slippage));
                     success = ExecuteOrderWithRetry(tradeID, "Sell", qty, bidPrice, symbol, sl, tp, comment);
                  }
                  else
                  {
                     tradeCancelled = true;
                     cancelReason = StringFormat("Sell Stop at %.5f crossed by Bid %.5f beyond threshold (consumed %.1f%% > max %.1f%%) - Price Lost",
                        pendingPrice, bidPrice, pctConsumed, InpMaxTargetConsumedPercent);
                  }
               }
            }
         }
      }

      if(tradeCancelled)
      {
         double pendingPrice2 = (reqPrice > 0) ? reqPrice : price;
         PrintFormat("[EA Price Lost] %s trade cancelled: %s", symbol, cancelReason);
         if(InpDrawPriceLostLabel)
            DrawPriceLostLabel(symbol, "Price Lost", isBuy, pendingPrice2, price);
         SendACK(tradeID, "cancelled", 0, 0, symbol, 0, price, cancelReason);
         ExtTotalFailed++;
         ExtStatusText = "Price Lost: " + symbol;
         return;
      }
   }
   else
   {
      // Market order — use current Ask/Bid
      string mktType = isBuy ? "Buy" : "Sell";
      success = ExecuteOrderWithRetry(tradeID, mktType, qty, price, symbol, sl, tp, comment);
   }

   if(success)
   {
      ulong ticket = ExtTrade.ResultOrder();
      ulong deal   = ExtTrade.ResultDeal();
      double fillPrice = ExtTrade.ResultPrice();

      PrintFormat("[EA Success] Trade executed! Ticket: #%I64u | Symbol: %s | Magic: %I64u | Vol: %.2f | Price: %.5f",
         ticket, symbol, tradeMagic, qty, fillPrice);
      SendACK(tradeID, "success", ticket, deal, symbol, qty, fillPrice, "");
      ExtTotalExecuted++;
   }
   else
   {
      uint retcode   = ExtTrade.ResultRetcode();
      string errDesc = ExtTrade.ResultComment();
      PrintFormat("[EA Failure] All retry attempts exhausted. Last retcode=%u (%s)", retcode, errDesc);
      SendACK(tradeID, "error", 0, 0, symbol, qty, price, errDesc);
      ExtTotalFailed++;
   }
}

//+------------------------------------------------------------------+
//| Close Positions for Specific Strategy and Symbol                 |
//+------------------------------------------------------------------+
int ClosePositionsForStrategy(const string tradeID, const string symbol, const string strategy, ulong magicNumber)
{
   int closedCount = 0;
   string closedTicketsStr = "";
   string resolvedSym = "";
   if(StringLen(symbol) > 0 && symbol != "ALL" && symbol != "*" && symbol != "ANY")
      resolvedSym = ResolveSymbol(symbol);

   ExtTrade.SetDeviationInPoints(InpSlippage);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(ExtPosition.SelectByIndex(i))
      {
         ulong posMagic = ExtPosition.Magic();
         string posComment = ExtPosition.Comment();
         string posSymbol = ExtPosition.Symbol();

         if(IsStrategyMatch(posMagic, posComment, posSymbol, magicNumber, strategy, resolvedSym, symbol))
         {
            ulong ticket = ExtPosition.Ticket();
            if(ExtTrade.PositionClose(ticket, InpSlippage))
            {
               closedCount++;
               if(StringLen(closedTicketsStr) > 0) closedTicketsStr += ",";
               closedTicketsStr += IntegerToString(ticket);
            }
            else
            {
               PrintFormat("[EA Error] Failed to close position #%I64u: retcode=%u (%s)", ticket, ExtTrade.ResultRetcode(), ExtTrade.ResultComment());
            }
         }
      }
   }

   string symLabel = StringLen(symbol) > 0 ? symbol : "ALL";
   string stratLabel = StringLen(strategy) > 0 ? strategy : (magicNumber > 0 ? IntegerToString(magicNumber) : "Default");
   PrintFormat("[EA Close Positions] Closed %d positions for Strategy '%s' on %s (%s)", closedCount, stratLabel, symLabel, closedTicketsStr);

   if(closedCount > 0)
   {
      SendACK(tradeID, "success", 0, 0, symLabel, 0, 0, StringFormat("Closed %d positions (%s)", closedCount, closedTicketsStr));
      ExtTotalExecuted++;
   }
   else
   {
      SendACK(tradeID, "success", 0, 0, symLabel, 0, 0, "No matching positions found for strategy");
   }

   return closedCount;
}

//+------------------------------------------------------------------+
//| Cancel Pending Orders for Specific Strategy and Symbol           |
//+------------------------------------------------------------------+
int CancelOrdersForStrategy(const string tradeID, const string symbol, const string strategy, ulong magicNumber)
{
   int cancelledCount = 0;
   string cancelledTicketsStr = "";
   string resolvedSym = "";
   if(StringLen(symbol) > 0 && symbol != "ALL" && symbol != "*" && symbol != "ANY")
      resolvedSym = ResolveSymbol(symbol);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         ulong ordMagic = OrderGetInteger(ORDER_MAGIC);
         string ordComment = OrderGetString(ORDER_COMMENT);
         string ordSymbol = OrderGetString(ORDER_SYMBOL);

         if(IsStrategyMatch(ordMagic, ordComment, ordSymbol, magicNumber, strategy, resolvedSym, symbol))
         {
            if(ExtTrade.OrderDelete(ticket))
            {
               cancelledCount++;
               if(StringLen(cancelledTicketsStr) > 0) cancelledTicketsStr += ",";
               cancelledTicketsStr += IntegerToString(ticket);
            }
            else
            {
               PrintFormat("[EA Error] Failed to cancel order #%I64u: retcode=%u (%s)", ticket, ExtTrade.ResultRetcode(), ExtTrade.ResultComment());
            }
         }
      }
   }

   string symLabel = StringLen(symbol) > 0 ? symbol : "ALL";
   string stratLabel = StringLen(strategy) > 0 ? strategy : (magicNumber > 0 ? IntegerToString(magicNumber) : "Default");
   PrintFormat("[EA Cancel Orders] Cancelled %d orders for Strategy '%s' on %s (%s)", cancelledCount, stratLabel, symLabel, cancelledTicketsStr);

   if(cancelledCount > 0)
   {
      SendACK(tradeID, "success", 0, 0, symLabel, 0, 0, StringFormat("Cancelled %d orders (%s)", cancelledCount, cancelledTicketsStr));
      ExtTotalExecuted++;
   }
   else
   {
      SendACK(tradeID, "success", 0, 0, symLabel, 0, 0, "No matching orders found for strategy");
   }

   return cancelledCount;
}

//+------------------------------------------------------------------+
//| Send Execution ACK to Python Server                              |
//+------------------------------------------------------------------+
void SendACK(const string tradeID, const string status, ulong ticket, ulong deal, const string symbol, double vol, double price, const string errorMsg)
{
   string json = StringFormat(
      "{\"trade_id\":\"%s\",\"client_id\":\"%s\",\"status\":\"%s\",\"ticket\":%I64u,\"deal\":%I64u,\"symbol\":\"%s\",\"volume\":%.2f,\"price\":%.5f,\"error\":\"%s\"}",
      tradeID,
      ExtClientID,
      status,
      ticket,
      deal,
      symbol,
      vol,
      price,
      errorMsg
   );

   string response;
   int code;
   HttpRequest("POST", "/api/v1/trades/ack", json, response, code);
}

//+------------------------------------------------------------------+
//| Symbol Resolution & Mapping                                      |
//+------------------------------------------------------------------+
string ResolveSymbol(const string rawSymbol)
{
   if(StringLen(rawSymbol) == 0) return "";

   string clean = rawSymbol;
   StringToUpper(clean);
   int pos = StringFind(clean, ":");
   if(pos >= 0)
      clean = StringSubstr(clean, pos + 1);

   // Check Symbol Map input string (e.g. "BTCUSD:BTCUSD.a,XAUUSD:GOLD")
   string mapped = MapSymbolFromCSV(clean);

   if(SymbolSelect(mapped, true)) return mapped;

   // Alternate matching
   string alts[6];
   alts[0] = mapped;
   alts[1] = mapped + ".a";
   alts[2] = mapped + "m";
   alts[3] = mapped + "_i";
   alts[4] = mapped + ".ecn";
   alts[5] = mapped + ".pro";

   for(int i = 0; i < 6; i++)
   {
      if(SymbolSelect(alts[i], true))
         return alts[i];
   }

   return "";
}

string MapSymbolFromCSV(const string symbol)
{
   if(StringLen(InpSymbolMap) == 0) return symbol;

   string pairs[];
   ushort sepComma = StringGetCharacter(",", 0);
   ushort sepColon = StringGetCharacter(":", 0);

   int total = StringSplit(InpSymbolMap, sepComma, pairs);
   for(int i = 0; i < total; i++)
   {
      string kv[];
      if(StringSplit(pairs[i], sepColon, kv) == 2)
      {
         string k = kv[0];
         string v = kv[1];
         StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);
         StringTrimLeft(v); StringTrimRight(v);

         if(k == symbol) return v;
      }
   }
   return symbol;
}

//+------------------------------------------------------------------+
//| Simple Lightweight JSON Helpers                                  |
//+------------------------------------------------------------------+
string JsonExtractString(const string json, const string key)
{
   string searchPattern = "\"" + key + "\"";
   int pos = StringFind(json, searchPattern);
   if(pos < 0) return "";

   int colonPos = StringFind(json, ":", pos + StringLen(searchPattern));
   if(colonPos < 0) return "";

   int startVal = colonPos + 1;
   while(startVal < StringLen(json) && (StringGetCharacter(json, startVal) == ' ' || StringGetCharacter(json, startVal) == '"' || StringGetCharacter(json, startVal) == '\t'))
      startVal++;

   int endVal = startVal;
   while(endVal < StringLen(json) && StringGetCharacter(json, endVal) != '"' && StringGetCharacter(json, endVal) != ',' && StringGetCharacter(json, endVal) != '}' && StringGetCharacter(json, endVal) != '\r' && StringGetCharacter(json, endVal) != '\n')
      endVal++;

   string val = StringSubstr(json, startVal, endVal - startVal);
   StringTrimLeft(val);
   StringTrimRight(val);
   return val;
}

double JsonExtractDouble(const string json, const string key)
{
   string strVal = JsonExtractString(json, key);
   if(StringLen(strVal) == 0) return 0.0;
   return StringToDouble(strVal);
}

//+------------------------------------------------------------------+
//| On-Chart Status Dashboard Panel                                  |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   string prefix = "TV_Relay_";
   ObjectCreate(0, prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_XSIZE, 320);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_YSIZE, 140);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_BGCOLOR, InpPanelBgColor);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);

   CreateLabel(prefix + "Title", "TradingView Relay EA (Multi-Client)", 30, 40, C'0,180,255', 10, true);
   CreateLabel(prefix + "ID", "Client ID: " + ExtClientID, 30, 62, InpTextColor, 9, false);
   CreateLabel(prefix + "Status", "Status: " + ExtStatusText, 30, 80, InpTextColor, 9, false);
   CreateLabel(prefix + "Stats", "Executed: 0 | Failed: 0 | Ping: 0 ms", 30, 98, InpTextColor, 9, false);
   CreateLabel(prefix + "Server", "Server: " + InpServerURL, 30, 116, C'150,160,175', 8, false);
   ChartRedraw();
}

void CreateLabel(string name, string text, int x, int y, color clr, int fontSize, bool bold)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
}

void UpdateDashboard()
{
   string prefix = "TV_Relay_";
   ObjectSetString(0, prefix + "Status", OBJPROP_TEXT, "Status: " + ExtStatusText);
   ObjectSetString(0, prefix + "Stats", OBJPROP_TEXT, StringFormat("Executed: %d | Failed: %d | Ping: %d ms", ExtTotalExecuted, ExtTotalFailed, ExtLastPingMS));
   ChartRedraw();
}

void DestroyDashboard()
{
   string prefix = "TV_Relay_";
   ObjectsDeleteAll(0, prefix);
   ChartRedraw();
}

