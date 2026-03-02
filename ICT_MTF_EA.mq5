#property strict
#property version   "1.00"
#property description "Multi-timeframe ICT EA for H1 execution with D1 bias and H4 zone context"

#include <Trade/Trade.mqh>

CTrade trade;

enum BiasState
{
   BIAS_NONE = 0,
   BIAS_BULLISH_CHOCH,
   BIAS_BEARISH_CHOCH,
   BIAS_BULLISH_FULL,
   BIAS_BEARISH_FULL
};

enum ZoneType
{
   ZONE_OB = 0,
   ZONE_FVG
};

struct PriceZone
{
   ZoneType type;
   int      direction; // 1 bullish, -1 bearish
   double   high;
   double   low;
   double   mid;
   datetime created;
   bool     mitigated;
};

struct PDArray
{
   string   name;
   int      rank;
   int      direction;
   double   high;
   double   low;
   double   mid;
   datetime created;
};

input double InpRiskDollars = 39.0;
input int    InpLondonStartUTC = 7;
input int    InpLondonEndUTC   = 12;
input int    InpNewYorkStartUTC = 13;
input int    InpNewYorkEndUTC   = 17;
input double InpFVGMitigationPercent = 50.0;
input int    InpOrderExpiryCandlesH1 = 3;

BiasState g_bias = BIAS_NONE;
double    g_chochObHigh = 0.0;
double    g_chochObLow  = 0.0;
bool      g_chochObTouched = false;
datetime  g_lastD1Close = 0;
datetime  g_lastH4Close = 0;
datetime  g_lastH1Close = 0;

PriceZone g_h4Zones[];

string BiasToString(BiasState b)
{
   switch(b)
   {
      case BIAS_BULLISH_CHOCH: return "Bullish CHoCH";
      case BIAS_BEARISH_CHOCH: return "Bearish CHoCH";
      case BIAS_BULLISH_FULL:  return "Bullish FULL";
      case BIAS_BEARISH_FULL:  return "Bearish FULL";
      default: return "NONE";
   }
}

bool IsBullishBias() { return g_bias == BIAS_BULLISH_CHOCH || g_bias == BIAS_BULLISH_FULL; }
bool IsBearishBias() { return g_bias == BIAS_BEARISH_CHOCH || g_bias == BIAS_BEARISH_FULL; }
bool IsFullTPMode()  { return g_bias == BIAS_BULLISH_FULL || g_bias == BIAS_BEARISH_FULL; }

bool IsSessionAllowed()
{
   datetime now = TimeGMT();
   MqlDateTime t;
   TimeToStruct(now, t);
   int h = t.hour;

   bool london = (h >= InpLondonStartUTC && h < InpLondonEndUTC);
   bool ny = (h >= InpNewYorkStartUTC && h < InpNewYorkEndUTC);
   return (london || ny);
}

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastClose)
{
   datetime times[2];
   if(CopyTime(_Symbol, tf, 0, 2, times) < 2)
      return false;

   datetime closedBarTime = times[1];
   if(closedBarTime != lastClose)
   {
      lastClose = closedBarTime;
      return true;
   }
   return false;
}

void DetectD1BiasOnClose()
{
   double o1 = iOpen(_Symbol, PERIOD_D1, 1);
   double c1 = iClose(_Symbol, PERIOD_D1, 1);
   double h1 = iHigh(_Symbol, PERIOD_D1, 1);
   double l1 = iLow(_Symbol, PERIOD_D1, 1);

   double o2 = iOpen(_Symbol, PERIOD_D1, 2);
   double c2 = iClose(_Symbol, PERIOD_D1, 2);
   double h2 = iHigh(_Symbol, PERIOD_D1, 2);
   double l2 = iLow(_Symbol, PERIOD_D1, 2);

   bool candle2Bull = (c2 > o2);
   bool candle2Bear = (c2 < o2);
   bool candle1Bull = (c1 > o1);
   bool candle1Bear = (c1 < o1);

   if(candle2Bull && candle1Bear && c1 < l2)
   {
      g_bias = BIAS_BEARISH_CHOCH;
      g_chochObHigh = h2;
      g_chochObLow = l2;
      g_chochObTouched = false;
      PrintFormat("D1 CHoCH detected: Bearish. OB range=[%.5f, %.5f]", g_chochObLow, g_chochObHigh);
      return;
   }

   if(candle2Bear && candle1Bull && c1 > h2)
   {
      g_bias = BIAS_BULLISH_CHOCH;
      g_chochObHigh = h2;
      g_chochObLow = l2;
      g_chochObTouched = false;
      PrintFormat("D1 CHoCH detected: Bullish. OB range=[%.5f, %.5f]", g_chochObLow, g_chochObHigh);
      return;
   }

   if(g_bias == BIAS_BEARISH_CHOCH)
   {
      if(h1 >= g_chochObLow && l1 <= g_chochObHigh)
         g_chochObTouched = true;
      if(g_chochObTouched && c1 < g_chochObLow)
      {
         g_bias = BIAS_BEARISH_FULL;
         Print("D1 bearish FULL confirmation achieved (OB flip confirmed).");
      }
   }
   else if(g_bias == BIAS_BULLISH_CHOCH)
   {
      if(h1 >= g_chochObLow && l1 <= g_chochObHigh)
         g_chochObTouched = true;
      if(g_chochObTouched && c1 > g_chochObHigh)
      {
         g_bias = BIAS_BULLISH_FULL;
         Print("D1 bullish FULL confirmation achieved (OB flip confirmed).");
      }
   }
}

