#!/usr/bin/env bash
defaultWallbashCurve="32 50\n42 46\n49 40\n56 39\n64 38\n76 37\n90 33\n94 29\n100 20"
balancedWallbashCurve="24 62\n34 56\n44 48\n56 44\n68 50\n78 54\n88 48\n94 36\n100 26"
colorProfile="default"
wallbashCurve="$defaultWallbashCurve"
sortMode="auto"
wallbashColors=4
wallbashCandidateColors=8
wallbashMinHueDistance=0.08
while [ $# -gt 0 ]; do
    case "$1" in
        -v | --vibrant)
            colorProfile="vibrant"
            wallbashCurve="18 99\n32 97\n48 95\n55 90\n70 80\n80 70\n88 60\n94 40\n99 24"
            ;;
        -B | --balanced)
            colorProfile="balanced"
            wallbashCurve="$balancedWallbashCurve"
            ;;
        -p | --pastel)
            colorProfile="pastel"
            wallbashCurve="10 99\n17 66\n24 49\n39 41\n51 37\n58 34\n72 30\n84 26\n99 22"
            ;;
        -m | --mono)
            colorProfile="mono"
            wallbashCurve="10 0\n17 0\n24 0\n39 0\n51 0\n58 0\n72 0\n84 0\n99 0"
            ;;
        -c | --custom)
            shift
            if [ -n "$1" ] && [[ $1 =~ ^([0-9]+[[:space:]][0-9]+\\n){8}[0-9]+[[:space:]][0-9]+$ ]]; then
                colorProfile="custom"
                wallbashCurve="$1"
            else
                echo "Error: Custom color curve format is incorrect $1"
                exit 1
            fi
            ;;
        --candidate-colors)
            shift
            if [ -n "$1" ] && [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge "$wallbashColors" ]; then
                wallbashCandidateColors="$1"
            else
                echo "Error: Candidate color count must be an integer >= $wallbashColors"
                exit 1
            fi
            ;;
        --min-hue-distance)
            shift
            if [ -n "$1" ] && [[ $1 =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] && awk -v value="$1" 'BEGIN {exit !(value >= 0 && value <= 0.5)}'; then
                wallbashMinHueDistance="$1"
            else
                echo "Error: Minimum hue distance must be a number between 0 and 0.5"
                exit 1
            fi
            ;;
        -d | --dark)
            sortMode="dark"
            colSort=""
            ;;
        -l | --light)
            sortMode="light"
            colSort="-r"
            ;;
        *) break ;;
    esac
    shift
done
wallbashImg="$1"
wallbashFuzz=70
wallbashRaw="${2:-"$wallbashImg"}.mpc"
wallbashOut="${2:-"$wallbashImg"}.dcol"
wallbashCache="${2:-"$wallbashImg"}.cache"
wallbashLock="${wallbashOut}.lock"
pryDarkBri=116
pryDarkSat=110
pryDarkHue=88
pryLightBri=100
pryLightSat=100
pryLightHue=114
txtDarkBri=188
txtLightBri=16
if [ -z "$wallbashImg" ] || [ ! -f "$wallbashImg" ]; then
    echo "Error: Input file not found!"
    exit 1
fi
if ! magick -ping "$wallbashImg" -format "%t" info: &> /dev/null; then
    echo "Error: Unsuppoted image format $wallbashImg"
    exit 1
