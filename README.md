
# parseJSON.sh

```text
Usage: ./parseJSON.sh [options] <fileToParse>

<fileToParse>: It must be a JSON file.
If no instructions are declared, the file is parsed and tabulated on the screen.

options:
  --debug                      Debug. Future use
  --delimiter="|", -d          Delimiter for the output CSV file. Default '|'
  --help, -h                   Show command line options
  --metadata-delimiter="1F"    Delimiter for the internal metadata. Must be one caracter length. Default 0x1F
  --parseDNSDumpster           Instructions for parse a DNSDumpster JSON file
  --tab="  ", -t               String for tabulated output. By default two spaces
  --verbose, -v			       Verbose

Examples:
  ./parseJSON.sh -d "||" --parseDNSDumpster -v fileToParse.json 
      # Delimiter "||", Instructions for parse a DNSDumpster JSON file, verbose, file to parse
  ./parseJSON.sh --delimiter="||" fileToParse.csv -t ".." --metadata-delimiter="1E"
      # Delimiter "||", file to parse, string for tabulated output "..", metadata delimiter 0x1E
```

TODO: Unit tests