void AddH4Zone(ZoneType type, int direction, double low, double high, datetime created)
{
   PriceZone z;
   z.type = type;
   z.direction = direction;
   z.low = MathMin(low, high);
   z.high = MathMax(low, high);
   z.mid = z.low + (z.high - z.low) * (InpFVGMitigationPercent / 100.0);
   z.created = created;
   z.mitigated = false;

   int n = ArraySize(g_h4Zones);
   ArrayResize(g_h4Zones, n + 1);
   g_h4Zones[n] = z;

   PrintFormat("H4 Zone added: %s dir=%d low=%.5f high=%.5f",
               (type == ZONE_OB ? "OB" : "FVG"), direction, z.low, z.high);
}

void RemoveMitigatedH4Zones(double barHigh, double barLow)
{
   for(int i = ArraySize(g_h4Zones) - 1; i >= 0; --i)
   {
      if(g_h4Zones[i].mitigated)
         continue;

      if(barHigh >= g_h4Zones[i].mid && barLow <= g_h4Zones[i].mid)
      {
         g_h4Zones[i].mitigated = true;
         PrintFormat("H4 Zone mitigated: index=%d type=%d", i, (int)g_h4Zones[i].type);
      }

      if(g_h4Zones[i].mitigated)
      {
         for(int j = i; j < ArraySize(g_h4Zones)-1; ++j)
            g_h4Zones[j] = g_h4Zones[j+1];
         ArrayResize(g_h4Zones, ArraySize(g_h4Zones)-1);
      }
   }
}

void IdentifyH4ZonesOnClose()
{
   if(g_bias == BIAS_NONE)
      return;

   double o1 = iOpen(_Symbol, PERIOD_H4, 1);
   double c1 = iClose(_Symbol, PERIOD_H4, 1);
   double h1 = iHigh(_Symbol, PERIOD_H4, 1);
   double l1 = iLow(_Symbol, PERIOD_H4, 1);

   double o2 = iOpen(_Symbol, PERIOD_H4, 2);
   double c2 = iClose(_Symbol, PERIOD_H4, 2);
   double h2 = iHigh(_Symbol, PERIOD_H4, 2);
   double l2 = iLow(_Symbol, PERIOD_H4, 2);

   double h3 = iHigh(_Symbol, PERIOD_H4, 3);
   double l3 = iLow(_Symbol, PERIOD_H4, 3);

   datetime t1 = iTime(_Symbol, PERIOD_H4, 1);

   // OB detection
   if(IsBearishBias())
   {
      if(c2 > o2 && c1 < o1 && c1 < l2)
         AddH4Zone(ZONE_OB, -1, l2, h2, t1);
   }
   else if(IsBullishBias())
   {
      if(c2 < o2 && c1 > o1 && c1 > h2)
         AddH4Zone(ZONE_OB, 1, l2, h2, t1);
   }

   // FVG detection (3-candle imbalance)
   // Bullish FVG: candle3 high < candle1 low (oldest high doesn't overlap newest low)
   if(IsBullishBias() && h3 < l1)
      AddH4Zone(ZONE_FVG, 1, h3, l1, t1);

   // Bearish FVG: candle3 low > candle1 high
   if(IsBearishBias() && l3 > h1)
      AddH4Zone(ZONE_FVG, -1, h1, l3, t1);

   RemoveMitigatedH4Zones(h1, l1);
}

