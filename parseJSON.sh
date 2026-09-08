#!/usr/bin/env bash

set -o nounset
shopt -s lastpipe

# Definir la limpieza al salir (EXIT) o recibir señales de interrupción (INT, TERM)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


usage() {
    cat <<EOF
Usage: $0 [options] <fileToParse>

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
  --verbose, -v			       Verbose
  --version, -V                Version

Examples:
  $0 -d "||" --parseDNSDumpster -v fileToParse.json 
      # Delimiter "||", Instructions for parse a DNSDumpster JSON file, verbose, file to parse
  $0 --delimiter="||" fileToParse.csv -t ".." --metadata-delimiter="0x1E"
      # Delimiter "||", file to parse, string for tabulated output "..", metadata delimiter 0x1E
EOF
}

DEBUG=0
DELIMITER_IS_SET=0; # Delimiter can be empty. Overrides parser value
DELIMITER=""
DOTOOL="xdotool"
FDS_RESTORED=1
FILE=""
METADATA=""
PARM_METADATA_DELIMITER="0x1F"
METADATA_DELIMITER=$(echo "${PARM_METADATA_DELIMITER:2}" | xxd -r -p)
NO_HEADER=0
OUTPUT_FILE_IS_SET=0; # If set, it can not be empty
OUTPUT_FILE=""
OUTPUT=""
OUTPUT_HEADER=""
PARSER=""
PARSER_FIELDS=()
PARSER_KEY=""
PARSER_LEVEL=0
PARSER_STOP=0 ## ELIMINAR CUANDO DEJE DE USARLA
TAB="  "
TEST="";
tmp=$(mktemp)
TMP_CLOSED=0
VERBOSE=0
VERSION="01.01"

ARGS=$(LC_ALL=C getopt \
	--long debug,delimiter:,file:help,metadata-delimiter:,no-header,parseDNSDumpster,tab:,verbose,version \
	-o d:f:ht:vV \
	-n "$0" \
	-- "$@" \
	2>"$tmp"
)
OPTERROR=$?

main() {

	testEnv

	if [[ $# -eq 0 ]]; then
		usage
		$DOTOOL type "$0 "
    	[[ -z $TEST ]] && exit 0 || return 0
	fi   

	args

	iterate_file
	[[ -n "$PARSER" ]] && parse_file
}

testEnv() {
	if [[ $OPTERROR -ne 0 ]]; then
		error 2 "$(cat "$tmp" | sed '1!s/^/❌ /')" # Options error
	fi

	if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then 
		if ! command -v ydotool &> /dev/null; then
			error 3 "ydotool" # ydotool is not installed
		fi
		DOTOOL="ydotool"
		return 
	fi

	if ! command -v xdotool &> /dev/null; then
	    error 3 "xdotool" # xdotool is not installed
	fi
}

args() {
	eval set -- "$ARGS"
	
	while true; do
		case "$1" in
			--debug)
				DEBUG=1
				;;
		    --delimiter|-d)
		        DELIMITER="$2" # Delimiter can be empty. Overrides parser value
				DELIMITER_IS_SET=1 
		        shift
		        ;;
			--file|-f)
				OUTPUT_FILE="$2"
				OUTPUT_FILE_IS_SET=1
				shift
				;;
		    --help|-h)
		        usage
		        [[ -z $TEST ]] && exit 0 || return 0
		        ;;
			--metadata-delimiter)
				PARM_METADATA_DELIMITER="$2"
				shift
				;;
			--no-header)
				NO_HEADER=1
				;;
		    --parseDNSDumpster)
				if [ -n "$PARSER" ]; then
					error 13 # Only one parser must be selected. '$PARSER' has already been selected
			    fi
				PARSER="DNSDumpster"
				;;
			--tab|-t)
				TAB="$2"
				shift
				;;
			--verbose|-v)
				VERBOSE=1
				;;
			--version|-V)
				echo "parseJSON v$VERSION"
		        [[ -z $TEST ]] && exit 0 || return 0
		        ;;
		    --)
		        shift
		    	if [ "$#" -eq 0 ]; then
					error 1 # Missing <fileToParse> argument
		    	fi
		    	if [ "$#" -eq 1 ]; then # FILE argument exists. OK
					FILE="$1"
			        break
		    	fi
				shift
		    	error 4 $@ # Unknown arguments: $@
		        ;;
		    *)
		        error 5 $@ # Error processing arguments: '$@'
		        ;;
		esac
		shift
	done

	if [[ "$DELIMITER" =~ ^0[xX] ]]; then
		local new=$(echo "${DELIMITER:2}" | xxd -r -p)
		if [ -z "$new" ]; then
			error 7 "$DELIMITER" # Empty or wrong delimiter ascii code: $DELIMITER"
		fi
		DELIMITER="$new"
	fi

	if [[ ! -f $FILE ]]; then
		error 8 "$FILE" # The file to be parsed does not exist: fileToParse
	fi

	if ! jq empty "$FILE" 2>/dev/null; then
		error 9 "$FILE" # The file to be parsed has not a valid JSON format: fileToParse
	fi

	if [[ -z $PARM_METADATA_DELIMITER ]]; then
		error 10 # Empty metadata delimiter
	fi

	if [[ "$PARM_METADATA_DELIMITER" =~ ^0[xX] ]]; then
		local new=$(echo "${PARM_METADATA_DELIMITER:2}" | xxd -r -p)
		if [ -z "$new" ]; then
			error 11 # Empty or wrong metadata delimiter ascii code: $PARM_METADATA_DELIMITER"
		fi
		METADATA_DELIMITER="$new"
	fi

	if [[ "${#METADATA_DELIMITER}" -ne 1 ]]; then
		error 12 # Metadata delimiter must be one caracter length: $PARM_METADATA_DELIMITER
	fi

	if [[ $OUTPUT_FILE_IS_SET -eq 1 && -z $OUTPUT_FILE ]]; then
		error 14 # Output file parameter cannot be empty
	fi

	if [[ -n $OUTPUT_FILE ]]; then
		while [[ -f ${OUTPUT_FILE}.cvs || -f ${OUTPUT_FILE}.log || -f ${OUTPUT_FILE}.txt.log ]]; do
			OUTPUT_FILE+=".new"
		done
	fi

	[[ $DEBUG -eq 1 ]] && VERBOSE=0
}

