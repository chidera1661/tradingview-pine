#property strict
#property version   "1.00"
#property description "MT5 EA: Multi-timeframe ICT strategy with D1 bias, H4 zones, H1 fractal entries"

#include <Trade/Trade.mqh>

//---- User inputs
input double RiskDollars = 39.0;
input int LondonStartUTC = 7;
input int LondonEndUTC = 12;
input int NYStartUTC = 13;
input int NYEndUTC = 20;
input double FVGMitigationPercent = 50.0;
input int OrderExpiryCandles = 3;
input int ImpulseCandles = 2;
input int SwingLookback = 3;
input int D1Lookback = 20;

//---- Strategy enums
enum BiasState
{
   NEUTRAL = 0,
   BEARISH_CHOCH,
   BEARISH_CONFIRMED,
   BULLISH_CHOCH,
   BULLISH_CONFIRMED
};

enum TPMode
{
   TP_CONSERVATIVE = 0,
   TP_FULL
};

enum ZoneType
{
   ZONE_OB = 0,
   ZONE_FVG
};

enum Direction
{
   DIR_BULLISH = 0,
   DIR_BEARISH
};

enum PDType
{
   PD_DOUBLE_FVG = 0,
   PD_BREAKER,
   PD_STANDARD_FVG,
   PD_OB,
   PD_CONFLUENCE
};

struct H4Zone
{
   ZoneType type;
   Direction direction;
   double high;
   double low;
   datetime formationTime;
   bool consumed;
   datetime consumedTime;
};

struct PDArray
{
   int rank;
   PDType type;
   Direction direction;
   double high;
   double low;
   double midpoint;
   datetime formationTime;
   bool valid;
};

CTrade trade;

BiasState g_bias = NEUTRAL;
TPMode g_tpMode = TP_CONSERVATIVE;
double g_biasObHigh = 0.0;
double g_biasObLow = 0.0;
datetime g_biasObTime = 0;
bool g_biasReturnedToOB = false;

H4Zone g_zones[];

// Last processed closed bar times per TF
datetime g_lastH1Close = 0;
datetime g_lastH4Close = 0;
datetime g_lastD1Close = 0;

//-------------------------------------------------------------------------------------------------
// Utility: instrument-specific pip value used for every distance rule in this EA.
//-------------------------------------------------------------------------------------------------
double PipValueForSymbol()
{
   string s = _Symbol;
   if(s == "GBPUSD") return 0.00010;
   if(s == "NDX100") return 1.0;
   if(s == "USOIL")  return 0.01;
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//-------------------------------------------------------------------------------------------------
// Utility: fixed 10-pip equivalent buffer per specification.
//-------------------------------------------------------------------------------------------------
double TenPipBuffer()
{
   return PipValueForSymbol() * 10.0;
}

//-------------------------------------------------------------------------------------------------
// Utility: check if symbol currently has any active position (one trade max per symbol).
//-------------------------------------------------------------------------------------------------
bool HasActivePositionForSymbol(const string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol)
            return true;
      }
   }
   return false;
}

//-------------------------------------------------------------------------------------------------
// Utility: UTC session gate. Valid only 07:00..20:59 UTC inclusive by default input ranges.
//-------------------------------------------------------------------------------------------------
bool IsSessionValid()
{
   MqlDateTime t;
   TimeToStruct(TimeGMT(), t);
   int h = t.hour;
   bool london = (h >= LondonStartUTC && h <= LondonEndUTC);
   bool ny = (h >= NYStartUTC && h <= NYEndUTC);
   return (london || ny);
}

//-------------------------------------------------------------------------------------------------
// Utility: generic 3-left/3-right (or SwingLookback) swing high check on any timeframe.
//-------------------------------------------------------------------------------------------------
bool IsSwingHigh(const ENUM_TIMEFRAMES tf, const int shift, const int leftRight)
{
   double candidate = iHigh(_Symbol, tf, shift);
   if(candidate == 0.0) return false;
   for(int i = 1; i <= leftRight; i++)
   {
      if(iHigh(_Symbol, tf, shift + i) >= candidate) return false;
      if(iHigh(_Symbol, tf, shift - i) >= candidate) return false;
   }
   return true;
}

//-------------------------------------------------------------------------------------------------
// Utility: generic 3-left/3-right (or SwingLookback) swing low check on any timeframe.
//-------------------------------------------------------------------------------------------------
bool IsSwingLow(const ENUM_TIMEFRAMES tf, const int shift, const int leftRight)
{
   double candidate = iLow(_Symbol, tf, shift);
   if(candidate == 0.0) return false;
   for(int i = 1; i <= leftRight; i++)
   {
      if(iLow(_Symbol, tf, shift + i) <= candidate) return false;
      if(iLow(_Symbol, tf, shift - i) <= candidate) return false;
   }
   return true;
}

