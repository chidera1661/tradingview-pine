#property strict
#property description "Multi-timeframe ICT EA for D1 bias, H4 zones, H1 fractal entries"

#include <Trade/Trade.mqh>

input double RiskDollars = 39.0;
input int LondonStartUTC = 7;
input int LondonEndUTC = 12;
input int NYStartUTC = 13;
input int NYEndUTC = 20;
input double FVGMitigationPercent = 50.0;
input int OrderExpiryCandles = 3;
input int ImpulseCandles = 2;

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

struct H4Zone
{
   string zoneType;
   int direction; // 1 bullish, -1 bearish
   double zoneHigh;
   double zoneLow;
   datetime formationTime;
   bool consumed;
   datetime consumedTime;
};

struct PDArray
{
   int rank; // 0 confluence, 1..5 as requested
   string arrayType;
   int direction; // 1 bullish, -1 bearish
   double high;
   double low;
   datetime formationTime;
   int formationShift;
};

CTrade trade;
H4Zone g_zones[];
BiasState g_biasState = NEUTRAL;
TPMode g_tpMode = TP_CONSERVATIVE;
double g_chochOBHigh = 0.0;
double g_chochOBLow = 0.0;
datetime g_lastD1CloseTime = 0;
datetime g_lastH4CloseTime = 0;
datetime g_lastH1CloseTime = 0;

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

string TPModeToString(TPMode m)
{
   return (m == TP_FULL) ? "FULL" : "CONSERVATIVE";
}

// DetectD1Bias: Detects D1 CHoCH and confirmation state strictly on closed D1 candles (shift>=1).
void DetectD1Bias()
{
   const int lookback = 300;
   BiasState latestState = NEUTRAL;
   datetime latestEventTime = 0;
   double chochHigh = 0.0, chochLow = 0.0;

   for(int i = lookback; i >= 1; i--)
   {
      double o = iOpen(_Symbol, PERIOD_D1, i);
      double c = iClose(_Symbol, PERIOD_D1, i);
      double h = iHigh(_Symbol, PERIOD_D1, i);
      double l = iLow(_Symbol, PERIOD_D1, i);
      datetime t = iTime(_Symbol, PERIOD_D1, i);
      if(o == 0 || c == 0 || t == 0)
         continue;

      if(i + 1 <= lookback)
      {
         double op = iOpen(_Symbol, PERIOD_D1, i + 1);
         double cp = iClose(_Symbol, PERIOD_D1, i + 1);
         double hp = iHigh(_Symbol, PERIOD_D1, i + 1);
         double lp = iLow(_Symbol, PERIOD_D1, i + 1);

         if(cp > op && c < o && c < lp)
         {
            latestState = BEARISH_CHOCH;
            latestEventTime = t;
            chochHigh = h;
            chochLow = l;
         }

         if(cp < op && c > o && c > hp)
         {
            latestState = BULLISH_CHOCH;
            latestEventTime = t;
            chochHigh = h;
            chochLow = l;
         }
      }
   }

   if(latestState == BEARISH_CHOCH || latestState == BULLISH_CHOCH)
   {
      bool returnedToOB = false;
      for(int j = 1; j <= 300; j++)
      {
         datetime tj = iTime(_Symbol, PERIOD_D1, j);
         if(tj <= latestEventTime || tj == 0)
            continue;

         double hj = iHigh(_Symbol, PERIOD_D1, j);
         double lj = iLow(_Symbol, PERIOD_D1, j);
         double cj = iClose(_Symbol, PERIOD_D1, j);

         if(!returnedToOB && hj >= chochLow && lj <= chochHigh)
            returnedToOB = true;

         if(returnedToOB)
         {
            if(latestState == BEARISH_CHOCH && cj < chochLow)
               latestState = BEARISH_CONFIRMED;
            if(latestState == BULLISH_CHOCH && cj > chochHigh)
               latestState = BULLISH_CONFIRMED;
         }
      }
   }

   g_biasState = latestState;
   g_tpMode = (g_biasState == BEARISH_CONFIRMED || g_biasState == BULLISH_CONFIRMED) ? TP_FULL : TP_CONSERVATIVE;
   g_chochOBHigh = chochHigh;
   g_chochOBLow = chochLow;
}

