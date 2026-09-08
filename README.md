
# parseJSON.sh

```text
Usage: ./parseJSON.sh [options] <fileToParse>

<fileToParse>: It must be a JSON file.
If parser instructions are declared, data is retrieved in csv format.

options:
  --debug                      Debug
  --delimiter="|", -d          Delimiter for the output CSV file. Default '|'
  --file="outputFile", -f      Output file name. The program adds the .csv, .log and .txt.log 
                                   extensions. 
                                   If the files already exist adds .new before the extension. 
                                   Only errors are sent to the screen using the standard error 
								                   flow								      
  --help, -h                   Show command line options
  --metadata-delimiter="0x1F"  Delimiter for the internal metadata. Must be one caracter 
                                   length. Default 0x1F
  --no-header                  Output data wihout headers
  --parseDNSDumpster           Instructions for parse a DNSDumpster JSON file
  --tab="  ", -t               String for tabulated output. By default two spaces
  --verbose, -v			           Verbose
  --version, -V                Version

Examples:
  ./parseJSON.sh -d "||" --parseDNSDumpster -v fileToParse.json 
      # Delimiter "||", Instructions for parse a DNSDumpster JSON file, verbose, file to parse
  ./parseJSON.sh --delimiter="||" fileToParse.csv -t ".." --metadata-delimiter="0x1E"
      # Delimiter "||", file to parse, string for tabulated output "..", metadata delimiter 0x1E
```

TODO: Unit tests
TODO: parseMetadata ->parseMetaSearch -> ...    Simplifyprocedures