//-------------------------------------------------------------------------------------------------
// DetectD1Bias
// Purpose: handles D1 CHoCH detection and full confirmation upgrade logic using closed candles only.
// Inputs: none (uses _Symbol D1 history with shift 1 as latest closed candle).
// Logic: identifies bullish/bearish CHoCH, stores OB reference range, upgrades to confirmed on close break
//        after return into OB range. Opposite CHoCH invalidates current bias immediately.
//-------------------------------------------------------------------------------------------------
void DetectD1Bias()
{
   const int scan = MathMax(D1Lookback + 20, 60);

   // Step 1: find latest CHoCH event in recent history.
   BiasState latest = NEUTRAL;
   double latestOBHigh = 0.0, latestOBLow = 0.0;
   datetime latestOBTime = 0;

   for(int s = scan; s >= 2; --s)
   {
      double o1 = iOpen(_Symbol, PERIOD_D1, s);
      double c1 = iClose(_Symbol, PERIOD_D1, s);
      double h1 = iHigh(_Symbol, PERIOD_D1, s);
      double l1 = iLow(_Symbol, PERIOD_D1, s);

      double o0 = iOpen(_Symbol, PERIOD_D1, s - 1);
      double c0 = iClose(_Symbol, PERIOD_D1, s - 1);
      double h0 = iHigh(_Symbol, PERIOD_D1, s - 1);
      double l0 = iLow(_Symbol, PERIOD_D1, s - 1);
      datetime t0 = iTime(_Symbol, PERIOD_D1, s - 1);

      // Bearish CHoCH: last bullish before bearish close below bullish low.
      if(c1 > o1 && c0 < o0 && c0 < l1)
      {
         latest = BEARISH_CHOCH;
         latestOBHigh = h0;
         latestOBLow = l0;
         latestOBTime = t0;
      }

      // Bullish CHoCH: last bearish before bullish close above bearish high.
      if(c1 < o1 && c0 > o0 && c0 > h1)
      {
         latest = BULLISH_CHOCH;
         latestOBHigh = h0;
         latestOBLow = l0;
         latestOBTime = t0;
      }
   }

   if(latest != NEUTRAL)
   {
      // Opposite CHoCH or first detection resets state into CHoCH stage.
      if(g_bias == NEUTRAL ||
         (latest == BEARISH_CHOCH && (g_bias == BULLISH_CHOCH || g_bias == BULLISH_CONFIRMED)) ||
         (latest == BULLISH_CHOCH && (g_bias == BEARISH_CHOCH || g_bias == BEARISH_CONFIRMED)) ||
         latestOBTime != g_biasObTime)
      {
         g_bias = latest;
         g_tpMode = TP_CONSERVATIVE;
         g_biasObHigh = latestOBHigh;
         g_biasObLow = latestOBLow;
         g_biasObTime = latestOBTime;
         g_biasReturnedToOB = false;
      }
   }

   // Step 2: full confirmation check after return into OB.
   double c = iClose(_Symbol, PERIOD_D1, 1);
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);

   if(g_bias == BEARISH_CHOCH)
   {
      if(h >= g_biasObLow && l <= g_biasObHigh)
         g_biasReturnedToOB = true;
      if(g_biasReturnedToOB && c < g_biasObLow)
      {
         g_bias = BEARISH_CONFIRMED;
         g_tpMode = TP_FULL;
      }
   }
   else if(g_bias == BULLISH_CHOCH)
   {
      if(h >= g_biasObLow && l <= g_biasObHigh)
         g_biasReturnedToOB = true;
      if(g_biasReturnedToOB && c > g_biasObHigh)
      {
         g_bias = BULLISH_CONFIRMED;
         g_tpMode = TP_FULL;
      }
   }
}

//-------------------------------------------------------------------------------------------------
// Utility: overlap between two price ranges.
//-------------------------------------------------------------------------------------------------
bool RangesOverlap(const double aLow, const double aHigh, const double bLow, const double bHigh)
{
   return !(aHigh < bLow || bHigh < aLow);
}

bool ZoneExists(const ZoneType zt, const Direction dir, const datetime t)
{
   for(int i = 0; i < ArraySize(g_zones); i++)
   {
      if(g_zones[i].type == zt && g_zones[i].direction == dir && g_zones[i].formationTime == t)
         return true;
   }
   return false;
}

void AddZone(const ZoneType type, const Direction direction, const double high, const double low, const datetime formation)
{
   if(high <= low) return;
   if(ZoneExists(type, direction, formation)) return;

   H4Zone z;
   z.type = type;
   z.direction = direction;
   z.high = high;
   z.low = low;
   z.formationTime = formation;
   z.consumed = false;
   z.consumedTime = 0;

   int n = ArraySize(g_zones);
   ArrayResize(g_zones, n + 1);
   g_zones[n] = z;
}