bool ZoneExists(string zoneType, int direction, datetime formationTime)
{
   for(int i = 0; i < ArraySize(g_zones); i++)
      if(g_zones[i].zoneType == zoneType && g_zones[i].direction == direction && g_zones[i].formationTime == formationTime)
         return true;
   return false;
}

// IdentifyH4Zones: Finds H4 OB/FVG zones aligned with current D1 bias and stores unmitigated zones.
void IdentifyH4Zones()
{
   if(g_biasState == NEUTRAL)
      return;

   int dir = (g_biasState == BEARISH_CHOCH || g_biasState == BEARISH_CONFIRMED) ? -1 : 1;
   const int lookback = 200;

   for(int i = lookback; i >= 1; i--)
   {
      datetime t = iTime(_Symbol, PERIOD_H4, i);
      if(t == 0)
         continue;

      double o = iOpen(_Symbol, PERIOD_H4, i);
      double c = iClose(_Symbol, PERIOD_H4, i);
      double h = iHigh(_Symbol, PERIOD_H4, i);
      double l = iLow(_Symbol, PERIOD_H4, i);

      if(dir == -1)
      {
         if(c > o)
         {
            bool impulse = true;
            for(int k = 1; k <= ImpulseCandles; k++)
            {
               double ok = iOpen(_Symbol, PERIOD_H4, i - k);
               double ck = iClose(_Symbol, PERIOD_H4, i - k);
               if(!(ck < ok))
               {
                  impulse = false;
                  break;
               }
            }
            if(impulse && !ZoneExists("OB", -1, t))
            {
               H4Zone z;
               z.zoneType = "OB";
               z.direction = -1;
               z.zoneHigh = h;
               z.zoneLow = l;
               z.formationTime = t;
               z.consumed = false;
               z.consumedTime = 0;
               int n = ArraySize(g_zones);
               ArrayResize(g_zones, n + 1);
               g_zones[n] = z;
            }
         }

         if(i + 2 <= lookback)
         {
            double c1Low = iLow(_Symbol, PERIOD_H4, i + 2);
            double c3High = iHigh(_Symbol, PERIOD_H4, i);
            if(c1Low > c3High && !ZoneExists("FVG", -1, t))
            {
               H4Zone z2;
               z2.zoneType = "FVG";
               z2.direction = -1;
               z2.zoneHigh = c1Low;
               z2.zoneLow = c3High;
               z2.formationTime = t;
               z2.consumed = false;
               z2.consumedTime = 0;
               int n2 = ArraySize(g_zones);
               ArrayResize(g_zones, n2 + 1);
               g_zones[n2] = z2;
            }
         }
      }
      else
      {
         if(c < o)
         {
            bool impulse2 = true;
            for(int k2 = 1; k2 <= ImpulseCandles; k2++)
            {
               double ok2 = iOpen(_Symbol, PERIOD_H4, i - k2);
               double ck2 = iClose(_Symbol, PERIOD_H4, i - k2);
               if(!(ck2 > ok2))
               {
                  impulse2 = false;
                  break;
               }
            }
            if(impulse2 && !ZoneExists("OB", 1, t))
            {
               H4Zone z3;
               z3.zoneType = "OB";
               z3.direction = 1;
               z3.zoneHigh = h;
               z3.zoneLow = l;
               z3.formationTime = t;
               z3.consumed = false;
               z3.consumedTime = 0;
               int n3 = ArraySize(g_zones);
               ArrayResize(g_zones, n3 + 1);
               g_zones[n3] = z3;
            }
         }

         if(i + 2 <= lookback)
         {
            double c1High = iHigh(_Symbol, PERIOD_H4, i + 2);
            double c3Low = iLow(_Symbol, PERIOD_H4, i);
            if(c1High < c3Low && !ZoneExists("FVG", 1, t))
            {
               H4Zone z4;
               z4.zoneType = "FVG";
               z4.direction = 1;
               z4.zoneHigh = c3Low;
               z4.zoneLow = c1High;
               z4.formationTime = t;
               z4.consumed = false;
               z4.consumedTime = 0;
               int n4 = ArraySize(g_zones);
               ArrayResize(g_zones, n4 + 1);
               g_zones[n4] = z4;
            }
         }
      }
   }
}