fi
echo -e "wallbash $colorProfile profile :: $sortMode :: Colors $wallbashColors :: Candidates $wallbashCandidateColors :: Fuzzy $wallbashFuzz :: HueDistance $wallbashMinHueDistance :: \"$wallbashOut\""
cacheDir="${cacheDir:-$XDG_CACHE_HOME/hyde}"
thmDir="${thmDir:-$cacheDir/thumbs}"
mkdir -p "$cacheDir/$thmDir"
exec {wallbashLockFd}> "$wallbashLock"
flock "$wallbashLockFd"
: > "$wallbashOut"
rgb_negative() {
    local inCol=$1
    local r=${inCol:0:2}
    local g=${inCol:2:2}
    local b=${inCol:4:2}
    local r16=$((16#$r))
    local g16=$((16#$g))
    local b16=$((16#$b))
    r=$(printf "%02X" $((255 - r16)))
    g=$(printf "%02X" $((255 - g16)))
    b=$(printf "%02X" $((255 - b16)))
    echo "$r$g$b"
}
rgba_convert() {
    local inCol=$1
    local r=${inCol:0:2}
    local g=${inCol:2:2}
    local b=${inCol:4:2}
    local r16=$((16#$r))
    local g16=$((16#$g))
    local b16=$((16#$b))
    printf "rgba(%d,%d,%d,\1341)\n" "$r16" "$g16" "$b16"
}
fx_brightness() {
    local inCol="$1"
    local fxb
    fxb=$(magick "$inCol" -colorspace gray -format "%[fx:mean]" info:)
    if awk -v fxb="$fxb" 'BEGIN {exit !(fxb < 0.5)}'; then
        return 0
    else
        return 1
    fi
}
color_hsb() {
    local inCol="$1"
    magick xc:"#$inCol" -colorspace HSB -format "%[fx:r] %[fx:g] %[fx:b]" info:
}
candidate_score() {
    local count="$1"
    local sat="$2"
    local bri="$3"
    awk -v count="$count" -v sat="$sat" -v bri="$bri" 'BEGIN {
        center = 1 - ((bri > 0.55 ? bri - 0.55 : 0.55 - bri) / 0.55)
        if (center < 0.15) {
            center = 0.15
        }
        printf "%.6f", count * (0.35 + sat) * center
    }'
}
hue_distance() {
    local first="$1"
    local second="$2"
    awk -v first="$first" -v second="$second" 'BEGIN {
        delta = first - second
        if (delta < 0) {
            delta = -delta
        }
        if (delta > 0.5) {
            delta = 1 - delta
        }
        printf "%.6f", delta
    }'
}
extract_candidate_palette() {
    local candidate_count="$1"
    readarray -t dcolRaw <<< "$(magick "$wallbashRaw" -depth 8 -fuzz $wallbashFuzz% +dither -kmeans "$candidate_count" -depth 8 -format "%c" histogram:info: | sed -n 's/^[ ]*\(.*\):.*[#]\([0-9a-fA-F]*\) .*$/\1,\2/p' | sort -r -n -k 1 -t ",")"
}
color_is_diverse() {
    local candidate_line="$1"
    local min_hue="$2"
    shift 2
    local candidate_hue
    local selected_line
    local selected_hue
    local delta
    IFS='|' read -r _ _ _ candidate_hue _ _ <<< "$candidate_line"
    for selected_line in "$@"; do
        IFS='|' read -r _ _ _ selected_hue _ _ <<< "$selected_line"
        delta=$(hue_distance "$candidate_hue" "$selected_hue")
        if awk -v delta="$delta" -v min_hue="$min_hue" 'BEGIN {exit !(delta < min_hue)}'; then
            return 1
        fi
    done
    return 0
}
sort_selected_colors() {
    if [ ${#dcolHex[@]} -eq 0 ]; then
        return 0
    fi
    if [ "$sortMode" == "light" ]; then
        mapfile -t dcolHex < <(
            for color in "${dcolHex[@]}"; do
                printf "%s|%s\n" "$(magick xc:"#$color" -colorspace gray -format "%[fx:mean]" info:)" "$color"
            done | sort -t '|' -k 1,1nr | awk -F '|' '{print $2}'
        )
    else
        mapfile -t dcolHex < <(
            for color in "${dcolHex[@]}"; do
                printf "%s|%s\n" "$(magick xc:"#$color" -colorspace gray -format "%[fx:mean]" info:)" "$color"
            done | sort -t '|' -k 1,1n | awk -F '|' '{print $2}'
        )
    fi
}
select_palette_colors() {
    local -a all_candidates=()
    local -a filtered_candidates=()
    local candidate_line
    local count
    local hex
    local hue
    local sat
    local bri
    local score
    local current_min_hue="$wallbashMinHueDistance"
    local -a pool=()
    local -a selected_meta=()
    local index
    local found_index
    local picked

    for candidate_line in "${dcolRaw[@]}"; do
        [ -n "$candidate_line" ] || continue
        count="${candidate_line%%,*}"
        hex="${candidate_line##*,}"
        read -r hue sat bri < <(color_hsb "$hex")
        score=$(candidate_score "$count" "$sat" "$bri")
        all_candidates+=("$score|$count|$hex|$hue|$sat|$bri")
        if awk -v sat="$sat" -v bri="$bri" 'BEGIN {exit !(sat >= 0.14 && bri >= 0.12 && bri <= 0.95)}'; then
            filtered_candidates+=("$score|$count|$hex|$hue|$sat|$bri")
        fi
    done

    pool=("${filtered_candidates[@]}")
    if [ ${#pool[@]} -lt $wallbashColors ]; then
        pool=("${all_candidates[@]}")
    fi

    if [ ${#pool[@]} -gt 0 ]; then
        mapfile -t pool < <(printf '%s\n' "${pool[@]}" | sort -t '|' -k 1,1nr -k 2,2nr)
    fi

    dcolHex=()
    while [ ${#dcolHex[@]} -lt $wallbashColors ] && [ ${#pool[@]} -gt 0 ]; do
        found_index=""
        for index in "${!pool[@]}"; do
            if color_is_diverse "${pool[$index]}" "$current_min_hue" "${selected_meta[@]}"; then
                found_index="$index"
                break
            fi
        done

        if [ -z "$found_index" ]; then
            if awk -v threshold="$current_min_hue" 'BEGIN {exit !(threshold > 0.02)}'; then
                current_min_hue=$(awk -v threshold="$current_min_hue" 'BEGIN {printf "%.6f", threshold * 0.75}')
                continue
            fi
            found_index=0
        fi

        picked="${pool[$found_index]}"
        selected_meta+=("$picked")
        IFS='|' read -r _ _ hex _ _ _ <<< "$picked"
        dcolHex+=("$hex")
        pool=("${pool[@]:0:$found_index}" "${pool[@]:$((found_index + 1))}")
    done

    sort_selected_colors
}
magick -quiet -regard-warnings "$wallbashImg"[0] -alpha off +repage "$wallbashRaw"
extract_candidate_palette "$wallbashCandidateColors"
if [ ${#dcolRaw[*]} -lt $wallbashColors ]; then
    echo -e "RETRYING :: distinct colors ${#dcolRaw[*]} is less than $wallbashColors palette color..."
    extract_candidate_palette "$((wallbashCandidateColors + wallbashColors))"
fi
if [ "$sortMode" == "auto" ]; then
    if fx_brightness "$wallbashRaw"; then
        sortMode="dark"
        colSort=""
    else
        sortMode="light"
        colSort="-r"
    fi
fi
echo "dcol_mode=\"$sortMode\"" >> "$wallbashOut"
select_palette_colors
greyCheck=$(magick "$wallbashRaw" -colorspace HSL -channel g -separate +channel -format "%[fx:mean]" info:)
if (($(awk 'BEGIN {print ('"$greyCheck"' < 0.12)}'))); then
    wallbashCurve="10 0\n17 0\n24 0\n39 0\n51 0\n58 0\n72 0\n84 0\n99 0"
fi
for ((i = 0; i < wallbashColors; i++)); do
    if [ -z "${dcolHex[i]}" ]; then
        if fx_brightness "xc:#${dcolHex[i - 1]}"; then
            modBri=$pryDarkBri
            modSat=$pryDarkSat
            modHue=$pryDarkHue
        else
            modBri=$pryLightBri
            modSat=$pryLightSat
            modHue=$pryLightHue
        fi
        echo -e "dcol_pry$((i + 1)) :: regen missing color"
        dcolHex[i]=$(magick xc:"#${dcolHex[i - 1]}" -depth 8 -normalize -modulate $modBri,$modSat,$modHue -depth 8 -format "%c" histogram:info: | sed -n 's/^[ ]*\(.*\):.*[#]\([0-9a-fA-F]*\) .*$/\2/p')
    fi
    echo "dcol_pry$((i + 1))=\"${dcolHex[i]}\"" >> "$wallbashOut"
    echo "dcol_pry$((i + 1))_rgba=\"$(rgba_convert "${dcolHex[i]}")\"" >> "$wallbashOut"
    nTxt=$(rgb_negative "${dcolHex[i]}")
    if fx_brightness "xc:#${dcolHex[i]}"; then
        modBri=$txtDarkBri
    else
        modBri=$txtLightBri
    fi
    tcol=$(magick xc:"#$nTxt" -depth 8 -normalize -modulate $modBri,10,100 -depth 8 -format "%c" histogram:info: | sed -n 's/^[ ]*\(.*\):.*[#]\([0-9a-fA-F]*\) .*$/\2/p')
    echo "dcol_txt$((i + 1))=\"$tcol\"" >> "$wallbashOut"
    echo "dcol_txt$((i + 1))_rgba=\"$(rgba_convert "$tcol")\"" >> "$wallbashOut"
    xHue=$(magick xc:"#${dcolHex[i]}" -colorspace HSB -format "%c" histogram:info: | awk -F '[hsb(,]' '{print $2}')
    acnt=1
    echo -e "$wallbashCurve" | sort -n ${colSort:+"$colSort"} | while read -r xBri xSat; do
        acol=$(magick xc:"hsb($xHue,$xSat%,$xBri%)" -depth 8 -format "%c" histogram:info: | sed -n 's/^[ ]*\(.*\):.*[#]\([0-9a-fA-F]*\) .*$/\2/p')
        echo "dcol_$((i + 1))xa$acnt=\"$acol\"" >> "$wallbashOut"
        echo "dcol_$((i + 1))xa${acnt}_rgba=\"$(rgba_convert "$acol")\"" >> "$wallbashOut"
        ((acnt++))
    done
done
flock -u "$wallbashLockFd"
eval "exec ${wallbashLockFd}>&-"
rm -f "$wallbashRaw" "$wallbashCache"