//-------------------------------------------------------------------------------------------------
// IdentifyH4Zones
// Purpose: scan closed H4 candles and store unmitigated OB/FVG zones aligned with current D1 bias.
// Inputs: none. Uses latest H4 close data and current global bias state.
// Logic: direction-filtered detection only; opposing zones ignored by design.
//-------------------------------------------------------------------------------------------------
void IdentifyH4Zones()
{
   if(g_bias == NEUTRAL) return;

   Direction dir = (g_bias == BEARISH_CHOCH || g_bias == BEARISH_CONFIRMED) ? DIR_BEARISH : DIR_BULLISH;

   // Scan a moderate window on each H4 close so newly formed arrays are captured.
   const int maxScan = 100;
   for(int s = maxScan; s >= 3; --s)
   {
      datetime t = iTime(_Symbol, PERIOD_H4, s - 1);
      if(t == 0) continue;

      // FVG detection (3-candle pattern)
      double c1High = iHigh(_Symbol, PERIOD_H4, s + 1);
      double c1Low  = iLow(_Symbol, PERIOD_H4, s + 1);
      double c3High = iHigh(_Symbol, PERIOD_H4, s - 1);
      double c3Low  = iLow(_Symbol, PERIOD_H4, s - 1);

      if(dir == DIR_BEARISH)
      {
         if(c1Low > c3High)
            AddZone(ZONE_FVG, DIR_BEARISH, c1Low, c3High, t);
      }
      else
      {
         if(c1High < c3Low)
            AddZone(ZONE_FVG, DIR_BULLISH, c3Low, c1High, t);
      }

      // OB detection: last opposite candle before ImpulseCandles consecutive directional candles.
      double obOpen = iOpen(_Symbol, PERIOD_H4, s);
      double obClose = iClose(_Symbol, PERIOD_H4, s);
      bool impulseOk = true;

      if(dir == DIR_BEARISH)
      {
         if(!(obClose > obOpen)) impulseOk = false;
         for(int k = 1; k <= ImpulseCandles && impulseOk; k++)
         {
            if(iClose(_Symbol, PERIOD_H4, s - k) >= iOpen(_Symbol, PERIOD_H4, s - k))
               impulseOk = false;
         }
         if(impulseOk)
            AddZone(ZONE_OB, DIR_BEARISH, iHigh(_Symbol, PERIOD_H4, s), iLow(_Symbol, PERIOD_H4, s), iTime(_Symbol, PERIOD_H4, s));
      }
      else
      {
         if(!(obClose < obOpen)) impulseOk = false;
         for(int k = 1; k <= ImpulseCandles && impulseOk; k++)
         {
            if(iClose(_Symbol, PERIOD_H4, s - k) <= iOpen(_Symbol, PERIOD_H4, s - k))
               impulseOk = false;
         }
         if(impulseOk)
            AddZone(ZONE_OB, DIR_BULLISH, iHigh(_Symbol, PERIOD_H4, s), iLow(_Symbol, PERIOD_H4, s), iTime(_Symbol, PERIOD_H4, s));
      }
   }
}

//-------------------------------------------------------------------------------------------------
// CheckZoneMitigation
// Purpose: remove H4 zones that become mitigated by 50% penetration on confirmed H4 closed candle.
// Inputs: none. Uses latest closed H4 bar (shift 1).
//-------------------------------------------------------------------------------------------------
void CheckZoneMitigation()
{
   double h = iHigh(_Symbol, PERIOD_H4, 1);
   double l = iLow(_Symbol, PERIOD_H4, 1);

   for(int i = ArraySize(g_zones) - 1; i >= 0; --i)
   {
      if(g_zones[i].consumed) continue;
      double range = g_zones[i].high - g_zones[i].low;
      double half = range * (FVGMitigationPercent / 100.0);

      bool mitigated = false;
      if(g_zones[i].direction == DIR_BULLISH)
      {
         double level = g_zones[i].low + half;
         if(l <= level) mitigated = true;
      }
      else
      {
         double level = g_zones[i].high - half;
         if(h >= level) mitigated = true;
      }

      if(mitigated)
      {
         ArrayRemove(g_zones, i);
      }
   }
}

//-------------------------------------------------------------------------------------------------
// IsPriceInH4Zone
// Purpose: return index of first active unconsumed H4 zone containing H1 close with 15% buffer.
// Inputs: h1Close price.
// Returns: zone index or -1.
//-------------------------------------------------------------------------------------------------
int IsPriceInH4Zone(const double h1Close)
{
   for(int i = ArraySize(g_zones) - 1; i >= 0; --i)
   {
      if(g_zones[i].consumed) continue;

      // Bias-aligned only
      if((g_bias == BEARISH_CHOCH || g_bias == BEARISH_CONFIRMED) && g_zones[i].direction != DIR_BEARISH) continue;
      if((g_bias == BULLISH_CHOCH || g_bias == BULLISH_CONFIRMED) && g_zones[i].direction != DIR_BULLISH) continue;

      double r = g_zones[i].high - g_zones[i].low;
      double b = r * 0.15;
      double low = g_zones[i].low - b;
      double high = g_zones[i].high + b;

      if(h1Close >= low && h1Close <= high)
         return i;
   }
   return -1;
}