// CheckZoneMitigation: Removes zones immediately when a closed H4 candle trades through the configured mitigation midpoint.
void CheckZoneMitigation()
{
   double h = iHigh(_Symbol, PERIOD_H4, 1);
   double l = iLow(_Symbol, PERIOD_H4, 1);
   if(h == 0 && l == 0)
      return;

   for(int i = ArraySize(g_zones) - 1; i >= 0; i--)
   {
      if(g_zones[i].consumed)
         continue;
      double range = g_zones[i].zoneHigh - g_zones[i].zoneLow;
      if(range <= 0)
         continue;
      double midpoint = (g_zones[i].direction == 1)
                        ? g_zones[i].zoneLow + range * (FVGMitigationPercent / 100.0)
                        : g_zones[i].zoneHigh - range * (FVGMitigationPercent / 100.0);
      bool mitigated = (g_zones[i].direction == 1) ? (l <= midpoint) : (h >= midpoint);
      if(mitigated)
      {
         for(int j = i; j < ArraySize(g_zones) - 1; j++)
            g_zones[j] = g_zones[j + 1];
         ArrayResize(g_zones, ArraySize(g_zones) - 1);
      }
   }
}

// IsPriceInH4Zone: Checks whether current H1 close is within any active H4 zone with +/-15% buffer and returns latest matching zone index.
int IsPriceInH4Zone(double price)
{
   int selected = -1;
   datetime latest = 0;
   for(int i = 0; i < ArraySize(g_zones); i++)
   {
      if(g_zones[i].consumed)
         continue;
      if(g_biasState == BEARISH_CHOCH || g_biasState == BEARISH_CONFIRMED)
      {
         if(g_zones[i].direction != -1)
            continue;
      }
      if(g_biasState == BULLISH_CHOCH || g_biasState == BULLISH_CONFIRMED)
      {
         if(g_zones[i].direction != 1)
            continue;
      }

      double range = g_zones[i].zoneHigh - g_zones[i].zoneLow;
      double lowB = g_zones[i].zoneLow - (range * 0.15);
      double highB = g_zones[i].zoneHigh + (range * 0.15);
      if(price >= lowB && price <= highB)
      {
         if(g_zones[i].formationTime > latest)
         {
            latest = g_zones[i].formationTime;
            selected = i;
         }
      }
   }
   return selected;
}

bool Overlap(double h1, double l1, double h2, double l2)
{
   return !(l1 > h2 || l2 > h1);
}

