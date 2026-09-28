#!/usr/bin/env bash
#
# check-primary.sh — refuse a brand primary that no text colour can sit on
# (T610, DECISIONS.md:6899).
#
#   ./check-primary.sh <light|dark> <colour>   check one colour; empty = not set
#   ./check-primary.sh --env <file>            BRANDING_{LIGHT,DARK}_PRIMARY_COLOR
#                                              from an env file (last one wins)
#
# Exit 0 — usable or not set (the system colour stays); 1 — refused;
# 2 — usage, an unreadable file, or the contrast could not be measured.
#
# The fronts pick the text on primary by contrast: white if it gives at least
# 4.5:1, else the theme's dark ink — pickOn() in
# frontend/driver/src/app/_themes/brandTheme.ts over the `on-primary` pick of
# DS_DERIVED in frontend/driver/src/app/_ds/tokens.ts (whiteOnPrimary() in pay
# is the same first half). A primary of relative luminance ≈ 0.18–0.21 fails
# both — AntD's default #1677FF sits there, 4.42:1 — and gets text below AA.
# The formula (WCAG 2.1, sRGB 0.03928 knee), the 4.5 threshold and the inks
# below must stay equal to the fronts': a difference is a defect.
# Colour syntax is what the fronts' rgbOf() reads — #rgb[a], #rrggbb[aa],
# rgb[a](…); alpha is ignored there and here. Anything else they cannot
# measure, so it is refused too.

set -euo pipefail
export LC_ALL=C   # awk and printf write and read the decimal point, not a locale's comma

WHITE='#ffffff'
declare -A INK=([light]='#071725' [dark]='#111315')

usage() { sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# colour → "r g b" (0–255), or nothing when the fronts could not read it either
rgb_of() {
  local c="${1,,}" h
  if [[ "$c" =~ ^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$ ]]; then
    h="${BASH_REMATCH[1]}"
    if (( ${#h} <= 4 )); then
      echo "$((16#${h:0:1}${h:0:1})) $((16#${h:1:1}${h:1:1})) $((16#${h:2:1}${h:2:1}))"
    else
      echo "$((16#${h:0:2})) $((16#${h:2:2})) $((16#${h:4:2}))"
    fi
  elif [[ "$c" =~ ^rgba?\([[:space:]]*([0-9]+(\.[0-9]+)?)[[:space:],]+([0-9]+(\.[0-9]+)?)[[:space:],]+([0-9]+(\.[0-9]+)?) ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[3]} ${BASH_REMATCH[5]}"
  fi
}

# "r g b" of the primary, of white, of the ink → "<white> <ink> <verdict>":
# WCAG 2.1 contrasts truncated for the message only; the verdict is taken on the
# unrounded values, as pickOn() does — white at >= 4.5, else the ink, and
# "refused" when the ink falls short too. Rounding first moves ~370 colours
# at the threshold to the wrong side.
measure() {
  awk -v p="$1" -v w="$2" -v k="$3" '
    function lin(x,  s) { s = x / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ^ 2.4 }
    function lum(t,  v) { split(t, v, " "); return 0.2126 * lin(v[1]) + 0.7152 * lin(v[2]) + 0.0722 * lin(v[3]) }
    function ratio(a, b,  hi, lo) { hi = a > b ? a : b; lo = a > b ? b : a; return (hi + 0.05) / (lo + 0.05) }
    BEGIN { lp = lum(p); cw = ratio(lp, lum(w)); ck = ratio(lp, lum(k))
            v = (cw >= 4.5) ? "white" : ((ck >= 4.5) ? "ink" : "refused")
            # shown truncated, not rounded: 4.49998 is "4.49", never a refused "4.50"
            printf "%.2f %.2f %s\n", int(cw * 100) / 100, int(ck * 100) / 100, v }'
}

# $1 theme, $2 colour
check() {
  local theme="$1" colour="$2" p cw ck verdict
  # The fronts trim() the value; a CRLF file leaves a \r they would not see.
  colour="${colour//$'\r'/}"
  colour="${colour#"${colour%%[![:space:]]*}"}"
  colour="${colour%"${colour##*[![:space:]]}"}"
  if [[ -z "$colour" ]]; then
    echo "  $theme primary: not set — the system colour stays"
    return 0
  fi
  p="$(rgb_of "$colour")"
  if [[ -z "$p" ]]; then
    echo "  $theme primary $colour: REFUSED — the fronts cannot read this colour; use #rrggbb or rgb(r, g, b)" >&2
    return 1
  fi
  # rgbOf() does not clamp, the browser does: rgb(0,0,999) is measured as one
  # colour and painted as another. Stricter than the fronts, on purpose.
  if awk -v t="$p" 'BEGIN { split(t, v, " "); exit !(v[1] > 255 || v[2] > 255 || v[3] > 255) }'; then
    echo "  $theme primary $colour: REFUSED — a channel above 255; the browser clips it and the contrast no longer holds" >&2
    return 1
  fi
  read -r cw ck verdict < <(measure "$p" "$(rgb_of "$WHITE")" "$(rgb_of "${INK[$theme]}")")
  if [[ "$verdict" == white || "$verdict" == ink ]]; then
    echo "  $theme primary $colour: ok — white $cw:1, ink ${INK[$theme]} $ck:1, text on it is $verdict"
    return 0
  fi
  [[ "$verdict" == refused ]] || { echo "  $theme primary $colour: contrast not measured" >&2; return 2; }
  echo "  $theme primary $colour: REFUSED — white gives $cw:1, the theme's ink ${INK[$theme]} $ck:1, 4.5:1 is needed; pick a darker or a lighter primary" >&2
  return 1
}

env_val() { sed -n "s/^$1=//p" "$2" | tail -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

case "${1:-}" in
  light|dark)
    [[ $# -eq 2 ]] || usage
    check "$1" "$2"
    ;;
  --env)
    [[ $# -eq 2 && -r "$2" ]] || usage
    rc=0
    for theme in light dark; do
      r=0
      check "$theme" "$(env_val "BRANDING_${theme^^}_PRIMARY_COLOR" "$2")" || r=$?
      (( r > rc )) && rc=$r
    done
    exit $rc
    ;;
  *) usage ;;
esac