bool InAnyActiveH4Zone(double price, PriceZone &matched)
{
   for(int i = 0; i < ArraySize(g_h4Zones); ++i)
   {
      if(!g_h4Zones[i].mitigated && price >= g_h4Zones[i].low && price <= g_h4Zones[i].high)
      {
         matched = g_h4Zones[i];
         return true;
      }
   }
   return false;
}

bool DetectStandardFVGH1(int shift, int direction, PDArray &pd)
{
   double h3 = iHigh(_Symbol, PERIOD_H1, shift + 2);
   double l3 = iLow(_Symbol, PERIOD_H1, shift + 2);
   double h1 = iHigh(_Symbol, PERIOD_H1, shift);
   double l1 = iLow(_Symbol, PERIOD_H1, shift);

   if(direction == 1 && h3 < l1)
   {
      pd.name = "Standard FVG";
      pd.rank = 3;
      pd.direction = 1;
      pd.low = h3;
      pd.high = l1;
      pd.mid = (pd.low + pd.high) * 0.5;
      pd.created = iTime(_Symbol, PERIOD_H1, shift);
      return true;
   }
   if(direction == -1 && l3 > h1)
   {
      pd.name = "Standard FVG";
      pd.rank = 3;
      pd.direction = -1;
      pd.low = h1;
      pd.high = l3;
      pd.mid = (pd.low + pd.high) * 0.5;
      pd.created = iTime(_Symbol, PERIOD_H1, shift);
      return true;
   }
   return false;
}

bool DetectOBH1(int shift, int direction, PDArray &pd)
{
   double o1 = iOpen(_Symbol, PERIOD_H1, shift);
   double c1 = iClose(_Symbol, PERIOD_H1, shift);
   double h1 = iHigh(_Symbol, PERIOD_H1, shift);
   double l1 = iLow(_Symbol, PERIOD_H1, shift);

   double o2 = iOpen(_Symbol, PERIOD_H1, shift + 1);
   double c2 = iClose(_Symbol, PERIOD_H1, shift + 1);
   double h2 = iHigh(_Symbol, PERIOD_H1, shift + 1);
   double l2 = iLow(_Symbol, PERIOD_H1, shift + 1);

   if(direction == 1 && c2 < o2 && c1 > o1 && c1 > h2)
   {
      pd.name = "Order Block";
      pd.rank = 4;
      pd.direction = 1;
      pd.low = l2;
      pd.high = h2;
      pd.mid = (pd.low + pd.high) * 0.5;
      pd.created = iTime(_Symbol, PERIOD_H1, shift);
      return true;
   }
   if(direction == -1 && c2 > o2 && c1 < o1 && c1 < l2)
   {
      pd.name = "Order Block";
      pd.rank = 4;
      pd.direction = -1;
      pd.low = l2;
      pd.high = h2;
      pd.mid = (pd.low + pd.high) * 0.5;
      pd.created = iTime(_Symbol, PERIOD_H1, shift);
      return true;
   }
   return false;
}

bool DetectDoubleFVG(int direction, PDArray &pd)
{
   PDArray a, b;
   if(!DetectStandardFVGH1(1, direction, a)) return false;
   if(!DetectStandardFVGH1(2, direction, b)) return false;

   double betweenHigh = iHigh(_Symbol, PERIOD_H1, 1);
   double betweenLow = iLow(_Symbol, PERIOD_H1, 1);
   if(direction == 1 && betweenLow <= a.mid) return false;
   if(direction == -1 && betweenHigh >= a.mid) return false;

   pd.name = "Double FVG";
   pd.rank = 1;
   pd.direction = direction;
   pd.low = MathMin(a.low, b.low);
   pd.high = MathMax(a.high, b.high);
   pd.mid = (pd.low + pd.high) * 0.5;
   pd.created = iTime(_Symbol, PERIOD_H1, 1);
   return true;
}

bool DetectBreakerBlock(int direction, PDArray &pd)
{
   PDArray ob, fvg;
   if(!DetectOBH1(2, direction, ob)) return false;
   if(!DetectStandardFVGH1(1, direction, fvg)) return false;

   double open1 = iOpen(_Symbol, PERIOD_H1, 1);
   bool gapBeyond = (direction == 1) ? (open1 > ob.high) : (open1 < ob.low);
   if(!gapBeyond)
      return false;

   pd.name = "Breaker Block";
   pd.rank = 2;
   pd.direction = direction;
   pd.low = MathMin(ob.low, fvg.low);
   pd.high = MathMax(ob.high, fvg.high);
   pd.mid = (pd.low + pd.high) * 0.5;
   pd.created = iTime(_Symbol, PERIOD_H1, 1);
   return true;
}