###############################################################################################################
################                
################                                    ITERATE FILE
################                   CREATE THE METADATA FROM THE THE FILE TO BE PARSED

iterate_file() {
	local type=$(jq -r type "$FILE")
	local lineNum=0
	local fathers=()

	if [[ $OUTPUT_FILE_IS_SET -eq 1 || -n $PARSER && $VERBOSE -eq 0 ]]; then
		exec 8>&1
		if [[ -z $PARSER || -n $PARSER && $VERBOSE -eq 1 ]]; then
			exec 7>"${OUTPUT_FILE}.log"
		else
			exec 7>/dev/null
		fi
		exec 1>&7
		FDS_RESTORED=0
	fi

    case "$type" in
    	object)
    		iterate_file_object
    		;;
    	array)
    		iterate_file_array
    		;;
    	*)
    		cat "$FILE"
    esac

	restore_fds	
	[[ -f ${OUTPUT_FILE}.log ]]	&& cat "${OUTPUT_FILE}.log" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' > "${OUTPUT_FILE}.txt.log"
}

iterate_file_object() {
	local keys=$(jq -c 'keys_unsorted[]' "$FILE")
	
	[[ -z "$keys" ]] && return # echo send \n, empty keys enter the while loop
	
	while IFS= read -r key; do
		local prop=$(normalizeQuotes $(jq -r ".$key" "$FILE"))
		local type=$(echo "$prop" | jq -r type)

		iterate 0 "$key" "$type" "$prop"
		
	done < <(echo "$keys")
}

iterate_file_array() {
	local keys=$(jq -c 'keys_unsorted[]' "$FILE")
	
	[[ -z "$keys" ]] && return # echo send \n, empty keys enter the while loop

	while IFS= read -r idx; do
		local value=$(normalizeQuotes $(jq ".[$idx]" "$FILE"))
		local type=$(echo "$value" | jq -r type)
		
		iterate 0 "$idx" "$type" "$value"

    done < <(echo "$keys")
}