//-------------------------------------------------------------------------------------------------
// FindH1FractalPDArrays
// Purpose: detect H1 PD arrays inside/overlapping a given active H4 zone.
// Inputs: zoneIndex, output dynamic array of PDArray.
// Logic: scans for standard FVG, OB, Double FVG, Breaker, and Confluence candidates.
//-------------------------------------------------------------------------------------------------
void FindH1FractalPDArrays(const int zoneIndex, PDArray &out[])
{
   ArrayResize(out, 0);
   if(zoneIndex < 0 || zoneIndex >= ArraySize(g_zones)) return;

   H4Zone z = g_zones[zoneIndex];
   const int maxScan = 150;

   // Collect base arrays (standard FVG and OB)
   for(int s = maxScan; s >= 3; --s)
   {
      // Standard FVG
      double c1High = iHigh(_Symbol, PERIOD_H1, s + 1);
      double c1Low  = iLow(_Symbol, PERIOD_H1, s + 1);
      double c3High = iHigh(_Symbol, PERIOD_H1, s - 1);
      double c3Low  = iLow(_Symbol, PERIOD_H1, s - 1);
      datetime ft = iTime(_Symbol, PERIOD_H1, s - 1);

      if(z.direction == DIR_BEARISH && c1Low > c3High)
      {
         if(RangesOverlap(c3High, c1Low, z.low, z.high))
         {
            PDArray pd;
            pd.rank = 3; pd.type = PD_STANDARD_FVG; pd.direction = DIR_BEARISH;
            pd.high = c1Low; pd.low = c3High; pd.midpoint = (pd.high + pd.low) * 0.5;
            pd.formationTime = ft; pd.valid = true;
            int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
         }
      }
      if(z.direction == DIR_BULLISH && c1High < c3Low)
      {
         if(RangesOverlap(c1High, c3Low, z.low, z.high))
         {
            PDArray pd;
            pd.rank = 3; pd.type = PD_STANDARD_FVG; pd.direction = DIR_BULLISH;
            pd.high = c3Low; pd.low = c1High; pd.midpoint = (pd.high + pd.low) * 0.5;
            pd.formationTime = ft; pd.valid = true;
            int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
         }
      }

      // OB
      double obOpen = iOpen(_Symbol, PERIOD_H1, s);
      double obClose = iClose(_Symbol, PERIOD_H1, s);
      bool impulseOk = true;

      if(z.direction == DIR_BEARISH)
      {
         if(!(obClose > obOpen)) impulseOk = false;
         for(int k = 1; k <= ImpulseCandles && impulseOk; k++)
            if(iClose(_Symbol, PERIOD_H1, s - k) >= iOpen(_Symbol, PERIOD_H1, s - k)) impulseOk = false;

         if(impulseOk)
         {
            double low = iLow(_Symbol, PERIOD_H1, s), high = iHigh(_Symbol, PERIOD_H1, s);
            if(RangesOverlap(low, high, z.low, z.high))
            {
               PDArray pd;
               pd.rank = 4; pd.type = PD_OB; pd.direction = DIR_BEARISH;
               pd.high = high; pd.low = low; pd.midpoint = (high + low) * 0.5;
               pd.formationTime = iTime(_Symbol, PERIOD_H1, s); pd.valid = true;
               int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
            }
         }
      }
      else
      {
         if(!(obClose < obOpen)) impulseOk = false;
         for(int k = 1; k <= ImpulseCandles && impulseOk; k++)
            if(iClose(_Symbol, PERIOD_H1, s - k) <= iOpen(_Symbol, PERIOD_H1, s - k)) impulseOk = false;

         if(impulseOk)
         {
            double low = iLow(_Symbol, PERIOD_H1, s), high = iHigh(_Symbol, PERIOD_H1, s);
            if(RangesOverlap(low, high, z.low, z.high))
            {
               PDArray pd;
               pd.rank = 4; pd.type = PD_OB; pd.direction = DIR_BULLISH;
               pd.high = high; pd.low = low; pd.midpoint = (high + low) * 0.5;
               pd.formationTime = iTime(_Symbol, PERIOD_H1, s); pd.valid = true;
               int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
            }
         }
      }
   }

   // Double FVG (rank 1): two consecutive same-direction FVGs with no full mitigation between.
   for(int i = 0; i < ArraySize(out) - 1; i++)
   {
      if(out[i].type != PD_STANDARD_FVG) continue;
      for(int j = i + 1; j < ArraySize(out); j++)
      {
         if(out[j].type != PD_STANDARD_FVG) continue;
         if(out[i].direction != out[j].direction) continue;

         // consecutive by formation time proximity (1 candle spacing tolerance)
         if(MathAbs((long)out[i].formationTime - (long)out[j].formationTime) > PeriodSeconds(PERIOD_H1) * 2)
            continue;

         double mergedHigh = MathMax(out[i].high, out[j].high);
         double mergedLow = MathMin(out[i].low, out[j].low);

         // no full mitigation between them: use recent closed candle check around their midpoint
         bool mitigated = false;
         for(int s = 1; s <= 6; s++)
         {
            double hh = iHigh(_Symbol, PERIOD_H1, s);
            double ll = iLow(_Symbol, PERIOD_H1, s);
            if(out[i].direction == DIR_BULLISH && ll <= mergedLow) mitigated = true;
            if(out[i].direction == DIR_BEARISH && hh >= mergedHigh) mitigated = true;
         }
         if(mitigated) continue;

         PDArray pd;
         pd.rank = 1; pd.type = PD_DOUBLE_FVG; pd.direction = out[i].direction;
         pd.high = mergedHigh; pd.low = mergedLow; pd.midpoint = (mergedHigh + mergedLow) * 0.5;
         pd.formationTime = MathMax(out[i].formationTime, out[j].formationTime); pd.valid = true;
         int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
      }
   }

   // Breaker (rank 2): failed OB + adjacent FVG.
   for(int i = 0; i < ArraySize(out); i++)
   {
      if(out[i].type != PD_OB) continue;
      for(int j = 0; j < ArraySize(out); j++)
      {
         if(out[j].type != PD_STANDARD_FVG) continue;
         if(out[j].direction != out[i].direction) continue;
         if(!RangesOverlap(out[i].low, out[i].high, out[j].low, out[j].high)) continue;

         bool obFailed = false;
         for(int s = 1; s <= 20; s++)
         {
            if(out[i].direction == DIR_BULLISH && iClose(_Symbol, PERIOD_H1, s) < out[i].low) obFailed = true;
            if(out[i].direction == DIR_BEARISH && iClose(_Symbol, PERIOD_H1, s) > out[i].high) obFailed = true;
         }
         if(!obFailed) continue;

         PDArray pd;
         pd.rank = 2; pd.type = PD_BREAKER; pd.direction = out[i].direction;
         pd.high = MathMax(out[i].high, out[j].high);
         pd.low = MathMin(out[i].low, out[j].low);
         pd.midpoint = (pd.high + pd.low) * 0.5;
         pd.formationTime = MathMax(out[i].formationTime, out[j].formationTime);
         pd.valid = true;
         int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
      }
   }

   // Confluence (rank 0 priority override): combine rank3/rank4 pairs overlapping or near (10% range).
   for(int i = 0; i < ArraySize(out); i++)
   {
      if(!(out[i].type == PD_STANDARD_FVG || out[i].type == PD_OB)) continue;
      for(int j = i + 1; j < ArraySize(out); j++)
      {
         if(!(out[j].type == PD_STANDARD_FVG || out[j].type == PD_OB)) continue;
         if(out[i].direction != out[j].direction) continue;

         double r1 = out[i].high - out[i].low;
         double r2 = out[j].high - out[j].low;
         double gap = 0.0;
         if(out[i].high < out[j].low) gap = out[j].low - out[i].high;
         else if(out[j].high < out[i].low) gap = out[i].low - out[j].high;

         bool near = RangesOverlap(out[i].low, out[i].high, out[j].low, out[j].high) ||
                     gap <= MathMin(r1, r2) * 0.10;
         if(!near) continue;

         PDArray pd;
         pd.rank = 0; pd.type = PD_CONFLUENCE; pd.direction = out[i].direction;
         pd.high = MathMax(out[i].high, out[j].high);
         pd.low = MathMin(out[i].low, out[j].low);
         pd.midpoint = (pd.high + pd.low) * 0.5;
         pd.formationTime = MathMax(out[i].formationTime, out[j].formationTime);
         pd.valid = true;
         int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = pd;
      }
   }
}