// FindH1FractalPDArrays: Finds Double FVG, Breaker, Standard FVG, OB and Confluence arrays inside/overlapping selected H4 zone.
void FindH1FractalPDArrays(const H4Zone &zone, PDArray &result[])
{
   ArrayResize(result, 0);
   int dir = zone.direction;
   const int lookback = 120;

   // Rank 1: Double FVG
   for(int i = 3; i < lookback; i++)
   {
      if(dir == 1)
      {
         double a1 = iHigh(_Symbol, PERIOD_H1, i + 2);
         double b1 = iLow(_Symbol, PERIOD_H1, i);
         double a2 = iHigh(_Symbol, PERIOD_H1, i + 1);
         double b2 = iLow(_Symbol, PERIOD_H1, i - 1);
         bool fvg1 = (a1 < b1);
         bool fvg2 = (a2 < b2);
         if(fvg1 && fvg2)
         {
            double zH = MathMax(b1, b2);
            double zL = MathMin(a1, a2);
            if(Overlap(zH, zL, zone.zoneHigh, zone.zoneLow))
            {
               PDArray p;
               p.rank = 1;
               p.arrayType = "DoubleFVG";
               p.direction = 1;
               p.high = zH;
               p.low = zL;
               p.formationTime = iTime(_Symbol, PERIOD_H1, i - 1);
               p.formationShift = i - 1;
               int n = ArraySize(result);
               ArrayResize(result, n + 1);
               result[n] = p;
            }
         }
      }
      else
      {
         double a1d = iLow(_Symbol, PERIOD_H1, i + 2);
         double b1d = iHigh(_Symbol, PERIOD_H1, i);
         double a2d = iLow(_Symbol, PERIOD_H1, i + 1);
         double b2d = iHigh(_Symbol, PERIOD_H1, i - 1);
         bool fvg1d = (a1d > b1d);
         bool fvg2d = (a2d > b2d);
         if(fvg1d && fvg2d)
         {
            double zH2 = MathMax(a1d, a2d);
            double zL2 = MathMin(b1d, b2d);
            if(Overlap(zH2, zL2, zone.zoneHigh, zone.zoneLow))
            {
               PDArray p2;
               p2.rank = 1;
               p2.arrayType = "DoubleFVG";
               p2.direction = -1;
               p2.high = zH2;
               p2.low = zL2;
               p2.formationTime = iTime(_Symbol, PERIOD_H1, i - 1);
               p2.formationShift = i - 1;
               int n2 = ArraySize(result);
               ArrayResize(result, n2 + 1);
               result[n2] = p2;
            }
         }
      }
   }

   // Rank 3: Standard FVG
   for(int i3 = 3; i3 < lookback; i3++)
   {
      if(dir == 1)
      {
         double c1h = iHigh(_Symbol, PERIOD_H1, i3 + 2);
         double c3l = iLow(_Symbol, PERIOD_H1, i3);
         if(c1h < c3l && Overlap(c3l, c1h, zone.zoneHigh, zone.zoneLow))
         {
            PDArray p3;
            p3.rank = 3;
            p3.arrayType = "FVG";
            p3.direction = 1;
            p3.high = c3l;
            p3.low = c1h;
            p3.formationTime = iTime(_Symbol, PERIOD_H1, i3);
            p3.formationShift = i3;
            int n3 = ArraySize(result);
            ArrayResize(result, n3 + 1);
            result[n3] = p3;
         }
      }
      else
      {
         double c1l = iLow(_Symbol, PERIOD_H1, i3 + 2);
         double c3h = iHigh(_Symbol, PERIOD_H1, i3);
         if(c1l > c3h && Overlap(c1l, c3h, zone.zoneHigh, zone.zoneLow))
         {
            PDArray p4;
            p4.rank = 3;
            p4.arrayType = "FVG";
            p4.direction = -1;
            p4.high = c1l;
            p4.low = c3h;
            p4.formationTime = iTime(_Symbol, PERIOD_H1, i3);
            p4.formationShift = i3;
            int n4 = ArraySize(result);
            ArrayResize(result, n4 + 1);
            result[n4] = p4;
         }
      }
   }

   // Rank 4: OB
   for(int i4 = lookback; i4 >= 3; i4--)
   {
      double o = iOpen(_Symbol, PERIOD_H1, i4);
      double c = iClose(_Symbol, PERIOD_H1, i4);
      double h = iHigh(_Symbol, PERIOD_H1, i4);
      double l = iLow(_Symbol, PERIOD_H1, i4);

      if(dir == 1 && c < o)
      {
         bool imp = true;
         for(int k = 1; k <= ImpulseCandles; k++)
            if(!(iClose(_Symbol, PERIOD_H1, i4 - k) > iOpen(_Symbol, PERIOD_H1, i4 - k))) imp = false;
         if(imp && Overlap(h, l, zone.zoneHigh, zone.zoneLow))
         {
            PDArray p5;
            p5.rank = 4;
            p5.arrayType = "OB";
            p5.direction = 1;
            p5.high = h;
            p5.low = l;
            p5.formationTime = iTime(_Symbol, PERIOD_H1, i4);
            p5.formationShift = i4;
            int n5 = ArraySize(result);
            ArrayResize(result, n5 + 1);
            result[n5] = p5;
         }
      }
      if(dir == -1 && c > o)
      {
         bool imp2 = true;
         for(int k2 = 1; k2 <= ImpulseCandles; k2++)
            if(!(iClose(_Symbol, PERIOD_H1, i4 - k2) < iOpen(_Symbol, PERIOD_H1, i4 - k2))) imp2 = false;
         if(imp2 && Overlap(h, l, zone.zoneHigh, zone.zoneLow))
         {
            PDArray p6;
            p6.rank = 4;
            p6.arrayType = "OB";
            p6.direction = -1;
            p6.high = h;
            p6.low = l;
            p6.formationTime = iTime(_Symbol, PERIOD_H1, i4);
            p6.formationShift = i4;
            int n6 = ArraySize(result);
            ArrayResize(result, n6 + 1);
            result[n6] = p6;
         }
      }
   }

   // Rank 2: Breaker block (simplified: OB broken opposite + adjacent FVG)
   for(int i5 = 5; i5 < lookback; i5++)
   {
      if(dir == 1)
      {
         double obH = iHigh(_Symbol, PERIOD_H1, i5);
         double obL = iLow(_Symbol, PERIOD_H1, i5);
         bool wasBearOB = (iClose(_Symbol, PERIOD_H1, i5) < iOpen(_Symbol, PERIOD_H1, i5));
         bool broke = iClose(_Symbol, PERIOD_H1, i5 - 1) > obH;
         bool adjFVG = iHigh(_Symbol, PERIOD_H1, i5 + 1) < iLow(_Symbol, PERIOD_H1, i5 - 1);
         if(wasBearOB && broke && adjFVG && Overlap(obH, obL, zone.zoneHigh, zone.zoneLow))
         {
            PDArray b;
            b.rank = 2;
            b.arrayType = "Breaker";
            b.direction = 1;
            b.high = obH;
            b.low = obL;
            b.formationTime = iTime(_Symbol, PERIOD_H1, i5 - 1);
            b.formationShift = i5 - 1;
            int nb = ArraySize(result);
            ArrayResize(result, nb + 1);
            result[nb] = b;
         }
      }
      else
      {
         double obH2 = iHigh(_Symbol, PERIOD_H1, i5);
         double obL2 = iLow(_Symbol, PERIOD_H1, i5);
         bool wasBullOB = (iClose(_Symbol, PERIOD_H1, i5) > iOpen(_Symbol, PERIOD_H1, i5));
         bool broke2 = iClose(_Symbol, PERIOD_H1, i5 - 1) < obL2;
         bool adjFVG2 = iLow(_Symbol, PERIOD_H1, i5 + 1) > iHigh(_Symbol, PERIOD_H1, i5 - 1);
         if(wasBullOB && broke2 && adjFVG2 && Overlap(obH2, obL2, zone.zoneHigh, zone.zoneLow))
         {
            PDArray b2;
            b2.rank = 2;
            b2.arrayType = "Breaker";
            b2.direction = -1;
            b2.high = obH2;
            b2.low = obL2;
            b2.formationTime = iTime(_Symbol, PERIOD_H1, i5 - 1);
            b2.formationShift = i5 - 1;
            int nb2 = ArraySize(result);
            ArrayResize(result, nb2 + 1);
            result[nb2] = b2;
         }
      }
   }

   // Rank 5 Confluence elevation (from rank3/rank4 pairs)
   for(int a = 0; a < ArraySize(result); a++)
   {
      if(result[a].rank != 3 && result[a].rank != 4)
         continue;
      for(int b = a + 1; b < ArraySize(result); b++)
      {
         if((result[b].rank != 3 && result[b].rank != 4) || result[a].direction != result[b].direction)
            continue;
         double maxH = MathMax(result[a].high, result[b].high);
         double minL = MathMin(result[a].low, result[b].low);
         double dist = MathAbs(((result[a].high + result[a].low) * 0.5) - ((result[b].high + result[b].low) * 0.5));
         double baseRange = MathMax(result[a].high - result[a].low, result[b].high - result[b].low);
         if(Overlap(result[a].high, result[a].low, result[b].high, result[b].low) || (baseRange > 0 && dist <= baseRange * 0.1))
         {
            PDArray c;
            c.rank = 0;
            c.arrayType = "Confluence";
            c.direction = result[a].direction;
            c.high = maxH;
            c.low = minL;
            c.formationTime = (result[a].formationTime > result[b].formationTime) ? result[a].formationTime : result[b].formationTime;
            c.formationShift = (result[a].formationShift < result[b].formationShift) ? result[a].formationShift : result[b].formationShift;
            int nc = ArraySize(result);
            ArrayResize(result, nc + 1);
            result[nc] = c;
         }
      }
   }
}

