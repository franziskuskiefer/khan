{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}

-- Module      : Network.AWS
-- Copyright   : (c) 2013 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

-- |
module Network.AWS
    (
    -- * AWS Context
      AWS
    , runAWS

    , AWSEnv
    , loadAWSEnv
    , runAWSEnv

    , getEnv
    , runEnv

    -- * Credentials
    , Credentials      (..)

    -- * Regions
    , Region           (..)
    , within
    , getRegion

    -- * Debugging
    , getDebug
    , whenDebug

    -- * Synchronous Requests
    , send
    , send_
    , sendCatch

    -- * Asynchronous Actions
    , async
    , wait
    , wait_

    -- * Asynchronous Requests
    , sendAsync
    , waitAsync
    , waitAsync_

    -- * Paginated Requests
    , paginate
    , paginateCatch

    -- * File Bodies
    , requestBodyFile

    -- * Errors
    , ToError          (..)
    , AWSError         (..)
    , hoistError
    , liftEitherT

    -- * Types
    , AvailabilityZone (..)
    , InstanceType     (..)
    , Items            (..)
    , Members          (..)

    -- * S3 Presigning
    , presignS3
    ) where

import           Control.Applicative
import qualified Control.Concurrent.Async              as A
import           Control.Error
import           Control.Exception
import qualified Control.Exception.Lifted              as Lifted
import           Control.Monad
import           Control.Monad.Error
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Resource
import           Control.Monad.Trans.Resource.Internal
import           Data.Acquire
import           Data.Conduit
import qualified Data.Conduit.Binary                   as Conduit
import           Network.AWS.Auth
import           Network.AWS.Internal
import           Network.HTTP.Conduit
import           System.IO
import           UnexceptionalIO                       (Unexceptional)

type AWSEnv = InternalState -> Env

runAWS :: Credentials -> Bool -> AWS a -> IO (Either AWSError a)
runAWS cred dbg aws =
    runExceptT (loadAWSEnv cred dbg) >>=
        either (return . Left . toError)
               (`runAWSEnv` aws)

runAWSEnv :: AWSEnv -> AWS a -> IO (Either AWSError a)
runAWSEnv f aws = runResourceT . withInternalState $ \s -> runEnv (f s) aws

loadAWSEnv :: (Applicative m, MonadIO m, Unexceptional m)
           => Credentials
           -> Bool
           -> ExceptT String m AWSEnv
loadAWSEnv cred dbg = Env defaultRegion dbg
    <$> liftIO (newManager conduitManagerSettings)
    <*> credentials cred

runEnv :: Env -> AWS a -> IO (Either AWSError a)
runEnv env aws = runExceptT $ runReaderT (unwrap aws) env

-- | Run an 'AWS' operation inside a specific 'Region'.
within :: Region -> AWS a -> AWS a
within reg = AWS . local (\e -> e { awsRegion = reg }) . unwrap

hoistError :: (MonadError e m, Error e) => Either e a -> m a
hoistError = either throwError return

liftEitherT :: ToError e => ExceptT e IO a -> AWS a
liftEitherT = AWS . lift . fmapLT toError

-- | Send a request and return the associated response type.
send :: (Rq a, ToError (Er a)) => a -> AWS (Rs a)
send = (hoistError . fmapL toError =<<) . sendCatch

send_ :: (Rq a, ToError (Er a)) => a -> AWS ()
send_ = void . send

sendCatch :: Rq a => a -> AWS (Either (Er a) (Rs a))
sendCatch rq = do
    s  <- sign $ request rq
    whenDebug . liftIO $ putStrLn "[Signed]" >> print s
    m  <- getManager
    h  <- http s m
    whenDebug . liftIO $ putStrLn "[Response]" >> print h
    rs <- response rq h
    hoistError rs

async :: AWS a -> AWS (A.Async (Either AWSError a))
async aws = getEnv >>= resourceAsync . lift . (`runEnv` aws)

wait :: A.Async (Either AWSError a) -> AWS a
wait a = liftIO (A.waitCatch a) >>= hoistError . join . fmapL toError

wait_ :: A.Async (Either AWSError a) -> AWS ()
wait_ = void . wait

sendAsync :: Rq a => a -> AWS (A.Async (Either AWSError (Either (Er a) (Rs a))))
sendAsync = async . sendCatch

waitAsync :: ToError e => A.Async (Either AWSError (Either e a)) -> AWS a
waitAsync a = wait a >>= hoistError . fmapL toError

waitAsync_ :: ToError e => A.Async (Either AWSError (Either e a)) -> AWS ()
waitAsync_ = void . waitAsync

-- | Create a 'Source' which yields the initial and subsequent repsonses
-- for requests that support pagination.
paginate :: (Rq a, Pg a, ToError (Er a))
         => a
         -> Source AWS (Rs a)
paginate rq = paginateCatch rq $= awaitForever go
  where
    go (Left  e) = lift . liftEitherT . throwE $ toError e
    go (Right x) = yield x

paginateCatch :: (Rq a, Pg a, ToError (Er a))
              => a
              -> Source AWS (Either (Er a) (Rs a))
paginateCatch = go . Just
  where
    go Nothing   = return ()
    go (Just rq) = do
        rs <- lift $ sendCatch rq
        yield rs
        either (const $ return ())
               (go . next rq)
               rs

resourceAsync :: MonadResource m => ResourceT IO a -> m (A.Async a)
resourceAsync (ResourceT f) = liftResourceT . ResourceT $ \g -> Lifted.mask $ \h ->
    bracket_
        (stateAlloc g)
        (return ())
        (A.async $ bracket_
            (return ())
            (stateCleanup ReleaseNormal g)
            (h $ f g))

requestBodyFile :: (MonadIO m, Unexceptional m) => FilePath -> m (Maybe RequestBody)
requestBodyFile f = runMaybeT $ do
    n <- join . hushT $ syncIO getFileSize
    return . requestBodySource n $ Conduit.sourceFile f
  where
    getFileSize = fmap hoistMaybe $
        bracket (openBinaryFile f ReadMode)
                hClose
                (fmap (Just . fromIntegral) . hFileSize)
