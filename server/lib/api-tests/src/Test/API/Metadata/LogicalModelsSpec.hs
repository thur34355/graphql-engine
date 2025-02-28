{-# LANGUAGE QuasiQuotes #-}

-- | Tests of the Logical Models feature.
module Test.API.Metadata.LogicalModelsSpec (spec) where

import Control.Lens
import Data.Aeson qualified as A
import Data.Aeson.Lens
import Data.List.NonEmpty qualified as NE
import Harness.Backend.BigQuery qualified as BigQuery
import Harness.Backend.Citus qualified as Citus
import Harness.Backend.Cockroach qualified as Cockroach
import Harness.Backend.Postgres qualified as Postgres
import Harness.Backend.Sqlserver qualified as Sqlserver
import Harness.GraphqlEngine qualified as GraphqlEngine
import Harness.Quoter.Graphql
import Harness.Quoter.Yaml (yaml)
import Harness.Quoter.Yaml.InterpolateYaml
import Harness.Schema qualified as Schema
import Harness.Services.GraphqlEngine
import Harness.Services.Metadata
import Harness.Services.PostgresSource
import Harness.Test.BackendType qualified as BackendType
import Harness.Test.Fixture qualified as Fixture
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment, getBackendTypeConfig, scalarTypeToText)
import Harness.Yaml (shouldBeYaml, shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

-- ** Preamble

-- We currently don't need the table to exist in order to set up a logical model
-- stanza.

featureFlagForLogicalModels :: String
featureFlagForLogicalModels = "HASURA_FF_LOGICAL_MODEL_INTERFACE"

spec :: SpecWith GlobalTestEnvironment
spec = do
  let fixtures =
        NE.fromList
          [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Postgres.setupTablesAction schema testEnv
                  ]
              },
            (Fixture.fixture $ Fixture.Backend BigQuery.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ BigQuery.setupTablesAction schema testEnv
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Citus.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Citus.setupTablesAction schema testEnv
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Cockroach.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Cockroach.setupTablesAction schema testEnv
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Sqlserver.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Sqlserver.setupTablesAction schema testEnv
                  ]
              }
          ]

  Fixture.hgeWithEnv [(featureFlagForLogicalModels, "True")] do
    -- do not need to run isolated
    traverse_
      (Fixture.run fixtures)
      [testAdminAccess, testPermissionFailures]
    -- need to run isolated
    traverse_
      (Fixture.runClean fixtures)
      [testImplementation, testPermissions]

  metadataHandlingWhenDisabledSpec

-- ** Setup and teardown

schema :: [Schema.Table]
schema =
  [ (Schema.table "stuff")
      { Schema.tableColumns =
          [ Schema.column "thing" Schema.TInt,
            Schema.column "date" Schema.TUTCTime
          ]
      }
  ]

