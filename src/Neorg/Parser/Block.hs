{-# LANGUAGE BangPatterns #-}

module Neorg.Parser.Block where

import Control.Applicative (Alternative (many, (<|>)), empty)
import Control.Monad (guard, void)
import Control.Monad.GetPut
import Control.Monad.Trans.Reader (ReaderT (runReaderT))
import Data.Char (isLetter)
import Data.Foldable (Foldable (foldl'))
import Data.Functor (($>), (<&>))
import Data.Maybe (catMaybes, maybeToList)
import qualified Data.Text as T
import qualified Data.Vector as V
import Debug.Trace
import Neorg.Document
import Neorg.Document.Tag
import Neorg.Parser.Paragraph
import Neorg.Parser.Types
import Neorg.Parser.Utils
import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Char as P

newtype CurrentListLevel = CurrentListLevel IndentationLevel deriving newtype (Show, Eq, Ord, Enum)

newtype CurrentHeadingLevel = CurrentHeadingLevel IndentationLevel deriving newtype (Show, Eq, Ord, Enum)

pureBlockWithoutParagraph :: (Get CurrentListLevel p, GenerateTagParser tags) => Parser p (Maybe (PureBlock tags))
pureBlockWithoutParagraph = do
  lookChar >>= \case
    '-' -> pure . List . TaskList <$> taskList <|> pure . List . UnorderedList <$> unorderedList
    '>' -> pure . Quote <$> quote
    '~' -> pure . List . OrderedList <$> orderedList
    '@' -> fmap Tag <$> tag
    _ -> fail "Not a pure block"

pureBlock :: (GenerateTagParser tags, Get CurrentListLevel p) => Parser p (Maybe (PureBlock tags))
pureBlock = do
  markupElement <- isMarkupElement
  if markupElement
    then pureBlockWithoutParagraph
    else pure . Paragraph <$> paragraph

blocks :: (GenerateTagParser tags, Modify CurrentHeadingLevel p) => Parser p (Blocks tags)
blocks = do
  blocks' <- P.many $ do
    P.try $ do
      clearBlankSpace
      P.notFollowedBy P.eof
    block
  pure $ V.fromList $ mconcat blocks'

block :: (GenerateTagParser tags, Modify CurrentHeadingLevel p) => Parser p [Block tags]
block = do
  isMarkup <- isMarkupElement
  if isMarkup
    then impureBlock <|> maybeToList . fmap PureBlock <$> runReaderT pureBlockWithoutParagraph (CurrentListLevel I0)
    else pure . PureBlock . Paragraph <$> paragraph
  where
    impureBlock =
      lookChar >>= \case
        '-' -> weakDelimiter $> [Delimiter WeakDelimiter]
        '=' -> strongDelimiter $> [Delimiter StrongDelimiter]
        '_' -> horizonalLine $> pure (Delimiter HorizonalLine)
        '|' -> pure . Marker <$> marker
        '*' -> headingWithDelimiter
        '$' -> pure . Definition <$> definition
        _ -> fail "Not a delimiter and not a heading"

tag :: forall tags p. GenerateTagParser tags => Parser p (Maybe (SomeTag tags))
tag = do
  tagName <- P.try $ do
    t <- P.char '@' >> P.takeWhileP (Just "Tag description") (\c -> isLetter c || c == '.')
    guard (t /= "end")
    pure t
  P.hspace
  P.choice
    [ P.eof >> pure Nothing,
      do
        let textContent =
              P.takeWhileP (Just "Tag content") (/= '@') >>= \t ->
                (P.try (P.string "@end") >> pure t) <|> (P.char '@' >> fmap ((t <> T.pack ['@']) <>) textContent)
        content <- textContent
        case parseTag @tags tagName of
          Nothing -> pure Nothing
          Just tagParser -> Just <$> embedParser tagParser content
    ]

horizonalLine :: Parser p ()
horizonalLine = P.try $ repeating '_' >>= guard . (> 2) >> P.hspace >> lNewline

unorderedList :: forall tags p. (Get CurrentListLevel p, GenerateTagParser tags) => Parser p (UnorderedList tags)
unorderedList = makeListParser '-' (pure ()) $ \l' v -> UnorderedListCons {_uListLevel = l', _uListItems = fmap snd v}

orderedList :: forall tags p. (Get CurrentListLevel p, GenerateTagParser tags) => Parser p (OrderedList tags)
orderedList = makeListParser '~' (pure ()) $ \l' v -> OrderedListCons {_oListLevel = l', _oListItems = fmap snd v}

taskList :: forall tags p. (Get CurrentListLevel p, GenerateTagParser tags) => Parser p (TaskList tags)
taskList = makeListParser '-' parseTask $ \l' v -> TaskListCons {_tListLevel = l', _tListItems = v}
  where
    parseTask = do
      _ <- P.char '['
      status <- P.char ' ' $> TaskUndone <|> P.char 'x' $> TaskDone <|> P.char '*' $> TaskPending
      _ <- P.char ']'
      _ <- P.char ' '
      pure status

