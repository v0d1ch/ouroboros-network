{-|
Module:      DeltaQ.Statistics
Description: statistical computations related to shortest paths in network
             graphs.
-}

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE GADTSyntax          #-}
{-# LANGUAGE StandaloneDeriving  #-}

module DeltaQ.Statistics where

import Algebra.Graph.Labelled.AdjacencyMap (AdjacencyMap)
import qualified Algebra.Graph.Labelled.AdjacencyMap as Graph
import Algebra.Graph.Labelled.AdjacencyMap.ShortestPath
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Semigroup (Last (..))
import Data.Vector.Unboxed (Vector)
import qualified Data.Vector.Unboxed as Vector
import DeltaQ.TCP
import DeltaQ.Topography
import Numeric.Natural (Natural)
import qualified Statistics.Quantile as Stats
import qualified Statistics.Sample as Stats

-- | Make an unboxed vector of total distances, suitable for use with the
-- statistics package. 'Statistics.Sample.meanVariance' and
-- 'Statistics.Quantile.median' may be of interest.
-- The identifiers of the other nodes are forgotten.
-- The semigroup instance on weight is needed in order to compute the total
-- length of each path. Then the total length is made a Double by the given
-- function. It would also make sense to map these weights to Double first,
-- then use the Sum semigroup. Thus that function should be a semigroup
-- homomorphism to @(Double, (+), 0.0)@.
-- If there are unreachable nodes, infinity is used.
distances
  :: forall vertex edge weight .
     (Semigroup weight)
  => (weight -> Double)
  -> ShortestPaths vertex edge weight
  -> Vector Double
distances to_double = Vector.fromList . fmap total_weight_inf . Map.elems
  where
  total_weight_inf :: WeightedPath vertex edge weight -> Double
  total_weight_inf = maybe infinity to_double . total_weight
  -- Could also @read "Infinity"@.
  -- Is there no better way to get infinity?
  infinity :: Double
  infinity = 1.0 / 0.0

-- | Empirical distribution function. If there are no samples, it's @const 0.0@.
edf :: Vector Double -> Double -> Double
edf samples x
  | num_samples == 0 = 0.0
  | otherwise        = fromRational (toRational (num_samples_lt samples x) / toRational num_samples)
  where
  num_samples :: Natural
  num_samples = fromIntegral (Vector.length samples)

-- | Count the number of samples less than or equal to a given value.
num_samples_lt :: Vector Double -> Double -> Natural
num_samples_lt samples x = Vector.foldr include 0 samples
  where
  include :: Double -> Natural -> Natural
  include a !n = if a <= x then n+1 else n

type Statistic = [Double] -> Double

mean :: Statistic
mean = Stats.mean . Vector.fromList

median :: Statistic
median = percentile 50

-- | In the context of path lengths,
-- @edf (distances to_seconds shortest_paths) d@ will give the probability that
-- a peer is reached within a given duration @d@. But we also would like to
-- know the smallest duration such that a given number of peers will be reached
-- before that duration has elapsed... or rather, the smallest duration such
-- that a peer will be reached with a given probability. That's to say, we're
-- after quantiles.
--
-- The statistics package does quantile estimation. For convenience, this
-- function will choose the alpha/beta parameters for interpolation, and
-- do percentiles, since we're interested in the duration at which 95% of
-- peers will be reached.
percentile :: Natural -> Statistic
percentile n = Stats.quantile contParam k 100 . Vector.fromList
  where
  k = if n >= 100 then 100 else fromIntegral n
  contParam = Stats.s

data Observations = Observations
  { -- | Compute a "local" statistic for each peer with its distances to all
    -- other peers.
    local_observation  :: Statistic
    -- | Compute a "global" statistic over all of the local statistics.
  , global_observation :: Statistic
  }

characteristic_path_length :: Observations
characteristic_path_length = Observations
  { local_observation  = mean
  , global_observation = median
  }

max_path_length :: Observations
max_path_length = Observations
  { local_observation  = percentile 100
  , global_observation = percentile 100
  }

average_percentile :: Natural -> Observations
average_percentile p = Observations
  { local_observation  = percentile p
  , global_observation = mean
  }

-- | Will be used as an edge weight in shortest-path computation. As such, its
-- Ord instance is key: @Lost@ is greater than everything. Its Semigroup
-- instance is also essential for it gives the length of multi-edge paths.
data Latency where
  Lost        :: Latency
  -- | Number of seconds to transmit.
  Transmitted :: !Rational -> Latency

deriving instance Show Latency

instance Eq Latency where
  Lost          == Lost          = True
  Transmitted a == Transmitted b = a == b
  _             == _             = False

instance Ord Latency where
  Lost `compare` Lost = EQ
  Lost `compare` _    = GT
  _    `compare` Lost = LT
  Transmitted a `compare` Transmitted b = a `compare` b

-- Sum monoid with infinity.
instance Semigroup Latency where
  Lost <> _    = Lost
  _    <> Lost = Lost
  Transmitted a <> Transmitted b = Transmitted (a + b)

instance Monoid Latency where
  mappend = (<>)
  mempty  = Transmitted 0

-- | Uses @Infinity :: Double@ for 'Lost'
to_seconds_double :: Latency -> Maybe Double
to_seconds_double Lost            = Nothing
to_seconds_double (Transmitted a) = Just $ fromRational a

data Edge e where
  Out  :: !e -> Edge e
  In   :: !e -> Edge e
  Both :: !e -> !e -> Edge e

instance Semigroup e => Semigroup (Edge e) where

  Out o <> Out o'    = Out  (o <> o')
  Out o <> In i      = Both o i
  Out o <> Both o' i = Both (o <> o') i

  In i <> In i'     = In (i <> i')
  In i <> Out o     = Both o i
  In i <> Both o i' = Both o (i <> i')

  Both i o <> Both i' o' = Both (i <> i') (o <> o')