testAdminAccess :: SpecWith TestEnvironment
testAdminAccess = do
  let query :: Text
      query = "SELECT thing / {{denominator}} AS divided FROM stuff WHERE date = {{target_date}}"

  describe "Admin access" do
    let dividedStuffLogicalModel :: Schema.LogicalModel
        dividedStuffLogicalModel =
          (Schema.logicalModel "divided_stuff" query)
            { Schema.logicalModelColumns =
                [ (Schema.logicalModelColumn "divided" Schema.TInt)
                    { Schema.logicalModelColumnDescription = Just "a divided thing"
                    }
                ],
              Schema.logicalModelArguments =
                [ Schema.logicalModelColumn "denominator" Schema.TInt,
                  Schema.logicalModelColumn "target_date" Schema.TUTCTime
                ]
            }

    it "Fails to track a Logical Model without admin access" $
      \testEnvironment -> do
        let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
            sourceName = BackendType.backendSourceName backendTypeMetadata

        shouldReturnYaml
          testEnvironment
          ( GraphqlEngine.postMetadataWithStatusAndHeaders
              400
              testEnvironment
              [ ("X-Hasura-Role", "not-admin")
              ]
              (Schema.trackLogicalModelCommand sourceName backendTypeMetadata dividedStuffLogicalModel)
          )
          [yaml|
            code: access-denied
            error: "restricted access : admin only"
            path: "$.args"
          |]

    it "Fails to untrack a Logical Model without admin access" $
      \testEnvironment -> do
        let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
            sourceName = BackendType.backendSourceName backendTypeMetadata

        shouldReturnYaml
          testEnvironment
          ( GraphqlEngine.postMetadataWithStatusAndHeaders
              400
              testEnvironment
              [ ("X-Hasura-Role", "not-admin")
              ]
              (Schema.untrackLogicalModelCommand sourceName backendTypeMetadata dividedStuffLogicalModel)
          )
          [yaml|
            code: access-denied
            error: "restricted access : admin only"
            path: "$.args"
          |]

    it "Fails to list a Logical Model without admin access" $
      \testEnvironment -> do
        let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
            sourceName = BackendType.backendSourceName backendTypeMetadata
            backendType = BackendType.backendTypeString backendTypeMetadata
            getRequestType = backendType <> "_get_logical_model"

        shouldReturnYaml
          testEnvironment
          ( GraphqlEngine.postMetadataWithStatusAndHeaders
              400
              testEnvironment
              [ ("X-Hasura-Role", "not-admin")
              ]
              [yaml|
                type: *getRequestType 
                args:
                  source: *sourceName
              |]
          )
          [yaml|
            code: access-denied
            error: "restricted access : admin only"
            path: "$.args"
          |]

-------------------------
-- Test implementation --
-------------------------

