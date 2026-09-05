#!/usr/bin/env bash

set -o nounset
shopt -s lastpipe

# Definir la limpieza al salir (EXIT) o recibir señales de interrupción (INT, TERM)
trap 'rm -f "$tmp"' EXIT INT TERM
tmp=$(mktemp)

usage() {
    cat <<EOF
Usage: $0 [options] <fileToParse>

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
  $0 -d "||" --parseDNSDumpster -v fileToParse.json 
      # Delimiter "||", Instructions for parse a DNSDumpster JSON file, verbose, file to parse
  $0 --delimiter="||" fileToParse.csv -t ".." --metadata-delimiter="1E"
      # Delimiter "||", file to parse, string for tabulated output "..", metadata delimiter 0x1E
EOF
}

DEBUG=0
DELIMITER_IS_SET=0; # Delimiter can be empty. Overrides parser value
DELIMITER=""
DOTOOL="xdotool"
FILE=""
METADATA=""
METADATA_DELIMITER=$'\x1F'
OUTPUT=""
OUTPUT_HEADER=""
PARSER=""
PARSER_FIELDS=()
PARSER_KEY=""
PARSER_LEVEL=0
PARSER_STOP=0 ## ELIMINAR CUANDO DEJE DE USARLA
TAB="  "
TEST="";
VERBOSE=0

ARGS=$(LC_ALL=C getopt \
	--long debug,delimiter:,help,metadata-delimiter:,parseDNSDumpster,tab:,verbose \
	-o d:ht:v \
	-n "$0" \
	-- "$@" \
	2>&1
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
		error 2 "$(cat $tmp | sed '1!s/^/❌ /')" # Options error
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
		    --help|-h)
		        usage
		        [[ -z $TEST ]] && exit 0 || return 0
		        ;;
			--metadata-delimiter)
				METADATA_DELIMITER="$2"
				shift
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

	# if [[ -z $DELIMITER ]]; then
	# 	error 6 # Empty delimiter
	# fi

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

	if [[ -z $METADATA_DELIMITER ]]; then
		error 10 # Empty metadata delimiter
	fi

	if [[ "$METADATA_DELIMITER" =~ ^0[xX] ]]; then
		local new=$(echo "${METADATA_DELIMITER:2}" | xxd -r -p)
		if [ -z "$new" ]; then
			error 11 "$METADATA_DELIMITER" # Empty or wrong metadata delimiter ascii code: $METADATA_DELIMITER"
		fi
		METADATA_DELIMITER="$new"
	fi

	if [[ "${#METADATA_DELIMITER}" -ne 1 ]]; then
		error 12 # Metadata delimiter must be one caracter length: $METADATA_DELIMITER
	fi
}

###############################################################################################################
################                
################                                    ITERATE FILE
################                   CREATE THE METADATA FROM THE THE FILE TO BE PARSED

iterate_file() {
	local type=$(jq -r type "$FILE")

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
	local level="$1"
	local tag="$2"
	local type="$3"
	local value="$4"
	local del="$DELIMITER"
	local ctrl="$METADATA_DELIMITER"
	local tab=$(tab "$level")
	
	if [[ "$1$2$3$4" =~ "$ctrl" ]]; then
		echo -e "\a❌ METADATA includes the delimiter '$ctrl', use another (ex. --metadata-delimiter=\"1E\")"
	fi

	[ -z "$METADATA" ] && METADATA="$1$ctrl$2$ctrl$3$ctrl$4" || METADATA+=$'\n'"$1$ctrl$2$ctrl$3$ctrl$4"

    case "$type" in
    	object)
		    print "${tab}$tag:" "$type"
    		iterate_object "$value" "$level"
    		;;
    	array)
		    print "${tab}$tag:" "$type"
    		iterate_array "$value" "$level"
    		;;
    	*)
		    print "${tab}$tag:" "$value"
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

print() {
    if [[ "$VERBOSE" -eq 1 || -z "$PARSER" ]]; then echo "$1 $2"; fi
}

###############################################################################################################
################                
################                                    PARSE FILE
################