bidirectional_bearer_graph
  :: (Ord peer)
  => Topography BearerCharacteristics peer
  -> AdjacencyMap (Edge (Last BearerCharacteristics)) peer
bidirectional_bearer_graph graph = Graph.overlay
  (Graph.emap Out graph)
  (Graph.emap In  (Graph.transpose graph))

-- | An experiment on a @Topography BearerCharacteristics peer@ that is
-- parameterised by @param@. See @runExperiment@.
data Experiment peer param = Experiment
  { topography       :: param -> Topography BearerCharacteristics peer
  , observations     :: Observations
  }

-- | Runs an @Experiment@ by weighting edges in the graph using
-- @tcpRPCLoadPattern@ (some params hard-coded). Path/edge weights are
-- seconds to complete a transfer of the given number of bytes, or Infinity.
--
-- FIXME we may want to treat the response size (size of block) as a parameter
-- for statistical analysis.
--
-- FIXME infinite distances are removed from the results, because statistics
-- functions will error on NaNs. How best to deal with this?
runExperiment
  :: forall peer param .
     (Ord peer)
  => Natural
  -> Experiment peer param
  -> param
  -> Double
runExperiment bytes experiment param = globals

  where

  globals :: Double
  globals = global_observation (observations experiment) (Map.elems locals)

  locals :: Map peer Double
  locals = fmap (local_observation (observations experiment)) all_finite_local_lengths

  all_finite_local_lengths :: Map peer [Double]
  all_finite_local_lengths = fmap finite_local_lengths all_sps

  finite_local_lengths :: forall edge . Map peer (WeightedPath peer edge Latency) -> [Double]
  finite_local_lengths = mapMaybe local_length . Map.elems

  local_length :: forall edge . WeightedPath peer edge Latency -> Maybe Double
  local_length = to_seconds_double . fromMaybe Lost . total_weight

  all_sps = all_pairs_sp weight graph

  uni_graph = topography experiment param
  graph     = bidirectional_bearer_graph uni_graph

  weight :: peer -> peer -> Edge (Last BearerCharacteristics) -> Latency
  weight _ _ (Out _) = Lost
  weight _ _ (In _)  = Lost
  weight _ _ (Both (Last o) (Last i)) =
    let pattern = tcpRPCLoadPattern i o pdu_overhead initial_window Nothing request_size response_size
    in  Transmitted $ toRational (fst (last pattern))

  -- TODO proper request size? It's not that important.
  request_size :: Natural
  request_size = 256

  response_size :: Natural
  response_size = bytes

  pdu_overhead :: Natural
  pdu_overhead = 20

  initial_window :: Natural
  initial_window = 4
