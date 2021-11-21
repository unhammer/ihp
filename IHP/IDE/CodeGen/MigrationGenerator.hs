{-|
Module: IHP.IDE.CodeGen.MigrationGenerator
Description: Generates database migration sql files
Copyright: (c) digitally induced GmbH, 2021
-}
module IHP.IDE.CodeGen.MigrationGenerator where

import IHP.Prelude
import qualified System.Directory as Directory
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import IHP.ModelSupport hiding (withTransaction)
import qualified Data.Time.Clock.POSIX as POSIX
import qualified IHP.NameSupport as NameSupport
import qualified Data.Char as Char
import IHP.Log.Types
import IHP.SchemaMigration
import qualified System.Process as Process
import qualified IHP.IDE.SchemaDesigner.Parser as Parser
import IHP.IDE.SchemaDesigner.Types
import Text.Megaparsec

-- | Generates a new migration @.sql@ file in @Application/Migration@
createMigration :: Text -> IO Migration
createMigration description = do
    revision <- round <$> POSIX.getPOSIXTime
    let slug = NameSupport.toSlug description
    let migrationFile = tshow revision <> (if isEmpty slug then "" else "-" <> slug) <> ".sql"
    Directory.createDirectoryIfMissing False "Application/Migration"
    Text.writeFile ("Application/Migration/" <> cs migrationFile) "-- Write your SQL migration code in here\n"
    pure Migration { .. }

diffAppDatabase = do
    (Right targetSchema) <- Parser.parseSchemaSql
    actualSchema <- getAppDBSchema

    pure (diffSchemas targetSchema actualSchema)

diffSchemas :: [Statement] -> [Statement] -> [Statement]
diffSchemas targetSchema actualSchema =
    targetSchema
        |> removeComments -- SQL Comments are not used in the diff
        |> (\schema -> schema \\ actualSchema) -- Get rid of all statements that exist in both schemas, there's nothing we need to do to them
        |> map statementToMigration
        |> concat
    where
        removeComments = filter \case
                Comment {} -> False
                _          -> True

        statementToMigration :: Statement -> [Statement]
        statementToMigration statement@(StatementCreateTable { unsafeGetCreateTable = table }) = 
                case actualTable of
                    Just actualTable -> migrateTable statement actualTable
                    Nothing -> [statement]
            where
                actualTable = actualSchema |> find \case
                        StatementCreateTable { unsafeGetCreateTable = CreateTable { name } } -> name == get #name table
                        otherwise                                                            -> False
        statementToMigration statement = [statement]

migrateTable :: Statement -> Statement -> [Statement]
migrateTable StatementCreateTable { unsafeGetCreateTable = targetTable } StatementCreateTable { unsafeGetCreateTable = actualTable } = migrateTable' targetTable actualTable
    where
        migrateTable' CreateTable { name = tableName, columns = targetColumns } CreateTable { columns = actualColumns } = map createColumn createColumns <> map dropColumn dropColumns
            where
                createColumns :: [Column]
                createColumns = actualColumns \\ targetColumns

                dropColumns :: [Column]
                dropColumns = targetColumns \\ actualColumns

                createColumn :: Column -> Statement
                createColumn column = AddColumn { tableName, column }

                dropColumn :: Column -> Statement
                dropColumn column = DropColumn { tableName, columnName = get #name column }

getAppDBSchema :: IO [Statement]
getAppDBSchema = do
    sql <- dumpAppDatabaseSchema
    case parseDumpedSql sql of
        Left error -> fail (cs error)
        Right result -> pure result

-- | Returns the DDL statements of the locally running dev db
--
-- Basically does the same as @make dumpdb@ but returns the output as a string
dumpAppDatabaseSchema :: IO Text
dumpAppDatabaseSchema = do
    projectDir <- Directory.getCurrentDirectory
    cs <$> Process.readProcess "pg_dump" ["-s", "--no-owner", "-h", projectDir <> "/build/db", "app"] []

parseDumpedSql :: Text -> (Either ByteString [Statement])
parseDumpedSql sql =
    case runParser Parser.parseDDL "pg_dump" sql of
        Left error -> Left (cs $ errorBundlePretty error)
        Right r -> Right r