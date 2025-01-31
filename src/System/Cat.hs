{-# LANGUAGE TemplateHaskell, OverloadedStrings #-}
module System.Cat where

import System.General
import Control.Monad.Trans.ReaderState
import Control.Monad
import Control.Concurrent.STM
import Control.Concurrent
import Control.Exception
import System
import Utils.Logging
import Data.HList
import MeowBot
import MeowBot.CommandRule
import Network.WebSockets
import Command
import Command.Aokana
import Module.CommandInstance
import Module.AsyncInstance
import Module.LogDatabase
import Module.ProxyWS

import System.Directory
import Data.Coerce
import Data.Maybe
import Text.Read (readMaybe)

import Control.Monad.ExceptionReturn

import Database.Persist.Sql hiding (In)
import Data.PersistModel
import External.ChatAPI
import Utils.Persist
import MeowBot.Data.Book

-- the modules loaded in the system are:
-- type Mods   = '[CommandModule, AsyncModule, LogDatabase, ProxyWS]

botLoop :: Cat never_returns
botLoop = do
  $(logDebug) "Bot loop started, running before meow actions"
  CatT beforeMeowActions

  $(logDebug) "Listening and handling events"
  CatT $ handleEvents =<< liftIO . atomically =<< listenToEvents

  $(logDebug) "Performing meow actions"
  performMeowActions

  $(logDebug) "After meow actions"
  CatT afterMeowActions

  $(logDebug) "Bot loop finished"
  botLoop

performMeowActions :: Cat ()
performMeowActions = do
  actions <- askSystem
  conn    <- askSystem
  as <- liftIO . atomically $ readTVar actions <* writeTVar actions []
  globalizeMeow $ mapM_ (doBotAction conn) =<< (concat <$> sequence as)

type R = MeowData -- ^ the r parameter

-- the process of initialization:
--
-- in the outer layer, init all global states
--
-- in each inner layer where we run each bot, init all local states
--
-- then initialize AllData, and run the botLoop

allInitDataG :: AllModuleInitDataG Mods
allInitDataG  = CommandInitDataG   :** AsyncInitDataG :** LogDatabaseInitDataG "meowbot.db"
              :** ProxyWSInitDataG :** FNil

allInitDataL :: [ProxyFlag] -> AllModuleInitDataL Mods
allInitDataL pf =   CommandInitDataL :** AsyncInitDataL :** LogDatabaseInitDataL
                :** ProxyWSInitDataL [(add, ip) | ProxyFlag add ip <- pf] :** FNil

runBots :: AllModuleInitDataG Mods -> [BotInstance] -> LoggingT IO ()
runBots initglobs bots = do
  $(logInfo) "Initializing all global states"
  global <- initAllModulesG @R initglobs
  $(logInfo) "Starting bot instances"
  mapM_ (runBot initglobs global) bots

-- | All these are read-only so no problem to reuse them when restarting the bot
runBot :: AllModuleInitDataG Mods -> AllModuleGlobalStates Mods -> BotInstance -> LoggingT IO ()
runBot initglobs glob bot = do
  case botRunFlag bot of
    RunClient ip port -> do
      earlyLocal <- initAllModulesEL @R allInitDataG (allInitDataL $ botProxyFlags bot)
      runBotClient ip port bot initglobs glob earlyLocal
    RunServer ip port -> do
      earlyLocal <- initAllModulesEL @R allInitDataG (allInitDataL $ botProxyFlags bot)
      runBotServer ip port bot initglobs glob earlyLocal

runBotServer ip port bot initglobs glob el = do
  $(logInfo) $ "Running bot server, listening on " <> tshow ip <> ":" <> tshow port
  botm     <- botInstanceToModule bot
  let botconfig = BotConfig botm (botDebugFlags bot)
  alldata  <- initAllData botconfig glob
  void $ (logThroughCont (runServer ip port) $ \pendingconn -> do
    conn <- lift $ acceptRequest pendingconn
    logThroughCont (withPingPong defaultPingPongOptions conn) $ \conn -> do
      $(logInfo) $ "Connected to client"
      meowData <- liftIO $ initMeowData conn
      $(logDebug) $ "initMeowData finished"
      local    <- initAllModulesL @R meowData initglobs (allInitDataL $ botProxyFlags bot) el
      $(logDebug) $ "initAllModulesL finished, entering bot loop"
      void (runReaderStateT (runCatT botLoop) (glob, meowData) (local, alldata))
    ) `logForkFinally` (rerunBot initglobs glob el bot)

runBotClient ip port bot initglobs glob el = do
  $(logInfo) $ "Running bot client, connecting to " <> tshow ip <> ":" <> tshow port
  botm     <- botInstanceToModule bot
  let botconfig = BotConfig botm (botDebugFlags bot)
  alldata  <- initAllData botconfig glob
  void $ (logThroughCont (runClient ip port "") $ \conn -> do
    $(logInfo) $ "Connected to server " <> tshow ip <> ":" <> tshow port
    meowData <- liftIO $ initMeowData conn
    local    <- initAllModulesL @R meowData initglobs (allInitDataL $ botProxyFlags bot) el
    runReaderStateT (runCatT botLoop) (glob, meowData) (local, alldata)
    ) `logForkFinally` rerunBot initglobs glob el bot

initMeowData :: Connection -> IO MeowData
initMeowData conn = MeowData <$> initAllMeowData (conn :* () :* () :* () :* () :* Nil)
    -- MeowData conn = Me
--MeowData conn <$> newTVarIO [] <*> newTVarIO Nothing <*> newTVarIO Nothing <*> newTVarIO Nothing

rerunBot :: AllModuleInitDataG Mods -> AllModuleGlobalStates Mods -> AllModuleEarlyLocalStates Mods -> BotInstance -> Either SomeException a -> LoggingT IO ()
rerunBot initglobs glob el bot (Left e) = do
  $(logError) $ "Bot instance failed: " <> tshow bot <> "\nWith Error: " <> tshow e
  $(logInfo) "Restarting bot instance in 60 seconds"
  liftIO $ threadDelay 60_000_000
  case botRunFlag bot of
    RunClient ip port -> runBotClient ip port bot initglobs glob el
    RunServer ip port -> runBotServer ip port bot initglobs glob el
rerunBot _ _ _ _ (Right _) = do
  $(logInfo) $ "Bot instance finished successfully."

botInstanceToModule :: BotInstance -> LoggingT IO BotModules
botInstanceToModule bot@(BotInstance runFlag identityFlags commandFlags mode proxyFlags logFlags) = do
    $(logInfo) $ "\n### Starting bot instance: " <> tshow bot
    $(logInfo) $ "Running mode: "   <> tshow mode
    $(logInfo) $ "Running flags: "  <> tshow runFlag
    $(logInfo) $ "Identity flags: " <> tshow identityFlags
    $(logInfo) $ "Command flags: "  <> tshow commandFlags
    $(logInfo) $ "Proxy flags: "    <> tshow proxyFlags
    $(logInfo) $ "Log flags: "      <> tshow logFlags
    -- proxyData <- lift $ sequence $ [ createProxyData addr port | ProxyFlag addr port <- proxyFlags ]
    let mGlobalSysMsg = listToMaybe [ pack sysMsg | UseSysMsg sysMsg <- identityFlags ]
        withDefault def [] = def
        withDefault _ xs = xs
        botModules = BotModules
          { canUseGroupCommands   = withDefault (identifier <$> allGroupCommands)   (coerce commandFlags)
          , canUsePrivateCommands = withDefault (identifier <$> allPrivateCommands) (coerce commandFlags)
          , nameOfBot = BotName $ listToMaybe [ nameBot | UseName nameBot <- identityFlags ]
          , globalSysMsg = mGlobalSysMsg
          , proxyTChans = []--proxyData
          , logFile = [ logFile | LogFlag logFile <- logFlags ]
          , botInstance = bot
          }
    return botModules

initAllData :: (LogDatabase `In` mods) => BotConfig -> AllModuleGlobalStates mods -> LoggingT IO AllData
initAllData botconfig glob = do
  let mods = botModules botconfig
  savedDataDB   <-                              runExceptT $ loadSavedDataDB   (nameOfBot mods) glob
  savedDataFile <- unsafeInterleaveLoggingTIO $ runExceptT $ loadSavedDataFile (nameOfBot mods)
  case (savedDataDB, savedDataFile) of
    (Right savedDataDB, _) -> do
      $(logInfo) "Loaded saved data from database"
      AllData [] botconfig . OtherData 0 Nothing [] savedDataDB (coerce $ savedAdditional savedDataDB) <$> lift getAllScripts
    (Left errDb, Right savedDataFile) -> do
      $(logError) $ "Failed to load saved data from database: " <> errDb
      $(logInfo) "Loaded saved data from file"
      $(logInfo) $ "Trying to migrate data from file to database"
      writeSavedDataDB botconfig glob savedDataFile
      AllData [] botconfig . OtherData 0 Nothing [] savedDataFile (coerce $ savedAdditional savedDataFile) <$> lift getAllScripts
    (Left errDb, Left errFile) -> do
      $(logError) $ "Failed to load saved data from database: " <> errDb
      $(logError) $ "Failed to load saved data from file: " <> errFile
      $(logInfo) "Starting with empty data, also writing empty data to database"
      writeSavedDataDB botconfig glob (SavedData [] initialUGroups initialGGroups initialRules initialBooks [])
      AllData [] botconfig . OtherData 0 Nothing [] (SavedData [] initialUGroups initialGGroups initialRules initialBooks []) [] <$> lift getAllScripts
  where
    initialUGroups = [(me, Admin)]
    initialGGroups = [(myGroup, AllowedGroup)]
    initialRules =
      [ Allow (UGroup Admin)          (ExceptCommands [Retract])
      , Allow AllUserAndGroups        (CGroup [Cat, Hangman, Help, Md, Random])
      , Allow (GGroup AllowedGroup)   (CGroup [System, Aokana])
      , Allow (UGroup Allowed)        (CGroup [System, Aokana])
      , Allow (SingleGroup myGroup)   (SingleCommand Retract)
      , Deny  (UGroup Denied)         AllCommands
      ]
    initialBooks = []
    me = 754829466 :: UserId
    myGroup = 437447251 :: GroupId

loadSavedDataFile :: BotName -> ExceptT Text (LoggingT IO) SavedData
loadSavedDataFile botName = do
  fileExist <- liftIO $ doesFileExist (savedDataPath botName)
  if fileExist
    then do
      $(logInfo) "Found saved data file, loading data! owo"
      savedData <- liftIO . readFile $ savedDataPath botName
      let maybeSavedData = readMaybe savedData
      case maybeSavedData of
        Just msavedData -> do
          $(logInfo) "Loaded and read saved data file successfully! owo"
          return msavedData
        Nothing -> do
          $(logError) "Failed to load saved data file! o.o Prelude no read!"
          throwE "Failed to load saved data file! o.o Prelude no read!"
    else do
      $(logInfo) "No saved data file found! o.o"
      throwE "No saved data file found! o.o"

loadSavedDataDB :: (LogDatabase `In` mods) => BotName -> AllModuleGlobalStates mods -> ExceptT Text (LoggingT IO) SavedData
loadSavedDataDB botName glob = do
  let pool = databasePool (getF @LogDatabase glob)
  _                    <- fmap entityVal . effectE    $ runSqlPool (selectList [BotSettingBotName          ==. maybeBotName botName] [LimitTo 1]) pool
  botSettingsPerChat   <- fmap (map entityVal) . lift $ runSqlPool (selectList [BotSettingPerChatBotName   ==. maybeBotName botName] []) pool
  inUserGroups         <- fmap (map entityVal) . lift $ runSqlPool (selectList [InUserGroupBotName         ==. maybeBotName botName] []) pool
  inGroupGroups        <- fmap (map entityVal) . lift $ runSqlPool (selectList [InGroupGroupBotName        ==. maybeBotName botName] []) pool
  commandRulesDB       <- fmap (map entityVal) . lift $ runSqlPool (selectList [CommandRuleDBBotName       ==. maybeBotName botName] []) pool
  savedAdditionalDatas <- fmap (map entityVal) . lift $ runSqlPool (selectList [SavedAdditionalDataBotName ==. maybeBotName botName] []) pool
  bookDBs              <- fmap (map entityVal) . lift $ runSqlPool (selectList [] []) pool
  let 
      chatIds_chatSettings = 
        [( botSettingPerChatChatId c, ChatSetting
          { systemMessage      = SystemMessage <$> botSettingPerChatSystemMessage c
          , systemTemp         = botSettingPerChatSystemTemp c
          , systemMaxToolDepth = botSettingPerChatSystemMaxToolDepth c
          , systemApiKeys      = case (botSettingPerChatSystemAPIKeyOpenAI c, botSettingPerChatSystemAPIKeyDeepSeek c) of
              (Nothing, Nothing) -> Nothing
              (a, b)             -> Just $ APIKey { apiKeyOpenAI = a, apiKeyDeepSeek = b }
          }) | c <- botSettingsPerChat]
      userIds_userGroups   = [(inUserGroupUserId u, inUserGroupUserGroup u) | u <- inUserGroups]
      groupIds_groupGroups = [(inGroupGroupGroupId g, inGroupGroupGroupGroup g) | g <- inGroupGroups]
      commandRules         = [commandRuleDBCommandRule c | c <- commandRulesDB]
      savedAdditionalData  = map (runPersistUseShow . savedAdditionalDataAdditionalData) savedAdditionalDatas :: [Saved AdditionalData]
      books = 
        [ Book 
          { book_name    = bookDBBookName b
          , book_pdfPath = bookDBBookPdfPath b
          , book_pages   = bookDBBookPages b
          , book_info    = bookDBBookInfo b
          }
          | b <- bookDBs]
  return $ SavedData
    { chatSettings    = chatIds_chatSettings
    , userGroups      = userIds_userGroups
    , groupGroups     = groupIds_groupGroups
    , commandRules    = commandRules
    , books           = books
    , savedAdditional = savedAdditionalData
    }

writeSavedDataDB :: (LogDatabase `In` mods) => BotConfig -> AllModuleGlobalStates mods -> SavedData -> LoggingT IO ()
writeSavedDataDB botconfig glob sd = do
  let pool = databasePool (getF @LogDatabase glob)
      botname = nameOfBot (botModules botconfig)
  runSqlPool (do
    -- deleteWhere [BotSettingBotName          ==. maybeBotName botname]
    -- deleteWhere [BotSettingPerChatBotName   ==. maybeBotName botname]
    -- deleteWhere [InUserGroupBotName         ==. maybeBotName botname]
    -- deleteWhere [InGroupGroupBotName        ==. maybeBotName botname]
    -- deleteWhere [CommandRuleDBBotName       ==. maybeBotName botname]
    -- deleteWhere [SavedAdditionalDataBotName ==. maybeBotName botname]
    -- deleteWhere ([] :: [Filter BookDB])
    insert_ $ BotSetting
      { botSettingBotName              = maybeBotName botname
      , botSettingDefaultModel         = coerce $ Just (DeepSeek DeepSeekChat)
      , botSettingDefaultModelS        = coerce $ Just (DeepSeek DeepSeekReasoner)
      , botSettingDisplayThinking      = Just True
      , botSettingSystemMessage        = globalSysMsg $ botModules botconfig
      , botSettingSystemTemp           = Nothing
      , botSettingSystemMaxToolDepth   = Just 5
      , botSettingSystemAPIKeyOpenAI   = Nothing
      , botSettingSystemAPIKeyDeepSeek = Nothing
      }
    insertMany_ [ BotSettingPerChat
      { botSettingPerChatBotName          = maybeBotName botname
      , botSettingPerChatChatId           = chatId
      , botSettingPerChatDefaultModel     = Nothing
      , botSettingPerChatDefaultModelS    = Nothing
      , botSettingPerChatDisplayThinking  = Just True
      , botSettingPerChatSystemMessage    = content <$> systemMessage chatSetting
      , botSettingPerChatSystemTemp       = systemTemp chatSetting
      , botSettingPerChatSystemMaxToolDepth = systemMaxToolDepth chatSetting
      , botSettingPerChatSystemAPIKeyOpenAI = apiKeyOpenAI =<< systemApiKeys chatSetting
      , botSettingPerChatSystemAPIKeyDeepSeek = apiKeyDeepSeek =<< systemApiKeys chatSetting
      } | (chatId, chatSetting) <- chatSettings sd]
    insertMany_ [ InUserGroup
      { inUserGroupBotName          = maybeBotName botname
      , inUserGroupUserId           = userId
      , inUserGroupUserGroup        = userGroup
      } | (userId, userGroup) <- userGroups sd]
    insertMany_ [ InGroupGroup
      { inGroupGroupBotName         = maybeBotName botname
      , inGroupGroupGroupId          = groupId
      , inGroupGroupGroupGroup       = groupGroup
      } | (groupId, groupGroup) <- groupGroups sd]
    insertMany_ [ CommandRuleDB
      { commandRuleDBBotName        = maybeBotName botname
      , commandRuleDBCommandRule    = commandRule
      } | commandRule <- commandRules sd]
    insertMany_ [ SavedAdditionalData
      { savedAdditionalDataBotName  = maybeBotName botname
      , savedAdditionalDataAdditionalData = PersistUseShow savedAdditional
      } | savedAdditional <- savedAdditional sd]
    insertMany_ [ BookDB
      { bookDBBookName    = book_name book
      , bookDBBookPdfPath = book_pdfPath book
      , bookDBBookPages   = book_pages book
      , bookDBBookInfo    = book_info book
      } | book <- books sd]
    ) pool
