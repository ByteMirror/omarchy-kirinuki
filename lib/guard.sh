# shellcheck shell=bash
#
# Path and resource guard, shared by every helper in this plugin.
#
# The panel's IPC is reachable by anything that can talk to the shell, and the
# helpers below are what turn a path into an image decode, an editor, an OCR
# run, or a clipboard write. So a path is never taken at its word: it has to be
# a capture this plugin could plausibly have produced -- an existing regular
# file, not a symlink, owned by the user running the shell, named with an image
# extension, and inside the staging dir or the screenshots folder. Anything
# else is refused before a single byte is read.
#
# Decoding is bounded too. ImageMagick and Tesseract will happily spend all the
# memory and time in the world on a crafted file, and they run inside the
# desktop session, so every invocation carries explicit size, dimension,
# output-size and wall-clock limits.
#
# Sourced, never executed:  source "$here/../lib/guard.sh"

# Ceilings. Overridable, but the defaults have to hold on their own: a capture
# runs unattended, and nobody tunes these before pressing PrintScreen.
KIRINUKI_MAX_BYTES="${KIRINUKI_MAX_BYTES:-67108864}"          # 64 MiB on disk
KIRINUKI_MAX_PIXELS="${KIRINUKI_MAX_PIXELS:-80000000}"        # 80 MP decoded
KIRINUKI_MAX_DIMENSION="${KIRINUKI_MAX_DIMENSION:-32768}"     # px per side
KIRINUKI_MAX_TEXT_BYTES="${KIRINUKI_MAX_TEXT_BYTES:-1048576}" # 1 MiB of OCR
KIRINUKI_TIMEOUT="${KIRINUKI_TIMEOUT:-20}"                    # seconds per helper

# Applied to every ImageMagick call. `time` makes the library give up on its
# own; `timeout` outside it is the backstop for a call that never gets that
# far, e.g. one wedged on a pipe.
kirinuki_im_limits=(
  -limit memory 256MiB
  -limit map 512MiB
  -limit disk 1GiB
  -limit area "$KIRINUKI_MAX_PIXELS"
  -limit width "$KIRINUKI_MAX_DIMENSION"
  -limit height "$KIRINUKI_MAX_DIMENSION"
  -limit time "$KIRINUKI_TIMEOUT"
  -limit thread 4
)

kirinuki_staging_dir() {
  printf '%s' "${KIRINUKI_STAGING_DIR:-${XDG_RUNTIME_DIR:-/tmp}/kirinuki}"
}

# Same resolution order as omarchy-capture-screenshot, so Save lands where the
# stock flow would have put it.
kirinuki_screenshot_dir() {
  [[ -f $HOME/.config/user-dirs.dirs ]] && source "$HOME/.config/user-dirs.dirs"
  printf '%s' "${OMARCHY_SCREENSHOT_DIR:-${XDG_PICTURES_DIR:-$HOME/Pictures}}"
}

# Private by construction: 0700 and ours, or the plugin does not stage here.
# A pre-existing dir owned by somebody else is the interesting case -- on a
# shared /tmp fallback that is how a capture would be handed to another user.
kirinuki_stage_ensure() {
  local dir
  dir=$(kirinuki_staging_dir) || return 1
  [[ -d $dir ]] || mkdir -m 700 -p -- "$dir" || return 1
  [[ -L $dir ]] && return 1
  [[ $(stat -c '%u' -- "$dir" 2>/dev/null) == "$(id -u)" ]] || return 1
  chmod 700 -- "$dir" 2>/dev/null
  printf '%s' "$dir"
}

# png|jpg for a name this plugin handles, nothing for anything else. The
# extension also becomes ImageMagick's explicit input format below, which is
# what keeps a renamed SVG or MSL file from reaching a delegate.
kirinuki_format() {
  case "${1,,}" in
    *.png) printf 'png' ;;
    *.jpg | *.jpeg) printf 'jpg' ;;
    *) return 1 ;;
  esac
}

# `format:path`, so ImageMagick never sniffs content to decide what a file is.
kirinuki_spec() {
  local fmt
  fmt=$(kirinuki_format "$1") || return 1
  printf '%s:%s' "$fmt" "$1"
}

