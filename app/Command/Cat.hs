{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}
module Command.Cat where

import Command
import Command.Md
import Command.Aokana
import MeowBot.BotStructure
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import External.ChatAPI 
import MonParserF (ParserF(..))
import qualified MonParserF as MP
import Control.Monad.IOe

import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.ReaderState

commandCat :: BotCommand
commandCat = botT $ do
  (msg, cid, uid, mid) <- MaybeT $ getEssentialContent <$> ask
  other_data <- lift get
  whole_chat <- lift ask
  let sd = savedData other_data
  let msys = lookup cid $ sysMessages sd
  lChatModelMsg <- pureMaybe $ MP.mRunParserF (treeCatParser msys mid) (getFirstTree whole_chat)
  let rlChatModelMsg = reverse lChatModelMsg
      params@(ChatParams model md _) = fst . head $ rlChatModelMsg
      ioEChatResponse = messageChat params $ (map snd . reverse . take 20) rlChatModelMsg
  cid <- pureMaybe $ checkAllowedCatUsers sd model cid
  lift $ onlyStateT $ (if md then sendIOeToChatIdMd else sendIOeToChatId)
    (msg, cid, uid, mid) ioEChatResponse
  where checkAllowedCatUsers _  GPT3 anybody = return anybody
        checkAllowedCatUsers sd GPT4 g@(GroupId gid) = mIf (gid `elem` allowedGroups sd) g
        checkAllowedCatUsers sd GPT4 p@(PrivateId uid) = mIf (UserId uid `elem` allowedUsers sd) p

catParser :: Maybe Message -> ParserF Char (ChatParams, String) 
catParser msys = do 
  MP.spaces0
  parseCat <> parseMeowMeow
  where
    parseCat = do
      MP.just ':' <> MP.just '：'
      md <- MP.tryBool $ MP.string "md"
      modelStr <- MP.string "cat" <> MP.string "supercat"
      MP.commandSeparator
      str <- MP.many MP.item
      let model = case modelStr of
                    "supercat" -> GPT4
                    _ -> GPT3
      return (ChatParams model md msys, str)
    parseMeowMeow = do
      MP.string "喵喵"
      MP.commandSeparator2
      str <- MP.many MP.item
      return (ChatParams GPT3 False msys, str)

replyCatParser :: Maybe Message -> ParserF Char (ChatParams, String)
replyCatParser msys = catParser msys <> ( do
  MP.spaces0
  str <- MP.many MP.item
  return (ChatParams GPT3 False msys, str)
  )

treeCatParser :: Maybe Message -> Int -> ParserF CQMessage [(ChatParams, Message)]
treeCatParser msys mid = do
  elist <- 
    ( do
        firstUMsg <- MP.satisfy (\cqm -> eventType cqm `elem` [GroupMessage, PrivateMessage] ) -- will be dropped
        firstAMsg <- MP.satisfy (\cqm -> eventType cqm == SelfMessage)
        case ( do
                MP.mRunParserF aokanaParser (extractMetaMessage firstUMsg)  -- the first user input should be an aokana command
                meta <- metaMessage firstAMsg                              
                return $ MP.withSystemMessage meta -- there might be modified system message
             ) of
          Just msys' -> 
            do
              innerList <- MP.many0 
                (do
                  umsg <- MP.satisfy (\cqm -> eventType cqm `elem` [GroupMessage, PrivateMessage])
                  amsg <- MP.satisfy (\cqm -> eventType cqm == SelfMessage)
                  let (params, metaUMsg) = fromMaybe (ChatParams GPT3 False msys', "") $ MP.mRunParserF (catParser msys') (extractMetaMessage umsg)
                  return [ (params, Message { role = "user", content = T.pack metaUMsg})
                         , (params, Message { role = "assistant", content = T.pack $ extractMetaMessage amsg})
                         ]
                )
              let params = ChatParams GPT3 False msys'
              return (msys', [(params, Message "assistant" $ T.pack $ extractMetaMessage firstAMsg)] : innerList)
          Nothing -> MP.zero
    )
    `MP.eitherParse`
    MP.many0 (do 
        umsg <- MP.satisfy (\cqm -> eventType cqm `elem` [GroupMessage, PrivateMessage])
        amsg <- MP.satisfy (\cqm -> eventType cqm == SelfMessage)
        let (params, metaUMsg) = fromMaybe (ChatParams GPT3 False msys, "") $ MP.mRunParserF (replyCatParser msys) (extractMetaMessage umsg) 
        return [ (params, Message { role = "user" , content = T.pack metaUMsg })
               , (params, Message { role = "assistant", content = T.pack $ extractMetaMessage amsg})
               ]
      )
  lastMsg <- MP.satisfy (\cqm -> (eventType cqm `elem` [GroupMessage, PrivateMessage]) && messageId cqm == Just mid)
  case elist of
    Right list ->
      case MP.mRunParserF (if isEmpty list then catParser msys else replyCatParser msys) (extractMetaMessage lastMsg) of
            Just (params, metaLast) -> return $ concat list ++ 
                [ (params, Message { role = "user", content = T.pack metaLast}) ]
            _ -> MP.zero
    Left (msys', list) -> case MP.mRunParserF (replyCatParser msys') (extractMetaMessage lastMsg) of
            Just (params, metaLast) -> return $ concat list ++ 
                [ (params, Message { role = "user", content = T.pack metaLast}) ]
            _ -> MP.zero
  where extractMetaMessage CQMessage{metaMessage = Nothing} = ""
        extractMetaMessage CQMessage{metaMessage = Just mmsg} = MP.onlyMessage mmsg
        isEmpty [] = True
        isEmpty (_:_) = False

