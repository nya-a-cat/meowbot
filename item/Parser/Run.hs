-- | Make running the parser easier by exporting the necessary functions.
module Parser.Run
  ( module Control.Monad.Item
  , module Control.Applicative
  , module Parser.Char
  , module Parser.String
  , module Parser.Text
  , module Parser.Template
  , runParser, runParserFull
  , Parser
  , IsStream
  ) where

import Control.Applicative
import Control.Monad.Item
import Parser.Char
import Parser.String
import Parser.Definition (IsStream, runParser, runParserFull, Parser) -- not fully exported
import Parser.Template
import Parser.Text