testImplementation :: SpecWith TestEnvironment
testImplementation = do
  let simpleQuery :: Text
      simpleQuery = "SELECT thing / 2 AS divided FROM stuff"

  let query :: Text
      query = "SELECT thing / {{denominator}} AS divided FROM stuff WHERE date = {{target_date}}"

  describe "Implementation" $ do
    it "Adds a simple logical model of a function with no arguments and returns a 200" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata

          dividedStuffLogicalModel :: Schema.LogicalModel
          dividedStuffLogicalModel =
            (Schema.logicalModel "divided_stuff" simpleQuery)
              { Schema.logicalModelColumns =
                  [ (Schema.logicalModelColumn "divided" Schema.TInt)
                      { Schema.logicalModelColumnDescription = Just "a divided thing"
                      }
                  ],
                Schema.logicalModelArguments =
                  [Schema.logicalModelColumn "unused" Schema.TInt]
              }

      Schema.trackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

    it "Adding a logical model of a function with broken SQL returns a 400" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          brokenQuery = "SELECT * FROM dogs WHERE name = {{name"

          brokenQueryLogicalModel :: Schema.LogicalModel
          brokenQueryLogicalModel =
            (Schema.logicalModel "divided_stuff" brokenQuery)
              { Schema.logicalModelColumns =
                  [ (Schema.logicalModelColumn "divided" Schema.TInt)
                      { Schema.logicalModelColumnDescription = Just "a divided thing"
                      }
                  ],
                Schema.logicalModelArguments =
                  [Schema.logicalModelColumn "unused" Schema.TInt]
              }

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadataWithStatus
            400
            testEnvironment
            (Schema.trackLogicalModelCommand sourceName backendTypeMetadata brokenQueryLogicalModel)
        )
        [yaml|
          code: parse-failed
          error: "Found '{{' without a matching closing '}}'"
          path: "$.args"
        |]

    it "Checks for the logical model of a function" $ \testEnvironment -> do
      let rootfield :: Text
          rootfield = "divided_stuff2"

          backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          backendType = BackendType.backendTypeString backendTypeMetadata
          getRequestType = backendType <> "_get_logical_model"

          dividedStuffLogicalModel :: Schema.LogicalModel
          dividedStuffLogicalModel =
            (Schema.logicalModel rootfield query)
              { Schema.logicalModelColumns =
                  [ (Schema.logicalModelColumn "divided" Schema.TInt)
                      { Schema.logicalModelColumnDescription = Just "a divided thing"
                      }
                  ],
                Schema.logicalModelArguments =
                  [ Schema.logicalModelColumn "denominator" Schema.TInt,
                    Schema.logicalModelColumn "target_date" Schema.TUTCTime
                  ]
              }

      Schema.trackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
              type: *getRequestType 
              args:
                source: *sourceName
            |]
        )
        [interpolateYaml|
          - root_field_name: #{rootfield}
            code: #{query}
            arguments:
              denominator:
                type: #{scalarTypeToText testEnvironment Schema.TInt}
                nullable: false
              target_date:
                type: #{scalarTypeToText testEnvironment Schema.TUTCTime}
                nullable: false
            returns:
              columns:
                  - name: divided
                    type: #{scalarTypeToText testEnvironment Schema.TInt}
                    nullable: false
                    description: "a divided thing"
        |]

    it "Drops a logical model of a function and returns a 200" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata

          dividedStuffLogicalModel :: Schema.LogicalModel
          dividedStuffLogicalModel =
            (Schema.logicalModel "divided_stuff" query)
              { Schema.logicalModelColumns =
                  [ (Schema.logicalModelColumn "divided" Schema.TInt)
                      { Schema.logicalModelColumnDescription = Just "a divided thing"
                      }
                  ],
                Schema.logicalModelArguments =
                  [ Schema.logicalModelColumn "denominator" Schema.TInt,
                    Schema.logicalModelColumn "target_date" Schema.TUTCTime
                  ]
              }

      Schema.trackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

      Schema.untrackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

    it "Checks the logical model of a function can be deleted" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          backendType = BackendType.backendTypeString backendTypeMetadata
          getRequestType = backendType <> "_get_logical_model"

          dividedStuffLogicalModel :: Schema.LogicalModel
          dividedStuffLogicalModel =
            (Schema.logicalModel "divided_stuff" query)
              { Schema.logicalModelColumns =
                  [ (Schema.logicalModelColumn "divided" Schema.TInt)
                      { Schema.logicalModelColumnDescription = Just "a divided thing"
                      }
                  ],
                Schema.logicalModelArguments =
                  [ Schema.logicalModelColumn "denominator" Schema.TInt,
                    Schema.logicalModelColumn "target_date" Schema.TUTCTime
                  ]
              }

      Schema.trackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

      Schema.untrackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
              type: *getRequestType 
              args:
                source: *sourceName
            |]
        )
        [yaml|
          []
        |]

----------------------
-- Test permissions --
----------------------

