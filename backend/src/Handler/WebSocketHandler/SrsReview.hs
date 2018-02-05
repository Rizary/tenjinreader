{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
module Handler.WebSocketHandler.SrsReview where

import Import
import Control.Lens hiding (reviews)
import SrsDB
import Handler.WebSocketHandler.Utils
import qualified Data.Text as T
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List.NonEmpty as NE
import Data.Time.Clock
import Data.Time.Calendar
import Text.Pretty.Simple
import System.Random
import Data.Aeson
import Data.Foldable (foldrM)
import qualified Data.BTree.Impure as Tree
import Control.Monad.Haskey
import Data.BTree.Alloc (AllocM, AllocReaderM)
import Database.Persist.Sql
import Data.These
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Control.Monad.State hiding (foldM)
import NLP.Japanese.Utils
import Data.SearchEngine


getSrsStats :: GetSrsStats
  -> WsHandlerM (SrsStats,SrsStats)
getSrsStats _ =
  (,) <$> getReviewStats ReviewTypeRecogReview
    <*> getReviewStats ReviewTypeProdReview

getReviewStats rt = do
  pend <- getAllPendingReviews rt

  allRs <- transactReadOnlySrsDB $ \rd -> do
    Tree.toList (_reviews rd)

  let total = length allRs

      succ = sumOf (folded . _2 . reviewStateL rt . _Just . _2 . successCount) allRs
      fail = sumOf (folded . _2 . reviewStateL rt . _Just . _2 . failureCount) allRs
      totalR = succ + fail

      avgSucc = if (totalR > 0)
        then floor $ ((fromIntegral succ) * 100) /
                  (fromIntegral totalR)
        else 0
  return $ SrsStats (length pend) total totalR avgSucc

getAllPendingReviews
  :: ReviewType
  -> WsHandlerM [(SrsEntryId, SrsEntry)]
getAllPendingReviews rt = do
  today <- liftIO $ utctDay <$> getCurrentTime

  transactReadOnlySrsDB $ \rd -> do
    rs <- Tree.toList (_reviews rd)
    let
      f (k,r) = (k,r) <$
        (r ^? (reviewStateL rt) . _Just . _1 . _NewReview)
        <|> (g =<< r ^? (reviewStateL rt) . _Just .
            _1 . _NextReviewDate)
        where g (d,_) = if d <= today
                then Just (k,r)
                else Nothing

    return $ mapMaybe f rs

getBrowseSrsItems :: BrowseSrsItems -> WsHandlerM [SrsItem]
getBrowseSrsItems (BrowseSrsItems rt brws) = do
  today <- liftIO $ utctDay <$> getCurrentTime

  let
    filF (k,r) = (k,r) <$ case brws of
      (BrowseDueItems l) -> g =<< r ^? (reviewStateL rt)
          . _Just . _1 . _NextReviewDate
        where g (d, interval) = if d <= today
                then checkInterval l interval
                else Nothing

      (BrowseNewItems) ->
        (r ^? (reviewStateL rt) . _Just . _1 . _NewReview)

      (BrowseSuspItems l) -> checkInterval l =<<
        (r ^? (reviewStateL rt) . _Just . _1 . _Suspended)

      (BrowseOtherItems l) -> g =<< r ^? (reviewStateL rt)
          . _Just . _1 . _NextReviewDate
        where g (d, interval) = if d > today
                then checkInterval l interval
                else Nothing

    checkInterval LearningLvl (SrsInterval l)=
      if l <= 4 then Just () else Nothing

    checkInterval IntermediateLvl (SrsInterval l)=
      if l > 4 && l <= 60 then Just () else Nothing

    checkInterval MatureLvl (SrsInterval l)=
      if l > 60 then Just () else Nothing

  rs <- transactReadOnlySrsDB $ \rd -> do
    rs <- Tree.toList (_reviews rd)
    return $ mapMaybe filF rs
  return $ map (\(i,r) -> SrsItem i (r ^. field)) rs

getBulkEditSrsItems :: BulkEditSrsItems
  -> WsHandlerM (Maybe ())
getBulkEditSrsItems
  (BulkEditSrsItems _ ss DeleteSrsItems) = do
  transactSrsDB_ $
    (reviews %%~ (\rt -> foldrM Tree.deleteTree rt ss))

  return $ Just ()

getBulkEditSrsItems (BulkEditSrsItems rt ss op) = do
  today <- liftIO $ utctDay <$> getCurrentTime

  let
    setL = case rt of
      ReviewTypeRecogReview -> here
      ReviewTypeProdReview -> there
    upF =
      case op of
        SuspendSrsItems ->
          reviewState . setL . _1 %~ \case
            NextReviewDate _ i -> Suspended i
            a -> a
        MarkDueSrsItems ->
          reviewState . setL . _1 %~ \case
            NextReviewDate _ i -> NextReviewDate today i
            Suspended i -> NextReviewDate today i
            a -> a
        ChangeSrsReviewData d ->
          reviewState . setL . _1 %~ \case
            NextReviewDate _ i -> NextReviewDate d i
            Suspended i -> NextReviewDate d i
            a -> a

    doUp :: (AllocM m) => Tree.Tree SrsEntryId SrsEntry
      -> SrsEntryId
      -> m (Tree.Tree SrsEntryId SrsEntry)
    doUp t rId = t & updateTreeM rId
      (\r -> return $ upF r)

  transactSrsDB_ $
    (reviews %%~ (\rt -> foldlM doUp rt ss))

  return $ Just ()

getSrsItem :: GetSrsItem
  -> WsHandlerM (Maybe (SrsEntryId, SrsEntry))
getSrsItem (GetSrsItem i) = do
  s <- transactReadOnlySrsDB (\rd ->
        Tree.lookupTree i (rd ^. reviews))
  return $ (,) i <$> s

getEditSrsItem :: EditSrsItem
  -> WsHandlerM ()
getEditSrsItem (EditSrsItem sId sItm) = do
  transactSrsDB_ $
    (reviews %%~ Tree.insertTree sId sItm)

getSyncReviewItems :: SyncReviewItems
  -> WsHandlerM (Maybe ([ReviewItem], Int))
getSyncReviewItems (SyncReviewItems rt results mAp) = do
  today <- liftIO $ utctDay <$> getCurrentTime

  let
    doUp :: (AllocM m) => Tree.Tree SrsEntryId SrsEntry
      -> (SrsEntryId, Bool)
      -> m (Tree.Tree SrsEntryId SrsEntry)
    doUp t (rId,b) = updateTreeM rId
        (\r -> return $ updateSrsEntry b today rt r) t

  transactSrsDB_ $
    (reviews %%~ (\rt -> foldlM doUp rt results))

  let
    getRv alreadyPresent = do
      rsAll <- getAllPendingReviews rt
      let rs = filter (\(i,_) -> not $ elem i alreadyPresent) rsAll
      return $ (getReviewItem <$> (take 20 rs), length rsAll)
  mapM getRv mAp


updateSrsEntry :: Bool -> Day -> ReviewType -> SrsEntry -> SrsEntry
updateSrsEntry b today rt r = r
  & reviewState . setL . _1 %~ modifyState
  & reviewState . setL . _2 %~ modifyStats

  where
    setL = case rt of
      ReviewTypeRecogReview -> here
      ReviewTypeProdReview -> there
    modifyState (NextReviewDate d i) =
      getNextReviewDate today d i b
    modifyState (NewReview) =
      getNextReviewDate today today (SrsInterval 1) b
    modifyState s = s -- error

    modifyStats s = if b
      then s & successCount +~ 1
      else s & failureCount +~ 1


getNextReviewDate
  :: Day
  -> Day
  -> SrsInterval
  -> Bool
  -> SrsEntryState
getNextReviewDate
  today dueDate (SrsInterval lastInterval) success =
  NextReviewDate (addDays nextInterval today) (SrsInterval fullInterval)
  where extraDays = diffDays today dueDate
        fullInterval = lastInterval + extraDays
        fi = fromIntegral fullInterval
        nextInterval = ceiling $ if success
          then fi * 2.5
          else fi * 0.25

-- getNextReviewDate
--   :: Bool
--   -> UTCTime
--   -> Maybe UTCTime
--   -> Int
--   -> UTCTime
-- getNextReviewDate
--   success curTime revDate oldGrade =
--   let
--     addHour h = addUTCTime (h*60*60) curTime
--     addDay d = addUTCTime (d*24*60*60) curTime
--   in case (oldGrade, success) of
--     (0,_) -> addHour 4
--     (1,False) -> addHour 4

--     (2,False) -> addHour 8
--     (1,True) -> addHour 8

--     (2,True) -> addDay 1
--     (3,False) -> addDay 1

--     (3,True) -> addDay 3
--     (4,False) -> addDay 3

--     (4,True) -> addDay 7
--     (5,False) -> addDay 7

--     (5,True) -> addDay 14
--     (6,False) -> addDay 14

--     (6,True) -> addDay 30
--     (7,False) -> addDay 30

--     (7,True) -> addDay 120
--     _ -> curTime -- error

getCheckAnswer :: CheckAnswer -> WsHandlerM CheckAnswerResult
getCheckAnswer (CheckAnswer readings alt) = do
  liftIO $ pPrint alt
  let  f (c,t) = (,) <$> pure c <*> getKana t
  kanaAlts <- lift $ mapM (mapM f) alt
  liftIO $ pPrint kanaAlts
  return $ checkAnswerInt readings kanaAlts

checkAnswerInt :: [Reading] -> [[(Double, Text)]] -> CheckAnswerResult
checkAnswerInt readings kanaAlts =
  case any (\r -> elem r kanas) (unReading <$> readings) of
    True -> AnswerCorrect
    False -> AnswerIncorrect "T"
  where
    kanas = concat $ map (map snd) kanaAlts

getQuickAddSrsItem :: QuickAddSrsItem -> WsHandlerM VocabSrsState
getQuickAddSrsItem (QuickAddSrsItem v t) = do
  srsItm <- lift $ makeSrsEntry v t
  let
    upFun :: (AllocM m) => SrsEntry
      -> AppUserDataTree CurrentDb
      -> StateT (Maybe VocabSrsState) m
           (AppUserDataTree CurrentDb)
    upFun itm rd = do
      mx <- lift $ Tree.lookupMaxTree (rd ^. reviews)
      let newk = maybe zerokey nextKey mx
          zerokey = SrsEntryId 0
          nextKey (SrsEntryId k, _) = SrsEntryId (k + 1)

      put (Just $ InSrs newk)
      lift $ rd & reviews %%~ Tree.insertTree newk itm
         >>= srsKanjiVocabMap %%~ Tree.insertTree newk v
         >>= case v of
         (Left k) ->
           kanjiSrsMap %%~ Tree.insertTree k (Right newk)
         (Right v) ->
           vocabSrsMap %%~ Tree.insertTree v (Right newk)

  ret <- forM srsItm $ \itm -> do
    transactSrsDB $ runStateWithNothing $ (upFun itm)

  return $ maybe NotInSrs id (join ret)

getQuickToggleWakaru :: QuickToggleWakaru -> WsHandlerM (VocabSrsState)
getQuickToggleWakaru (QuickToggleWakaru e) = do
  let
    f k t = (lift $ Tree.lookupTree k t)
      >>= \case
        Nothing -> do
          put (Just IsWakaru)
          lift $ Tree.insertTree k (Left ()) t
        Just _ -> do
          put (Just NotInSrs)
          lift $ Tree.deleteTree k t

    upFun :: (AllocM m)
      => AppUserDataTree CurrentDb
      -> StateT (Maybe VocabSrsState) m
           (AppUserDataTree CurrentDb)
    upFun = case e of
      (Left k) -> kanjiSrsMap %%~ (f k)
      (Right v) -> vocabSrsMap %%~ (f v)

  ret <- transactSrsDB $ runStateWithNothing upFun

  return $ maybe NotInSrs id ret

data TRM = TRM SrsEntryField (NonEmpty Reading) (NonEmpty Meaning)

makeSrsEntry
  :: (Either KanjiId VocabId)
  -> Maybe Text
  -> Handler (Maybe SrsEntry)
makeSrsEntry v surface = do
  today <- liftIO $ utctDay <$> getCurrentTime
  let
  tmp <- case v of
    (Left kId) -> do
      kanjiDb <- asks appKanjiDb
      let k = arrayLookupMaybe kanjiDb kId
          r = nonEmpty =<< (++)
            <$> k ^? _Just . kanjiDetails . kanjiOnyomi
            <*> k ^? _Just . kanjiDetails . kanjiKunyomi
          m = nonEmpty =<< k ^? _Just . kanjiDetails . kanjiMeanings
          f = k ^? _Just . kanjiDetails . kanjiCharacter . to unKanji
            . to (:|[])
      return $ TRM <$> f <*> r <*> m

    (Right vId) -> do
      vocabDb <- asks appVocabDb
      let v = arrayLookupMaybe vocabDb vId
          r = nonEmpty $ v ^.. _Just . vocabEntry . entryReadingElements
            . traverse . readingPhrase . to (Reading . unReadingPhrase)
          m = nonEmpty $ v ^.. _Just . vocabEntry . entrySenses
            . traverse . senseGlosses . traverse . glossDefinition . to (Meaning)
          f = (isSurfaceKana surface vocabField) <|>
            ((:|[]) <$> (unKanjiPhrase <$> (matchingSurface ks =<< surface)
                         <|> vocabField))

          vocabField = v ^? _Just . vocabDetails . vocab
            . to vocabToText

          ks = v ^.. _Just . vocabEntry . entryKanjiElements
            . traverse . kanjiPhrase


      return $ TRM <$> f <*> r <*> m

  let get (TRM f r m) = SrsEntry
        { _reviewState = These state state
          , _readings = r
          , _meaning  = m
          , _readingNotes = Nothing
          , _meaningNotes = Nothing
          , _field = f
        }
      state = (NewReview, SrsEntryStats 0 0)
  return (get <$> tmp)

isSurfaceKana (Just t) (Just v) = if isKanaOnly t
  then if t == v then Just (t:|[]) else Just (t:|[v])
  else Nothing
isSurfaceKana _ _ = Nothing

isKanaOnly :: Text -> Bool
isKanaOnly = (all f) . T.unpack
  where f = not . isKanji

getImportSearchFields :: ImportSearchFields
  -> WsHandlerM ([(Int, Maybe (Either SrsEntryId (NonEmpty EntryId)))])
getImportSearchFields (ImportSearchFields fs)= do
  return []
  -- uId <- asks currentUserId
  -- vocabDb <- lift $ asks appVocabDb
  -- vocabSearchEng <- lift $ asks appVocabSearchEng

  -- s <- lift $ transactReadOnlySrsDB $ \db ->
  --   Tree.lookupTree uId (db ^. userData) >>= mapM (\rd -> do
  --     let
  --       f ne = mapM (\i -> Tree.lookupTree i (rd ^. vocabSrsMap)) keys
  --         >>= (\xs -> case (NE.nonEmpty keys, catMaybes xs) of
  --           (_,(sId:_)) -> return (Just $ Left sId))
  --           (Just es,_) -> return (Just $ Right es)
  --           _ -> return Nothing
  --         where
  --           keys = query vocabSearchEng (NE.toList ne)
  --     fs & each . _2 %%~ f)
  -- return $ maybe (fs & each . _2 .~ Nothing) id s

flippedfoldM f ta b = foldM f b ta

getImportData :: ImportData
  -> WsHandlerM ()
getImportData (ImportData fs) = do
  -- uId <- asks currentUserId
  -- let
  --   f rd (AddVocabs vs) = do
  --     srsItm <- lift $ makeSrsEntry (Right $ NE.head v) Nothing

  --     nrd <- forM srsItm $ \itm -> do
  --       mx <- lift $ Tree.lookupMaxTree (rd ^. reviews)
  --       let newk = maybe zerokey nextKey mx
  --           zerokey = SrsEntryId 0
  --           nextKey (SrsEntryId k, _) = SrsEntryId (k + 1)

  --       rd & reviews %%~ Tree.insertTree newk itm
  --          >>= srsKanjiVocabMap %%~ Tree.insertTree newk (NE.head vs)
  --          >>= flippedfoldM (\v -> vocabSrsMap %%~ Tree.insertTree v newk) vs

  --     return $ maybe rd id nrd

  --   f rd (AddCustomEntry nE vs) = do
  --     let
  --       state = (NewReview, SrsEntryStats 0 0)
  --       itm = SrsEntry (These state state)
  --         (Reading <$> (maybe (mainField nE)
  --           id (NE.nonEmpty $ readingField nE)))
  --         (Meaning <$> meaningField nE)
  --         (ReadingNotes <$> readingNotesField nE)
  --         (MeaningNotes <$> meaningNotesField nE)
  --         (mainField nE)
  --     rd &

  --   f rd (MarkWakaru vs) = rd &

  -- lift $ transactSrsDB_ $
  --   userData %%~ updateTreeM uId (flippedfoldM f fs)
  return ()

matchingSurface :: [KanjiPhrase] -> Text -> Maybe KanjiPhrase
matchingSurface ks surf = fmap fst $ headMay $ reverse (sortF comPrefixes)
  where
    comPrefixes = map (\k -> (k, T.commonPrefixes surf (unKanjiPhrase k))) ks
    sortF = sortBy (comparing (preview (_2 . _Just . _1 . to (T.length))))

-- initSrsDb :: Handler ()
-- initSrsDb = do
--   users <- runDB $ selectKeysList ([] :: [Filter User]) []
--   transactSrsDB_ $ \db -> do
--     let f db u = do
--           let uId = fromSqlKey u
--               d = AppUserDataTree  Tree.empty Tree.empty Tree.empty Tree.empty Tree.empty def
--           Tree.lookupTree uId (db ^. userData) >>= \case
--             (Just _) -> return db
--             Nothing -> db & userData %%~ (Tree.insertTree uId d)
--     foldM f db users

--   return ()

fixSrsDb :: Handler ()
fixSrsDb = do
  -- se <- asks appVocabSearchEngNoGloss
  -- let uId = 1
  -- let
  --   upFun :: (AllocM m) => AppUserDataTree CurrentDb
  --     -> m (AppUserDataTree CurrentDb)
  --   upFun rd = do
  --     rws <- Tree.toList (rd ^. reviews)
  --     let

  --       getF (ri,r) = (,) <$> pure ri <*> listToMaybe eIds
  --         where f = NE.head (r ^. field)
  --               eIds = query se [f]
  --       newIds :: [(SrsEntryId, EntryId)]
  --       newIds = catMaybes $ map getF rws

  --       ff rd (s,e) = rd & srsKanjiVocabMap %%~ Tree.insertTree s (Right e)
  --         >>= vocabSrsMap %%~ Tree.insertTree e s

  --     foldlM ff rd newIds

  -- transactSrsDB_ $ userData %%~ updateTreeM uId upFun

  return ()
