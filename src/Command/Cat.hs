{-# LANGUAGE TemplateHaskell, PartialTypeSignatures, ScopedTypeVariables, OverloadedStrings #-}
module Command.Cat where

import Command
import Command.Md
import Command.Cat.CatSet
import MeowBot
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Text as T
import External.ChatAPI hiding (SystemMessage)
import qualified External.ChatAPI as API
import External.ChatAPI.Tool
import MeowBot.Parser (Parser, Chars)
import Parser.Definition (IsStream)
import qualified MeowBot.Parser as MP

import Control.Applicative

import Control.Monad.Trans
import Control.Monad.Logger
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.ReaderState
import Control.Monad.Except
import Control.Concurrent

import Data.HList
import Data.Proxy
import Data.Coerce

import Utils.RunDB
import Utils.Persist
import Data.PersistModel

type MeowTools = '[] --FibonacciTool]

type ModelCat      = DeepSeek DeepSeekChat
type ModelSuperCat = DeepSeek DeepSeekReasoner

modelCatDef      = chatModel @ModelCat
modelSuperCatDef = chatModel @ModelSuperCat

type ChatParamsPerModel m1 m2 ts = Either (ChatParams m1 ts) (ChatParams m2 ts)

commandCat :: BotCommand
commandCat = BotCommand Cat $ botT $ do
  (msg, cid, uid, mid, sender) <- MaybeT $ getEssentialContent <$> query
  other_data <- query
  whole_chat <- query
  botmodules <- query
  botname    <- query
  mcatSetCommand <- (`MP.runParser` msg) <$> lift (commandParserTransformByBotName catSetParser)
  case mcatSetCommand of
    Just catSetCommand -> catSet catSetCommand
    Nothing -> do
      botSetting        <- lift $ fmap (fmap entityVal) . runDB $ selectFirst [BotSettingBotName ==. maybeBotName botname] []
      botSettingPerChat <- lift $ fmap (fmap entityVal) . runDB $ selectFirst [BotSettingPerChatChatId ==. cid, BotSettingPerChatBotName ==. maybeBotName botname] []
      let sd = savedData other_data
      let msys = ChatSetting
                   ( asum
                     [ fmap API.SystemMessage $ botSettingPerChatSystemMessage =<< botSettingPerChat
                     , systemMessage =<< lookup cid (chatSettings sd) 
                     , fmap API.SystemMessage . globalSysMsg $ botmodules
                     , fmap API.SystemMessage $ botSettingSystemMessage =<< botSetting
                     ]
                   )
                   ( asum
                     [ botSettingPerChatSystemTemp =<< botSettingPerChat
                     , systemTemp =<< lookup cid (chatSettings sd)
                     , botSettingSystemTemp =<< botSetting
                     ]
                   )
                   ( asum
                     [ botSettingPerChatSystemMaxToolDepth =<< botSettingPerChat
                     , systemMaxToolDepth =<< lookup cid (chatSettings sd)
                     , botSettingSystemMaxToolDepth =<< botSetting
                     , Just 5
                     ]
                   )
                   ( asum
                     [ botSettingPerChatSystemAPIKey =<< botSettingPerChat
                     , systemApiKeys =<< lookup cid (chatSettings sd)
                     , botSettingSystemAPIKey =<< botSetting
                     ]
                   )
      let modelCat = fromMaybe (modelCat) $ runPersistUseShow <$> asum 
            [ botSettingPerChatDefaultModel =<< botSettingPerChat
            , botSettingDefaultModel =<< botSetting
            ]
          modelSuperCat = fromMaybe (DeepSeek DeepSeekReasoner) $ runPersistUseShow <$> asum
            [ botSettingPerChatDefaultModelS =<< botSettingPerChat
            , botSettingDefaultModelS =<< botSetting
            ]
          displayThinking = fromMaybe True $ asum
            [ botSettingPerChatDisplayThinking =<< botSettingPerChat
            , botSettingDisplayThinking =<< botSetting
            ]
      lChatModelMsg <- pureMaybe $ MP.runParser (treeCatParser botname msys mid) (getFirstTree whole_chat)
      let rlChatModelMsg = reverse lChatModelMsg
          params = fst . head $ rlChatModelMsg
          md = either chatMarkDown chatMarkDown params
          ioEChatResponse = case params of

            Left  paramCat      -> 
              case (cfListPickElem modelsInUse (\(Proxy :: Proxy a) -> chatModel @a == modelCat)) of
                Nothing ->
                  messagesChat @ModelCat @MeowTools (coerce paramCat) $ (map snd . reverse . take 20) rlChatModelMsg
                Just proxyCont -> proxyCont $ \(Proxy :: Proxy a) -> 
                  messagesChat @a @MeowTools (coerce paramCat) $ (map snd . reverse . take 20) rlChatModelMsg

            Right paramSuperCat ->
              case (cfListPickElem modelsInUse (\(Proxy :: Proxy a) -> chatModel @a == modelSuperCat)) of
                Nothing ->
                  messagesChat @ModelSuperCat @MeowTools (coerce paramSuperCat) $ (map snd . reverse . take 20) rlChatModelMsg
                Just proxyCont -> proxyCont $ \(Proxy :: Proxy a) -> 
                  messagesChat @a @MeowTools (coerce paramSuperCat) $ (map snd . reverse . take 20) rlChatModelMsg

      asyncAction <- liftIO $ actionSendMessages displayThinking md (msg, cid, uid, mid, sender) ioEChatResponse
      $(logDebug) $ "created async: " <> T.pack (show asyncAction)
      return $ pure $ BAAsync $ asyncAction

type UseMarkdown = Bool
type DisplayThinking = Bool
actionSendMessages 
  :: DisplayThinking -> UseMarkdown 
  -> EssentialContent -> ExceptT Text IO [Message] -> IO (Async (Meow [BotAction]))
actionSendMessages displayThink usemd essc@(_, cid, _, mid, _) ioess = async $ do
  ess <- runExceptT ioess
  case ess of
    Left err   -> return . return $ [ baSendToChatId cid ("喵~出错啦：" <> err) ]
    Right msgs -> casingMessages usemd essc msgs
  where casingMessages :: UseMarkdown -> EssentialContent -> [Message] -> IO (Meow [BotAction])
        casingMessages _ _ [] = return . return $ []
        casingMessages usemd essc (msg:rest) = case msg of
          AssistantMessage { content = str, thinking = Nothing } -> return $ if usemd
            then do
              mdcq <- liftIO . runExceptT $ turnMdCQCode str
              case mdcq of
                Left err   -> return [ baSendToChatId cid ("喵~出错啦：" <> err) ]
                Right mdcq -> do
                  send <- meowSendToChatIdFull cid (Just mid) [] [MReplyTo mid, MMessage msg] mdcq
                  waitAndDoRest <- liftIO . actionSendMessages displayThink usemd essc $ do
                      liftIO $ threadDelay 2500000
                      ExceptT $ return $ Right rest
                  return $ send <> [BAAsync waitAndDoRest]
            else do
              send <- meowSendToChatIdFull cid (Just mid) [] [MReplyTo mid, MMessage msg] str
              waitAndDoRest <- liftIO . actionSendMessages displayThink usemd essc $ do
                  liftIO $ threadDelay 2500000
                  ExceptT $ return $ Right rest
              return $ send <> [BAAsync waitAndDoRest]
          AssistantMessage { thinking = Just think } -> do
            if displayThink
              then return $ do
                send <- meowSendToChatIdFull cid (Just mid) [] [MReplyTo mid, MMessage msg] $ "(..." <> T.strip think <> ")"
                waitAndDoRest <- liftIO . actionSendMessages displayThink usemd essc $ do
                    liftIO $ threadDelay 2500000
                    ExceptT $ return $ Right $ msg { thinking = Nothing } : rest
                return $ send <> [BAAsync waitAndDoRest]
              else
                casingMessages usemd essc $ msg { thinking = Nothing } : rest
          _ -> casingMessages usemd essc rest

catParser :: (Chars sb) => BotName -> ChatSetting ->
  Parser sb Char
    ( ChatParamsPerModel m1 m2 ts
    , String
    )
catParser (BotName (Just botname)) msys = do
  MP.spaces0
  parseCat <|> parseMeowMeow
  where
    parseMeowMeow = do
      MP.string botname
      MP.commandSeparator2
      str <- MP.some MP.item
      return (Left $ ChatParams False msys, str)
    parseCat = do
      MP.string botname
      MP.just ':' <|> MP.just '：'
      md <- MP.optBool $ $(MP.stringQ "md")
      modelStr <- $(MP.stringQ "cat") <|> $(MP.stringQ "supercat")
      MP.commandSeparator
      str <- MP.some MP.item
      case modelStr of
         "supercat" -> return . (, str) . Right $ ChatParams md (Just msys `chatSettingAlternative` ChatSetting Nothing (Just 0.2) Nothing Nothing)
         _          -> return . (, str) . Left  $ ChatParams md (Just msys `chatSettingAlternative` ChatSetting Nothing (Just 0.7) Nothing Nothing)
catParser (BotName Nothing) msys = do
  MP.spaces0
  parseCat <|> parseMeowMeow
  where
    parseMeowMeow = do
      $(MP.stringQ "喵喵")
      MP.commandSeparator2
      str <- MP.some MP.item
      return (Left $ ChatParams False msys, str)
    parseCat = do
      MP.just ':' <|> MP.just '：'
      md <- MP.optBool $ $(MP.stringQ "md")
      modelStr <- $(MP.stringQ "cat") <|> $(MP.stringQ "supercat")
      MP.commandSeparator
      str <- MP.some MP.item
      case modelStr of
         "supercat" -> return . (, str) . Right $ ChatParams md (Just msys `chatSettingAlternative` ChatSetting Nothing (Just 0.2) Nothing Nothing)
         _          -> return . (, str) . Left  $ ChatParams md (Just msys `chatSettingAlternative` ChatSetting Nothing (Just 0.7) Nothing Nothing)

replyCatParser :: (Chars sb) => BotName -> ChatSetting -> Parser sb Char (ChatParamsPerModel m1 m2 ts, String)
replyCatParser name msys = catParser name msys <|> ( do
  MP.spaces0
  str <- MP.some MP.item
  return (Left $ ChatParams False msys, str)
  )

treeCatParser :: forall s m1 m2 ts. (IsStream s CQMessage) => BotName -> ChatSetting -> Int -> Parser s CQMessage [(ChatParamsPerModel m1 m2 ts, Message)]
treeCatParser name msys mid = do
  elist  <- Right <$>
      MP.many (do
          umsg <- MP.satisfy (\cqm -> eventType cqm `elem` [GroupMessage, PrivateMessage])
          amsg <- MP.satisfy (\cqm -> eventType cqm == SelfMessage )
          msg <- maybe MP.zero return $ do
            mtmAmsg <- metaMessage amsg
            listToMaybe [ m | MMessage m <- metaMessageItems mtmAmsg ]
          let (params, metaUMsg) = fromMaybe (Left $ ChatParams False msys, "") $ MP.runParser (replyCatParser name msys) (extractMetaMessage umsg)
          return [ (params, UserMessage { content = T.pack metaUMsg })
                 , (params, msg)
                 ]
        ) :: Parser s CQMessage (Either (Maybe ChatSetting, [[(ChatParamsPerModel m1 m2 ts, Message)]]) [[(ChatParamsPerModel m1 m2 ts, Message)]])

  lastMsg <- MP.satisfy (\cqm -> (eventType cqm `elem` [GroupMessage, PrivateMessage]) && messageId cqm == Just mid)
  case elist of
    Right list ->
      case MP.runParser (if null list then catParser name msys else replyCatParser name msys) (extractMetaMessage lastMsg) of
            Just (params, metaLast) -> return $ concat list ++
                [ (params, UserMessage { content = T.pack metaLast}) ]
            _ -> MP.zero
    Left (msys', list) -> case MP.runParser (replyCatParser name (chatSettingMaybeWrapper msys')) (extractMetaMessage lastMsg) of
            Just (params, metaLast) -> return $ concat list ++
                [ (params, UserMessage { content = T.pack metaLast}) ]
            _ -> MP.zero
  where extractMetaMessage CQMessage{metaMessage = Nothing} = ""
        extractMetaMessage CQMessage{metaMessage = Just mmsg} = MP.onlyMessage mmsg