testPermissions :: SpecWith TestEnvironment
testPermissions = do
  let simpleQuery :: Text
      simpleQuery = "SELECT thing / 2 AS divided FROM stuff"

  describe "Permissions" do
    let dividedStuffLogicalModel :: Schema.LogicalModel
        dividedStuffLogicalModel =
          (Schema.logicalModel "divided_stuff" simpleQuery)
            { Schema.logicalModelColumns =
                [ (Schema.logicalModelColumn "divided" Schema.TInt)
                    { Schema.logicalModelColumnDescription = Just "a divided thing"
                    }
                ],
              Schema.logicalModelArguments =
                [ Schema.logicalModelColumn "unused" Schema.TInt
                ]
            }

    it "Adds a simple logical model function with no arguments a select permission and returns a 200" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          backendType = BackendType.backendTypeString backendTypeMetadata
          createPermRequestType = backendType <> "_create_logical_model_select_permission"
          getRequestType = backendType <> "_get_logical_model"

      Schema.trackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
              type: bulk
              args:
                - type: *createPermRequestType
                  args:
                    source: *sourceName
                    root_field_name: divided_stuff
                    role: "test"
                    permission:
                      columns:
                        - divided
                      filter: {}
            |]
        )
        [yaml|
          - message: success
        |]

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
              type: *getRequestType 
              args:
                source: *sourceName
            |]
        )
        [interpolateYaml|
          - root_field_name: divided_stuff
            code: #{simpleQuery}
            arguments:
              unused:
                type: #{scalarTypeToText testEnvironment Schema.TInt}
                nullable: false
            select_permissions:
              - role: "test"
                permission:
                  columns:
                    - divided
                  filter: {}
            returns:
              columns:
                - name: divided
                  description: a divided thing
                  nullable: false
                  type: #{scalarTypeToText testEnvironment Schema.TInt}
        |]

    it "Adds a logical model, removes it, and returns 200" $ \testEnvironment -> do
      let rootfield :: Text
          rootfield = Schema.logicalModelName dividedStuffLogicalModel

          backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          backendType = BackendType.backendTypeString backendTypeMetadata
          createPermRequestType = backendType <> "_create_logical_model_select_permission"
          dropPermRequestType = backendType <> "_drop_logical_model_select_permission"
          getRequestType = backendType <> "_get_logical_model"

      Schema.trackLogicalModel sourceName dividedStuffLogicalModel testEnvironment

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
              type: bulk
              args:
                - type: *createPermRequestType 
                  args:
                    source: *sourceName
                    root_field_name: *rootfield
                    role: "test"
                    permission:
                      columns:
                        - divided
                      filter: {}
                - type: *dropPermRequestType 
                  args:
                    source: *sourceName
                    root_field_name: *rootfield
                    role: "test"
            |]
        )
        [yaml|
          - message: success
          - message: success
        |]

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
              type: *getRequestType 
              args:
                source: *sourceName
            |]
        )
        [interpolateYaml|
          - root_field_name: #{rootfield}
            code: #{simpleQuery}
            arguments:
              unused:
                type: #{scalarTypeToText testEnvironment Schema.TInt}
                nullable: false
            returns:
              columns:
                - name: divided
                  description: a divided thing
                  nullable: false
                  type: #{scalarTypeToText testEnvironment Schema.TInt}
        |]

testPermissionFailures :: SpecWith TestEnvironment
testPermissionFailures = do
  describe "Permission failures" do
    it "Fails to adds a select permission to a nonexisting source" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          backendType = BackendType.backendTypeString backendTypeMetadata
          createPermRequestType = backendType <> "_create_logical_model_select_permission"

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadataWithStatus
            400
            testEnvironment
            [yaml|
              type: bulk
              args:
                - type: *createPermRequestType 
                  args:
                    source: made_up_source
                    root_field_name: made_up_logical_model
                    role: "test"
                    permission:
                      columns:
                        - divided
                      filter: {}
            |]
        )
        [yaml|
          code: not-found
          error: "Source \"made_up_source\" not found."
          path: "$.args[0].args"
        |]

    it "Fails to adds a select permission to a nonexisting logical model" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          backendType = BackendType.backendTypeString backendTypeMetadata
          createPermRequestType = backendType <> "_create_logical_model_select_permission"

          expectedError = "Logical model \"made_up_logical_model\" not found in source \"" <> sourceName <> "\"."

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadataWithStatus
            400
            testEnvironment
            [yaml|
              type: bulk
              args:
                - type: *createPermRequestType 
                  args:
                    source: *sourceName
                    root_field_name: made_up_logical_model
                    role: "test"
                    permission:
                      columns:
                        - divided
                      filter: {}
            |]
        )
        [yaml|
          code: "not-found"
          error: *expectedError
          path: "$.args[0].args"
        |]

    it "Fails to drop a select permission on a nonexisting source" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          backendType = BackendType.backendTypeString backendTypeMetadata
          dropPermRequestType = backendType <> "_drop_logical_model_select_permission"

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadataWithStatus
            400
            testEnvironment
            [yaml|
              type: *dropPermRequestType 
              args:
                source: made_up_source
                root_field_name: made_up_logical_model
                role: "test"
                permission:
                  columns:
                    - divided
                  filter: {}
            |]
        )
        [yaml|
          code: not-found
          error: "Source \"made_up_source\" not found."
          path: "$.args"
        |]

    it "Fails to drop a select permission from a nonexisting logical model" $ \testEnvironment -> do
      let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
          sourceName = BackendType.backendSourceName backendTypeMetadata
          backendType = BackendType.backendTypeString backendTypeMetadata
          dropPermRequestType = backendType <> "_drop_logical_model_select_permission"
          expectedError = "Logical model \"made_up_logical_model\" not found in source \"" <> sourceName <> "\"."

      shouldReturnYaml
        testEnvironment
        ( GraphqlEngine.postMetadataWithStatus
            400
            testEnvironment
            [yaml|
              type: *dropPermRequestType 
              args:
                source: *sourceName
                root_field_name: made_up_logical_model
                role: "test"
            |]
        )
        [yaml|
          code: "not-found"
          error: *expectedError 
          path: "$.args"
        |]

