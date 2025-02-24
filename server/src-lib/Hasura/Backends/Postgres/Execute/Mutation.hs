-- | Postgres Execute Mutation
--
-- Generic combinators for translating and excecuting IR mutation statements.
-- Used by the specific mutation modules, e.g. 'Hasura.Backends.Postgres.Execute.Insert'.
--
-- See 'Hasura.Backends.Postgres.Instances.Execute'.
module Hasura.Backends.Postgres.Execute.Mutation
  ( MutateResp (..),
    --
    execDeleteQuery,
    execInsertQuery,
    execUpdateQuery,
    --
    executeMutationOutputQuery,
    mutateAndFetchCols,
  )
where

import Control.Monad.Writer (runWriter)
import Data.Aeson
import Data.Sequence qualified as DS
import Database.PG.Query qualified as PG
import Hasura.Backends.Postgres.Connection
import Hasura.Backends.Postgres.SQL.DML qualified as S
import Hasura.Backends.Postgres.SQL.Types
import Hasura.Backends.Postgres.SQL.Value
import Hasura.Backends.Postgres.Translate.Delete
import Hasura.Backends.Postgres.Translate.Insert
import Hasura.Backends.Postgres.Translate.Mutation
import Hasura.Backends.Postgres.Translate.Returning
import Hasura.Backends.Postgres.Translate.Select
import Hasura.Backends.Postgres.Translate.Select.Internal.Helpers (customSQLToTopLevelCTEs, toQuery)
import Hasura.Backends.Postgres.Translate.Update
import Hasura.Base.Error
import Hasura.EncJSON
import Hasura.GraphQL.Schema.NamingCase (NamingCase)
import Hasura.GraphQL.Schema.Options qualified as Options
import Hasura.Prelude
import Hasura.QueryTags
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.IR.Delete
import Hasura.RQL.IR.Insert
import Hasura.RQL.IR.Returning
import Hasura.RQL.IR.Select
import Hasura.RQL.IR.Update
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.SQL.Backend
import Hasura.Session

data MutateResp (b :: BackendType) a = MutateResp
  { _mrAffectedRows :: Int,
    _mrReturningColumns :: [ColumnValues b a]
  }
  deriving (Generic)

deriving instance (Backend b, Show a) => Show (MutateResp b a)

deriving instance (Backend b, Eq a) => Eq (MutateResp b a)

instance (Backend b, ToJSON a) => ToJSON (MutateResp b a) where
  toJSON = genericToJSON hasuraJSON

instance (Backend b, FromJSON a) => FromJSON (MutateResp b a) where
  parseJSON = genericParseJSON hasuraJSON

data Mutation (b :: BackendType) = Mutation
  { _mTable :: QualifiedTable,
    _mQuery :: (MutationCTE, DS.Seq PG.PrepArg),
    _mOutput :: MutationOutput b,
    _mCols :: [ColumnInfo b],
    _mStrfyNum :: Options.StringifyNumbers,
    _mNamingConvention :: Maybe NamingCase
  }