parse_file() {
	local fathers=()
#	local lastLevel=-1
	local lineNum=0
	local instruction=()
	local BLACKMETA="" # Take off
	local SEARCHMETA=""

	case "$PARSER" in
		DNSDumpster)
			parser_new="parserDNSDumpster"
			parser="parserDNSDumpster22"
			parser_ini="parserDNSDumpster_ini"
			;;
	esac
	
	data=$($parser_new)
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
				parse_new
				echo;echo
				;;
			__*)
				declare -g "${instruction[0]}"=""
				SEARCHMETA+="$line"$'\n'
				PARSER_FIELDS+=("${instruction[0]}")
				;;
			*)
				sleep 0
				# parse_new
				;;
		esac
	done <<< "$data"
	while IFS= read -r line; do
    	[[ -z "$line" ]] && continue
    	IFS="$METADATA_DELIMITER" read -r -a fields <<< "$line"

		local levelMeta="${fields[0]}"
		local tagMeta="${fields[1]}"
		local typeMeta="${fields[2]}"
		local valueMeta="${fields[3]}"

		if [[ -n $DELIMITER && "$levelMeta$tagMeta$typeMeta$valueMeta" == *"$DELIMITER"* ]]; then
			error 50 # The source data includes the delimiter, use another		
		fi

		parseMetaFathers "$levelMeta" "$tagMeta" "$typeMeta" "$valueMeta"
		parseMetadata
	done <<< "$METADATA"
	
	mountLine
		
	echo "$OUTPUT_HEADER"
	echo "$OUTPUT"
}

parse_delimiter() {
	[[ $DELIMITER_IS_SET -eq 0 ]] && DELIMITER="$1"
}

parse_header() {
	OUTPUT_HEADER=$(echo "$@" | sed -e "s/|/$DELIMITER/g")
}

parse_new() {
	local fathers=()
	local fatherFirstLine=""
	local blockFirstLine=""
	local blockLastLine=""
	local fatherLastLine=""
	local newData=""
	local tmpBlock=""

	while IFS= read -r line; do
    	[[ -z "$line" ]] && continue
    	IFS="$METADATA_DELIMITER" read -r -a fields <<< "$line"

		local levelMeta="${fields[0]}"
		local tagMeta="${fields[1]}"
		local typeMeta="${fields[2]}"
		local valueMeta="${fields[3]}"

		if [[ -n $DELIMITER && "$levelMeta$tagMeta$typeMeta$valueMeta" == *"$DELIMITER"* ]]; then
			error 50 # The source data includes the delimiter, use another		
		fi

		parseMetaFathers "$levelMeta" "$tagMeta" "$typeMeta" "$valueMeta"
		findLines "${instruction[@]}" # "${instruction[@]:1}"

	done <<< "$METADATA"

	METADATA="$newData"
}