//-------------------------------------------------------------------------------------------------
// RankAndSelectPDArray
// Purpose: apply ranking hierarchy and choose highest-priority, most recent candidate.
// Inputs: PD array list and output selected struct.
// Returns: true if selected.
//-------------------------------------------------------------------------------------------------
bool RankAndSelectPDArray(PDArray &arrays[], PDArray &selected)
{
   if(ArraySize(arrays) == 0) return false;

   int bestIndex = -1;
   int bestRank = 999;
   datetime bestTime = 0;

   for(int i = 0; i < ArraySize(arrays); i++)
   {
      if(!arrays[i].valid) continue;
      int effectiveRank = arrays[i].rank;
      if(arrays[i].type == PD_CONFLUENCE) effectiveRank = -1; // above all individual arrays

      if(bestIndex < 0 || effectiveRank < bestRank ||
         (effectiveRank == bestRank && arrays[i].formationTime > bestTime))
      {
         bestIndex = i;
         bestRank = effectiveRank;
         bestTime = arrays[i].formationTime;
      }
   }

   if(bestIndex < 0) return false;
   selected = arrays[bestIndex];
   return true;
}

//-------------------------------------------------------------------------------------------------
// CalculateSL
// Purpose: compute SL from H1 swing points before impulse that created selected PD array.
// Inputs: selected PD array and assumed entry price.
// Returns: SL price or 0 if unavailable.
//-------------------------------------------------------------------------------------------------
double CalculateSL(const PDArray &pd, const double entryPrice)
{
   double buffer = TenPipBuffer();

   // find most recent qualifying swing before PD formation.
   for(int s = 200; s >= SwingLookback + 2; --s)
   {
      datetime t = iTime(_Symbol, PERIOD_H1, s);
      if(t <= 0 || t >= pd.formationTime) continue;

      if(pd.direction == DIR_BULLISH)
      {
         if(IsSwingLow(PERIOD_H1, s, SwingLookback))
         {
            double sl = iLow(_Symbol, PERIOD_H1, s) - buffer;
            if(sl < entryPrice) return sl;
         }
      }
      else
      {
         if(IsSwingHigh(PERIOD_H1, s, SwingLookback))
         {
            double sl = iHigh(_Symbol, PERIOD_H1, s) + buffer;
            if(sl > entryPrice) return sl;
         }
      }
   }
   return 0.0;
}

