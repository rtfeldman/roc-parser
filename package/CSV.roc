interface CSV
    exposes [
        CSV,
        CSVRecord,
        file,
        record,
        parseStr,
        parseCSV,
        parseStrToCSVRecord,
        field,
        string,
        u64,
        f64,
    ]
    imports [
        Core.{ Parser, parse, buildPrimitiveParser, alt, map, many, sepBy1, between, ignore, flatten, sepBy },
        String.{ Utf8, oneOf, codeunit, codeunitSatisfies, strFromUtf8 },
    ]

## This is a CSV parser which follows RFC4180
##
## For simplicity's sake, the following things are not yet supported:
## - CSV files with headings
##
## The following however *is* supported
## - A simple LF ("\n") instead of CRLF ("\r\n") to separate records.
CSV : List CSVRecord
CSVRecord : List CSVField
CSVField : Utf8

## Attempts to parse an `a` from a `Str` that is encoded in CSV format.
parseStr : Parser CSVRecord a, Str -> Result (List a) [ParsingFailure Str, SyntaxError Str, ParsingIncomplete CSVRecord]
parseStr = \csvParser, input ->
    when parseStrToCSV input is
        Err (ParsingIncomplete rest) ->
            restStr = String.strFromUtf8 rest

            Err (SyntaxError restStr)

        Err (ParsingFailure str) ->
            Err (ParsingFailure str)

        Ok csvData ->
            when parseCSV csvParser csvData is
                Err (ParsingFailure str) ->
                    Err (ParsingFailure str)

                Err (ParsingIncomplete problem) ->
                    Err (ParsingIncomplete problem)

                Ok vals ->
                    Ok vals

## Attempts to parse an `a` from a `CSV` datastructure (a list of lists of bytestring-fields).
parseCSV : Parser CSVRecord a, CSV -> Result (List a) [ParsingFailure Str, ParsingIncomplete CSVRecord]
parseCSV = \csvParser, csvData ->
    csvData
    |> List.mapWithIndex (\recordFieldsList, index -> { record: recordFieldsList, index: index })
    |> List.walkUntil (Ok []) \state, { record: recordFieldsList, index: index } ->
        when parseCSVRecord csvParser recordFieldsList is
            Err (ParsingFailure problem) ->
                indexStr = Num.toStr (index + 1)
                recordStr = recordFieldsList |> List.map strFromUtf8 |> List.map (\val -> "\"$(val)\"") |> Str.joinWith ", "
                problemStr = "$(problem)\nWhile parsing record no. $(indexStr): `$(recordStr)`"

                Break (Err (ParsingFailure problemStr))

            Err (ParsingIncomplete problem) ->
                Break (Err (ParsingIncomplete problem))

            Ok val ->
                state
                |> Result.map (\vals -> List.append vals val)
                |> Continue

## Attempts to parse an `a` from a `CSVRecord` datastructure (a list of bytestring-fields)
##
## This parser succeeds when all fields of the CSVRecord are consumed by the parser.
parseCSVRecord : Parser CSVRecord a, CSVRecord -> Result a [ParsingFailure Str, ParsingIncomplete CSVRecord]
parseCSVRecord = \csvParser, recordFieldsList ->
    parse csvParser recordFieldsList (\leftover -> leftover == [])

## Wrapper function to combine a set of fields into your desired `a`
##
## ```
## record (\firstName -> \lastName -> \age -> User {firstName, lastName, age})
## |> field string
## |> field string
## |> field u64
## ```
record : a -> Parser CSVRecord a
record = Core.const

## Turns a parser for a `List U8` into a parser that parses part of a `CSVRecord`.
field : Parser Utf8 a -> Parser CSVRecord a
field = \fieldParser ->
    buildPrimitiveParser \fieldsList ->
        when List.get fieldsList 0 is
            Err OutOfBounds ->
                Err (ParsingFailure "expected another CSV field but there are no more fields in this record")

            Ok rawStr ->
                when String.parseUtf8 fieldParser rawStr is
                    Ok val ->
                        Ok { val: val, input: List.dropFirst fieldsList 1 }

                    Err (ParsingFailure reason) ->
                        fieldStr = rawStr |> strFromUtf8

                        Err (ParsingFailure "Field `$(fieldStr)` could not be parsed. $(reason)")

                    Err (ParsingIncomplete reason) ->
                        reasonStr = strFromUtf8 reason
                        fieldsStr = fieldsList |> List.map strFromUtf8 |> Str.joinWith ", "

                        Err (ParsingFailure "The field parser was unable to read the whole field: `$(reasonStr)` while parsing the first field of leftover $(fieldsStr))")

## Parser for a field containing a UTF8-encoded string
string : Parser CSVField Str
string = String.anyString

## Parse a number from a CSV field
u64 : Parser CSVField U64
u64 =
    string
    |> map \val ->
        when Str.toU64 val is
            Ok num -> Ok num
            Err _ -> Err "$(val) is not a Nat."
    |> flatten

## Parse a 64-bit float from a CSV field
f64 : Parser CSVField F64
f64 =
    string
    |> map \val ->
        when Str.toF64 val is
            Ok num -> Ok num
            Err _ -> Err "$(val) is not a F64."
    |> flatten

## Attempts to parse a Str into the internal `CSV` datastructure (A list of lists of bytestring-fields).
parseStrToCSV : Str -> Result CSV [ParsingFailure Str, ParsingIncomplete Utf8]
parseStrToCSV = \input ->
    parse file (Str.toUtf8 input) (\leftover -> leftover == [])

## Attempts to parse a Str into the internal `CSVRecord` datastructure (A list of bytestring-fields).
parseStrToCSVRecord : Str -> Result CSVRecord [ParsingFailure Str, ParsingIncomplete Utf8]
parseStrToCSVRecord = \input ->
    parse csvRecord (Str.toUtf8 input) (\leftover -> leftover == [])

# The following are parsers to turn strings into CSV structures
file : Parser Utf8 CSV
file = sepBy csvRecord endOfLine

csvRecord : Parser Utf8 CSVRecord
csvRecord = sepBy1 csvField comma

csvField : Parser Utf8 CSVField
csvField = alt escapedCsvField nonescapedCsvField

escapedCsvField : Parser Utf8 CSVField
escapedCsvField = between escapedContents dquote dquote

escapedContents : Parser Utf8 (List U8)
escapedContents = 
    oneOf [
        twodquotes |> map (\_ -> '"'),
        comma,
        cr,
        lf,
        textdata,
    ]
    |> many


twodquotes : Parser Utf8 Str
twodquotes = String.string "\"\""

nonescapedCsvField : Parser Utf8 CSVField
nonescapedCsvField = many textdata

comma = codeunit ','
dquote = codeunit '"'
endOfLine = alt (ignore crlf) (ignore lf)
cr = codeunit '\r'
lf = codeunit '\n'
crlf = String.string "\r\n"
textdata = codeunitSatisfies (\x -> (x >= 32 && x <= 33) || (x >= 35 && x <= 43) || (x >= 45 && x <= 126)) # Any printable char except " (34) and , (44)