# The boundary. Prints the canonical path on success, nothing on refusal.
#
# Symlinks are rejected at the named component rather than followed, so a link
# planted in the staging dir cannot borrow the trust of the directory it sits
# in; the parents are canonicalised, because a symlinked $HOME or /run is
# ordinary and harmless.
kirinuki_safe_path() {
  local file="${1:-}" canon root staging shots
  [[ -n $file && $file == /* ]] || return 1
  [[ $file == *$'\n'* ]] && return 1
  kirinuki_format "$file" >/dev/null || return 1
  [[ -L $file ]] && return 1
  [[ -f $file ]] || return 1

  canon=$(realpath -e -- "$file" 2>/dev/null) || return 1
  [[ -f $canon && ! -L $canon ]] || return 1
  [[ $(stat -c '%u' -- "$canon" 2>/dev/null) == "$(id -u)" ]] || return 1

  staging=$(realpath -m -- "$(kirinuki_staging_dir)" 2>/dev/null) || return 1
  shots=$(realpath -m -- "$(kirinuki_screenshot_dir)" 2>/dev/null) || return 1
  for root in "$staging" "$shots"; do
    [[ -n $root && $canon == "$root"/* ]] || continue
    printf '%s' "$canon"
    return 0
  done
  return 1
}

# kirinuki_safe_path plus what it costs to decode: the file has to fit the size
# ceiling, and its header has to describe an image within the pixel and
# dimension ceilings whose real format matches its extension.
kirinuki_safe_image() {
  local canon size out fmt m w h
  canon=$(kirinuki_safe_path "${1:-}") || return 1

  size=$(stat -c '%s' -- "$canon" 2>/dev/null) || return 1
  (( size > 0 && size <= KIRINUKI_MAX_BYTES )) || return 1

  # Header-only read, and only the first frame: a multi-frame file costs
  # nothing extra to refuse here but a lot to decode later.
  if command -v magick >/dev/null 2>&1; then
    fmt=$(kirinuki_format "$canon") || return 1
    out=$(timeout "$KIRINUKI_TIMEOUT" magick identify -quiet "${kirinuki_im_limits[@]}" \
      -format '%m %w %h' "${fmt}:${canon}[0]" 2>/dev/null) || return 1
    read -r m w h <<<"$out"
    case "$fmt:$m" in png:PNG | jpg:JPEG | jpg:JPG) ;; *) return 1 ;; esac
    [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
    (( w > 0 && h > 0 )) || return 1
    (( w <= KIRINUKI_MAX_DIMENSION && h <= KIRINUKI_MAX_DIMENSION )) || return 1
    (( w * h <= KIRINUKI_MAX_PIXELS )) || return 1
  fi

  printf '%s' "$canon"
}

# Every ImageMagick call in this plugin goes through here: bounded, and given
# its input and output formats explicitly.
kirinuki_magick() {
  timeout "$KIRINUKI_TIMEOUT" magick "${kirinuki_im_limits[@]}" "$@"
}

# What a conversion produced has to be bounded as well -- a small input can
# still decompress into an enormous output.
kirinuki_output_ok() {
  local size
  size=$(stat -c '%s' -- "${1:-}" 2>/dev/null) || return 1
  (( size > 0 && size <= KIRINUKI_MAX_BYTES ))
}

# Language codes reach tesseract as a data path, so keep them to the shape a
# language code actually has.
kirinuki_ocr_langs() {
  local langs="${OMARCHY_OCR_LANGS:-eng}"
  [[ $langs =~ ^[A-Za-z0-9_+-]+$ ]] || langs=eng
  printf '%s' "$langs"
}

# The clipboard always gets PNG, whatever the file on disk is: wl-copy
# advertises only the type it is given, most apps ask for image/png when
# pasting, and Omarchy's clipboard history watches `text` and `image/png`
# alone.
#
# A JPEG is transcoded into a private scratch file rather than through a pipe,
# so the result can be size-checked before it is offered -- a small input can
# still decompress into an enormous one, and a truncated pipe would put a
# corrupt image on the clipboard instead of failing.
kirinuki_copy_png() {
  local file="${1:-}" tmpdir png rc=1
  case "$file" in
    *.png | *.PNG)
      wl-copy --type image/png <"$file" && rc=0
      return $rc
      ;;
  esac
  tmpdir=$(mktemp -d) || return 1
  png="$tmpdir/clip.png"
  if kirinuki_magick "$(kirinuki_spec "$file")" -background white -flatten "png:$png" 2>/dev/null \
    && kirinuki_output_ok "$png"; then
    wl-copy --type image/png <"$png" && rc=0
  fi
  rm -rf "$tmpdir"
  return $rc
}
