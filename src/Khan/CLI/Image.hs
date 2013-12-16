{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- Module      : Khan.CLI.Image
-- Copyright   : (c) 2013 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Khan.CLI.Image (commands) where

import           Data.Version
import           Khan.Internal
import qualified Khan.Model.Image         as Image
import qualified Khan.Model.Instance      as Instance
import qualified Khan.Model.Key           as Key
import qualified Khan.Model.Profile       as Profile
import qualified Khan.Model.SecurityGroup as Security
import           Khan.Prelude
import           Network.AWS
import           Network.AWS.EC2
import qualified Shelly                   as Shell

data AMI = AMI
    { aRole     :: !Text
    , aVersion  :: Maybe Version
    , aScript   :: !FilePath
    , aImage    :: !Text
    , aType     :: !InstanceType
    , aPreserve :: !Bool
    }

amiParser :: Parser AMI
amiParser = AMI
    <$> roleOption
    <*> optional versionOption
    <*> pathOption "script" (short 's' <> action "file")
        "Script to pass the image-id as $1 to."
    <*> textOption "base" (short 'b')
        "Id of the base image/ami."
    <*> readOption "type" "TYPE" (value M1_Small)
        "Instance's type."
    <*> switchOption "preserve" False
        "Don't terminate the base instance on error."

instance Options AMI where
    validate AMI{..} =
        checkPath aScript " specified by --script must exist."

instance Naming AMI where
    names AMI{..} = v
        { profileName = "ami-builder"
        , groupName   = sshGroup "ami"
        }
      where
        v = maybe (unversioned aRole "ami")
                  (versioned aRole "ami")
                  aVersion

commands :: Mod CommandFields Command
commands = group "image" "Create AMIs." $ mconcat
    [ command "build" build amiParser
        "AMI."
    ]

build :: Common -> AMI -> AWS ()
build c@Common{..} d@AMI{..} = do
    log "Looking for Images matching {}" [aImage]
    a <- async $ Image.find [aImage] []

    log "Looking for IAM Profiles matching {}" [profileName]
    i <- async $ Profile.find d

    ami <- diritImageId <$> wait a
    log "Found Image {}" [ami]

    wait_ i <* log "Found IAM Profile {}" [profileName]

    k <- async $ Key.create cBucket d cCerts
    g <- async $ Security.create d

    wait_ k <* log "Found KeyPair {}" [keyName]
    wait_ g <* log "Found Role Group {}" [groupName]

    az  <- shuffle "bc"
    mr  <- listToMaybe . map riitInstanceId <$>
        Instance.run d ami aType (AZ cRegion az) 1 1 False
    iid <- noteAWS "Failed to launch any Instances using Image {}" [ami] mr

    Instance.wait [iid]

    e <- contextAWS c $ do
        p <- shell . Shell.errExit False $ do
            log "Running {}" [aScript]
            Shell.runHandles "bash"
                [Shell.toTextIgnore aScript, iid]
                [Shell.OutHandle Shell.Inherit]
                (\_ _ _ -> return ())
            (== 0) <$> Shell.lastExitCode
        _ <- Image.create iid imageName []
        return p

    if (not (either (const False) id e) && aPreserve)
        then log "Error creating Image, preserving base Instance {}" [iid]
        else do
            log_ "Terminating base instance"
            send_ $ TerminateInstances [iid]

    const () <$> hoistError e
  where
    Names{..} = names d