metadataHandlingWhenDisabledSpec :: SpecWith GlobalTestEnvironment
metadataHandlingWhenDisabledSpec = do
  describe "When logical models are enabled" do
    withHge
      ( emptyHgeConfig
          { hgeConfigEnvironmentVars =
              [ (featureFlagForLogicalModels, "True")
              ]
          }
      )
      $ withPostgresSource "default"
      $ do
        it "`replace_metadata` does not report any inconsistent objects" $ \env -> do
          currentMetadata <- export_metadata env
          actual <- replace_metadata env (metadataWithLogicalModel currentMetadata)

          actual
            `shouldBeYaml` [yaml|
              inconsistent_objects: []
              is_consistent: true
              |]

        it "They do appear in the schema" $ \env -> do
          currentMetadata <- export_metadata env
          _res <- replace_metadata env (metadataWithLogicalModel currentMetadata)

          let expected =
                [yaml|
                data:
                  __type:
                    name: divided_stuff
                |]

          actual <- hgePostGraphql env queryTypesIntrospection
          actual `shouldBeYaml` expected

  describe "When logical models are disabled" do
    withHge emptyHgeConfig $ do
      withPostgresSource "default" $ do
        it "`replace_metadata` preserves logical models" $ \env -> do
          currentMetadata <- export_metadata env
          _ <- replace_metadata env (metadataWithLogicalModel currentMetadata)
          actual <- export_metadata env
          actual `shouldBeYaml` (metadataWithLogicalModel currentMetadata)

        it "`replace_metadata` reports inconsistent objects" $ \env -> do
          currentMetadata <- export_metadata env
          actual <- replace_metadata env (metadataWithLogicalModel currentMetadata)

          actual
            `shouldBeYaml` [yaml|
              inconsistent_objects:
                - definition: *logicalModelsMetadata
                  name: logical_model divided_stuff in source default
                  reason: 'Inconsistent object: The Logical Models feature is disabled'
                  type: logical_model
              is_consistent: false
            |]

        it "They do not appear in the schema" $ \env -> do
          currentMetadata <- export_metadata env
          _res <- replace_metadata env (metadataWithLogicalModel currentMetadata)

          let expected =
                [yaml|
                data:
                  __type: null
                |]

          actual <- hgePostGraphql env queryTypesIntrospection
          actual `shouldBeYaml` expected
  where
    logicalModelsMetadata =
      [yaml|
          arguments:
            divided:
              nullable: false
              type: int
          code: SELECT {{divided}} as divided
          returns:
            columns:
              - name: divided
                description: a divided thing
                nullable: false
                type: integer
          root_field_name: divided_stuff
      |]

    metadataWithLogicalModel :: A.Value -> A.Value
    metadataWithLogicalModel currentMetadata =
      currentMetadata
        & key "sources"
          . nth 0
          . atKey "logical_models"
          .~ Just [yaml| - *logicalModelsMetadata |]

    queryTypesIntrospection :: A.Value
    queryTypesIntrospection =
      [graphql|
          query {
            __type(name: "divided_stuff") {
              name
            }
          }
        |]