//-------------------------------------------------------------------------------------------------
// ScanD1TroubleAreas
// Purpose: find nearest unmitigated D1 OB/FVG in path between entry and primary target.
// Inputs: direction, entry, primary target.
// Outputs: troubleHigh/Low and found flag.
//-------------------------------------------------------------------------------------------------
bool ScanD1TroubleAreas(const Direction dir, const double entry, const double primaryTarget, double &troubleHigh, double &troubleLow)
{
   bool found = false;
   double nearestDistance = DBL_MAX;

   for(int s = D1Lookback; s >= 3; --s)
   {
      // D1 OB detect
      double o = iOpen(_Symbol, PERIOD_D1, s);
      double c = iClose(_Symbol, PERIOD_D1, s);
      double zHigh = iHigh(_Symbol, PERIOD_D1, s);
      double zLow = iLow(_Symbol, PERIOD_D1, s);

      bool obCandidate = false;
      if(dir == DIR_BULLISH)
      {
         bool impulse = (c < o);
         for(int k = 1; k <= ImpulseCandles && impulse; k++)
            if(iClose(_Symbol, PERIOD_D1, s - k) <= iOpen(_Symbol, PERIOD_D1, s - k)) impulse = false;
         obCandidate = impulse;
      }
      else
      {
         bool impulse = (c > o);
         for(int k = 1; k <= ImpulseCandles && impulse; k++)
            if(iClose(_Symbol, PERIOD_D1, s - k) >= iOpen(_Symbol, PERIOD_D1, s - k)) impulse = false;
         obCandidate = impulse;
      }

      // D1 FVG detect
      double c1High = iHigh(_Symbol, PERIOD_D1, s + 1);
      double c1Low = iLow(_Symbol, PERIOD_D1, s + 1);
      double c3High = iHigh(_Symbol, PERIOD_D1, s - 1);
      double c3Low = iLow(_Symbol, PERIOD_D1, s - 1);

      double fHigh = 0.0, fLow = 0.0;
      bool fvgCandidate = false;
      if(dir == DIR_BULLISH && c1High < c3Low)
      {
         fvgCandidate = true; fHigh = c3Low; fLow = c1High;
      }
      if(dir == DIR_BEARISH && c1Low > c3High)
      {
         fvgCandidate = true; fHigh = c1Low; fLow = c3High;
      }

      // Process both candidates through path and mitigation checks.
      for(int type = 0; type < 2; type++)
      {
         bool cand = (type == 0 ? obCandidate : fvgCandidate);
         if(!cand) continue;

         double high = (type == 0 ? zHigh : fHigh);
         double low = (type == 0 ? zLow : fLow);
         double mid = low + (high - low) * (FVGMitigationPercent / 100.0);

         // Unmitigated since formation (scan candles more recent than s)
         bool mitigated = false;
         for(int r = s - 1; r >= 1; --r)
         {
            double hh = iHigh(_Symbol, PERIOD_D1, r);
            double ll = iLow(_Symbol, PERIOD_D1, r);
            if(dir == DIR_BULLISH && ll <= mid) mitigated = true;
            if(dir == DIR_BEARISH && hh >= (high - (high - low) * (FVGMitigationPercent / 100.0))) mitigated = true;
         }
         if(mitigated) continue;

         bool inPath = false;
         double edge = 0.0;
         if(dir == DIR_BULLISH)
         {
            inPath = (low > entry && low < primaryTarget);
            edge = low;
         }
         else
         {
            inPath = (high < entry && high > primaryTarget);
            edge = high;
         }
         if(!inPath) continue;

         double d = MathAbs(edge - entry);
         if(d < nearestDistance)
         {
            nearestDistance = d;
            troubleHigh = high;
            troubleLow = low;
            found = true;
         }
      }
   }

   return found;
}