bool BuildBestPDArray(int direction, PriceZone &zone, PDArray &best)
{
   PDArray candidates[];
   ArrayResize(candidates, 0);

   PDArray pd;
   if(DetectDoubleFVG(direction, pd))
   {
      int n = ArraySize(candidates); ArrayResize(candidates, n + 1); candidates[n] = pd;
   }
   if(DetectBreakerBlock(direction, pd))
   {
      int n = ArraySize(candidates); ArrayResize(candidates, n + 1); candidates[n] = pd;
   }
   if(DetectStandardFVGH1(1, direction, pd))
   {
      int n = ArraySize(candidates); ArrayResize(candidates, n + 1); candidates[n] = pd;
   }
   if(DetectOBH1(1, direction, pd))
   {
      int n = ArraySize(candidates); ArrayResize(candidates, n + 1); candidates[n] = pd;
   }

   if(ArraySize(candidates) == 0)
      return false;

   // Confluence elevation (Rank 5 as strongest override per specification)
   for(int i = 0; i < ArraySize(candidates); ++i)
   {
      for(int j = i + 1; j < ArraySize(candidates); ++j)
      {
         double overlapLow = MathMax(candidates[i].low, candidates[j].low);
         double overlapHigh = MathMin(candidates[i].high, candidates[j].high);
         double dist = MathAbs(candidates[i].mid - candidates[j].mid);
         double ref = MathMax(candidates[i].high - candidates[i].low, candidates[j].high - candidates[j].low);
         if(overlapLow <= overlapHigh || dist <= ref * 0.1)
         {
            PDArray c;
            c.name = "Confluence";
            c.rank = 5;
            c.direction = direction;
            c.low = MathMin(candidates[i].low, candidates[j].low);
            c.high = MathMax(candidates[i].high, candidates[j].high);
            c.mid = (c.low + c.high) * 0.5;
            c.created = TimeCurrent();
            best = c;
            return (best.mid >= zone.low && best.mid <= zone.high);
         }
      }
   }

   int bestIdx = 0;
   int bestScore = -1;
   for(int i = 0; i < ArraySize(candidates); ++i)
   {
      int score = (candidates[i].rank == 1 ? 4 : (candidates[i].rank == 2 ? 3 : (candidates[i].rank == 3 ? 2 : 1)));
      if(score > bestScore)
      {
         bestScore = score;
         bestIdx = i;
      }
   }

   best = candidates[bestIdx];
   return (best.mid >= zone.low && best.mid <= zone.high);
}

bool HasOpenExposure()
{
   if(PositionSelect(_Symbol))
      return true;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

double FindSwingSL(int direction)
{
   if(direction == 1)
   {
      double low = DBL_MAX;
      double candleRange = 0.0;
      for(int i = 2; i <= 15; ++i)
      {
         double li = iLow(_Symbol, PERIOD_H1, i);
         if(li < low)
         {
            low = li;
            candleRange = iHigh(_Symbol, PERIOD_H1, i) - li;
         }
      }
      return low - candleRange * 0.1;
   }
   else
   {
      double high = -DBL_MAX;
      double candleRange = 0.0;
      for(int i = 2; i <= 15; ++i)
      {
         double hi = iHigh(_Symbol, PERIOD_H1, i);
         if(hi > high)
         {
            high = hi;
            candleRange = hi - iLow(_Symbol, PERIOD_H1, i);
         }
      }
      return high + candleRange * 0.1;
   }
}

double FindD1LiquidityTarget(int direction)
{
   if(direction == 1)
   {
      double eqHigh = iHigh(_Symbol, PERIOD_D1, 1);
      for(int i = 2; i <= 40; ++i)
      {
         double h = iHigh(_Symbol, PERIOD_D1, i);
         if(MathAbs(h - eqHigh) <= (_Point * 20))
            return MathMax(h, eqHigh);
         if(h > eqHigh) eqHigh = h;
      }
      return eqHigh;
   }
   else
   {
      double eqLow = iLow(_Symbol, PERIOD_D1, 1);
      for(int i = 2; i <= 40; ++i)
      {
         double l = iLow(_Symbol, PERIOD_D1, i);
         if(MathAbs(l - eqLow) <= (_Point * 20))
            return MathMin(l, eqLow);
         if(l < eqLow) eqLow = l;
      }
      return eqLow;
   }
}

double FindNearestTroubleArea(int direction, double entry)
{
   double nearest = 0.0;
   bool found = false;

   // H4 trouble areas from unmitigated zones
   for(int i = 0; i < ArraySize(g_h4Zones); ++i)
   {
      if(g_h4Zones[i].mitigated)
         continue;
      double edge = (direction == 1) ? g_h4Zones[i].low : g_h4Zones[i].high;
      if((direction == 1 && edge > entry) || (direction == -1 && edge < entry))
      {
         if(!found || (direction == 1 && edge < nearest) || (direction == -1 && edge > nearest))
         {
            nearest = edge;
            found = true;
         }
      }
   }

   // D1 swing liquidity as fallback trouble area
   for(int i = 2; i <= 20; ++i)
   {
      double edge = (direction == 1) ? iHigh(_Symbol, PERIOD_D1, i) : iLow(_Symbol, PERIOD_D1, i);
      if((direction == 1 && edge > entry) || (direction == -1 && edge < entry))
      {
         if(!found || (direction == 1 && edge < nearest) || (direction == -1 && edge > nearest))
         {
            nearest = edge;
            found = true;
         }
      }
   }

   return found ? nearest : 0.0;
}

double CalculateVolumeByRisk(double entry, double sl)
{
   double riskPerLot = MathAbs(entry - sl) / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)
                       * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(riskPerLot <= 0.0)
      return 0.0;

   double vol = InpRiskDollars / riskPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   vol = MathMax(minLot, MathMin(maxLot, vol));
   vol = MathFloor(vol / step) * step;
   return NormalizeDouble(vol, 2);
}

