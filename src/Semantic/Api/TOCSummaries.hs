{-# LANGUAGE LambdaCase, MonoLocalBinds #-}
module Semantic.Api.TOCSummaries
( diffSummary
, legacyDiffSummary
, diffSummaryBuilder
) where

import           Analysis.Decorator (decoratorWithAlgebra)
import           Analysis.TOCSummary (Declaration, HasDeclaration, declarationAlgebra, formatKind)
import           Control.Effect.Error
import           Control.Effect.Parse
import           Control.Lens
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Blob
import           Data.ByteString.Builder
import           Data.Either (partitionEithers)
import           Data.Functor.Classes
import           Data.Hashable.Lifted
import           Data.Language (Language)
import           Data.Map (Map)
import qualified Data.Map.Monoidal as Map
import           Data.ProtoLens (defMessage)
import           Data.Semilattice.Lower
import           Data.Term (Term)
import qualified Data.Text as T
import           Data.These (These)
import           Diffing.Algorithm (Diffable)
import           Parsing.Parser (SomeParser, aLaCarteParsers)
import           Proto.Semantic as P hiding (Blob, BlobPair)
import           Proto.Semantic_Fields as P
import           Rendering.TOC
import           Semantic.Api.Bridge
import           Semantic.Api.Diffs
import           Semantic.Task as Task
import           Serializing.Format
import           Source.Loc

diffSummaryBuilder :: DiffEffects sig m => Format DiffTreeTOCResponse -> [BlobPair] -> m Builder
diffSummaryBuilder format blobs = diffSummary blobs >>= serialize format

legacyDiffSummary :: DiffEffects sig m => [BlobPair] -> m Summaries
legacyDiffSummary = distributeFoldMap go
  where
    go :: (Carrier sig m, Member (Error SomeException) sig, Member Parse sig, Member Telemetry sig, MonadIO m) => BlobPair -> m Summaries
    go blobPair = parsePairWith summarizeDiffParsers (fmap (uncurry (flip Summaries) . bimap toMap toMap . partitionEithers) . summarizeTerms) blobPair
      `catchError` \(SomeException e) ->
        pure $ Summaries mempty (toMap [ErrorSummary (T.pack (show e)) lowerBound lang])
      where path = T.pack $ pathKeyForBlobPair blobPair
            lang = languageForBlobPair blobPair

            toMap :: ToJSON a => [a] -> Map.Map T.Text [Value]
            toMap [] = mempty
            toMap as = Map.singleton path (toJSON <$> as)


diffSummary :: DiffEffects sig m => [BlobPair] -> m DiffTreeTOCResponse
diffSummary blobs = do
  diff <- distributeFor blobs go
  pure $ defMessage & P.files .~ diff
  where
    go :: (Carrier sig m, Member (Error SomeException) sig, Member Parse sig, Member Telemetry sig, MonadIO m) => BlobPair -> m TOCSummaryFile
    go blobPair = parsePairWith summarizeDiffParsers (fmap (uncurry toFile . partitionEithers . map (bimap toError toChange)) . summarizeTerms) blobPair
      `catchError` \(SomeException e) ->
        pure $ toFile [defMessage & P.error .~ T.pack (show e) & P.maybe'span .~ Nothing] []
      where toFile errors changes = defMessage
              & P.path     .~ T.pack (pathKeyForBlobPair blobPair)
              & P.language .~ bridging # languageForBlobPair blobPair
              & P.changes  .~ changes
              & P.errors   .~ errors

toChangeType :: Change -> ChangeType
toChangeType = \case
  Changed  -> MODIFIED
  Deleted  -> REMOVED
  Inserted -> ADDED
  Replaced -> MODIFIED

toChange :: TOCSummary -> TOCSummaryChange
toChange TOCSummary{..} = defMessage
  & P.category   .~ formatKind kind
  & P.term       .~ ident
  & P.maybe'span .~ (converting #? span)
  & P.changeType .~ toChangeType change

toError :: ErrorSummary -> TOCSummaryError
toError ErrorSummary{..} = defMessage
  & P.error      .~ message
  & P.maybe'span .~ converting #? span


summarizeDiffParsers :: Map Language (SomeParser SummarizeDiff Loc)
summarizeDiffParsers = aLaCarteParsers

class SummarizeDiff term where
  summarizeTerms :: (Member Telemetry sig, Carrier sig m, MonadIO m) => These (Blob, term Loc) (Blob, term Loc) -> m [Either ErrorSummary TOCSummary]

instance (Diffable syntax, Eq1 syntax, HasDeclaration syntax, Hashable1 syntax, Traversable syntax) => SummarizeDiff (Term syntax) where
  summarizeTerms = fmap diffTOC . diffTerms . bimap decorateTerm decorateTerm where
    decorateTerm :: (Foldable syntax, Functor syntax, HasDeclaration syntax) => (Blob, Term syntax Loc) -> (Blob, Term syntax (Maybe Declaration))
    decorateTerm (blob, term) = (blob, decoratorWithAlgebra (declarationAlgebra blob) term)
