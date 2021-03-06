{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- Module      : Khan.Internal.AWS
-- Copyright   : (c) 2013 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Khan.Internal.AWS
    (
    -- * Filters
      ec2Filter
    , asgFilter

    -- * EC2 Metadata
    , Meta(..)
    , meta

    -- * Encapsulate/rerun an AWS context
    , contextAWS

    -- * Region
    , abbreviate

    -- * Errors
    , liftAWS
    , throwAWS
    , noteAWS

    -- * Asserts
    , verifyAS
    , verifyEC2
    , verifyIAM

    -- * Shell
--    , which
    ) where

import           Control.Monad.Except
import qualified Data.Text.Encoding        as Text
import           Data.Text.Format          (Format, format)
import           Data.Text.Format.Params
import qualified Data.Text.Lazy            as LText
import           Khan.Internal.IO
import           Khan.Internal.Options
import           Khan.Prelude              hiding (min, max)
import           Network.AWS
import           Network.AWS.AutoScaling   as ASG hiding (DescribeTags)
import           Network.AWS.EC2           as EC2
import           Network.AWS.EC2.Metadata  (Meta(..))
import qualified Network.AWS.EC2.Metadata  as Meta
import           Network.AWS.IAM
import           UnexceptionalIO           (Unexceptional)

ec2Filter :: Text -> [Text] -> EC2.Filter
ec2Filter = EC2.Filter

asgFilter :: Text -> [Text] -> ASG.Filter
asgFilter = ASG.Filter

meta :: (Functor m, MonadIO m, Unexceptional m) => Meta -> ExceptT String m Text
meta = fmap Text.decodeUtf8 . Meta.meta

contextAWS :: MonadIO m => Common -> AWS a -> m (Either AWSError a)
contextAWS Common{..} = liftIO . runAWS AuthDiscover cDebug . within cRegion

abbreviate :: Region -> Text
abbreviate NorthVirginia   = "va"
abbreviate NorthCalifornia = "ca"
abbreviate Oregon          = "or"
abbreviate Ireland         = "ie"
abbreviate Singapore       = "sg"
abbreviate Tokyo           = "tyo"
abbreviate Sydney          = "syd"
abbreviate SaoPaulo        = "sao"

--liftAWS :: MonadIO m => IO a -> ExceptT String m a
liftAWS :: IO a -> AWS a
liftAWS = liftEitherT . sync

throwAWS :: (Params a, MonadError AWSError m) => Format -> a -> m b
throwAWS f = throwError . Err . LText.unpack . format f

noteAWS :: (Params ps, MonadError AWSError m)
        => Format
        -> ps
        -> Maybe a
        -> m a
noteAWS f ps = hoistError . note (Err . LText.unpack $ format f ps)

verifyAS :: Text -> Either AutoScalingErrorResponse a -> AWS ()
verifyAS  = (`verify` (aseCode . aserError))

verifyEC2 :: Text -> Either EC2ErrorResponse a -> AWS ()
verifyEC2 = (`verify` (ecCode . head . eerErrors))

verifyIAM :: Text -> Either IAMError a -> AWS ()
verifyIAM = (`verify` (etCode . erError))

verify :: (MonadError AWSError m, Eq a, ToError e)
       => a
       -> (e -> a)
       -> Either e b
       -> m ()
verify k f = g
  where
    g (Right _) = return ()
    g (Left  x) | k == f x  = return ()
                | otherwise = throwError $ toError x

-- FIXME: Move to IO module
-- which :: String -> AWS ()
-- which cmd = shell (FS.which $ Path.decodeString cmd) >>=
--     void . noteAWS "Command {} doesn't exist." [B cmd]