//-------------------------------------------------------------------------------------------------
// CalculateTP
// Purpose: compute D1 TP using swing target then trouble-area override with 10-pip shy adjustment.
// Inputs: direction, entry price, output override flag.
// Returns: TP price or 0 if unavailable.
//-------------------------------------------------------------------------------------------------
double CalculateTP(const Direction dir, const double entryPrice, bool &overrideApplied)
{
   overrideApplied = false;
   double buffer = TenPipBuffer();

   double primary = 0.0;
   double bestDistance = (g_tpMode == TP_CONSERVATIVE ? DBL_MAX : -1.0);

   for(int s = D1Lookback; s >= SwingLookback + 2; --s)
   {
      if(dir == DIR_BULLISH && IsSwingHigh(PERIOD_D1, s, SwingLookback))
      {
         double sh = iHigh(_Symbol, PERIOD_D1, s);
         if(sh <= entryPrice) continue;
         double d = sh - entryPrice;
         if((g_tpMode == TP_CONSERVATIVE && d < bestDistance) ||
            (g_tpMode == TP_FULL && d > bestDistance))
         {
            bestDistance = d;
            primary = sh - buffer;
         }
      }
      else if(dir == DIR_BEARISH && IsSwingLow(PERIOD_D1, s, SwingLookback))
      {
         double sl = iLow(_Symbol, PERIOD_D1, s);
         if(sl >= entryPrice) continue;
         double d = entryPrice - sl;
         if((g_tpMode == TP_CONSERVATIVE && d < bestDistance) ||
            (g_tpMode == TP_FULL && d > bestDistance))
         {
            bestDistance = d;
            primary = sl + buffer;
         }
      }
   }

   if(primary == 0.0) return 0.0;

   double tHigh = 0.0, tLow = 0.0;
   if(ScanD1TroubleAreas(dir, entryPrice, primary, tHigh, tLow))
   {
      overrideApplied = true;
      if(dir == DIR_BULLISH)
         return tLow - buffer;
      return tHigh + buffer;
   }

   return primary;
}

//-------------------------------------------------------------------------------------------------
// Utility: lot sizing using fixed dollar risk and symbol value per price unit.
//-------------------------------------------------------------------------------------------------
double CalculateLotsByRisk(const double riskDollars, const double entryPrice, const double slPrice)
{
   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0.0) return 0.0;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   // Value per 1.0 price move for one lot.
   double valuePerPrice = tickValue / tickSize;
   double rawLots = riskDollars / (slDist * valuePerPrice);

   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(rawLots > volMax) rawLots = volMax;
   if(rawLots < volMin) rawLots = volMin;

   double steps = MathFloor(rawLots / volStep);
   double lots = steps * volStep;
   return NormalizeDouble(lots, 2);
}

//-------------------------------------------------------------------------------------------------
// ManageZoneConsumption
// Purpose: permanently consume an H4 zone once a trade is executed from it.
// Inputs: zone index.
//-------------------------------------------------------------------------------------------------
void ManageZoneConsumption(const int zoneIndex)
{
   if(zoneIndex < 0 || zoneIndex >= ArraySize(g_zones)) return;
   g_zones[zoneIndex].consumed = true;
   g_zones[zoneIndex].consumedTime = TimeCurrent();
}

string BiasToString(BiasState b)
{
   switch(b)
   {
      case BEARISH_CHOCH: return "BEARISH_CHOCH";
      case BEARISH_CONFIRMED: return "BEARISH_CONFIRMED";
      case BULLISH_CHOCH: return "BULLISH_CHOCH";
      case BULLISH_CONFIRMED: return "BULLISH_CONFIRMED";
      default: return "NEUTRAL";
   }
}

string TPModeToString(TPMode m){ return (m == TP_FULL ? "FULL" : "CONSERVATIVE"); }
string ZoneTypeToString(ZoneType t){ return (t == ZONE_OB ? "OB" : "FVG"); }
string DirectionToString(Direction d){ return (d == DIR_BULLISH ? "BULLISH" : "BEARISH"); }
string PDTypeToString(PDType t)
{
   switch(t)
   {
      case PD_DOUBLE_FVG: return "DOUBLE_FVG";
      case PD_BREAKER: return "BREAKER";
      case PD_STANDARD_FVG: return "STANDARD_FVG";
      case PD_OB: return "OB";
      default: return "CONFLUENCE";
   }
}