parseMetaFathers() {
	
	((lineNum++))

	local strLine="0000${lineNum}"
	local tab=$(tab "$levelMeta")
	local lastLevel=$(( ${#fathers[@]} - 1 ))

	# [[ "$VERBOSE" -eq 1 ]] && 
	echo "${strLine:(-4)}" "$tab$tagMeta: $typeMeta"
	
	# [[ ${#fathers[@]} -gt 0 ]] && lastLevel=$(( ${#fathers[@]} - 1 )) || lastLevel=-1

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

	#	[[ "$VERBOSE" -eq 1 ]] && gray "${fathers[@]}"
	gray "${fathers[@]}"
}

findLines() {
	local action="$1"
	shift
	local metadata=("$@")
	local i=-1
	local level="${#metadata[@]}"

	(( level-- ))

	for meta in "${metadata[@]}"; do
		(( i++ ))
		[[ $i -ge ${#fathers[@]} && -n $blockFirstLine && -z $blockLastLine ]] && echo "############################################# blockLastLine  # $lineNum" && blockFirstLine=""
		[[ $i -ge ${#fathers[@]} && -n $fatherFirstLine && -z $fatherLastLine ]] && echo "############################################# fatherLastLine  # $lineNum" && fatherFirstLine=""
		[[ $i -ge ${#fathers[@]} ]] && performAction && return
		[[ $i -eq $level && -z $fatherFirstLine ]] && echo "############################################# fatherFirstLine  # $lineNum" && fatherFirstLine="$lineNum"
		[[ "$meta" == '"@"' && "${fathers[i]}" ]] && continue
		[[ "$meta" == '@' && "${fathers[i]}" =~ ^[0-9]+$ ]] && continue
		[[ "$meta" == "${fathers[i]}" ]] && continue
		
		[[ -n $blockFirstLine && -z $blockLastLine ]] && echo "############################################# blockLastLine  # $lineNum" && blockFirstLine=""
		performAction
		return
	done

	[[ -z $blockFirstLine ]] && echo "############################################# blockFirstLine  # $lineNum" && blockFirstLine="$lineNum"
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

parserDNSDumpster_ini() {
	# Create a local reference 'fields' to the global array of output variable names
	#local -n fields="PARSER_FIELDS"
	
	#fields+=(__RTYPE __HOST __IP __ASN_NAME __ASN_RANGE __PTR __PORT __ALT_N __APPS __CN __REDIR __MISC01)
	[[ $DELIMITER_IS_SET -eq 0 ]] && DELIMITER="|"
	PARSER_FIELDS=(__RTYPE __HOST __IP __ASN_NAME __ASN_RANGE __PTR __PORT __ALT_N __APPS __CN __REDIR __MISC01)
	OUTPUT_HEADER="Record type|Host|IP|asn_name|asn_range|ptr|Port|alt_n|apps|cn|redirect_location|miscelaneous 01"
	OUTPUT_HEADER=$(echo "$OUTPUT_HEADER" | sed -e "s/|/$DELIMITER/g")
	
	#for name in "${fields[@]}"; do
	for name  in "${PARSER_FIELDS[@]}"; do
    	declare -g "$name"=""
	done

    #unset -n fields # Clear reference

	#blk=' "a" 0 "host"up'
	blk='   "@" @ "ips" @ "banners"down'
	moveBlock "$blk"
}

parserDNSDumpster22() {
	local levelMeta="${fields[0]}"
	local tagMeta="${fields[1]}"
	local typeMeta="${fields[2]}"
	local valueMeta="${fields[3]}"
	local SEARCHMETA=$(cat <<'EOF'
        __RTYPE     "@"                          key
        __HOST      "@" @ "host"                 value
        __IP        "@" @ "ips" @ "ip"           value
        __ASN_NAME  "@" @ "ips" @ "asn_name"     value
        __ASN_RANGE "@" @ "ips" @ "asn_range"    value
        __PTR       "@" @ "ips" @ "ptr"          value
        __PORT      "@" @ "ips" @ "banners" "@"  key
        __ALT_N     "@" @ "ips" @ "banners" "@" "alt_n"  value
        __APPS      "@" @ "ips" @ "banners" "@" "apps"   value
        __CN        "@" @ "ips" @ "banners" "@" "cn"     value
        __REDIR     "@" @ "ips" @ "banners" "@" "redirect_location"   value
        __MISC01    "txt"                        value 
EOF
)
	local BLACKMETA=$(cat <<'EOF'
        "total_a_recs"
EOF
)
	# TODO: I can pass a callback to parseMetaMount 
	parseMetaSearch 
}

###############################################################################################################
################                
################                                    MOVE BLOCK
################

moveBlock() {
	local blockMetadata="$1"
	local metadata=()
	local direction=""
	
	parseInstruction "metadata" "$blockMetadata"

	[[ "$VERBOSE" -eq 1 ]] && echo "MOVE METADATA: ${metadata[@]}"
	
	direction=${metadata[-1]}
	unset 'metadata[-1]'
	 
	if [[ $direction == "up" ]]; then
		upBlock
	elif [[ $direction == "down" ]]; then
		downBlock
	else
		echo -e "\a❌ expected 'up'|'down', but got: '$direction'"
	fi
}

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

upBlock() {
	echo -e "\a❌ TODO: upBlock"
}

downBlock() {
	local fathers=()
	local lastLevel=-1
	local lineNum=0
	local blockFirstLine=-1
	local blockLastLine=-1
	local blockMoveLine=1
	local newMetadata=""

	del="$METADATA_DELIMITER"
		
	while IFS= read -r line; do
	    IFS="$del" read -r -a fields <<< "$line"
	
		local levelMeta="${fields[0]}"
		local tagMeta="${fields[1]}"
		local typeMeta="${fields[2]}"
		
		fathers "$levelMeta" "$tagMeta" "$typeMeta" # "$metadata" 
		
	done <<< "$METADATA"

	lineNum=0
	
	while IFS= read -r line; do
		(( lineNum++ ))
		if [[ "$lineNum" -lt "$blockMoveLine" ]]; then
			continue
		else
			[ -z "$newMetadata" ] && newMetadata="$line" || newMetadata+=$'\n'"$line"
		fi
	done <<< "$METADATA"
	
	METADATA="$newMetadata"
}

fathers() {
	local levelMeta="$1"
	local tagMeta="$2"
	local typeMeta="$3"
	
	((lineNum++))

	local strLine="0000${lineNum}"
	local tab=$(tab "$levelMeta")

	[[ "$VERBOSE" -eq 1 ]] && echo "${strLine:(-4)}" "$tab$tagMeta: $typeMeta"
	
	[[ ${#fathers[@]} -gt 0 ]] && lastLevel=$(( ${#fathers[@]} - 1 )) || lastLevel=-1

	if [[ "$typeMeta" == "object" || "$typeMeta" == "array" ]]; then
		if [[ "$levelMeta" -gt "$lastLevel" ]]; then
			fathers+=("$tagMeta")
			(( lastLevel++ ))
			firstBlockLine
		fi
	fi

	while [[ "$levelMeta" -lt "$lastLevel" ]]; do
		unset 'fathers[-1]'
		fathers=("${fathers[@]}")   
		(( lastLevel-- ))
		lastBlockLine
	done
	
	if [[ "$typeMeta" == "object" || "$typeMeta" == "array" ]]; then
		fathers["$lastLevel"]="$tagMeta"
		[[ "$VERBOSE" -eq 1 ]] && gray "${fathers[@]}"
	fi
	moveDown
}

firstBlockLine() {
	local level="${#metadata[@]}"
	(( level-- ))

	[[ "$blockFirstLine" -ne -1 || "$lastLevel" -ne "$level" ]] && return

	local i=-1

	for meta in "${metadata[@]}"; do
		(( i++ ))
		[[ "$meta" == '"@"' && "${fathers[i]}" ]] && continue # i++ only here, the first condition
		[[ "$meta" == '@' && "${fathers[i]}" =~ ^[0-9]+$ ]] && continue
		[[ "$meta" == "${fathers[i]}" ]] && continue
		return
	done

	blockFirstLine="$lineNum"
	[[ "$VERBOSE" -eq 1 ]] && echo "############################################# First  # $lineNum"
}

lastBlockLine() {
	local level="${#metadata[@]}"
	(( level-- ))
	
	[[ "$blockFirstLine" -eq -1 || "$blockLastLine" -ne -1 || "$lastLevel" -gt "$level" ]] && return
	[[ "$VERBOSE" -eq 1 ]] && echo "################################################# Last  # $lineNum"
	blockLastLine="$lineNum"
}

moveDown() {
	local block=""
	[[ "$blockLastLine" -eq -1 ]] && return
	local i=-1

	for meta in "${metadata[@]}"; do
		(( i++ ))
		set +o nounset
		[[ "$meta" == '"@"' && "${fathers[i]}" == \"*\" ]] && continue
		[[ "$meta" == '@' && "${fathers[i]}" =~ ^[0-9]+$ ]] && continue
		[[ "$meta" == "${fathers[i]}" ]] && continue
		set -o nounset
		[[ "$VERBOSE" -eq 1 ]] && echo "############################################################ moveDown  #  $lineNum"
		
		if [[ "$blockLastLine" -eq "$lineNum" ]]; then
			# RESET
			blockFirstLine=-1
			blockLastLine=-1
			blockMoveLine="$lineNum"
			return
		fi
		
		local ln=0
		while IFS= read -r line; do
			(( ln++ ))
			if [[ "$ln" -lt "$blockMoveLine" ]]; then
				continue
			elif [[ "$ln" -lt "$blockFirstLine" ]]; then
				[ -z "$newMetadata" ] && newMetadata="$line" || newMetadata+=$'\n'"$line"
			elif [[ "$ln" -lt "$blockLastLine" ]]; then
				[ -z "$block" ] && block="$line" || block+=$'\n'"$line"
			elif [[ "$ln" -lt "$lineNum" ]]; then
				[ -z "$newMetadata" ] && newMetadata="$line" || newMetadata+=$'\n'"$line"
			else
				[ -z "$newMetadata" ] && newMetadata="$block" || newMetadata+=$'\n'"$block"
				# RESET
				blockFirstLine=-1
				blockLastLine=-1
				blockMoveLine="$lineNum"
				break
			fi
		done <<< "$METADATA"
		return
	done
}

parseMetaSearch() {
	local metaBlack=0
	local -a metadata=()

	while IFS= read -r line; do
	    [[ -z "$line" ]] && continue
    	#IFS=" " read -r -a fields <<< "$line"
    	parseInstruction "metadata" "$line"
    	parseMetaBlack
		metadata=()
	done <<< "$BLACKMETA"
	[[ "$metaBlack" -eq 1 ]] && return
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
echo "############################################# finded ${typeMeta} # $lineNum"
	[[ "$VERBOSE" -eq 1 ]] && echo "############################################# finded  # $lineNum"
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
	
echo "*********** fld: $fld"
echo "*********** valueType: $valueType"	
echo "*********** value: $value"
echo "*********** key: $key"
	if [[ -n "$fld" && "$fld" != "$key" ]]; then
		mountLine
	fi
	fld="$value"
	local fieldNum=0
	resetFields "$fieldName"
	unset -n fld
}

parseMetaBlack() {
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
	
	metaBlack=1
	
echo "############################################# finded BLACK ${typeMeta} # $lineNum"
	[[ "$VERBOSE" -eq 1 ]] && echo "############################################# finded BLACK # $lineNum"
}

parseLevel-Key() {
	! [[ "$level" -eq $1 ]] && return
	
	local -n fields="PARSER_FIELDS"
	fieldName="${fields[$fieldNum]}"
	local -n fld="$fieldName"
	
	if [[ -n "$fld" && "$fld" != "$key" ]]; then
		mountLine
	fi
	fld="$key"
	resetFields
}

parseLevelKey-Value() {
	! [[ "$level" -eq $1 && "$key" == "$2" ]] && return
	
	local -n fields="PARSER_FIELDS"
	fieldName="${fields[$fieldNum]}"
	local -n fld="$fieldName"
	
	if [[ -n "$fld" && "$fld" != "$value" ]]; then
		mountLine
	fi
	fld="$value"
	resetFields
}

mountLine() {
	# Create a local reference 'fields' to the global array of output variable names
	local -n fields="PARSER_FIELDS"
	local string=""
echo "************ fields: ${fields[@]}"	
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
			MSG="Empty or wrong metadata delimiter ascii code: '$2'"
			;;
		"12")
			MSG="Metadata delimiter must be one caracter length: '$METADATA_DELIMITER'"
			;;
		"13")
			MSG="Only one parser must be selected. '$PARSER' has already been selected"
			;;


		"20")
			MSG="The folder name cannot be empty"
			;;
		"21")
			MSG="The folder name can only contain letters, numbers, '_' and '-': '$FOLDER'"
			;;
		"22")
			MSG="Folder name should not start with '-': '$FOLDER'"
			;;
		"23")
			MSG="Invalid log file name: '$2'"
			;;
		"24")
			MSG="Can not actualize the environment: '$2'"
			;;
		"50")
			MSG="The source data includes the delimiter '$2', use another (ex. --delimiter=\"\$2\$2\")"
			;;
		"51")
			MSG="Unknown parser instruction: '$2'"
			;;
		*)
			MSG="$2"
	esac

    echo -e "\a❌ $MSG"

	#[[ $LOGEXISTS -eq 1 ]] && echo -e "\a❌ $MSG" >> "$LOG"

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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