// RankAndSelectPDArray: Selects highest-priority array (confluence first, then rank ascending), newest when tied.
bool RankAndSelectPDArray(PDArray &arrs[], PDArray &selected)
{
   if(ArraySize(arrs) == 0)
      return false;

   int bestIdx = -1;
   int bestRank = 99;
   datetime bestTime = 0;

   for(int i = 0; i < ArraySize(arrs); i++)
   {
      int r = (arrs[i].rank == 0) ? -1 : arrs[i].rank;
      if(r < bestRank || (r == bestRank && arrs[i].formationTime > bestTime))
      {
         bestRank = r;
         bestTime = arrs[i].formationTime;
         bestIdx = i;
      }
   }

   if(bestIdx < 0)
      return false;
   selected = arrs[bestIdx];
   return true;
}

// CalculateSL: Returns structural SL using swing wick before impulse that created the selected H1 array, with 10% range buffer.
double CalculateSL(const PDArray &entryArray)
{
   int s = entryArray.formationShift + 1;
   if(s < 2)
      s = 2;
   double h = iHigh(_Symbol, PERIOD_H1, s);
   double l = iLow(_Symbol, PERIOD_H1, s);
   double r = h - l;
   if(entryArray.direction == 1)
      return l - (r * 0.1);
   return h + (r * 0.1);
}

