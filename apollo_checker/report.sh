#!/bin/bash

set -u # stop if a variable is not initialized
set -e # stop in case of error


wa_url=${1%/} # Url of the Apollo server (trim trailing slash)
wa_ext_url=${2%/} # Url of the Apollo server (trim trailing slash)
genome_dir=$3 # Path to the directory containing genome fasta file(s). Files must be named "Common_Name.fa", with the apollo common name.
output_dir=$4 # Directory where generated fils should be placed

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Automatic config
tmp_dir=`mktemp -d`
raw_apollo_gff="raw_apollo.gff"
raw_apollo_gff_gz="$raw_apollo_gff.gz"
cur_date=`date +%F_%X`

OPTS=""
if [[ $ANNOTATION_GROUPS == "1" ]]
then
    OPTS="-g /data/annotation_groups.tsv"
fi

if [[ $SPLIT_USERS == "1" ]]
then
    OPTS="$OPTS --split-users"
fi

# Get organisms

res=`curl --header "Content-Type:application/json" -d"{'username': '$APOLLO_USER', 'password': '$APOLLO_PASS'}" "$wa_url/organism/findAllOrganisms"`
echo -n "" > "$output_dir/full_report.json"

echo "$res" | jq -c '.[]' | while read -r i; do
    tmp_dir=`mktemp -d`
    cd "$tmp_dir"
    orga=`echo $i | jq ".commonName"`
    orga_remote=`sed -e 's/^"//' -e 's/"$//' <<<"${orga}"` # The name of the organism in apollo
    orga=`sed -e 's/^"//' -e 's/"$//' <<<"${orga// /_}"` # The name of the organism here (safer)
    res=`curl --header "Content-Type:application/json" -d "{'username': '$APOLLO_USER', 'password': '$APOLLO_PASS', 'type':'GFF3', 'exportAllSequences':'true', 'chadoExportType':'', 'seqType':'genomic', 'exportGff3Fasta':'false', 'output':'file', 'format':'gzip', 'organism':'$orga_remote', 'sequences':[]}" "$wa_url/IOService/write"`
    uuid=`echo $res | sed "s/.*uuid\"\:\"\([-a-z0-9]\+\)\".*/\1/"`
    orga_output_dir="$output_dir/$orga"
# Get genome file
    if [[ -n "$APOLLO_MOUNTPOINT" ]]; then
        APOLLO_MOUNTPOINT=${APOLLO_MOUNTPOINT%/}
        internal_path=`echo $i | jq ".directory" | sed 's/\/[^\/]*//' | sed 's/"//g'`
        orga="genome"
        genome_dir="$APOLLO_MOUNTPOINT""$internal_path/seq/"
        genome_file=`find "$genome_dir" -iname "$orga.fasta" -type f`
    else
        genome_file=`find "$genome_dir" -iname "$orga.fa" -o -iname "$orga.fasta" -type f`
    fi
    file_numbers=`wc -l <<< "$genome_file"`
    if [[ -z "$genome_file" ]]; then
        echo "Error : no $orga.fa or $orga.fasta found in $genome_dir"
        exit 1
    fi
    if [[ "$file_numbers" != "1" ]]; then
        echo "Error : could not find an unique genome file for organism $orga_remote : $file_numbers appropriate files found"
        echo "$genome_file"
        exit 1
    fi

    echo "Generating report for '$orga_remote' in $orga_output_dir using genome $genome_file"

    mkdir -p "$orga_output_dir"

# Download the gz file
    curl --data-urlencode data="{'username': '$APOLLO_USER', 'password': '$APOLLO_PASS'}" -o "$raw_apollo_gff_gz" "$wa_url/IOService/download?uuid=$uuid&format=gzip&seqType=genomic&exportType=GFF3"

# Unzip the annotation file

    gunzip "$raw_apollo_gff_gz"

# Launch the script to check gene models
    python $SCRIPT_DIR/apollo_checker.py \
        -a "$wa_ext_url" \
        -o "$orga_output_dir/valid.gff" \
        -i "$orga_output_dir/invalid.gff" \
        -d "$orga_output_dir/deleted.tsv" \
        --report_admin_json "$orga_output_dir/report.json" \
        $OPTS \
        "$raw_apollo_gff" \
        "$genome_file"

    gffread "$orga_output_dir/valid.gff" -F -g "$genome_file" \
        -w "$orga_output_dir/valid_transcripts.fa" \
        -x "$orga_output_dir/valid_cds.fa" \
        -y "$orga_output_dir/valid_proteins.fa"

    echo -n "\"$orga\""":" >> "$output_dir/full_report.json"
    cat "$orga_output_dir/report.json" >> "$output_dir/full_report.json"
    echo "" >> "$output_dir/full_report.json"
    cp "$raw_apollo_gff" "$orga_output_dir/$raw_apollo_gff"

    # Remove temp files
    rm -rf $tmp_dir
done

sed -i '1s/^/{/;$!s/$/,/;$s/$/}/' "$output_dir/full_report.json"