iterate() {
	local levelMeta="$1"
	local tagMeta="$2"
	local typeMeta="$3"
	local valueMeta="$4"
	local del="$DELIMITER"
	local ctrl="$METADATA_DELIMITER"
	local tab=$(tab "$levelMeta")
	
	if [[ "$1$2$3$4" =~ "$ctrl" ]]; then
		error 52 # METADATA includes the delimiter '$PARM_METADATA_DELIMITER', use another (ex. --metadata-delimiter=\"0x1E\")"
	fi

	[ -z "$METADATA" ] && METADATA="$1$ctrl$2$ctrl$3$ctrl$4" || METADATA+=$'\n'"$1$ctrl$2$ctrl$3$ctrl$4"

    case "$type" in
    	object)
			parse_stack
    		iterate_object "$valueMeta" "$levelMeta"
    		;;
    	array)
			parse_stack
    		iterate_array "$valueMeta" "$levelMeta"
    		;;
    	*)
			parse_stack
    esac
}

iterate_object() {
	local object="$1"
	local level=$(( $2 + 1 ))
	local keys=$(echo "$object" | jq -c 'keys_unsorted[]')
	local tab=$(tab "$level")
	
	[[ -z "$keys" ]] && return # echo send \n, empty keys enter the while loop

	while IFS= read -r key; do
		local prop=$(normalizeQuotes $(echo "$object" | jq ".$key"))
		local type=$(echo "$prop" | jq -r type)
		
		iterate "$level" "$key" "$type" "$prop"

	done < <(echo "$keys")
}

iterate_array() {
	local array=$1
	local level=$(( $2 + 1 ))
	local keys=$(echo "$array" | jq -c 'keys_unsorted[]')
	local tab=$(tab "$level")

	[[ -z "$keys" ]] && return # echo send \n, empty keys enter the while loop

	while IFS= read -r idx; do
		local value=$(normalizeQuotes $(echo "$array" | jq ".[$idx]"))
		local type=$(echo "$value" | jq -r type)

		iterate "$level" "$idx" "$type" "$value"

    done < <(echo "$keys") 
}

normalizeQuotes() {
	echo "$@" | sed -e 's/^"\\"/"/' -e 's/\\""$/"/'
}

###############################################################################################################
################                
################                                    PARSE FILE
################

parse_file() {
	local fathers=()
	local lineNum=0
	local instruction=()
	local BLACKMETA="" # Take off
	local SEARCHMETA=""
	local defaultDelimiter=""
	local INITIAL_METADATA=""

	case "$PARSER" in
		DNSDumpster)
			parser="parserDNSDumpster"
			;;
	esac

	if [[ $DEBUG -eq 0 || $OUTPUT_FILE_IS_SET -eq 1 ]]; then
		exec 8>&1
		if [[ $DEBUG -eq 1 ]]; then
			exec 7>"${OUTPUT_FILE}.log"
		else
			exec 7>/dev/null
		fi
		exec 1>&7
		FDS_RESTORED=0
	fi

	data=$($parser)
	while IFS= read -r line; do
		parseInstruction "instruction" "$line"
		case "${instruction[0]}" in
			DELIMITER)
				parse_delimiter "${instruction[1]}"
				;;
			HEADER)
				parse_header "${instruction[1]}"
				;;
			remove|up|down)
				parse_metadata
				# echo;echo
				;;
			__*)
				declare -g "${instruction[0]}"=""
				SEARCHMETA+="$line"$'\n'
				PARSER_FIELDS+=("${instruction[0]}")
				;;
			*)
				erro 55 "$PARSER" "${instruction[0]}" # Unknown parser instrucion
				;;
		esac
	done <<< "$data"

	echo
	echo "######################################################################################################"
	echo "########"
	echo "########                                         PARSE $PARSER"
	echo "########"
	echo

	while IFS= read -r line; do
    	[[ -z "$line" ]] && continue
    	IFS="$METADATA_DELIMITER" read -r -a fields <<< "$line"

		local levelMeta="${fields[0]}"
		local tagMeta="${fields[1]}"
		local typeMeta="${fields[2]}"
		local valueMeta="${fields[3]}"

		parse_stack # "$levelMeta" "$tagMeta" "$typeMeta" "$valueMeta"

		parseMetadata
	done <<< "$METADATA"

	mountLine
		
	echo
	echo "######################################################################################################"
	echo "########"
	echo "########                                         INITIAL METADATA"
	echo "########"
	echo

	echo "$INITIAL_METADATA"

	echo
	echo "######################################################################################################"
	echo "########"
	echo "########                                         FINAL METADATA"
	echo "########"
	echo

	echo "$METADATA"

	restore_fds	
	[[ -f ${OUTPUT_FILE}.log ]]	&& cat "${OUTPUT_FILE}.log" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' > "${OUTPUT_FILE}.txt.log"

	if [[ -n $OUTPUT_FILE ]]; then
		if [[ $NO_HEADER -eq 0 ]] && ! echo "$OUTPUT_HEADER" > "$OUTPUT_FILE.csv"; then
			error 54 ".csv" # Cannot write on the output file
		fi
		if ! echo "$OUTPUT" >> "$OUTPUT_FILE.csv"; then
			error 54 ".csv" # Cannot write on the output file
		fi
	else
		[[ $NO_HEADER -eq 0 ]] && echo "$OUTPUT_HEADER"
		echo "$OUTPUT"
	fi
}