double FindOpposingLiquidity(int direction)
{
   const int look = 300;
   double price = iClose(_Symbol, PERIOD_D1, 1);
   double tol = price * 0.001;
   for(int i = 10; i < look; i++)
   {
      double p1 = (direction == 1) ? iHigh(_Symbol, PERIOD_D1, i) : iLow(_Symbol, PERIOD_D1, i);
      double p2 = (direction == 1) ? iHigh(_Symbol, PERIOD_D1, i + 1) : iLow(_Symbol, PERIOD_D1, i + 1);
      if(MathAbs(p1 - p2) <= tol)
      {
         if(direction == 1 && p1 > price)
            return p1;
         if(direction == -1 && p1 < price)
            return p1;
      }
   }
   return (direction == 1) ? iHigh(_Symbol, PERIOD_D1, 20) : iLow(_Symbol, PERIOD_D1, 20);
}

double FindNearestTroubleArea(double entry, int direction)
{
   double best = 0.0;
   double bestDist = DBL_MAX;

   for(int i = 2; i < 120; i++)
   {
      double h4h = iHigh(_Symbol, PERIOD_H4, i);
      double h4l = iLow(_Symbol, PERIOD_H4, i);
      double d1h = iHigh(_Symbol, PERIOD_D1, i);
      double d1l = iLow(_Symbol, PERIOD_D1, i);

      double candidates[4] = {h4h, h4l, d1h, d1l};
      for(int c = 0; c < 4; c++)
      {
         double lv = candidates[c];
         if(direction == 1 && lv > entry)
         {
            double d = lv - entry;
            if(d < bestDist)
            {
               bestDist = d;
               best = lv;
            }
         }
         if(direction == -1 && lv < entry)
         {
            double d2 = entry - lv;
            if(d2 < bestDist)
            {
               bestDist = d2;
               best = lv;
            }
         }
      }
   }

   return best;
}

// CalculateTP: Computes TP using conservative/full mode with nearest trouble area and opposing D1 liquidity fallback.
double CalculateTP(double entryPrice, const PDArray &entryArray)
{
   int dir = entryArray.direction;
   double trouble = FindNearestTroubleArea(entryPrice, dir);
   double oppLiq = FindOpposingLiquidity(dir);

   if(g_tpMode == TP_CONSERVATIVE)
      return (trouble > 0 ? trouble : oppLiq);

   if(g_tpMode == TP_FULL)
   {
      if(dir == 1)
      {
         if(trouble > entryPrice && trouble < oppLiq)
            return trouble;
         return oppLiq;
      }
      else
      {
         if(trouble < entryPrice && trouble > oppLiq)
            return trouble;
         return oppLiq;
      }
   }

   return oppLiq;
}