makeListParser :: (Get CurrentListLevel p, GenerateTagParser tags) => Char -> Parser p a -> (IndentationLevel -> V.Vector (a, V.Vector (PureBlock tags)) -> l) -> Parser p l
makeListParser c p f = do
  CurrentListLevel minLevel <- envGet
  (level, a) <- P.try $ repeatingLevel c >>= \l -> guard (l >= minLevel) >> singleSpace >> p <&> (l,)
  items1 <- P.hspace >> listBlock (CurrentListLevel level)
  itemsN <- many $ listItem level
  pure $ f level $ V.fromList ((a, items1) : itemsN)
  where
    listItem level = do
      (_, a) <- P.try $ P.hspace >> repeatingLevel c >>= \l -> guard (level == l) >> singleSpace >> p <&> (l,)
      items <- listBlock $ CurrentListLevel level
      pure (a, items)
    listBlock :: GenerateTagParser tags => CurrentListLevel -> Parser p (V.Vector (PureBlock tags))
    listBlock currentLevel = do

      pureBlocks <- catMaybes <$> manyOrEnd P.hspace (P.try $ clearBlankSpace >> runReaderT pureBlock (succ currentLevel)) doubleNewline
      pure $ V.fromList pureBlocks

weakDelimiter :: Modify CurrentHeadingLevel p => Parser p ()
weakDelimiter = do
  P.try (repeating '-' >> P.hspace >> newline)
  envModify @CurrentHeadingLevel pred

strongDelimiter :: Put CurrentHeadingLevel p => Parser p ()
strongDelimiter = do
  P.try (repeating '=' >> P.hspace >> newline)
  envPut $ CurrentHeadingLevel I0

quote :: Parser p Quote
quote =
  P.try (repeatingLevel '>' >-> singleSpace) >>= \l ->
  
    singleLineParagraph <&> \c -> QuoteCons {_quoteLevel = l, _quoteContent = c}

marker :: Parser p Marker
marker = do
  first <- P.try $ P.char '|' >> singleSpace >> P.hspace >> textWord
  rest <- P.many $ P.hspace >> textWord
  let markerId' = foldl' (\acc r -> acc <> "-" <> T.toLower r) (T.toLower first) rest
  let markerText' = foldl' (\acc r -> acc <> " " <> T.toLower r) first rest
  pure $ MarkerCons {_markerId = markerId', _markerText = markerText'}

headingWithDelimiter :: (Modify CurrentHeadingLevel p, GenerateTagParser tags) => Parser p [Block tags]
headingWithDelimiter = do
  CurrentHeadingLevel currentLevel <- envGet
  h@(HeadingCons _ headingLevel') <- heading
  let delimiters = case (currentLevel, headingLevel') of
        (I0, I0) -> []
        (I1, I0) -> [Delimiter WeakDelimiter]
        (_, I0) -> [Delimiter StrongDelimiter]
        -- _ -> replicate (fromEnum currentLevel - fromEnum headingLevel) (Delimiter WeakDelimiter)
        _ -> [Delimiter WeakDelimiter | currentLevel > headingLevel']
  pure $ delimiters ++ [Heading h]

heading :: Modify CurrentHeadingLevel p => Parser p Heading
heading = do
  (level, text) <- headingText'
  envPut $ CurrentHeadingLevel $ succ level
  pure $ HeadingCons text level
  where
    headingText' = do
      level <-
        P.try $
          repeatingLevel '*' >-> singleSpace
      headingInline <- singleLineParagraph
      pure (level, headingInline)

definition :: (GenerateTagParser tags) => Parser p (Definition tags)
definition =
  singleLineDefinition <|> multiLineDefinition
  where
    singleLineDefinition = do
      _ <- P.try $ P.string "$ "
      definitionObject' <- singleLineParagraph
      P.hspace >> newline
      DefinitionCons definitionObject' . V.fromList . maybeToList <$> runReaderT pureBlock (CurrentListLevel I0)
    multiLineDefinition = do
      _ <- P.try $ P.string "$$ "
      definitionObject' <- singleLineParagraph
      pureBlocks <- catMaybes <$> manyOrEnd clearBlankSpace (runReaderT pureBlock (CurrentListLevel I0)) (void (P.string "$$") <|> P.eof)
      pure $ DefinitionCons definitionObject' $ V.fromList pureBlocks
