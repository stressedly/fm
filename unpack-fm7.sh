#!/usr/bin/env bash
# unpack-fm7.sh — turn fm7 JSON files back into the photos/videos on disk.
#
# Handles every JSON format fm7.html reads or writes:
#   * full exports   {"version":2,"images":[{id,data,tags,rating,packId,...}],"packs":[...]}
#   * pack files     {"packVersion":1|2,"name":...,"images":[{data,tags}] | ["data:..."]}
#   * legacy packs   {"sampleImages":[...]}
#   * ui.json.js     window.__UI_ASSETS__ = {"sampleImages":[...]};
#
# Each media item is a base64 data: URL; it is decoded into a file whose
# extension comes from its MIME type. Full exports are split into one
# folder per pack ("unpacked" for loose images). A manifest.tsv next to the
# files records tags and ratings.
#
# Usage: unpack-fm7.sh [-o OUTDIR] FILE.json [FILE.json ...]
#   -o OUTDIR   where to write (default: ./fm7-unpacked)
#               each input gets its own subfolder named after the file

set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

outroot="./fm7-unpacked"
while getopts ":o:h" opt; do
    case $opt in
        o) outroot=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 >&2 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -ge 1 ]] || usage 1 >&2

for tool in jq awk base64; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' is required" >&2; exit 1; }
done

# jq program: emits one tab-separated line per item:
#   F <relpath> <base64>                         -> a file to write
#   M <relpath> <tags> <rating> <battles> <wins> <losses>  -> manifest row
#   S <index> <reason>                           -> skipped item
read -r -d '' JQ_PROG <<'JQ' || true
def slug: tostring | gsub("[^A-Za-z0-9._-]+"; "-") | gsub("^[-.]+|-+$"; "")
          | if . == "" then "untitled" else .[0:80] end;
def ext: ({"image/jpeg":"jpg","image/jpg":"jpg","image/pjpeg":"jpg",
           "image/svg+xml":"svg","image/x-icon":"ico","image/vnd.microsoft.icon":"ico",
           "video/quicktime":"mov","video/x-matroska":"mkv","video/x-msvideo":"avi",
           "video/mpeg":"mpg","video/3gpp":"3gp"}[.])
         // ((split("/")[1] // "bin") | gsub("[^A-Za-z0-9]"; "") | if . == "" then "bin" else . end);
def pad: tostring | ("00000" + .)[-5:];
def tsv: tostring | gsub("[\t\n\r]"; " ");

. as $root
| ( if has("packVersion") then
        [ (.images // [])[] | {dir: ($root.name // "pack" | slug), img: .} ]
    elif has("sampleImages") then
        [ .sampleImages[] | {dir: "samples", img: .} ]
    elif has("images") then
        ( [ ($root.packs // [])[] | select(.packId != null)
            | {key: (.packId | tostring), value: ((.name // .packId) | slug)} ] | from_entries ) as $pm
        | [ .images[]
            | {dir: (if (.packId? // null) == null then "unpacked"
                     else ($pm[.packId | tostring] // (.packId | slug)) end),
               img: .} ]
    else error("unrecognised fm7 JSON format (no images/packVersion/sampleImages)") end )
| to_entries[]
| .key as $i
| .value.dir as $dir
| (.value.img | if type == "string" then {data: .} else . end) as $o
| ($o.data // "" | if type == "string" then . else "" end) as $u
| ($u | index(",")) as $comma
| if ($u | startswith("data:")) and $comma != null and ($u[0:$comma] | endswith(";base64")) then
      ($u[5:$comma] | split(";")[0] | ascii_downcase) as $mime
    | "\($dir)/\($i + 1 | pad).\($mime | ext)" as $path
    | "F\t\($path)\t\($u[$comma + 1:])",
      "M\t\($path)\t\(($o.tags // []) | map(tsv) | join(","))\t\($o.rating // "" | tsv)\t\($o.battles // "" | tsv)\t\($o.wins // "" | tsv)\t\($o.losses // "" | tsv)"
  else
      "S\t\($i + 1)\t\(if $u == "" then "no data" else "not a base64 data: URL (" + ($u[0:40] | tsv) + ")" end)"
  end
JQ

mkdir -p -- "$outroot"
outroot=$(cd -- "$outroot" && pwd)
status=0

for src in "$@"; do
    if [[ ! -f $src ]]; then
        echo "warning: '$src' not found, skipping" >&2; status=1; continue
    fi
    src=$(cd -- "$(dirname -- "$src")" && pwd)/$(basename -- "$src")  # absolute, since we cd below
    name=$(basename -- "$src"); name=${name%.js}; name=${name%.json}
    dest="$outroot/$name"
    mkdir -p -- "$dest"
    echo "==> $src -> $dest"

    # ui.json.js wraps the JSON in "window.__UI_ASSETS__ = ...;" — strip that.
    if [[ $src == *.js ]]; then
        reader=(sed -e '1s/^[^{]*//' -e '$s/;[[:space:]]*$//' -- "$src")
    else
        reader=(cat -- "$src")
    fi

    # awk does the writing: it copes with multi-megabyte lines, which bash's
    # `read` does not. Paths are slugged by jq, so they are shell-safe, and
    # awk runs inside $dest so it only ever sees relative paths.
    if ! ( cd -- "$dest" && "${reader[@]}" | jq -r "$JQ_PROG" | awk -F'\t' '
        BEGIN { n = 0; skipped = 0; failed = 0
                print "file\ttags\trating\tbattles\twins\tlosses" > "manifest.tsv" }
        $1 == "F" {
            d = $2; sub(/\/[^\/]*$/, "", d)
            if (!(d in made)) { system("mkdir -p \"" d "\""); made[d] = 1 }
            cmd = "base64 -d > \"" $2 "\""
            printf "%s", $3 | cmd
            if (close(cmd) != 0) { print "  failed to decode " $2 > "/dev/stderr"; failed++ }
            else n++
            next
        }
        $1 == "M" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 >> "manifest.tsv"; next }
        $1 == "S" { print "  skipped item " $2 ": " $3 > "/dev/stderr"; skipped++; next }
        END {
            printf "  %d file(s) written", n
            if (skipped) printf ", %d skipped", skipped
            if (failed)  printf ", %d failed", failed
            print ""
            exit (failed ? 1 : 0)
        }' ); then
        echo "  error while unpacking '$src'" >&2
        status=1
    fi
done

exit "$status"