void TryPlaceEntryOnH1Close()
{
   if(g_bias == BIAS_NONE)
      return;
   if(HasOpenExposure())
      return;
   if(!IsSessionAllowed())
   {
      Print("Entry blocked: outside London/NY session.");
      return;
   }

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   PriceZone zone;
   if(!InAnyActiveH4Zone(close1, zone))
   {
      Print("No active H4 zone contains the H1 close.");
      return;
   }

   int direction = IsBullishBias() ? 1 : -1;
   PDArray pd;
   if(!BuildBestPDArray(direction, zone, pd))
   {
      Print("No valid H1 PD array found within active H4 zone.");
      return;
   }

   double entry = pd.mid;
   double sl = FindSwingSL(direction);
   double tpModeLiquidity = FindD1LiquidityTarget(direction);
   double trouble = FindNearestTroubleArea(direction, entry);

   string tpMode = "conservative";
   double tp = trouble;

   if(IsFullTPMode())
   {
      if(trouble == 0.0 || (direction == 1 && tpModeLiquidity < trouble) || (direction == -1 && tpModeLiquidity > trouble))
      {
         tp = tpModeLiquidity;
         tpMode = "full";
      }
      else
      {
         tp = trouble;
         tpMode = "conservative";
      }
   }

   if(tp == 0.0)
   {
      Print("TP calculation failed: no trouble area or D1 liquidity found.");
      return;
   }

   double volume = CalculateVolumeByRisk(entry, sl);
   if(volume <= 0.0)
   {
      Print("Volume calculation failed.");
      return;
   }

   datetime expiration = TimeCurrent() + (InpOrderExpiryCandlesH1 * 3600);
   string zoneName = (zone.type == ZONE_OB ? "H4_OB" : "H4_FVG");
   string comment = StringFormat("PD:%s|Bias:%s|TP:%s|Zone:%s", pd.name, BiasToString(g_bias), tpMode, zoneName);

   bool sent = false;
   if(direction == 1)
      sent = trade.BuyLimit(volume, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comment);
   else
      sent = trade.SellLimit(volume, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comment);

   if(sent)
   {
      PrintFormat("Order placed: %s dir=%d vol=%.2f entry=%.5f sl=%.5f tp=%.5f exp=%s",
                  pd.name, direction, volume, entry, sl, tp, TimeToString(expiration));
   }
   else
   {
      PrintFormat("Order placement failed. Retcode=%d", trade.ResultRetcode());
   }
}

int OnInit()
{
   Print("ICT MTF EA initialized.");
   ArrayResize(g_h4Zones, 0);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(IsNewBar(PERIOD_D1, g_lastD1Close))
      DetectD1BiasOnClose();

   if(IsNewBar(PERIOD_H4, g_lastH4Close))
      IdentifyH4ZonesOnClose();

   if(IsNewBar(PERIOD_H1, g_lastH1Close))
      TryPlaceEntryOnH1Close();
}