parse_delimiter() {
	defaultDelimiter=$(echo "$1" | sed 's/^"//; s/"$//;')

	[[ $DELIMITER_IS_SET -eq 0 ]] && DELIMITER="$defaultDelimiter"

	echo
	echo "######################################################################################################"
	echo "########"
	echo "########                                         DELIMITER"
	echo "########"
	echo

	echo -n "DELIMITER: '$DELIMITER'"
	[[ $DELIMITER != $1 ]] && echo ". Overwritten by command line --delimiter parameter" || echo
}

parse_header() {
	OUTPUT_HEADER=$(echo "$@" | sed 's/^"//; s/"$//;' | sed -e "s/$defaultDelimiter//g")

	if [[ -n $DELIMITER && "$OUTPUT_HEADER" == *"$DELIMITER"* ]]; then
		error 53 # The output header includes the delimiter, use another		
	fi

	OUTPUT_HEADER=$(echo "$@" | sed 's/^"//; s/"$//;' | sed -e "s/$defaultDelimiter/$DELIMITER/g")
	
	echo
	echo "######################################################################################################"
	echo "########"
	echo "########                                         OUTPUT HEADER"
	echo "########"
	echo

	echo -e "\nOUTPUT HEADER: '$OUTPUT_HEADER'"
}

parse_metadata() {
	local fathers=()
	local fatherFirstLine=""
	local blockFirstLine=""
	local blockLastLine=""
	local fatherLastLine=""
	local newData=""
	local tmpBlock=""

	echo
	echo "######################################################################################################"
	echo "########"
	echo "########                                         ${instruction[@]}"
	echo "########"
	echo

	INITIAL_METADATA="$METADATA"

	while IFS= read -r line; do
    	[[ -z "$line" ]] && continue
    	IFS="$METADATA_DELIMITER" read -r -a fields <<< "$line"

		local levelMeta="${fields[0]}"
		local tagMeta="${fields[1]}"
		local typeMeta="${fields[2]}"
		local valueMeta="${fields[3]}"

		if [[ -n $DELIMITER && "$tagMeta$valueMeta" == *"$DELIMITER"* ]]; then
			error 50 # The source data includes the delimiter, use another		
		fi

		parse_stack # "$levelMeta" "$tagMeta" "$typeMeta" "$valueMeta"
		parse_action "${instruction[@]}" # "${instruction[@]:1}"

	done <<< "$METADATA"

	METADATA="$newData"
}

