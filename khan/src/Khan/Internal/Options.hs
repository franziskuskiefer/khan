{-# LANGUAGE GADTs             #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- Module      : Khan.Internal.Options
-- Copyright   : (c) 2013 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Khan.Internal.Options
    (
    -- * GADT/Class
      Options     (..)
    , Command     (..)

    -- * Common
    , Common      (..)
    , RKeysBucket (..)
    , LKeysDir    (..)
    , CacheDir    (..)
    , ConfigDir   (..)
    , commonParser

    -- * Top-level
    , group
    , command

    -- * Overrides
    , readOption
    , switchOption
    , textOption
    , pathOption
    , stringOption
    , integralOption
    , customOption
    , argsOption

    -- * Common
    , roleOption
    , envOption
    , versionOption
    , keyOption
    , cacheOption
    , trustOption
    , policyOption
    , ansibleOption
    , userOption
    , instanceOption
    , rKeysOption
    , groupRefOption
    , vpcRefOption

    -- * Validation
    , check
    , checkIO
    , checkDir
    , checkFile

    , module Export
    ) where

import qualified Data.Attoparsec.Text                 as AText
import qualified Data.HashMap.Strict                  as Map
import           Data.SemVer                          (Version)
import qualified Data.SemVer                          as Ver
import           Data.String
import qualified Data.Text                            as Text
import qualified Filesystem                           as FS
import qualified Filesystem.Path.CurrentOS            as Path
import           Khan.Internal.Types
import           Khan.Prelude
import           Network.AWS
import           Options.Applicative                  as Export hiding (command, info, header, infoParser, execParser)
import qualified Options.Applicative                  as Options
import           Options.Applicative.Builder.Internal (HasValue)
import           Prelude                              (error)

data Command where
    Command :: Options a => (Common -> a -> AWS ()) -> a -> Command

class Options a where
    discover :: Bool -> Common -> a -> AWS a
    validate :: MonadIO m => a -> ExceptT AWSError m ()

    discover _ _ = return
    validate     = void . return

data Common = Common
    { cDebug  :: !Bool
    , cSilent :: !Bool
    , cVPN    :: !Bool
    , cRegion :: !Region
    , cLKeys  :: !LKeysDir
    , cCache  :: !CacheDir
    , cConfig :: !ConfigDir
    } deriving (Show)

newtype RKeysBucket = RKeysBucket { rKeysBucket :: Text }
    deriving (Eq, Show)

newtype LKeysDir = LKeysDir { lKeysDir :: FilePath }
    deriving (Eq, Show)

newtype CacheDir = CacheDir { cacheDir :: FilePath }
    deriving (Eq, Show)

newtype ConfigDir = ConfigDir { configDir :: FilePath }
    deriving (Eq, Show)

commonParser :: EnvMap -> Parser Common
commonParser env = Common
    <$> switchOption "debug" False
        "Log debug output."
    <*> switchOption "silent" False
        "Suppress standard log output."
    <*> switchOption "no-vpn" True
        "Use public DNS instead of private IPv4 (default) for EC2 addresses."
    <*> readOption "region" "REGION"
         ( evalue (readMay . Text.unpack) "KHAN_REGION" env
        <> short 'R'
         ) "Region to operate in."
    <*> (LKeysDir <$> pathOption "local-keys"
         ( value "/etc/ssl/khan"
        <> epath "KHAN_LKEYS" env
        <> short 'L'
         ) "Path to certificates.")
    <*> cacheOption env
    <*> (ConfigDir <$> pathOption "config"
         ( value "/etc/khan"
        <> epath "KHAN_CONFIG" env
        <> short 'C'
         ) "Path to configuration files.")

instance Options Common where
    validate Common{..} = do
       check cRegion " --region or KHAN_REGION must be specified."

       checkDir (lKeysDir  cLKeys)  " specified by --local-keys or KHAN_LKEYS must exist."
       checkDir (cacheDir  cCache)  " specified by --cache or KHAN_CACHE must exist."
       checkDir (configDir cConfig) " specified by --config or KHAN_CONFIG must exist."

group :: String -> String -> Mod CommandFields a -> Mod CommandFields a
group name desc cs = Options.command name $
    Options.info (hsubparser cs) (progDesc desc <> fullDesc)

command :: Options a
        => String
        -> (Common -> a -> AWS ())
        -> Parser a
        -> String
        -> Mod CommandFields Command
command name f p desc = Options.command name $
    Options.info (Command f <$> p) (progDesc desc <> fullDesc)

readOption :: (Show a, Read a)
           => String
           -> String
           -> Mod OptionFields a
           -> String
           -> Parser a
readOption key typ m desc = option auto $ mconcat
    [ long key
    , metavar typ
    , help desc
    , m
    , showDefault
    ]

switchOption :: String -> Bool -> String -> Parser Bool
switchOption key p desc = flag p (not p) $ long key <> help desc

textOption :: String -> Mod OptionFields Text -> String -> Parser Text
textOption key = customOption key "STR" (Right . Text.pack)

pathOption :: String
           -> Mod OptionFields FilePath
           -> String
           -> Parser FilePath
pathOption key = customOption key "PATH" (Right . Path.decodeString)

stringOption :: String -> Mod OptionFields String -> String -> Parser String
stringOption key m desc = strOption $ mconcat
    [ long key
    , metavar "STR"
    , help desc
    , m
    , showDefault
    ]

integralOption :: (Show a, Integral a)
               => String
               -> Mod OptionFields a
               -> String
               -> Parser a
integralOption key = customOption key "INT"
    (AText.parseOnly AText.decimal . Text.pack)

customOption :: Show a
             => String
             -> String
             -> (String -> Either String a)
             -> Mod OptionFields a
             -> String
             -> Parser a
customOption key typ rdr m desc = option (eitherReader rdr) $ mconcat
    [ long key
    , metavar typ
    , help desc
    , m
    , showDefault
    ]

argsOption :: ReadM a
           -> Mod ArgumentFields a
           -> String
           -> Parser [a]
argsOption rdr m desc = many . argument rdr $
    metavar "ARGS .." <> help desc <> m

roleOption :: Parser Role
roleOption = newRole <$> textOption "role" (short 'r')
    "Role of the application."

envOption :: EnvMap -> Parser Env
envOption env = newEnv <$> textOption "env"
    (  short 'e'
    <> value ""
    <> etext "KHAN_ENV" env
    ) "Environment of the application."

versionOption :: Parser Version
versionOption = customOption "version" "SEMVER" p mempty
    "Version of the application."
  where
    p = Ver.fromText . Text.map f . Text.pack

    f '/' = '+'
    f  c  = c

keyOption :: Parser (Maybe FilePath)
keyOption = optional $ pathOption "key" (short 'i')
    "Path to the private key to use."

cacheOption :: EnvMap -> Parser CacheDir
cacheOption env = CacheDir
    <$> pathOption "cache"
      ( value "/var/cache/khan"
     <> epath "KHAN_CACHE" env
      ) "Path to cache."

trustOption :: Parser TrustPath
trustOption = TrustPath <$> pathOption "trust"  (value "")
    "Trust relationship file."

policyOption :: Parser PolicyPath
policyOption = PolicyPath <$> pathOption "policy" (value "")
    "Role policy file."

ansibleOption :: Parser Bool
ansibleOption = switchOption "ansible" False
    "Ansible module compatible output."

userOption :: Parser Text
userOption = textOption "user" (value "ubuntu" <> short 'u')
    "SSH User."

instanceOption :: Parser InstanceType
instanceOption = readOption "instance" "TYPE" (value M3_Medium)
    "Instance type to use."

rKeysOption :: EnvMap -> Parser RKeysBucket
rKeysOption env = RKeysBucket <$> textOption "remote-keys"
    ( etext "KHAN_RKEYS" env
   <> short 'K'
    ) "Bucket to retrieve/store certificates."

groupRefOption :: String -> Mod OptionFields GroupRef -> String -> Parser GroupRef
groupRefOption key = customOption key "ID|name:STR" (Right . parser . Text.pack)
  where
    parser s = case Text.stripPrefix "name:" s of
      Nothing -> GroupId s
      Just n  -> GroupName n

vpcRefOption :: String -> Mod OptionFields VpcRef -> String -> Parser VpcRef
vpcRefOption key = customOption key "ID|name:STR" (Right . parser . Text.pack)
  where
    parser s = case Text.stripPrefix "name:" s of
      Nothing -> VpcId s
      Just n  -> VpcName n

check :: (MonadIO m, Invalid a) => a -> String -> ExceptT AWSError m ()
check x = when (invalid x) . throwE . Err

checkIO :: (MonadIO m, Invalid a) => IO a -> String -> ExceptT AWSError m ()
checkIO io e = liftIO io >>= (`check` e)

checkDir :: MonadIO m => FilePath -> String -> ExceptT AWSError m ()
checkDir p e = check p msg >> checkIO (not <$> FS.isDirectory p) msg
  where
    msg = Text.unpack ("directory '" <> toTextIgnore p <> "'") ++ e

checkFile :: MonadIO m => FilePath -> String -> ExceptT AWSError m ()
checkFile p e = check p msg >> checkIO (not <$> FS.isFile p) msg
  where
    msg = Text.unpack ("file '" <> toTextIgnore p <> "'") ++ e

etext :: HasValue f => Text -> EnvMap -> Mod f Text
etext = evalue Just

epath :: HasValue f => Text -> EnvMap -> Mod f FilePath
epath = evalue (Just . Path.fromText)

evalue :: HasValue f => (Text -> Maybe a) -> Text -> EnvMap -> Mod f a
evalue f k env =
    case k `Map.lookup` env of
        Nothing -> mempty
        Just x  ->
            maybe (error . Text.unpack $ "Error parsing value from: " <> k <> "=" <> x)
                  value
                  (f x)
