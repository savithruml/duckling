-- Copyright (c) 2016-present, Facebook, Inc.
-- All rights reserved.
--
-- This source code is licensed under the BSD-style license found in the
-- LICENSE file in the root directory of this source tree. An additional grant
-- of patent rights can be found in the PATENTS file in the same directory.


{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoRebindableSyntax #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

module Duckling.Time.Types where

import Control.Arrow ((***))
import Control.DeepSeq
import Control.Monad (join)
import Data.Aeson
import Data.Hashable
import qualified Data.HashMap.Strict as H
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified Data.Time.Calendar.WeekDate as Time
import qualified Data.Time.LocalTime.TimeZone.Series as Series
import GHC.Generics
import TextShow (showt)
import Prelude

import Duckling.Resolve
import Duckling.TimeGrain.Types (Grain)
import qualified Duckling.TimeGrain.Types as TG

data TimeObject = TimeObject
  { start :: Time.UTCTime
  , grain :: Grain
  , end :: Maybe Time.UTCTime
  } deriving (Eq, Show)

data Form = DayOfWeek
  | TimeOfDay
    { hours :: Maybe Int
    , is12H :: Bool
    }
  | Month { month :: Int }
  | PartOfDay
  deriving (Eq, Generic, Hashable, Show, Ord, NFData)

data IntervalDirection = Before | After
  deriving (Eq, Generic, Hashable, Ord, Show, NFData)

-- Grain needed here for intersect
data TimeData = TimeData
  { timePred :: Predicate
  , latent :: Bool
  , timeGrain :: Grain
  , notImmediate :: Bool
  , form :: Maybe Form
  , direction :: Maybe IntervalDirection
  }

instance Eq TimeData where
  (==) (TimeData _ l1 g1 n1 f1 d1) (TimeData _ l2 g2 n2 f2 d2) =
    l1 == l2 && g1 == g2 && n1 == n2 && f1 == f2 && d1 == d2

instance Hashable TimeData where
  hashWithSalt s (TimeData _ latent grain imm form dir) = hashWithSalt s
    (0::Int, (latent, grain, imm, form, dir))

instance Ord TimeData where
  compare (TimeData _ l1 g1 n1 f1 d1) (TimeData _ l2 g2 n2 f2 d2) =
    case compare g1 g2 of
      EQ -> case compare f1 f2 of
        EQ -> case compare l1 l2 of
          EQ -> case compare n1 n2 of
            EQ -> compare d1 d2
            z -> z
          z -> z
        z -> z
      z -> z

instance Show TimeData where
  show (TimeData _ latent grain _ form dir) =
    "TimeData{" ++
    "latent=" ++ show latent ++
    ", grain=" ++ show grain ++
    ", form=" ++ show form ++
    ", direction=" ++ show dir ++
    "}"

instance NFData TimeData where
  rnf TimeData{..} = rnf (latent, timeGrain, notImmediate, form, direction)

instance Resolve TimeData where
  type ResolvedValue TimeData = TimeValue
  resolve _ TimeData {latent = True} = Nothing
  resolve context TimeData {timePred, notImmediate, direction} = do
    t <- case ts of
      (behind, []) -> listToMaybe behind
      (_, ahead:nextAhead:_)
        | notImmediate && isJust (timeIntersect ahead refTime) -> Just nextAhead
      (_, ahead:_) -> Just ahead
    Just $ case direction of
      Nothing -> TimeValue (timeValue tzSeries t) .
        map (timeValue tzSeries) $ take 3 future
      Just d -> TimeValue (openInterval tzSeries d t) .
        map (openInterval tzSeries d) $ take 3 future
    where
      DucklingTime (Series.ZoneSeriesTime utcTime tzSeries) = referenceTime context
      refTime = TimeObject
        { start = utcTime
        , grain = TG.Second
        , end = Nothing
        }
      tc = TimeContext
        { refTime = refTime
        , tzSeries = tzSeries
        , maxTime = timePlus refTime TG.Year 2000
        , minTime = timePlus refTime TG.Year $ - 2000
        }
      ts@(_, future) = runPredicate timePred refTime tc

timedata' :: TimeData
timedata' = TimeData
  { timePred = EmptyPredicate
  , latent = False
  , timeGrain = TG.Second
  , notImmediate = False
  , form = Nothing
  , direction = Nothing
  }

data TimeContext = TimeContext
  { refTime  :: TimeObject
  , tzSeries :: Series.TimeZoneSeries
  , maxTime  :: TimeObject
  , minTime  :: TimeObject
  }

data InstantValue = InstantValue
  { vValue :: Time.ZonedTime
  , vGrain :: Grain
  }
  deriving (Show)

instance Eq InstantValue where
  (==) (InstantValue (Time.ZonedTime lt1 tz1) g1)
       (InstantValue (Time.ZonedTime lt2 tz2) g2) =
    g1 == g2 && lt1 == lt2 && tz1 == tz2

data SingleTimeValue
  = SimpleValue InstantValue
  | IntervalValue (InstantValue, InstantValue)
  | OpenIntervalValue (InstantValue, IntervalDirection)
  deriving (Show, Eq)

data TimeValue = TimeValue SingleTimeValue [SingleTimeValue]
  deriving (Show, Eq)

instance ToJSON InstantValue where
  toJSON (InstantValue value grain) = object
    [ "value" .= toRFC3339 value
    , "grain" .= grain
    ]

instance ToJSON SingleTimeValue where
  toJSON (SimpleValue value) = case toJSON value of
    Object o -> Object $ H.insert "type" (toJSON ("value" :: Text)) o
    _ -> Object H.empty
  toJSON (IntervalValue (from, to)) = object
    [ "type" .= ("interval" :: Text)
    , "from" .= toJSON from
    , "to" .= toJSON to
    ]
  toJSON (OpenIntervalValue (instant, Before)) = object
    [ "type" .= ("interval" :: Text)
    , "to" .= toJSON instant
    ]
  toJSON (OpenIntervalValue (instant, After)) = object
    [ "type" .= ("interval" :: Text)
    , "from" .= toJSON instant
    ]

instance ToJSON TimeValue where
  toJSON (TimeValue value values) = case toJSON value of
    Object o -> Object $ H.insert "values" (toJSON values) o
    _ -> Object H.empty

-- | Return a tuple of (past, future) elements
type SeriesPredicate = TimeObject -> TimeContext -> ([TimeObject], [TimeObject])

data AMPM = AM | PM
  deriving Eq

data Predicate
  = SeriesPredicate SeriesPredicate
  | EmptyPredicate
  | TimeDatePredicate -- invariant: at least one of them is Just
    { tdSecond :: Maybe Int
    , tdMinute :: Maybe Int
    , tdHour :: Maybe (Bool, Int)
    , tdAMPM :: Maybe AMPM -- only used if we have an hour
    , tdDayOfTheWeek :: Maybe Int
    , tdDayOfTheMonth :: Maybe Int
    , tdMonth :: Maybe Int
    , tdYear :: Maybe Int
    }
  | IntersectPredicate Predicate Predicate

{-# ANN runPredicate ("HLint: ignore Use foldr1OrError" :: String) #-}
runPredicate :: Predicate -> SeriesPredicate
runPredicate EmptyPredicate = \_ _ -> ([], [])
runPredicate (SeriesPredicate p) = p
runPredicate TimeDatePredicate{..}
  -- This should not happen by construction, but if it does then
  -- empty time series should be ok
  | isNothing tdHour && isJust tdAMPM = \_ _ -> ([], [])
runPredicate TimeDatePredicate{..} =
  foldr1 runCompose toCompose
  where
  -- runComposePredicate performs best when the first predicate is of
  -- smaller grain, that's why we order by grain here
  toCompose = catMaybes
    [ runSecondPredicate <$> tdSecond
    , runMinutePredicate <$> tdMinute
    , uncurry (runHourPredicate tdAMPM) <$> tdHour
    , runDayOfTheWeekPredicate <$> tdDayOfTheWeek
    , runDayOfTheMonthPredicate <$> tdDayOfTheMonth
    , runMonthPredicate <$> tdMonth
    , runYearPredicate <$> tdYear
    ]
runPredicate (IntersectPredicate pred1 pred2) =
  runIntersectPredicate pred1 pred2

-- Don't use outside this module, use a smart constructor
emptyTimeDatePredicate :: Predicate
emptyTimeDatePredicate =
  TimeDatePredicate Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    Nothing

-- Predicate smart constructors

mkSeriesPredicate :: SeriesPredicate -> Predicate
mkSeriesPredicate = SeriesPredicate

mkSecondPredicate :: Int -> Predicate
mkSecondPredicate n = emptyTimeDatePredicate { tdSecond = Just n }

mkMinutePredicate :: Int -> Predicate
mkMinutePredicate n = emptyTimeDatePredicate { tdMinute = Just n }

mkHourPredicate :: Bool -> Int -> Predicate
mkHourPredicate is12H h = emptyTimeDatePredicate { tdHour = Just (is12H, h) }

mkAMPMPredicate :: AMPM -> Predicate
mkAMPMPredicate ampm = emptyTimeDatePredicate { tdAMPM = Just ampm }

mkDayOfTheWeekPredicate :: Int -> Predicate
mkDayOfTheWeekPredicate n = emptyTimeDatePredicate { tdDayOfTheWeek = Just n }

mkDayOfTheMonthPredicate :: Int -> Predicate
mkDayOfTheMonthPredicate n = emptyTimeDatePredicate { tdDayOfTheMonth = Just n }

mkMonthPredicate :: Int -> Predicate
mkMonthPredicate n = emptyTimeDatePredicate { tdMonth = Just n }

mkYearPredicate :: Int -> Predicate
mkYearPredicate n = emptyTimeDatePredicate { tdYear = Just n }

mkIntersectPredicate :: Predicate -> Predicate -> Predicate
mkIntersectPredicate EmptyPredicate _ = EmptyPredicate
mkIntersectPredicate _ EmptyPredicate = EmptyPredicate
mkIntersectPredicate
  (TimeDatePredicate a1 b1 c1 d1 e1 f1 g1 h1)
  (TimeDatePredicate a2 b2 c2 d2 e2 f2 g2 h2)
  = fromMaybe EmptyPredicate
      (TimeDatePredicate <$>
        unify a1 a2 <*>
        unify b1 b2 <*>
        unify c1 c2 <*>
        unify d1 d2 <*>
        unify e1 e2 <*>
        unify f1 f2 <*>
        unify g1 g2 <*>
        unify h1 h2)
  where
  unify Nothing a = Just a
  unify a Nothing = Just a
  unify ma@(Just a) (Just b)
    | a == b = Just ma
    | otherwise = Nothing
mkIntersectPredicate pred1 pred2 = IntersectPredicate pred1 pred2

-- Predicate runners

runSecondPredicate :: Int -> SeriesPredicate
runSecondPredicate n = series
  where
  series t _ = timeSequence TG.Minute 1 anchor
    where
      Time.UTCTime _ diffTime = start t
      Time.TimeOfDay _ _ s = Time.timeToTimeOfDay diffTime
      anchor = timePlus (timeRound t TG.Second) TG.Second
        $ mod (toInteger n - floor s :: Integer) 60

runMinutePredicate :: Int -> SeriesPredicate
runMinutePredicate n = series
  where
  series t _ = timeSequence TG.Hour 1 anchor
    where
      Time.UTCTime _ diffTime = start t
      Time.TimeOfDay _ m _ = Time.timeToTimeOfDay diffTime
      rounded = timeRound t TG.Minute
      anchor = timePlus rounded TG.Minute . toInteger $ mod (n - m) 60

runHourPredicate :: Maybe AMPM -> Bool -> Int -> SeriesPredicate
runHourPredicate ampm is12H n = series
  where
  series t _ =
    ( drop 1 $
        iterate (\t -> timePlus t TG.Hour . toInteger $ - step) anchor
    , iterate (\t -> timePlus t TG.Hour $ toInteger step) anchor
    )
    where
      Time.UTCTime _ diffTime = start t
      Time.TimeOfDay h _ _ = Time.timeToTimeOfDay diffTime
      step :: Int
      step = if is12H && n <= 12 && isNothing ampm then 12 else 24
      n' = case ampm of
            Just AM -> n `mod` 12
            Just PM -> (n `mod` 12) + 12
            Nothing -> n
      rounded = timeRound t TG.Hour
      anchor = timePlus rounded TG.Hour . toInteger $ mod (n' - h) step

runAMPMPredicate :: AMPM -> SeriesPredicate
runAMPMPredicate ampm = series
  where
  series t _ = (past, future)
    where
    past = maybeShrinkFirst $
      iterate (\t -> timePlusEnd t TG.Hour . toInteger $ - step) anchor
    future = maybeShrinkFirst $
      iterate (\t -> timePlusEnd t TG.Hour $ toInteger step) anchor
    -- to produce time in the future/past we need to adjust
    -- the start/end of the first interval
    maybeShrinkFirst (a:as) =
      case timeIntersect (t { grain = TG.Day }) a of
        Nothing -> as
        Just ii -> ii:as
    maybeShrinkFirst a = a
    step :: Int
    step = 24
    n = case ampm of
          AM -> 0
          PM -> 12
    rounded = timeRound t TG.Day
    anchorStart = timePlus rounded TG.Hour n
    anchorEnd = timePlus anchorStart TG.Hour 12
    -- an interval of length 12h starting either at 12am or 12pm,
    -- the same day as input time
    anchor = timeInterval Open anchorStart anchorEnd

runDayOfTheWeekPredicate :: Int -> SeriesPredicate
runDayOfTheWeekPredicate n = series
  where
  series t _ = timeSequence TG.Day 7 anchor
    where
      Time.UTCTime day _ = start t
      (_, _, dayOfWeek) = Time.toWeekDate day
      daysUntilNextWeek = toInteger $ mod (n - dayOfWeek) 7
      anchor =
        timePlus (timeRound t TG.Day) TG.Day daysUntilNextWeek

runDayOfTheMonthPredicate :: Int -> SeriesPredicate
runDayOfTheMonthPredicate n = series
  where
  series t _ =
    ( map addDays . filter enoughDays . iterate (addMonth $ - 1) $
        addMonth (- 1) anchor
    , map addDays . filter enoughDays $ iterate (addMonth 1) anchor
    )
    where
      enoughDays :: TimeObject -> Bool
      enoughDays t = let Time.UTCTime day _ = start t
                         (year, month, _) = Time.toGregorian day
                     in n <= Time.gregorianMonthLength year month
      addDays :: TimeObject -> TimeObject
      addDays t = timePlus t TG.Day . toInteger $ n - 1
      addMonth :: Int -> TimeObject -> TimeObject
      addMonth i t = timePlus t TG.Month $ toInteger i
      roundMonth :: TimeObject -> TimeObject
      roundMonth t = timeRound t TG.Month
      rounded = roundMonth t
      Time.UTCTime day _ = start t
      (_, _, dayOfMonth) = Time.toGregorian day
      anchor = if dayOfMonth <= n then rounded else addMonth 1 rounded

runMonthPredicate :: Int -> SeriesPredicate
runMonthPredicate n = series
  where
  series t _ = timeSequence TG.Year 1 anchor
    where
      rounded =
        timePlus (timeRound t TG.Year) TG.Month . toInteger $ n - 1
      anchor = if timeStartsBeforeTheEndOf t rounded
        then rounded
        else timePlus rounded TG.Year 1

-- | Converts 2-digits to a year between 1950 and 2050
runYearPredicate :: Int -> SeriesPredicate
runYearPredicate n = series
  where
  series t _ =
    if tyear <= year
      then ([], [y])
      else ([y], [])
    where
      Time.UTCTime day _ = start t
      (tyear, _, _) = Time.toGregorian day
      year = toInteger $ if n <= 99 then mod (n + 50) 100 + 2000 - 50 else n
      y = timePlus (timeRound t TG.Year) TG.Year $ year - tyear

-- Limits how deep into lists of segments to look
safeMax :: Int
safeMax = 10

runIntersectPredicate :: Predicate -> Predicate -> SeriesPredicate
runIntersectPredicate pred1 pred2 =
  runCompose (runPredicate pred1) (runPredicate pred2)

-- Performs best when pred1 is smaller grain than pred2
runCompose :: SeriesPredicate -> SeriesPredicate -> SeriesPredicate
runCompose pred1 pred2 = series
  where
  series nowTime context = (backward, forward)
    where
    (past, future) = pred2 nowTime context
    computeSerie tokens =
      [t | time1 <- take safeMax tokens
         , t <- mapMaybe (timeIntersect time1) .
                takeWhile (startsBefore time1) .
                snd . pred1 time1 $ fixedRange time1
      ]

    startsBefore t1 this = timeStartsBeforeTheEndOf this t1
    fixedRange t1 = context {minTime = t1, maxTime = t1}

    backward = computeSerie $ takeWhile (\t ->
      timeStartsBeforeTheEndOf (minTime context) t) past
    forward = computeSerie $ takeWhile (\t ->
      timeStartsBeforeTheEndOf t (maxTime context)) future

timeSequence
  :: TG.Grain
  -> Int
  -> TimeObject
  -> ([TimeObject], [TimeObject])
timeSequence grain step anchor =
  ( drop 1 $ iterate (f $ - step) anchor
  , iterate (f step) anchor
  )
  where
    f :: Int -> TimeObject -> TimeObject
    f n t = timePlus t grain $ toInteger n

-- | Zero-pad `x` to reach length `n`.
pad :: Int -> Int -> Text
pad n x
  | x <= magnitude = Text.replicate (n - Text.length s) "0" <> s
  | otherwise      = s
  where
    magnitude = round ((10 :: Float) ** fromIntegral (n - 1) :: Float)
    s = showt x

-- | Return the timezone offset portion of the RFC3339 format, e.g. "-02:00".
timezoneOffset :: Time.TimeZone -> Text
timezoneOffset (Time.TimeZone t _ _) = Text.concat [sign, hh, ":", mm]
  where
    (sign, t') = if t < 0 then ("-", negate t) else ("+", t)
    (hh, mm) = join (***) (pad 2) $ divMod t' 60

-- | Return a RFC3339 formatted time, e.g. "2013-02-12T04:30:00.000-02:00".
-- | Backward-compatible with Duckling: fraction of second is milli and padded.
toRFC3339 :: Time.ZonedTime -> Text
toRFC3339 (Time.ZonedTime (Time.LocalTime day (Time.TimeOfDay h m s)) tz) =
  Text.concat
    [ Text.pack $ Time.showGregorian day
    , "T"
    , pad 2 h
    , ":"
    , pad 2 m
    , ":"
    , pad 2 $ floor s
    , "."
    , pad 3 . round $ (s - realToFrac (floor s :: Integer)) * 1000
    , timezoneOffset tz
    ]

instantValue :: Series.TimeZoneSeries -> Time.UTCTime -> Grain -> InstantValue
instantValue tzSeries t g = InstantValue
  { vValue = fromUTC t $ Series.timeZoneFromSeries tzSeries t
  , vGrain = g
  }

timeValue :: Series.TimeZoneSeries -> TimeObject -> SingleTimeValue
timeValue tzSeries (TimeObject s g Nothing) =
  SimpleValue $ instantValue tzSeries s g
timeValue tzSeries (TimeObject s g (Just e)) = IntervalValue
  ( instantValue tzSeries s g
  , instantValue tzSeries e g
  )

openInterval
  :: Series.TimeZoneSeries -> IntervalDirection -> TimeObject -> SingleTimeValue
openInterval tzSeries direction (TimeObject s g _) = OpenIntervalValue
  ( instantValue tzSeries s g
  , direction
  )

-- -----------------------------------------------------------------
-- Time object helpers

timeRound :: TimeObject -> TG.Grain -> TimeObject
timeRound t TG.Week = TimeObject {start = s, grain = TG.Week, end = Nothing}
  where
    Time.UTCTime day diffTime = start $ timeRound t TG.Day
    (year, week, _) = Time.toWeekDate day
    newDay = Time.fromWeekDate year week 1
    s = Time.UTCTime newDay diffTime
timeRound t TG.Quarter = newTime {grain = TG.Quarter}
  where
    monthTime = timeRound t TG.Month
    Time.UTCTime day _ = start monthTime
    (_, month, _) = Time.toGregorian day
    newTime = timePlus monthTime TG.Month . toInteger $ - (mod (month - 1) 3)
timeRound t grain = TimeObject {start = s, grain = grain, end = Nothing}
  where
    Time.UTCTime day diffTime = start t
    timeOfDay = Time.timeToTimeOfDay diffTime
    (year, month, dayOfMonth) = Time.toGregorian day
    Time.TimeOfDay hours mins secs = timeOfDay
    newMonth = if grain > TG.Month then 1 else month
    newDayOfMonth = if grain > TG.Day then 1 else dayOfMonth
    newDay = Time.fromGregorian year newMonth newDayOfMonth
    newHours = if grain > TG.Hour then 0 else hours
    newMins = if grain > TG.Minute then 0 else mins
    newSecs = if grain > TG.Second then 0 else secs
    newDiffTime = Time.timeOfDayToTime $ Time.TimeOfDay newHours newMins newSecs
    s = Time.UTCTime newDay newDiffTime

timePlus :: TimeObject -> TG.Grain -> Integer -> TimeObject
timePlus (TimeObject start grain _) theGrain n = TimeObject
  { start = TG.add start theGrain n
  , grain = min grain theGrain
  , end = Nothing
  }

-- | Shifts the whole interval by n units of theGrain
-- Returned interval has the same length as the input one
timePlusEnd :: TimeObject -> TG.Grain -> Integer -> TimeObject
timePlusEnd (TimeObject start grain end) theGrain n = TimeObject
  { start = TG.add start theGrain n
  , grain = min grain theGrain
  , end = TG.add <$> end <*> return theGrain <*> return n
  }

timeEnd :: TimeObject -> Time.UTCTime
timeEnd (TimeObject start grain end) = fromMaybe (TG.add start grain 1) end

timeStartingAtTheEndOf :: TimeObject -> TimeObject
timeStartingAtTheEndOf t = TimeObject
  {start = timeEnd t, end = Nothing, grain = grain t}

-- | Closed if the interval between A and B should include B
-- Open if the interval should end right before B
data TimeIntervalType = Open | Closed

timeInterval :: TimeIntervalType -> TimeObject -> TimeObject -> TimeObject
timeInterval intervalType t1 t2 = TimeObject
  { start = start t1
  , grain = min (grain t1) (grain t2)
  , end = Just $ case intervalType of
                   Open -> start t2
                   Closed -> timeEnd t2
  }

timeStartsBeforeTheEndOf :: TimeObject -> TimeObject -> Bool
timeStartsBeforeTheEndOf t1 t2 = start t1 < timeEnd t2

timeBefore :: TimeObject -> TimeObject -> Bool
timeBefore t1 t2 = start t1 < start t2

-- | Intersection between two `TimeObject`.
-- The resulting grain and end fields are the smallest.
-- Prefers intervals when the range is equal.
timeIntersect :: TimeObject -> TimeObject -> Maybe TimeObject
timeIntersect t1 t2
  | s1 > s2 = timeIntersect t2 t1
  | e1 <= s2 = Nothing
  | e1 < e2 || s1 == s2 && e1 == e2 && isJust end1 = Just TimeObject
    {start = s2, end = end1, grain = g'}
  | otherwise = Just t2 {grain = g'}
  where
    TimeObject s1 g1 end1 = t1
    TimeObject s2 g2 _    = t2
    e1 = timeEnd t1
    e2 = timeEnd t2
    g' = min g1 g2