parse_stack() {
	
	((lineNum++))

	local strLine="0000${lineNum}"
	local tab=$(tab "$levelMeta")
	local lastLevel=$(( ${#fathers[@]} - 1 ))
	local val=""

	[[ $typeMeta != "object" && $typeMeta != "array" ]] && val="$valueMeta"
	[[ ${#val} -gt 20 ]] && val="${val:0:20}..." 

	echo "${strLine:(-4)}" "$tab$tagMeta: $typeMeta $val"
	
	if [[ "$levelMeta" -gt "$lastLevel" ]]; then
		fathers+=("$tagMeta")
		(( lastLevel++ ))
	elif [[ "$levelMeta" -eq "$lastLevel" ]]; then
		fathers["$lastLevel"]="$tagMeta"
	else
		while [[ "$levelMeta" -lt "$lastLevel" ]]; do
			unset 'fathers[-1]'
			fathers=("${fathers[@]}")   
			(( lastLevel-- ))
		done
		fathers["$lastLevel"]="$tagMeta"
	fi	

	gray "${fathers[@]}"
}

parse_action() {
	local action="$1"
	shift
	local metadata=("$@")
	local i=-1
	local level="${#metadata[@]}"

	(( level-- ))

	for meta in "${metadata[@]}"; do
		(( i++ ))
		[[ $i -ge ${#fathers[@]} && -n $blockFirstLine && -z $blockLastLine ]] && blockFirstLine="" && echo "###############################################  blockLastLine  # $lineNum"
		[[ $i -ge ${#fathers[@]} && -n $fatherFirstLine && -z $fatherLastLine ]] && fatherFirstLine="" && echo "###############################################  fatherLastLine  # $lineNum"
		[[ $i -ge ${#fathers[@]} ]] && performAction && return
		[[ $i -eq $level && -z $fatherFirstLine ]] && fatherFirstLine="$lineNum" && echo "###############################################  fatherFirstLine  # $lineNum"
		[[ "$meta" == '"@"' && "${fathers[i]}" ]] && continue
		[[ "$meta" == '@' && "${fathers[i]}" =~ ^[0-9]+$ ]] && continue
		[[ "$meta" == "${fathers[i]}" ]] && continue
		
		[[ -n $blockFirstLine && -z $blockLastLine ]] && blockFirstLine="" && echo "###############################################  blockLastLine  # $lineNum"
		performAction
		return
	done

	[[ -z $blockFirstLine ]] && blockFirstLine="$lineNum" && echo "###############################################  blockFirstLine  # $lineNum"
	performAction
}

performAction() {
	case "$action" in
		remove)
			[[ -z $fatherFirstLine || -z $blockFirstLine ]] && newData+="$line"$'\n' && return
			;;
		up)
			[[ -n $fatherFirstLine && -z $blockFirstLine ]] && tmpBlock+="$line"$'\n' && return
			[[ -n $fatherFirstLine && -n $blockFirstLine ]] && newData+="$line"$'\n' && return
			[[ -z $fatherFirstLine && -z $blockFirstLine && -n $tmpBlock ]] && newData+="$tmpBlock" && tmpBlock=""
			newData+="$line"$'\n'
			;;
		down)
			[[ -n $fatherFirstLine && -z $blockFirstLine ]] && newData+="$line"$'\n' && return
			[[ -n $fatherFirstLine && -n $blockFirstLine ]] && tmpBlock+="$line"$'\n' && return
			[[ -z $fatherFirstLine && -z $blockFirstLine && -n $tmpBlock ]] && newData+="$tmpBlock" && tmpBlock=""
			newData+="$line"$'\n'
			;;
	esac
}

parseMetadata() {
	local levelMeta="${fields[0]}"
	local tagMeta="${fields[1]}"
	local typeMeta="${fields[2]}"
	local valueMeta="${fields[3]}"

	# TODO: I can pass a callback to parseMetaMount 
	parseMetaSearch 
}

###############################################################################################################
################                
################                                    PARSERS
################

parserDNSDumpster() {
cat <<'EOF'
DELIMITER   "|"
HEADER "Record type|Host|IP|asn_name|asn_range|ptr|Port|alt_n|apps|cn|redirect_location|miscelaneous 01"
remove      "total_a_recs"
down        "@" @ "ips"  @ "banners"
__RTYPE     "@"                                                key
__HOST      "@" @ "host"                                       value
__IP        "@" @ "ips"  @ "ip"                                value
__ASN_NAME  "@" @ "ips"  @ "asn_name"                          value
__ASN_RANGE "@" @ "ips"  @ "asn_range"                         value
__PTR       "@" @ "ips"  @ "ptr"                               value
__PORT      "@" @ "ips"  @ "banners"   "@"                     key
__ALT_N     "@" @ "ips"  @ "banners"   "@" "alt_n"             value
__APPS      "@" @ "ips"  @ "banners"   "@" "apps"              value
__CN        "@" @ "ips"  @ "banners"   "@" "cn"                value
__REDIR     "@" @ "ips"  @ "banners"   "@" "redirect_location" value
__MISC01    "txt"                                              value

EOF
}

###############################################################################################################
################                
################                                    MOVE BLOCK
################

parseInstruction() {
	# Create a local reference 'array' to the array name argument
    local -n array="$1"
	local blk="$2"
	local token=""
	local reading=0 # 0 no reading, 1 reading quotes, 2 reading without quotes

	array=()
	for (( i=0; i<${#blk}; i++ )); do
       	local char="${blk:$i:1}"
       	[[ "$char" == " " && "$reading" -eq 0 ]] && continue
       	[[ "$char" == " " && "$reading" -eq 2 ]] && array+=("$token") && token="" && reading=0 && continue
       	[[ "$char" == '"' && "$reading" -eq 0 ]] && token="$char" && reading=1 && continue
       	[[ "$char" == '"' && "$reading" -eq 1 ]] && token+="$char" && array+=("$token") && token="" && reading=0 && continue
       	[[ "$char" == '"' && "$reading" -eq 2 ]] && array+=("$token") && token="$char" && reading=1 && continue
       	[[ "$reading" -eq 0 ]] && token="$char" && reading=2 && continue
       	token+="$char"
	done

	[[ "$reading" -eq 2 ]] && array+=("$token") && reading=0
	[[ "$reading" -eq 1 && "$token" == '"' ]] && token="" && reading=0
	[[ "$reading" -eq 1 ]] && token+='"' && array+=("$token") && reading=0
	
	unset -n array
}

parseMetaSearch() {
	local -a metadata=()

	while IFS= read -r line; do
	    [[ -z "$line" ]] && continue
    	#IFS=" " read -r -a fields <<< "$line"
    	parseInstruction "metadata" "$line"
    	parseMetaSearch01
		metadata=()
	done <<< "$SEARCHMETA"
}

parseMetaSearch01() {

	fieldName="${metadata[0]}"
	valueType="${metadata[-1]}"
	unset 'metadata[0]'
	unset 'metadata[-1]'
	metadata=("${metadata[@]}")   
	local i=-1
	if [[ ${#metadata[@]} -ne ${#fathers[@]} ]]; then
		return
	fi
	set +o nounset
	for meta in "${metadata[@]}"; do
		(( i++ ))
		[[ "$meta" == '"@"' && "${fathers[i]}" == \"*\" ]] && continue
		[[ "$meta" == '@' && "${fathers[i]}" =~ ^[0-9]+$ ]] && continue
		[[ "$meta" == "${fathers[i]}" ]] && continue
		return
	done
	set -o nounset

	parseMetaMount
	echo "###############################################  finded  # $lineNum"
}

parseMetaMount(){
	local -n fld="$fieldName"
	local value=""

	if [[ "$valueType" == "key" ]]; then
		value="$tagMeta"
	elif [[ "$typeMeta" == "array" ]]; then
		value=$(echo "$valueMeta" | jq -r 'map("\"\(.)\"") | join(",")')
		value=$(echo "$value" | sed 's/"",""/","/g')
		value=$(echo "$value" | sed 's/^""/"/')
		value=$(echo "$value" | sed 's/""$/"/')
	elif [[ "$typeMeta" == "object" ]]; then
		value=$(echo "$valueMeta" | jq -r 'tostring')
	else
		value="$valueMeta"
	fi
	[[ "$value" == '""' ]] && value=""
	
	if [[ -n "$fld" && "$fld" != "$key" ]]; then
		mountLine
	fi
	fld="$value"
	local fieldNum=0
	resetFields "$fieldName"
	unset -n fld
}

mountLine() {
	# Create a local reference 'fields' to the global array of output variable names
	local -n fields="PARSER_FIELDS"
	local string=""

    for name in "${fields[@]}"; do
        # Create a local reference 'ref' to the global output variable '$name'
        local -n ref="$name"

        if [ -z "$string" ]; then
        	string+="$ref"
        else
        	string+="$DELIMITER$ref"
        fi

        unset -n ref # Clear reference
    done
    
    unset -n fields # Clear reference
    
	if [ -z "$string" ]; then return; fi
	
	if [ -z "$OUTPUT" ]; then
		OUTPUT="$string"
	else
		OUTPUT+=$'\n'"$string"
	fi
}

resetFields() {
	# Create a local reference 'fields' to the global array of output variable names
    local fieldName="${1:-__default__}"   # Si $1 no existe o está vacía → "default"
	local -n fields="PARSER_FIELDS"
	local index="$fieldNum"
	local i=0
	(( index++ ))
 
 	if [[ "$fieldName" != "__default__" ]]; then
 		index=1000000000 
 	fi
	for name in "${fields[@]}"; do
        # Create a local reference 'ref' to the global output variable '$name'
		local -n ref="$name"
        
        if [[ "$i" -ge "$index" ]]; then
        	ref=""
        fi

        (( i++ ))

	 	if [[ "$fieldName" != "__default__" && "$fieldName" == "$name" ]]; then
	 		index="$i"
	 	fi
        
        unset -n ref # Clear reference
    done
    unset -n fields # Clear reference
}


# $1:   Error number
# $2..: Error parameters
error() {
	local CODE=1 # Environment error
	if [[ $1 -ge 50 ]]; then	
		CODE=2
	fi

	case "$1" in
		"1")
			MSG="Missing <fileToParse> argument"
			;;
	### "2") 
	###     MSG="$2"
	###     ;;
		"3")
			MSG="$2 is not installed"
			;;
		"4")
			shift
			MSG="Unknown arguments: '$@'"
			;;
		"5")
			shift
			MSG="Error processing arguments: '$@'"
			;;
		# "6")
		# 	MSG="Empty delimiter"
		# 	;;
		"7")
			MSG="Empty or wrong delimiter ascii code: '$2'"
			;;
		"8")
			MSG=" The file to be parsed does not exist: '$2'"
			;;
		"9")
			MSG="The file to be parsed has not a valid JSON format: '$2'"
			;;
		"10")
			MSG="Empty metadata delimiter"
			;;
		"11")
			MSG="Empty or wrong metadata delimiter ascii code: '$PARM_METADATA_DELIMITER'"
			;;
		"12")
			MSG="Metadata delimiter must be one caracter length: '$PARM_METADATA_DELIMITER'"
			;;
		"13")
			MSG="Only one parser must be selected. '$PARSER' has already been selected"
			;;
		"14")
			MSG="Output file parameter cannot be empty"
			;;


		"50")
			MSG="The source data includes the delimiter '$DELIMITER', use another (ex. --delimiter=\"\$DELIMITER\$DELIMITER\")"
			;;
		"51")
			MSG="Unknown parser instruction: '$2'"
			;;
		"52")
			local parm="$PARM_METADATA_DELIMITER"
			[[  $parm == "0x1F" || $parm == "0X1F" ]] && $parm="0x1E" || $parm="0x1F"
			MSG="METADATA includes the delimiter '$PARM_METADATA_DELIMITER', use another (ex. --metadata-delimiter=\"$parm\")"
			;;
		"53")
			MSG="The output header includes the delimiter '$DELIMITER', use another (ex. --delimiter=\"\$DELIMITER\$DELIMITER\")"
			;;
		"54")
			MSG="Cannot write to output file: '$OUTPUT_FILE$2'"
			;;
		"55")
			MSG="Unknown parser instruction. Parser: '$2', instruction: '$3'"
			;;
		*)
			MSG="$2"
	esac

    echo -e "\a❌ $MSG" >2

	[[ -n $TEST ]] && return $CODE

	exit $CODE
}

tab() {
	local level="$1"
	local tab=""
	
	for ((i=0; i<level; i++)); do
	    tab+="$TAB"
	done
	
	echo "$tab"
}

gray() {	
	echo -e "\e[38;5;243m$@\e[0m"
}

red() {
	echo -e "\e[1;31m$@\e[0m"
}

yellow() {
	echo -e "\e[1;33m$@\e[0m"
}

cleanup() {
    close_tmp
    restore_fds
}

close_tmp() {
    [[ $TMP_CLOSED -eq 1 ]] && return

    rm -f -- "$tmp"
    TMP_CLOSED=1
}

restore_fds() {
    [[ $FDS_RESTORED -eq 1 ]] && return

    exec 1>&8
    exec 7>&-
    exec 8>&-

    FDS_RESTORED=1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
