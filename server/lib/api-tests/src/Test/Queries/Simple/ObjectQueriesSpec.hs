{-# LANGUAGE QuasiQuotes #-}

-- |
-- Simple queries on single objects.
--
-- https://hasura.io/docs/latest/queries/postgres/simple-object-queries/#fetch-list-of-objects
-- https://hasura.io/docs/latest/queries/ms-sql-server/simple-object-queries/#fetch-list-of-objects
-- https://hasura.io/docs/latest/queries/bigquery/simple-object-queries/#fetch-list-of-objects
module Test.Queries.Simple.ObjectQueriesSpec (spec) where

import Data.Aeson (Value)
import Data.List.NonEmpty qualified as NE
import Harness.Backend.BigQuery qualified as BigQuery
import Harness.Backend.Citus qualified as Citus
import Harness.Backend.Cockroach qualified as Cockroach
import Harness.Backend.DataConnector.Sqlite qualified as Sqlite
import Harness.Backend.Postgres qualified as Postgres
import Harness.Backend.Sqlserver qualified as Sqlserver
import Harness.GraphqlEngine (postGraphql)
import Harness.Permissions (Permission (..), SelectPermissionDetails (..), selectPermission)
import Harness.Quoter.Graphql (graphql)
import Harness.Quoter.Yaml (interpolateYaml)
import Harness.Schema (Table (..), table)
import Harness.Schema qualified as Schema
import Harness.Test.Fixture qualified as Fixture
import Harness.Test.Protocol (withEachProtocol)
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment)
import Harness.Yaml (shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

spec :: SpecWith GlobalTestEnvironment
spec = do
  withEachProtocol $
    Fixture.run
      ( NE.fromList
          [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnvironment, _) ->
                  [ Postgres.setupTablesAction schema testEnvironment
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Citus.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnvironment, _) ->
                  [ Citus.setupTablesAction schema testEnvironment
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Cockroach.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Cockroach.setupTablesAction schema testEnv
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Sqlserver.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnvironment, _) ->
                  [ Sqlserver.setupTablesAction schema testEnvironment
                  ]
              },
            (Fixture.fixture $ Fixture.Backend BigQuery.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnvironment, _) ->
                  [ BigQuery.setupTablesAction schema testEnvironment
                  ],
                Fixture.customOptions =
                  Just $
                    Fixture.defaultOptions
                      { Fixture.stringifyNumbers = True
                      }
              },
            (Fixture.fixture $ Fixture.Backend Sqlite.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnvironment, _) ->
                  [ Sqlite.setupTablesAction schema testEnvironment
                  ]
              }
          ]
      )
      ( Fixture.withPermissions
          ( NE.fromList
              [ SelectPermission
                  selectPermission
                    { selectPermissionTable = "authors",
                      selectPermissionColumns = ["id", "name"]
                    }
              ]
          )
          tests
      )

--------------------------------------------------------------------------------
-- Schema

schema :: [Schema.Table]
schema =
  [ (table "authors")
      { tableColumns =
          [ Schema.column "id" Schema.TInt,
            Schema.column "name" Schema.TStr
          ],
        tablePrimaryKey = ["id"],
        tableData =
          [ [ Schema.VInt 1,
              Schema.VStr "Justin"
            ],
            [ Schema.VInt 2,
              Schema.VStr "Beltran"
            ],
            [ Schema.VInt 3,
              Schema.VStr "Sidney"
            ],
            [ Schema.VInt 4,
              Schema.VStr "Anjela"
            ]
          ]
      }
  ]

--------------------------------------------------------------------------------
-- Tests

tests :: SpecWith TestEnvironment
tests = do
  describe "Fetch a list of objects" do
    it "Fetch a list of authors" \testEnvironment -> do
      let schemaName :: Schema.SchemaName
          schemaName = Schema.getSchemaName testEnvironment

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                query {
                  #{schemaName}_authors(order_by: { id: asc }) {
                    id
                    name
                  }
                }
              |]

          expected :: Value
          expected =
            [interpolateYaml|
              data:
                #{schemaName}_authors:
                - id: 1
                  name: Justin
                - id: 2
                  name: Beltran
                - id: 3
                  name: Sidney
                - id: 4
                  name: Anjela
            |]

      shouldReturnYaml testEnvironment actual expected

    it "Fails on unknown fields" \testEnvironment -> do
      let schemaName :: Schema.SchemaName
          schemaName = Schema.getSchemaName testEnvironment

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                query {
                  #{schemaName}_authors {
                    unknown
                  }
                }
              |]

          expected :: Value
          expected =
            [interpolateYaml|
              errors:
              - extensions:
                  code: validation-failed
                  path: $.selectionSet.#{schemaName}_authors.selectionSet.unknown
                message: 'field ''unknown'' not found in type: ''#{schemaName}_authors'''
            |]

      shouldReturnYaml testEnvironment actual expected