// IsSessionValid: True only during London/NY windows; all other UTC hours are blocked.
bool IsSessionValid(datetime nowUTC)
{
   MqlDateTime dt;
   TimeToStruct(nowUTC, dt);
   int h = dt.hour;
   bool inLondon = (h >= LondonStartUTC && h <= LondonEndUTC);
   bool inNY = (h >= NYStartUTC && h <= NYEndUTC);
   return (inLondon || inNY);
}

bool HasActiveTrade()
{
   return PositionSelect(_Symbol);
}

double CalcVolumeByRisk(double entry, double sl)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double riskPerLot = (MathAbs(entry - sl) / tickSize) * tickValue;
   if(riskPerLot <= 0)
      return 0;

   double vol = RiskDollars / riskPerLot;
   vol = MathFloor(vol / volStep) * volStep;
   vol = MathMax(minVol, MathMin(vol, maxVol));
   return vol;
}

// ManageZoneConsumption: Marks zone as consumed immediately after entry attempt/execution to enforce one-entry-per-zone.
void ManageZoneConsumption(int zoneIndex)
{
   if(zoneIndex < 0 || zoneIndex >= ArraySize(g_zones))
      return;
   g_zones[zoneIndex].consumed = true;
   g_zones[zoneIndex].consumedTime = TimeCurrent();
}

// ExecuteEntry: Places market orders for non-rank1 arrays and midpoint limit order for rank1 Double FVG.
bool ExecuteEntry(const PDArray &entryArray, int zoneIndex, string &reason)
{
   if(HasActiveTrade())
   {
      reason = "trade already active on symbol";
      return false;
   }

   if(!IsSessionValid(TimeGMT()))
   {
      reason = "Asian session block";
      return false;
   }

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double high1 = iHigh(_Symbol, PERIOD_H1, 1);
   double low1 = iLow(_Symbol, PERIOD_H1, 1);
   double entry = 0.0;

   if(entryArray.rank == 1)
   {
      double midpoint = (entryArray.high + entryArray.low) * 0.5;
      bool reached = (high1 >= midpoint && low1 <= midpoint);
      if(!reached)
      {
         reason = "Double FVG waiting for 50% level";
         return false;
      }
      entry = midpoint;
   }
   else
   {
      double nearEdge = (entryArray.direction == 1) ? entryArray.high : entryArray.low;
      bool tapped = (entryArray.direction == 1) ? (low1 <= nearEdge) : (high1 >= nearEdge);
      if(!tapped)
      {
         reason = "higher ranked/edge not tapped";
         return false;
      }
      entry = close1;
   }

   double sl = CalculateSL(entryArray);
   double tp = CalculateTP(entry, entryArray);
   double vol = CalcVolumeByRisk(entry, sl);
   if(vol <= 0)
   {
      reason = "invalid lot size";
      return false;
   }

   bool sent = false;
   if(entryArray.rank == 1)
   {
      datetime expiry = TimeCurrent() + (OrderExpiryCandles * 3600);
      if(entryArray.direction == 1)
         sent = trade.BuyLimit(vol, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, "ICT DoubleFVG");
      else
         sent = trade.SellLimit(vol, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, "ICT DoubleFVG");
   }
   else
   {
      if(entryArray.direction == 1)
         sent = trade.Buy(vol, _Symbol, 0.0, sl, tp, "ICT Entry");
      else
         sent = trade.Sell(vol, _Symbol, 0.0, sl, tp, "ICT Entry");
   }

   if(sent)
   {
      Print("Entry placed | entry=", DoubleToString(entry, _Digits), " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits), " lot=", DoubleToString(vol, 2),
            " TPMode=", TPModeToString(g_tpMode), " H4Zone=", g_zones[zoneIndex].zoneType,
            " H1Array=", entryArray.arrayType, " rank=", entryArray.rank);
      ManageZoneConsumption(zoneIndex);
      reason = "entry placed";
      return true;
   }

   reason = "order send failed";
   return false;
}