mkMutation ::
  UserInfo ->
  QualifiedTable ->
  (MutationCTE, DS.Seq PG.PrepArg) ->
  MutationOutput ('Postgres pgKind) ->
  [ColumnInfo ('Postgres pgKind)] ->
  Options.StringifyNumbers ->
  Maybe NamingCase ->
  Mutation ('Postgres pgKind)
mkMutation _userInfo table query output allCols strfyNum tCase =
  Mutation table query output allCols strfyNum tCase

runMutation ::
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  Mutation ('Postgres pgKind) ->
  m EncJSON
runMutation mut =
  bool (mutateAndReturn mut) (mutateAndSel mut) $
    hasNestedFld $
      _mOutput mut

mutateAndReturn ::
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  Mutation ('Postgres pgKind) ->
  m EncJSON
mutateAndReturn (Mutation qt (cte, p) mutationOutput allCols strfyNum tCase) =
  executeMutationOutputQuery qt allCols Nothing cte mutationOutput strfyNum tCase (toList p)

execUpdateQuery ::
  forall pgKind m.
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  Options.StringifyNumbers ->
  Maybe NamingCase ->
  UserInfo ->
  (AnnotatedUpdate ('Postgres pgKind), DS.Seq PG.PrepArg) ->
  m EncJSON
execUpdateQuery strfyNum tCase userInfo (u, p) =
  case updateCTE of
    Update singleUpdate -> runCTE singleUpdate
    MultiUpdate ctes -> encJFromList <$> traverse runCTE ctes
  where
    updateCTE :: UpdateCTE
    updateCTE = mkUpdateCTE u

    runCTE :: S.TopLevelCTE -> m EncJSON
    runCTE cte =
      runMutation
        (mkMutation userInfo (_auTable u) (MCCheckConstraint cte, p) (_auOutput u) (_auAllCols u) strfyNum tCase)

execDeleteQuery ::
  forall pgKind m.
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  Options.StringifyNumbers ->
  Maybe NamingCase ->
  UserInfo ->
  (AnnDel ('Postgres pgKind), DS.Seq PG.PrepArg) ->
  m EncJSON
execDeleteQuery strfyNum tCase userInfo (u, p) =
  runMutation
    (mkMutation userInfo (_adTable u) (MCDelete delete, p) (_adOutput u) (_adAllCols u) strfyNum tCase)
  where
    delete = mkDelete u

execInsertQuery ::
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  Options.StringifyNumbers ->
  Maybe NamingCase ->
  UserInfo ->
  (InsertQueryP1 ('Postgres pgKind), DS.Seq PG.PrepArg) ->
  m EncJSON
execInsertQuery strfyNum tCase userInfo (u, p) =
  runMutation
    (mkMutation userInfo (iqp1Table u) (MCCheckConstraint insertCTE, p) (iqp1Output u) (iqp1AllCols u) strfyNum tCase)
  where
    insertCTE = mkInsertCTE u

{- Note: [Prepared statements in Mutations]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The SQL statements we generate for mutations seem to include the actual values
in the statements in some cases which pretty much makes them unfit for reuse
(Handling relationships in the returning clause is the source of this
complexity). Further, `PGConn` has an internal cache which maps a statement to
a 'prepared statement id' on Postgres. As we prepare more and more single-use
SQL statements we end up leaking memory both on graphql-engine and Postgres
till the connection is closed. So a simpler but very crude fix is to not use
prepared statements for mutations. The performance of insert mutations
shouldn't be affected but updates and delete mutations with complex boolean
conditions **might** see some degradation.
-}

mutateAndSel ::
  forall pgKind m.
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  Mutation ('Postgres pgKind) ->
  m EncJSON
mutateAndSel (Mutation qt q mutationOutput allCols strfyNum tCase) = do
  -- Perform mutation and fetch unique columns
  MutateResp _ columnVals <- liftTx $ mutateAndFetchCols qt allCols q strfyNum tCase
  select <- mkSelectExpFromColumnValues qt allCols columnVals
  -- Perform select query and fetch returning fields
  executeMutationOutputQuery
    qt
    allCols
    Nothing
    (MCSelectValues select)
    mutationOutput
    strfyNum
    tCase
    []

withCheckPermission :: (MonadError QErr m) => m (a, Bool) -> m a
withCheckPermission sqlTx = do
  (rawResponse, checkConstraint) <- sqlTx
  unless checkConstraint $
    throw400 PermissionError $
      "check constraint of an insert/update permission has failed"
  pure rawResponse

executeMutationOutputQuery ::
  forall pgKind m.
  ( MonadTx m,
    Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadReader QueryTagsComment m
  ) =>
  QualifiedTable ->
  [ColumnInfo ('Postgres pgKind)] ->
  Maybe Int ->
  MutationCTE ->
  MutationOutput ('Postgres pgKind) ->
  Options.StringifyNumbers ->
  Maybe NamingCase ->
  -- | Prepared params
  [PG.PrepArg] ->
  m EncJSON
executeMutationOutputQuery qt allCols preCalAffRows cte mutOutput strfyNum tCase prepArgs = do
  queryTags <- ask
  let queryTx :: PG.FromRes a => m a
      queryTx = do
        let selectWith = mkMutationOutputExp qt allCols preCalAffRows cte mutOutput strfyNum tCase
            query = toQuery selectWith
            queryWithQueryTags = query {PG.getQueryText = (PG.getQueryText query) <> (_unQueryTagsComment queryTags)}
        -- See Note [Prepared statements in Mutations]
        liftTx (PG.rawQE dmlTxErrorHandler queryWithQueryTags prepArgs False)

  if checkPermissionRequired cte
    then withCheckPermission $ PG.getRow <$> queryTx
    else runIdentity . PG.getRow <$> queryTx

mutateAndFetchCols ::
  forall pgKind.
  (Backend ('Postgres pgKind), PostgresAnnotatedFieldJSON pgKind) =>
  QualifiedTable ->
  [ColumnInfo ('Postgres pgKind)] ->
  (MutationCTE, DS.Seq PG.PrepArg) ->
  Options.StringifyNumbers ->
  Maybe NamingCase ->
  PG.TxE QErr (MutateResp ('Postgres pgKind) TxtEncodedVal)
mutateAndFetchCols qt cols (cte, p) strfyNum tCase = do
  let mutationTx :: PG.FromRes a => PG.TxE QErr a
      mutationTx =
        -- See Note [Prepared statements in Mutations]
        PG.rawQE dmlTxErrorHandler sqlText (toList p) False

  if checkPermissionRequired cte
    then withCheckPermission $ (first PG.getViaJSON . PG.getRow) <$> mutationTx
    else (PG.getViaJSON . runIdentity . PG.getRow) <$> mutationTx
  where
    rawAlias = S.mkTableAlias $ "mutres__" <> qualifiedObjectToText qt
    rawIdentifier = S.tableAliasToIdentifier rawAlias
    tabFrom = FromIdentifier $ FIIdentifier (unTableIdentifier rawIdentifier)
    tabPerm = TablePerm annBoolExpTrue Nothing
    selFlds = flip map cols $
      \ci -> (fromCol @('Postgres pgKind) $ ciColumn ci, mkAnnColumnFieldAsText ci)

    sqlText = toQuery selectWith

    select =
      S.mkSelect
        { S.selExtr =
            S.Extractor extrExp Nothing
              : bool [] [S.Extractor checkErrExp Nothing] (checkPermissionRequired cte)
        }

    selectWith =
      S.SelectWith
        ( [(rawAlias, getMutationCTE cte)]
            <> customSQLToTopLevelCTEs customSQLCTEs
        )
        select

    checkErrExp = mkCheckErrorExp rawIdentifier
    extrExp =
      S.applyJsonBuildObj
        [ S.SELit "affected_rows",
          affRowsSel,
          S.SELit "returning_columns",
          colSel
        ]

    affRowsSel =
      S.SESelect $
        S.mkSelect
          { S.selExtr = [S.Extractor S.countStar Nothing],
            S.selFrom = Just $ S.FromExp [S.FIIdentifier rawIdentifier]
          }

    (colSel, customSQLCTEs) =
      runWriter $
        S.SESelect
          <$> mkSQLSelect
            JASMultipleRows
            ( AnnSelectG selFlds tabFrom tabPerm noSelectArgs strfyNum tCase
            )