//-------------------------------------------------------------------------------------------------
// ExecuteEntry
// Purpose: executes selected entry (limit for Double FVG midpoint, market for others on first tap).
// Inputs: zone index and selected PD array.
// Returns: true when order placed.
//-------------------------------------------------------------------------------------------------
bool ExecuteEntry(const int zoneIndex, const PDArray &selected, string &reason)
{
   reason = "";

   if(HasActivePositionForSymbol(_Symbol))
   {
      reason = "trade already active on symbol";
      return false;
   }

   if(!IsSessionValid())
   {
      reason = "Asian session block";
      return false;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry = (selected.direction == DIR_BULLISH ? ask : bid);

   double nearEdge = (selected.direction == DIR_BULLISH ? selected.high : selected.low);

   // Price tap gating
   bool tapped = (selected.direction == DIR_BULLISH ? (bid <= nearEdge) : (ask >= nearEdge));

   if(selected.type == PD_DOUBLE_FVG)
   {
      double mid = selected.midpoint;
      bool reachedMid = (selected.direction == DIR_BULLISH ? (bid <= mid) : (ask >= mid));
      if(!reachedMid)
      {
         reason = "Double FVG waiting for 50% level";
         return false;
      }
      entry = mid;
   }
   else
   {
      if(!tapped)
      {
         reason = "higher ranked array present in zone";
         return false;
      }
   }

   double sl = CalculateSL(selected, entry);
   if(sl == 0.0)
   {
      reason = "no valid swing-based SL";
      return false;
   }

   bool overrideApplied = false;
   double tp = CalculateTP(selected.direction, entry, overrideApplied);
   if(tp == 0.0)
   {
      reason = "no valid D1 TP target";
      return false;
   }

   double lots = CalculateLotsByRisk(RiskDollars, entry, sl);
   if(lots <= 0.0)
   {
      reason = "invalid lot size";
      return false;
   }

   bool ok = false;
   trade.SetExpertMagicNumber(23062026);
   trade.SetDeviationInPoints(30);

   if(selected.type == PD_DOUBLE_FVG)
   {
      datetime expiration = TimeCurrent() + (PeriodSeconds(PERIOD_H1) * OrderExpiryCandles);
      if(selected.direction == DIR_BULLISH)
         ok = trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, "ICT DFVG long");
      else
         ok = trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, "ICT DFVG short");
   }
   else
   {
      if(selected.direction == DIR_BULLISH)
         ok = trade.Buy(lots, _Symbol, entry, sl, tp, "ICT market long");
      else
         ok = trade.Sell(lots, _Symbol, entry, sl, tp, "ICT market short");
   }

   if(ok)
   {
      Print("ENTRY PLACED | entry=", DoubleToString(entry, _Digits),
            " sl=", DoubleToString(sl, _Digits),
            " tp=", DoubleToString(tp, _Digits),
            " lots=", DoubleToString(lots, 2),
            " tpMode=", TPModeToString(g_tpMode),
            " h4ZoneType=", ZoneTypeToString(g_zones[zoneIndex].type),
            " h1Array=", PDTypeToString(selected.type),
            " rank=", selected.rank,
            " troubleOverride=", (overrideApplied ? "YES" : "NO"));

      ManageZoneConsumption(zoneIndex);
      return true;
   }

   reason = "order placement failed";
   return false;
}

//-------------------------------------------------------------------------------------------------
// EA initialization
//-------------------------------------------------------------------------------------------------
int OnInit()
{
   ArrayResize(g_zones, 0);
   return(INIT_SUCCEEDED);
}

//-------------------------------------------------------------------------------------------------
// OnTick
// Purpose: orchestrates MTF updates strictly on closed candles: D1, H4, H1.
//-------------------------------------------------------------------------------------------------
void OnTick()
{
   datetime d1Close = iTime(_Symbol, PERIOD_D1, 1);
   datetime h4Close = iTime(_Symbol, PERIOD_H4, 1);
   datetime h1Close = iTime(_Symbol, PERIOD_H1, 1);

   if(d1Close != 0 && d1Close != g_lastD1Close)
   {
      g_lastD1Close = d1Close;
      DetectD1Bias();
   }

   if(h4Close != 0 && h4Close != g_lastH4Close)
   {
      g_lastH4Close = h4Close;
      CheckZoneMitigation();
      IdentifyH4Zones();
   }

   if(h1Close == 0 || h1Close == g_lastH1Close)
      return;

   g_lastH1Close = h1Close;

   // H1 evaluation and mandatory logging.
   double closePrice = iClose(_Symbol, PERIOD_H1, 1);
   Print("H1 EVAL | bias=", BiasToString(g_bias), " tpMode=", TPModeToString(g_tpMode),
         " h1Close=", DoubleToString(closePrice, _Digits));

   if(g_bias == NEUTRAL)
   {
      Print("NO ENTRY | no active H4 zone");
      return;
   }

   if(HasActivePositionForSymbol(_Symbol))
   {
      Print("NO ENTRY | trade already active on symbol");
      return;
   }

   int zoneIndex = IsPriceInH4Zone(closePrice);
   if(zoneIndex < 0)
   {
      Print("NO ENTRY | no active H4 zone");
      return;
   }

   H4Zone z = g_zones[zoneIndex];
   Print("ZONE | type=", ZoneTypeToString(z.type), " high=", DoubleToString(z.high, _Digits),
         " low=", DoubleToString(z.low, _Digits), " dir=", DirectionToString(z.direction),
         " consumed=", (z.consumed ? "true" : "false"));

   if(z.consumed)
   {
      Print("NO ENTRY | zone already consumed");
      return;
   }

   PDArray arrays[];
   FindH1FractalPDArrays(zoneIndex, arrays);
   PDArray selected;
   if(!RankAndSelectPDArray(arrays, selected))
   {
      Print("NO ENTRY | no H1 fractal array found");
      return;
   }

   Print("H1 ARRAY | rank=", selected.rank, " type=", PDTypeToString(selected.type),
         " high=", DoubleToString(selected.high, _Digits), " low=", DoubleToString(selected.low, _Digits));

   string reason;
   if(!ExecuteEntry(zoneIndex, selected, reason))
      Print("NO ENTRY | ", reason);
}
