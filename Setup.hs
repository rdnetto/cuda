{-# LANGUAGE CPP             #-}
{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

-- The MIN_VERSION_Cabal macro was introduced with Cabal-1.24 (??)
#ifndef MIN_VERSION_Cabal
#define MIN_VERSION_Cabal(major1,major2,minor) 0
#endif

import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.Simple
import Distribution.Simple.BuildPaths
import Distribution.Simple.Command
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.PreProcess                               hiding ( ppC2hs )
import Distribution.Simple.Program
import Distribution.Simple.Program.Db
import Distribution.Simple.Program.Find
import Distribution.Simple.Setup
import Distribution.Simple.Utils                                    hiding ( isInfixOf )
import Distribution.System
import Distribution.Verbosity

#if MIN_VERSION_Cabal(1,25,0)
import Distribution.PackageDescription.PrettyPrint
import Distribution.Version
#endif

import Control.Exception
import Control.Monad
import Data.Function
import Data.List
import Data.Maybe
import System.Directory
import System.Environment
import System.FilePath
import System.IO.Error
import Text.Printf
import Prelude


-- Configuration
-- -------------

customBuildInfoFilePath :: FilePath
customBuildInfoFilePath = "cuda" <.> "buildinfo"

generatedBuildInfoFilePath :: FilePath
generatedBuildInfoFilePath = customBuildInfoFilePath <.> "generated"

defaultCUDAInstallPath :: Platform -> FilePath
defaultCUDAInstallPath _ = "/usr/local/cuda"  -- windows?


-- Build setup
-- -----------

main :: IO ()
main = defaultMainWithHooks customHooks
  where
    readHook get_verbosity a flags = do
        noExtraFlags a
        getHookedBuildInfo (fromFlag (get_verbosity flags))

    preprocessors = hookedPreProcessors simpleUserHooks

    -- Our readHook implementation uses our getHookedBuildInfo. We can't rely on
    -- cabal's autoconfUserHooks since they don't handle user overwrites to
    -- buildinfo like we do.
    --
    customHooks =
      simpleUserHooks
        { preBuild            = preBuildHook -- not using 'readHook' here because 'build' takes; extra args
        , preClean            = readHook cleanVerbosity
        , preCopy             = readHook copyVerbosity
        , preInst             = readHook installVerbosity
        , preHscolour         = readHook hscolourVerbosity
        , preHaddock          = readHook haddockVerbosity
        , preReg              = readHook regVerbosity
        , preUnreg            = readHook regVerbosity
        , postConf            = postConfHook
        , hookedPreProcessors = ("chs", ppC2hs) : filter (\x -> fst x /= "chs") preprocessors
        }

    -- The hook just loads the HookedBuildInfo generated by postConfHook,
    -- unless there is user-provided info that overwrites it.
    --
    preBuildHook :: Args -> BuildFlags -> IO HookedBuildInfo
    preBuildHook _ flags = getHookedBuildInfo $ fromFlag $ buildVerbosity flags

    -- The hook scans system in search for CUDA Toolkit. If the toolkit is not
    -- found, an error is raised. Otherwise the toolkit location is used to
    -- create a `cuda.buildinfo.generated` file with all the resulting flags.
    --
    postConfHook :: Args -> ConfigFlags -> PackageDescription -> LocalBuildInfo -> IO ()
    postConfHook args flags pkg_descr lbi = do
      let
          verbosity       = fromFlagOrDefault normal (configVerbosity flags)
          profile         = fromFlagOrDefault False  (configProfLib flags)
          currentPlatform = hostPlatform lbi
          compilerId_     = compilerId (compiler lbi)
      --
      noExtraFlags args
      generateAndStoreBuildInfo verbosity profile currentPlatform compilerId_ generatedBuildInfoFilePath
      validateLinker verbosity currentPlatform $ withPrograms lbi
      --
      actualBuildInfoToUse <- getHookedBuildInfo verbosity
      let pkg_descr' = updatePackageDescription actualBuildInfoToUse pkg_descr
      postConf simpleUserHooks args flags pkg_descr' lbi


-- Generates build info with flags needed for CUDA Toolkit to be properly
-- visible to underlying build tools.
--
libraryBuildInfo :: Bool -> FilePath -> Platform -> Version -> IO HookedBuildInfo
libraryBuildInfo profile installPath platform@(Platform arch os) ghcVersion = do
  let
      libraryPaths      = [cudaLibraryPath platform installPath]
      includePaths      = [cudaIncludePath platform installPath]

      -- options for GHC
      extraLibDirs'     = libraryPaths
      ccOptions'        = map ("-I"++) includePaths
      ldOptions'        = map ("-L"++) libraryPaths
      ghcOptions        = map ("-optc"++) ccOptions'
                       ++ map ("-optl"++) ldOptions'
                       ++ if os /= Windows && not profile
                            then map ("-optl-Wl,-rpath,"++) extraLibDirs'
                            else []
      extraLibs'        = cudaLibraries platform
      frameworks'       = [ "CUDA" | os == OSX ]

      -- options or c2hs
      archFlag          = case arch of
                            I386   -> "-m32"
                            X86_64 -> "-m64"
                            _      -> ""
      emptyCase         = ["-DUSE_EMPTY_CASE" | versionBranch ghcVersion >= [7,8]]
      blocksExtension   = [ "-U__BLOCKS__" | os == OSX ]
      c2hsOptions       = unwords $ map ("--cppopts="++) ("-E" : archFlag : emptyCase ++ blocksExtension)
      c2hsExtraOptions  = ("x-extra-c2hs-options", c2hsOptions)

      addSystemSpecificOptions :: BuildInfo -> IO BuildInfo
      addSystemSpecificOptions bi =
        case os of
          _ -> return bi

  extraGHCiLibs' <- cudaGHCiLibraries platform installPath extraLibs'
  buildInfo'     <- addSystemSpecificOptions $ emptyBuildInfo
    { ccOptions      = ccOptions'
    , ldOptions      = ldOptions'
    , extraLibs      = extraLibs'
    , extraGHCiLibs  = extraGHCiLibs'
    , extraLibDirs   = extraLibDirs'
    , frameworks     = frameworks'
    , options        = [(GHC, ghcOptions) | os /= Windows]
    , customFieldsBI = [c2hsExtraOptions]
    }

  return (Just buildInfo', [])


-- Return the location of the include directory relative to the base CUDA
-- installation.
--
cudaIncludePath :: Platform -> FilePath -> FilePath
cudaIncludePath _ installPath = installPath </> "include"


-- Return the location of the libraries relative to the base CUDA installation.
--
cudaLibraryPath :: Platform -> FilePath -> FilePath
cudaLibraryPath (Platform arch os) installPath = installPath </> libpath
  where
    libpath =
      case (os, arch) of
        (Windows, I386)   -> "lib/Win32"
        (Windows, X86_64) -> "lib/x64"
        (OSX,     _)      -> "lib"    -- MacOS does not distinguish 32- vs. 64-bit paths
        (_,       X86_64) -> "lib64"  -- treat all others similarly
        _                 -> "lib"


-- On Windows and OSX we use different libraries depending on whether we are
-- linking statically (executables) or dynamically (ghci).
--
cudaLibraries :: Platform -> [String]
cudaLibraries (Platform _ os) =
  case os of
    OSX -> ["cudadevrt", "cudart_static"]
    _   -> ["cudart", "cuda"]

cudaGHCiLibraries :: Platform -> FilePath -> [String] -> IO [String]
cudaGHCiLibraries platform@(Platform _ os) installPath libraries =
  case os of
    Windows -> cudaGhciLibrariesWindows platform installPath libraries
    OSX     -> return ["cudart"]
    _       -> return []

-- Windows compatibility function.
--
-- The function is used to populate the extraGHCiLibs list on Windows
-- platform. It takes libraries directory and .lib filenames and returns
-- their corresponding dll filename. (Both filenames are stripped from
-- extensions)
--
-- Eg: "C:\cuda\toolkit\lib\x64" -> ["cudart", "cuda"] -> ["cudart64_65", "ncuda"]
--
cudaGhciLibrariesWindows :: Platform -> FilePath -> [FilePath] -> IO [FilePath]
cudaGhciLibrariesWindows platform installPath libraries = do
  candidates <- mapM importLibraryToDLLFileName [ cudaLibraryPath platform installPath </> lib <.> "lib" | lib <- libraries ]
  return [ dropExtension dll | Just dll <- candidates ]


-- Windows compatibility function.
--
-- CUDA toolkit uses different names for import libraries and their
-- respective DLLs. For example, on 32-bit architecture and version 7.0 of
-- toolkit, `cudart.lib` imports functions from `cudart32_70`.
--
-- The ghci linker fails to resolve this. Therefore, it needs to be given
-- the DLL filenames as `extra-ghci-libraries` option.
--
-- This function takes *a path to* import library and returns name of
-- corresponding DLL.
--
-- Eg: "C:/CUDA/Toolkit/Win32/cudart.lib" -> "cudart32_70.dll"
--
-- Internally it assumes that 'nm' tool is present in PATH. This should be
-- always true, as 'nm' is distributed along with GHC.
--
-- The function is meant to be used on Windows. Other platforms may or may
-- not work.
--
importLibraryToDLLFileName :: FilePath -> IO (Maybe FilePath)
importLibraryToDLLFileName importLibPath = do
  -- Sample output nm generates on cudart.lib
  --
  -- nvcuda.dll:
  -- 00000000 i .idata$2
  -- 00000000 i .idata$4
  -- 00000000 i .idata$5
  -- 00000000 i .idata$6
  -- 009c9d1b a @comp.id
  -- 00000000 I __IMPORT_DESCRIPTOR_nvcuda
  --          U __NULL_IMPORT_DESCRIPTOR
  --          U nvcuda_NULL_THUNK_DATA
  --
  nmOutput <- getProgramInvocationOutput normal (simpleProgramInvocation "nm" [importLibPath])
  return $ find (isInfixOf ("" <.> dllExtension)) (lines nmOutput)


-- Slightly modified version of `words` from base - it takes predicate saying on
-- which characters split.
--
splitOn :: (Char -> Bool) -> String -> [String]
splitOn p s =
  case dropWhile p s of
    [] -> []
    s' -> let (w, s'') = break p s'
          in  w : splitOn p s''

-- Tries to obtain the version `ld`. Throws an exception if failed.
--
getLdVersion :: Verbosity -> FilePath -> IO (Maybe [Int])
getLdVersion verbosity ldPath = do
  -- Version string format is like `GNU ld (GNU Binutils) 2.25.1`
  --                            or `GNU ld (GNU Binutils) 2.20.51.20100613`
  ldVersionString <- getProgramInvocationOutput normal (simpleProgramInvocation ldPath ["-v"])

  let versionText   = last $ words ldVersionString -- takes e. g. "2.25.1"
      versionParts  = splitOn (== '.') versionText
      versionParsed = Just $ map read versionParts

      -- last and read above may throw and message would be not understandable
      -- for user, so we'll intercept exception and rethrow it with more useful
      -- message.
      handleError :: SomeException -> IO (Maybe [Int])
      handleError e = do
          warn verbosity $ printf "cannot parse ld version string: `%s`. Parsing exception: `%s`" ldVersionString (show e)
          return Nothing

  evaluate versionParsed `catch` handleError


-- On Windows GHC package comes with two copies of ld.exe.
--
--  1. ProgramDb knows about the first one: ghcpath\mingw\bin\ld.exe
--  2. This function returns the other one: ghcpath\mingw\x86_64-w64-mingw32\bin\ld.exe
--
-- The second one is the one that does actual linking and code generation.
-- See: https://github.com/tmcdonell/cuda/issues/31#issuecomment-149181376
--
-- The function is meant to be used only on 64-bit GHC distributions.
--
getRealLdPath :: Verbosity -> ProgramDb -> IO (Maybe FilePath)
getRealLdPath verbosity programDb =
  -- TODO: This should ideally work `programFindVersion ldProgram` but for some
  -- reason it does not. The issue should be investigated at some time.
  --
  case lookupProgram ghcProgram programDb of
    Nothing            -> return Nothing
    Just configuredGhc -> do
      let ghcPath        = locationPath $ programLocation configuredGhc
          presumedLdPath = (takeDirectory . takeDirectory) ghcPath </> "mingw" </> "x86_64-w64-mingw32" </> "bin" </> "ld.exe"
      info verbosity $ "Presuming ld location" ++ presumedLdPath
      presumedLdExists <- doesFileExist presumedLdPath
      return $ if presumedLdExists
                 then Just presumedLdPath
                 else Nothing


-- On Windows platform the binutils linker targeting x64 is bugged and cannot
-- properly link with import libraries generated by MS compiler (like the CUDA ones).
-- The programs would correctly compile and crash as soon as the first FFI call is made.
--
-- Therefore we fail configure process if the linker is too old and provide user
-- with guidelines on how to fix the problem.
--
validateLinker :: Verbosity -> Platform -> ProgramDb -> IO ()
validateLinker verbosity (Platform arch os) db =
  when (arch == X86_64 && os == Windows) $ do
    maybeLdPath <- getRealLdPath verbosity db
    case maybeLdPath of
      Nothing     -> warn verbosity $ "Cannot find ld.exe to check if it is new enough. If generated executables crash when making calls to CUDA, please see " ++ windowsHelpPage
      Just ldPath -> do
        debug verbosity $ "Checking if ld.exe at " ++ ldPath ++ " is new enough"
        maybeVersion <- getLdVersion verbosity ldPath
        case maybeVersion of
          Nothing        -> warn verbosity $ "Unknown ld.exe version. If generated executables crash when making calls to CUDA, please see " ++ windowsHelpPage
          Just ldVersion -> do
            debug verbosity $ "Found ld.exe version: " ++ show ldVersion
            when (ldVersion < [2,25,1]) $ die $ windowsLinkerBugMsg ldPath


windowsHelpPage :: String
windowsHelpPage = "https://github.com/tmcdonell/cuda/blob/master/WINDOWS.markdown"

windowsLinkerBugMsg :: FilePath -> String
windowsLinkerBugMsg ldPath = printf (unlines msg) windowsHelpPage ldPath
  where
    msg =
      [ "********************************************************************************"
      , ""
      , "The installed version of `ld.exe` has version < 2.25.1. This version has known bug on Windows x64 architecture, making it unable to correctly link programs using CUDA. The fix is available and MSys2 released fixed version of `ld.exe` as part of their binutils package (version 2.25.1)."
      , ""
      , "To fix this issue, replace the `ld.exe` in your GHC installation with the correct binary. See the following page for details:"
      , ""
      , "  %s"
      , ""
      , "The full path to the outdated `ld.exe` detected in your installation:"
      , ""
      , "> %s"
      , ""
      , "Please download a recent version of binutils `ld.exe`, from, e.g.:"
      , ""
      , "  http://repo.msys2.org/mingw/x86_64/mingw-w64-x86_64-binutils-2.25.1-1-any.pkg.tar.xz"
      , ""
      , "********************************************************************************"
      ]


-- Runs CUDA detection procedure and stores .buildinfo to a file.
--
generateAndStoreBuildInfo :: Verbosity -> Bool -> Platform -> CompilerId -> FilePath -> IO ()
generateAndStoreBuildInfo verbosity profile platform (CompilerId _ghcFlavor ghcVersion) path = do
  installPath <- findCUDAInstallPath verbosity platform
  hbi         <- libraryBuildInfo profile installPath platform ghcVersion
  storeHookedBuildInfo verbosity path hbi

storeHookedBuildInfo :: Verbosity -> FilePath -> HookedBuildInfo -> IO ()
storeHookedBuildInfo verbosity path hbi = do
  notice verbosity $ "Storing parameters to " ++ path
  writeHookedBuildInfo path hbi


-- Try to locate CUDA installation by checking (in order):
--
--  1. CUDA_PATH environment variable
--  2. Looking for `nvcc` in `PATH`
--  3. Checking /usr/local/cuda
--  4. CUDA_PATH_Vx_y environment variable, for recent CUDA toolkit versions x.y
--
-- In case of failure, calls die with the pretty long message from below.
--
findCUDAInstallPath :: Verbosity -> Platform -> IO FilePath
findCUDAInstallPath verbosity platform = do
  result <- findFirstValidLocation verbosity platform (candidateCUDAInstallPaths verbosity platform)
  case result of
    Just installPath -> do
      notice verbosity $ printf "Found CUDA toolkit at: %s" installPath
      return installPath
    Nothing -> die cudaNotFoundMsg


cudaNotFoundMsg :: String
cudaNotFoundMsg = unlines
  [ "********************************************************************************"
  , ""
  , "The configuration process failed to locate your CUDA installation. Ensure that you have installed both the developer driver and toolkit, available from:"
  , ""
  , "> http://developer.nvidia.com/cuda-downloads"
  , ""
  , "and make sure that `nvcc` is available in your PATH, or set the CUDA_PATH environment variable appropriately. Check the above output log and run the command directly to ensure it can be located."
  , ""
  , "If you have a non-standard installation, you can add additional search paths using --extra-include-dirs and --extra-lib-dirs. Note that 64-bit Linux flavours often require both `lib64` and `lib` library paths, in that order."
  , ""
  , "********************************************************************************"
  ]


-- Function iterates over action yielding possible locations, evaluating them
-- and returning the first valid one. Returns Nothing if no location matches.
--
findFirstValidLocation :: Verbosity -> Platform -> [(IO FilePath, String)] -> IO (Maybe FilePath)
findFirstValidLocation verbosity platform = go
  where
    go :: [(IO FilePath, String)] -> IO (Maybe FilePath)
    go []     = return Nothing
    go (x:xs) = do
      let (path,desc) = x
      info verbosity $ printf "checking for %s" desc
      found <- validateIOLocation verbosity platform path
      if found
        then Just `fmap` path
        else go xs


-- Evaluates IO to obtain the path, handling any possible exceptions.
-- If path is evaluable and points to valid CUDA toolkit returns True.
--
validateIOLocation :: Verbosity -> Platform -> IO FilePath -> IO Bool
validateIOLocation verbosity platform iopath =
  let handler :: IOError -> IO Bool
      handler err = do
        info verbosity (show err)
        return False
  in
  (iopath >>= validateLocation verbosity platform) `catch` handler


-- Checks whether given location looks like a valid CUDA toolkit directory
--
validateLocation :: Verbosity -> Platform -> FilePath -> IO Bool
validateLocation verbosity platform path = do
  -- TODO: Ideally this should check for e.g. cuda.lib and whether it exports
  -- relevant symbols. This should be achievable with some `nm` trickery
  --
  let cudaHeader = cudaIncludePath platform path </> "cuda.h"
  --
  exists <- doesFileExist cudaHeader
  info verbosity $
    if exists
      then printf "Path accepted: %s\n" path
      else printf "Path rejected: %s\nDoes not exist: %s\n" path cudaHeader
  return exists

-- Returns pairs of (action yielding candidate path, String description of that location)
--
candidateCUDAInstallPaths :: Verbosity -> Platform -> [(IO FilePath, String)]
candidateCUDAInstallPaths verbosity platform =
  [ (getEnv "CUDA_PATH",      "environment variable CUDA_PATH")
  , (findInPath,              "nvcc compiler executable in PATH")
  , (return defaultPath,      printf "default install location (%s)" defaultPath)
  , (getEnv "CUDA_PATH_V8_0", "environment variable CUDA_PATH_V8_0")
  , (getEnv "CUDA_PATH_V7_5", "environment variable CUDA_PATH_V7_5")
  , (getEnv "CUDA_PATH_V7_0", "environment variable CUDA_PATH_V7_0")
  , (getEnv "CUDA_PATH_V6_5", "environment variable CUDA_PATH_V6_5")
  , (getEnv "CUDA_PATH_V6_0", "environment variable CUDA_PATH_V6_0")
  ]
  where
    findInPath :: IO FilePath
    findInPath = do
      nvccPath <- findProgramLocationOrError verbosity "nvcc"
      -- The obtained path is likely TOOLKIT/bin/nvcc. We want to extract the
      -- TOOLKIT part
      return (takeDirectory $ takeDirectory nvccPath)

    defaultPath :: FilePath
    defaultPath = defaultCUDAInstallPath platform


-- NOTE: this function throws an exception when there is no `nvcc` in PATH.
-- The exception contains a meaningful message.
--
findProgramLocationOrError :: Verbosity -> String -> IO FilePath
findProgramLocationOrError verbosity execName = do
  location <- findProgram verbosity execName
  case location of
    Just path -> return path
    Nothing   -> ioError $ mkIOError doesNotExistErrorType ("not found: " ++ execName) Nothing Nothing

findProgram :: Verbosity -> FilePath -> IO (Maybe FilePath)
findProgram verbosity prog = do
  result <- findProgramOnSearchPath verbosity defaultProgramSearchPath prog
#if MIN_VERSION_Cabal(1,25,0)
  return (fmap fst result)
#else
  $( case withinRange cabalVersion (orLaterVersion (Version [1,24] [])) of
       True  -> [| return (fmap fst result) |]
       False -> [| return result |]
    )
#endif


-- Reads user-provided `cuda.buildinfo` if present, otherwise loads `cuda.buildinfo.generated`
-- Outputs message informing about the other possibility.
-- Calls die when neither of the files is available.
-- (generated one should be always present, as it is created in the post-conf step)
--
getHookedBuildInfo :: Verbosity -> IO HookedBuildInfo
getHookedBuildInfo verbosity = do
  doesCustomBuildInfoExists <- doesFileExist customBuildInfoFilePath
  if doesCustomBuildInfoExists
    then do
      notice verbosity $ printf "The user-provided buildinfo from file %s will be used. To use default settings, delete this file.\n" customBuildInfoFilePath
      readHookedBuildInfo verbosity customBuildInfoFilePath
    else do
      doesGeneratedBuildInfoExists <- doesFileExist generatedBuildInfoFilePath
      if doesGeneratedBuildInfoExists
        then do
          notice verbosity $ printf "Using build information from '%s'.\n" generatedBuildInfoFilePath
          notice verbosity $ printf "Provide a '%s' file to override this behaviour.\n" customBuildInfoFilePath
          readHookedBuildInfo verbosity generatedBuildInfoFilePath
        else
          die $ printf "Unexpected failure. Neither the default %s nor custom %s exist.\n" generatedBuildInfoFilePath customBuildInfoFilePath


-- Replicate the default C2HS preprocessor hook here, and inject a value for
-- extra-c2hs-options, if it was present in the buildinfo file
--
-- Everything below copied from Distribution.Simple.PreProcess
--
#if MIN_VERSION_Cabal(1,25,0)
ppC2hs :: BuildInfo -> LocalBuildInfo -> ComponentLocalBuildInfo -> PreProcessor
ppC2hs bi lbi _clbi
#else
ppC2hs :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppC2hs bi lbi
#endif
    = PreProcessor {
        platformIndependent = False,
        runPreProcessor     = \(inBaseDir, inRelativeFile)
                               (outBaseDir, outRelativeFile) verbosity ->
          rawSystemProgramConf verbosity c2hsProgram (withPrograms lbi) . filter (not . null) $
            maybe [] words (lookup "x-extra-c2hs-options" (customFieldsBI bi))
            ++ ["--include=" ++ outBaseDir]
            ++ ["--cppopts=" ++ opt | opt <- getCppOptions bi lbi]
            ++ ["--output-dir=" ++ outBaseDir,
                "--output=" ++ outRelativeFile,
                inBaseDir </> inRelativeFile]
      }

getCppOptions :: BuildInfo -> LocalBuildInfo -> [String]
getCppOptions bi lbi
    = hcDefines (compiler lbi)
   ++ ["-I" ++ dir | dir <- includeDirs bi]
   ++ [opt | opt@('-':c:_) <- ccOptions bi, c `elem` "DIU"]

hcDefines :: Compiler -> [String]
hcDefines comp =
  case compilerFlavor comp of
    GHC  -> ["-D__GLASGOW_HASKELL__=" ++ versionInt version]
    JHC  -> ["-D__JHC__=" ++ versionInt version]
    NHC  -> ["-D__NHC__=" ++ versionInt version]
    Hugs -> ["-D__HUGS__"]
    _    -> []
  where version = compilerVersion comp

-- TODO: move this into the compiler abstraction
-- FIXME: this forces GHC's crazy 4.8.2 -> 408 convention on all the other
-- compilers. Check if that's really what they want.
versionInt :: Version -> String
versionInt v =
  case versionBranch v of
    []      -> "1"
    [n]     -> show n
    n1:n2:_ -> printf "%d%02d" n1 n2


#if MIN_VERSION_Cabal(1,25,0)
versionBranch :: Version -> [Int]
versionBranch = versionNumbers
#endif

