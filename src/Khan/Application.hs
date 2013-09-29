{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ViewPatterns        #-}

-- Module      : Khan.Application
-- Copyright   : (c) 2013 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Khan.Application (command) where

import           Control.Applicative
import           Control.Concurrent      (threadDelay)
import           Control.Error
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Text               (Text)
import qualified Data.Text               as Text
import           Data.Version
import           Khan.Internal
import           Network.AWS
import           Network.AWS.AutoScaling hiding (Filter)
import           Network.AWS.EC2
import           Network.AWS.IAM
import           Network.AWS.Internal
import           Pipes
import qualified Pipes.Prelude           as Pipes
import           Text.Show.Pretty

defineOptions "App" $ do
    textOption "aName" "name" ""
        "Name of the application."

    textOption "aEnv" "env" "dev"
        "Environment of the application."

deriving instance Show App

instance Discover App

instance Validate App where
    validate App{..} = do
        check aName "--name must be specified."
        check aEnv  "--env must be specified."

defineOptions "Deploy" $ do
    textOption "dName" "name" ""
        "Name of the application."

    textOption "dEnv" "env" "dev"
        "Environment to deploy the application into."

    versionOption "dVersion" "version" defaultVersion
        "Version of the application."

    textsOption "dZones" "zone" []
        "Availability zone in which instances are provisioned."

    integerOption "dGrace" "grace" 20
        "Seconds until healthchecks are activated."

    integerOption "dMin" "min" 1
        "Minimum number of instances."

    integerOption "dMax" "max" 20
        "Maximum number of instances."

    integerOption "dCapacity" "desired" 2
        "Desired number of instances."

    integerOption "dCooldown" "cooldown" 60
        "Seconds between scaling activities."

    instanceTypeOption "dType" "instance" M1_Medium
        "Type of instance to provision."

deriving instance Show Deploy

instance Discover Deploy

instance Validate Deploy where
    validate Deploy{..} = do
        check dName     "--name must be specified."
        check dEnv      "--env must be specified."
        check dZones    "--zone must be specified at least once."
        check dGrace    "--grace must be greater than 0."
        check dMin      "--min must be greater than 0."
        check dMax      "--max must be greater than 0."
        check dCapacity "--desired must be greater than 0."
        check dCooldown "--cooldown must be greater than 0"
        check (defaultVersion == dVersion) "--version must be specified."

defineOptions "Route" $
    versionOption "rVersion" "version" defaultVersion
        "Version of the application."

deriving instance Show Route

instance Discover Route
instance Validate Route

command :: Command
command = Command "app" "Application."
    [ subCommand "create" create
    , subCommand "deploy" deploy
    , subCommand "info"   info
    , subCommand "route"  route
    ]
  where
    prerequisites role = do
        a <- sendAsync $ GetRole role
        b <- sendAsync $ DescribeKeyPairs [role] []
        wait_ a >> wait_ b
        logInfo $ "Found Role and KeyPair for " ++ Text.unpack role

    create App{..} = do
        prerequisites role
      where
        role = Text.concat [aName, "-", aEnv]

    deploy Deploy{..} = do
        prerequisites role

        -- Find AMI
        mi  <- fmap (listToMaybe . djImagesSet) . send $
            DescribeImages [] [] ["self"] [Filter "name" [name]]
        ami <- diritImageId <$> noteError "Failed to find any AMIs" mi
        logInfo $ "Found AMI " ++ Text.unpack ami

        -- Create versioned Security Group (Exists == OK)
        esg <- sendCatch $ CreateSecurityGroup role role Nothing
        _  <- case esg of
            Left e | ecCode (head (eerErrors e)) == "InvalidGroup.Duplicate"
                -> return undefined
            o   -> hoistError $ fmapL toError o

        -- -- Authorise Ingress Rules
        -- _ <- send $ AuthorizeSecurityGroupIngress Nothing (Just role)
        --     [ flip (IpPermissionType TCP 8080 8080) []
        --         [ UserIdGroupPair Nothing Nothing (Just role)
        --         ]
        --     ]

        -- Create versioned LaunchConfiguration (Exists == OK)
        _ <- send $ CreateLaunchConfiguration
            (Members [])
            Nothing
            (Just role) -- Role
            ami
            Nothing
            dType
            Nothing
            Nothing -- (Just keypair)
            name -- Versioned Name
            Nothing
            (Members []) -- securityGroups
            Nothing
            Nothing

        logInfo $ "Created Launch Configuration " ++ Text.unpack name

        -- Create ASG (Exists == Error!)
        -- let a = CreateAutoScalingGroup
        --             name -- Versioned Name
        --             (Members dZones)
        --             (Just dCooldown)
        --             (Just dCapacity)
        --             (Just dGrace)
        --             (Just "EC2")
        --             launchConfigName
        --             (Members [])
        --             dMin
        --             dMax
        --             Nothing
        --             (Members tags)
        --             (Members [])
        --             Nothing

        -- logInfo $ show a

      where
        role = Text.concat [dName, "-", dEnv]
        name = Text.concat [dName, "_", safeVersion dVersion]

    info App{..} = return ()

    route Route{..} = return ()