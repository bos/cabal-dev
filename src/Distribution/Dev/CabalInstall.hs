{-# LANGUAGE TemplateHaskell #-}
module Distribution.Dev.CabalInstall
       ( findOnPath
       , program
       , getFeatures
       , CabalFeatures
       , needsQuotes
       , hasOnlyDependencies
       , configDir
       , CabalCommand(..)
       , Option(..)
       , OptionName(..)
       , ArgType(..)
       , matchLongOption
       , commandToString
       , stringToCommand
       , allCommands
       , commandOptions
       , supportsLongOption
       , supportedOptions
       , getUserConfig
       )
where

import Data.Maybe ( fromMaybe )
import Control.Applicative ( (<$>), pure )
import System.FilePath ( (</>) )
import System.Environment ( getEnvironment )
import Distribution.Version ( Version(..), withinRange
                            , earlierVersion, orLaterVersion )
import Distribution.Verbosity ( Verbosity )
import Distribution.Simple.Program ( Program( programFindVersion
                                            )
                                   , ConfiguredProgram
                                   , emptyProgramConfiguration
                                   , findProgramVersion
                                   , programLocation
                                   , programVersion
                                   , requireProgram
                                   , getProgramOutput
                                   , simpleProgram
                                   )
import Distribution.Simple.Utils ( debug )
import Distribution.Text ( display, simpleParse )

import System.Directory ( getAppUserDataDirectory )

import Distribution.Dev.InterrogateCabalInstall
    ( Option(..), OptionName(..), ArgType(..) )
import Distribution.Dev.TH.DeriveCabalCommands
    ( deriveCabalCommands )

-- XXX This is duplicated in Setup.hs
-- |Definition of the cabal-install program
program :: Maybe String -> Program
program p =
    (simpleProgram $ fromMaybe "cabal" p) { programFindVersion =
                                  findProgramVersion "--numeric-version" id
                            }

-- |Find cabal-install on the user's PATH
findOnPath :: Verbosity -> Maybe FilePath -> IO ConfiguredProgram
findOnPath v ci = do
  (cabal, _) <- requireProgram v (program ci) emptyProgramConfiguration
  debug v $ concat [ "Using cabal-install "
                   , maybe "(unknown version)" display $ programVersion cabal
                   , " at "
                   , show (programLocation cabal)
                   ]
  return cabal

-- |Parse the Cabal library version from the output of cabal --version
parseVersionOutput :: String -> Either String Version
parseVersionOutput str =
    case lines str of
      []      -> Left "No version string provided."
      [_]     -> Left "Could not find Cabal version line."
      (_:ln:_) -> case simpleParse ((words ln)!!2) of
                   Just v  -> Right v
                   Nothing -> Left $ err ln
        where err line = "Could not parse Cabal verison.\n"
                         ++ "(simpleParse "++show line++")"

-- |The information necessary to properly invoke cabal-install
data CabalFeatures = CabalFeatures { cfLibVersion :: Version
                                   , cfExeVersion :: Version
                                   }

mkVer :: [Int] -> Version
mkVer l = Version l []

-- |Extract the features of this cabal-install executable
getFeatures :: Verbosity -> ConfiguredProgram ->
               IO (Either String CabalFeatures)
getFeatures v cabal = do
  case programVersion cabal of
    Nothing -> return $ Left "Failed to find cabal-install version"
    Just exeVer -> do
      verRes <- parseVersionOutput <$> getProgramOutput v cabal ["--version"]
      case verRes of
        Left err -> return $ Left $ "Detecting cabal-install's Cabal: " ++ err
        Right libVer -> return $ Right $
                        CabalFeatures { cfLibVersion = libVer
                                      , cfExeVersion = exeVer
                                      }

-- |Does the cabal-install configuration file use quoted paths in the
-- install-dirs section?
needsQuotes :: CabalFeatures -> Bool
needsQuotes = (`withinRange` earlierVersion (mkVer [1,10])) . cfLibVersion

-- |Does this cabal-install executable support the --dependencies-only
-- flag to install?
hasOnlyDependencies :: CabalFeatures -> Bool
hasOnlyDependencies =
  (`withinRange` orLaterVersion (mkVer [0, 10])) . cfExeVersion

$(deriveCabalCommands)

supportsLongOption :: CabalCommand -> String -> Bool
supportsLongOption cc s = any ((`matchLongOption` s) . optionName) $ supportedOptions cc

optionName :: Option -> OptionName
optionName (Option n _) = n

supportedOptions :: CabalCommand -> [Option]
supportedOptions cc = commonOptions ++ commandOptions cc

matchLongOption :: OptionName -> String -> Bool
matchLongOption (Short _) = const False
matchLongOption (LongOption s) = (== s)

commonOptions :: [Option]
commonOptions = [Option (LongOption "config-file") Req]

-- |What is the configuration directory for this cabal-install executable?

-- XXX: This needs to do something different for certain platforms for
-- new versions of cabal-install (look at the tickets on creswick's
-- cabal-dev repo)
configDir :: CabalFeatures -> IO FilePath
configDir _ = getAppUserDataDirectory "cabal"

getUserConfig :: CabalFeatures -> IO FilePath
getUserConfig cf = do
  env <- lookup "CABAL_CONFIG" <$> getEnvironment
  case env of
    Nothing -> (</> "config") <$> configDir cf
    Just f  -> pure f