int OnInit()
{
   ArrayResize(g_zones, 0);
   return(INIT_SUCCEEDED);
}

// OnTick: Coordinates MTF event handling on closed D1/H4/H1 candles and drives bias->zone->entry workflow.
void OnTick()
{
   datetime d1Close = iTime(_Symbol, PERIOD_D1, 1);
   datetime h4Close = iTime(_Symbol, PERIOD_H4, 1);
   datetime h1Close = iTime(_Symbol, PERIOD_H1, 1);

   if(d1Close != 0 && d1Close != g_lastD1CloseTime)
   {
      DetectD1Bias();
      g_lastD1CloseTime = d1Close;
   }

   if(h4Close != 0 && h4Close != g_lastH4CloseTime)
   {
      IdentifyH4Zones();
      CheckZoneMitigation();
      g_lastH4CloseTime = h4Close;
   }

   if(h1Close == 0 || h1Close == g_lastH1CloseTime)
      return;

   double h1ClosePrice = iClose(_Symbol, PERIOD_H1, 1);
   string reason = "";

   if(g_biasState == NEUTRAL)
   {
      Print("H1 Eval | Bias=", BiasToString(g_biasState), " TPMode=", TPModeToString(g_tpMode),
            " H1Close=", DoubleToString(h1ClosePrice, _Digits), " | no entry: no active H4 zone");
      g_lastH1CloseTime = h1Close;
      return;
   }

   if(HasActiveTrade())
   {
      Print("H1 Eval | Bias=", BiasToString(g_biasState), " TPMode=", TPModeToString(g_tpMode),
            " H1Close=", DoubleToString(h1ClosePrice, _Digits), " | no entry: trade already active on symbol");
      g_lastH1CloseTime = h1Close;
      return;
   }

   int zoneIdx = IsPriceInH4Zone(h1ClosePrice);
   if(zoneIdx < 0)
   {
      Print("H1 Eval | Bias=", BiasToString(g_biasState), " TPMode=", TPModeToString(g_tpMode),
            " H1Close=", DoubleToString(h1ClosePrice, _Digits), " | no entry: no active H4 zone");
      g_lastH1CloseTime = h1Close;
      return;
   }

   if(g_zones[zoneIdx].consumed)
   {
      Print("H1 Eval | Bias=", BiasToString(g_biasState), " TPMode=", TPModeToString(g_tpMode),
            " H1Close=", DoubleToString(h1ClosePrice, _Digits), " | zone consumed");
      g_lastH1CloseTime = h1Close;
      return;
   }

   Print("H1 Eval | Bias=", BiasToString(g_biasState), " TPMode=", TPModeToString(g_tpMode),
         " H1Close=", DoubleToString(h1ClosePrice, _Digits),
         " | InZone=YES type=", g_zones[zoneIdx].zoneType,
         " dir=", (g_zones[zoneIdx].direction == 1 ? "bullish" : "bearish"),
         " high=", DoubleToString(g_zones[zoneIdx].zoneHigh, _Digits),
         " low=", DoubleToString(g_zones[zoneIdx].zoneLow, _Digits));

   PDArray candidates[];
   FindH1FractalPDArrays(g_zones[zoneIdx], candidates);

   PDArray chosen;
   if(!RankAndSelectPDArray(candidates, chosen))
   {
      Print("H1 Eval | no entry: no H1 fractal array found");
      g_lastH1CloseTime = h1Close;
      return;
   }

   Print("H1 Array | rank=", chosen.rank, " type=", chosen.arrayType,
         " high=", DoubleToString(chosen.high, _Digits),
         " low=", DoubleToString(chosen.low, _Digits));

   ExecuteEntry(chosen, zoneIdx, reason);
   if(reason != "entry placed")
      Print("H1 Eval | no entry: ", reason);

   g_lastH1CloseTime = h1Close;
}
