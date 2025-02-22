module Main where

import Control.Monad.Trans.State (State, evalState)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as B
import Data.Foldable (fold)
import Data.Functor ((<&>))
import qualified Data.Sequence as S
import Data.Text (Text, pack)
import qualified Data.Text.IO as T
import qualified Data.Vector as V
import Neorg.Document
import Neorg.Document.Tag
import Neorg.Parser.Block (definition)
import Neorg.Parser.Main
import Optics.Core ((<&>), (^.))
import System.Environment (getArgs)
import qualified Text.Pandoc.Builder as P
import qualified Text.Pandoc.Definition as P
import Type.Set (FromList)

main :: IO ()
main = do
  fileName <-
    getArgs <&> \case
      [name] -> name
      _ -> error "Supply one norg file as argument"
  fileContent <- T.readFile fileName
  case parse (pack fileName) fileContent of
    Left err -> T.putStrLn err
    Right doc -> B.putStr $ encode $ convertDocument tagHandler doc

type Convert a = State () a

runConvert :: Convert a -> a
runConvert c = evalState c ()

convertDocument :: GenerateTagParser tags => TagHandler tags (Convert P.Blocks) -> Document tags -> P.Pandoc
convertDocument handler (Document blocks) = runConvert $ P.doc . V.foldMap id <$> traverse (convertBlock handler) blocks

convertBlock :: TagHandler tags (Convert P.Blocks) -> Block tags -> Convert P.Blocks
convertBlock handler = \case
  Heading heading -> convertHeading handler heading
  Delimiter delimiter -> convertDelimiter delimiter
  Marker marker -> convertMarker marker
  PureBlock pb -> convertPureBlock handler pb
  Definition definition -> convertDefinition handler definition

convertPureBlock :: TagHandler tags (Convert P.Blocks) -> PureBlock tags -> Convert P.Blocks
convertPureBlock handler = \case
  Tag tag -> handleSomeTag handler tag
  Paragraph i -> convertParagraph i
  Quote quote -> convertQuote quote
  List list -> convertList handler list

convertParagraph :: Inline -> Convert P.Blocks
convertParagraph = fmap P.para . convertInline

convertMarker :: Marker -> Convert P.Blocks
convertMarker = error "not implemented"

convertList :: TagHandler tags (Convert P.Blocks) -> List tags -> Convert P.Blocks
convertList handler = \case
  UnorderedList ul ->
    fmap (P.bulletList . V.toList) $
      traverse (applicativeConcatMap $ convertPureBlock handler) $
        ul ^. uListItems
  OrderedList ol ->
    fmap (P.bulletList . V.toList) $
      traverse (applicativeConcatMap $ convertPureBlock handler) $
        ol ^. oListItems
  TaskList tl ->
    let convertTaskListBlock taskStatus lb = convertPureBlock handler lb
     in fmap (P.bulletList . V.toList) $
          traverse (\(taskStatus, items) -> applicativeConcatMap (convertTaskListBlock taskStatus) items) $
            tl ^. tListItems

convertQuote :: Quote -> Convert P.Blocks
convertQuote quote = P.blockQuote . P.para <$> convertInline (quote ^. quoteContent)

convertHeading :: TagHandler tags (Convert P.Blocks) -> Heading -> Convert P.Blocks
convertHeading handler heading = do
  text <- convertInline $ heading ^. headingText
  pure $ P.header (succ . fromEnum $ heading ^. headingLevel) text

convertDefinition :: TagHandler tags (Convert P.Blocks) -> Definition tags -> Convert P.Blocks
convertDefinition handler definition = do
  definitionText <- convertInline $ definition ^. definitionObject
  definitionBlocks <- traverse (convertPureBlock handler) $ definition ^. definitionContent
  pure $ P.definitionList [(definitionText, V.toList definitionBlocks)]

convertDelimiter :: Delimiter -> Convert P.Blocks
convertDelimiter delimiter = case delimiter of
  HorizonalLine -> pure P.horizontalRule
  _ -> pure mempty

convertInline :: Inline -> Convert P.Inlines
convertInline = \case
  Text t -> pure $ P.text t
  Bold inline -> P.strong <$> convertInline inline
  Italic inline -> P.emph <$> convertInline inline
  Underline inline -> P.underline <$> convertInline inline
  Strikethrough inline -> P.strikeout <$> convertInline inline
  Superscript inline -> P.superscript <$> convertInline inline
  Subscript inline -> P.subscript <$> convertInline inline
  Spoiler inline -> P.strikeout <$> convertInline inline -- TODO: No native spoilers in pandoc
  ConcatInline inlines -> V.foldMap id <$> traverse convertInline inlines
  Link (LinkCons target inlines maybeId) -> applicativeConcatMap convertInline inlines -- TODO: Investigate title field
  Space -> pure P.space
  Verbatim t -> pure $ P.code t
  Math t -> pure $ P.math t

type SupportedTags = FromList '["code", "math", "comment", "embed", "document.meta", "table"]

tagHandler :: TagHandler SupportedTags (Convert P.Blocks)
tagHandler = code `mergeHandler` math `mergeHandler` comment `mergeHandler` embed `mergeHandler` documentMeta `mergeHandler` table
  where
    code = handleTag @"code" $ \_language text -> pure $ P.codeBlock text
    math = handleTag @"math" $ \_ text -> pure $ P.plain $ P.displayMath text
    comment = handleTag @"comment" $ \_ text -> pure mempty
    embed = handleTag @"embed" $ \_embedType url -> pure $ P.plain $ P.image url "" mempty
    documentMeta = handleTag @"document.meta" $ \_ _ -> pure mempty
    table = handleTag @"table" $ \_ (Table rows) ->
      if V.length rows == 0
        then pure mempty
        else
          let header = V.head rows
              body = V.drop 1 rows
           in P.simpleTable <$> convertTableRow header <*> traverse convertTableRow (V.toList body)
      where
        convertTableRow TableRowDelimiter = pure [P.horizontalRule]
        convertTableRow (TableRowInlines inlines) = traverse (fmap P.plain . convertInline) (V.toList inlines)

vecToMany :: V.Vector a -> P.Many a
vecToMany = P.Many . S.fromList . V.toList

applicativeConcatMap :: (Applicative f, Monoid m, Traversable t) => (a -> f m) -> t a -> f m
applicativeConcatMap f elems = fold <$> traverse f elems
