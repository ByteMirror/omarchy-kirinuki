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
# And a name is only ever used once: to open the file, in bin/open, with
# flags a shell cannot set (O_NOFOLLOW|O_NONBLOCK|O_NOCTTY, relative to a
# directory descriptor walked down from the trusted root). What was opened is
# what gets verified, and every helper runs beneath bin/open reading fd 3 --
# as /dev/fd/3, which on Linux resolves to that inode and not to whatever the
# name has come to mean since. Writes go the same way: a save lands beside
# its destination and is renamed into place, so a symlink planted at the
# destination is replaced rather than written through.
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

# The boundary itself is bin/open, and it is Python for one reason: bash
# cannot pass flags to open(2). A shell redirection follows a symlink and
# blocks on a FIFO, and every check a script could make before it is a check
# on a name that may already mean something else. bin/open steps from the
# trusted root down to the capture on directory descriptors and opens the
# last component with O_NOFOLLOW|O_NONBLOCK|O_NOCTTY, judges the *open* object
# with fstat, reads the header from the descriptor, and only then hands fd 3
# to whatever runs beneath it.
kirinuki_open_helper() {
  printf '%s' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/open"
}

# The two places a capture may live. Anything else is not ours to touch.
kirinuki_root_args() {
  kirinuki_roots=(--root "$(kirinuki_staging_dir)" --root "$(kirinuki_screenshot_dir)")
}

# Run the rest of this script with <path> held open on fd 3.
#
#   kirinuki_hold "$file" "$0" "$@" || exit 1
#   file=$KIRINUKI_FILE   # canonical
#   ... "/dev/fd/3" ...
#
# The first time through there is nothing held, so the script replaces itself
# with bin/open, which opens and verifies the capture and exec's the script
# again -- same arguments -- with fd 3 in place and KIRINUKI_FILE set. The
# second time through this returns at once. A script exec'd by another that
# already holds the same capture (actions.sh -> bin/edit) inherits the
# descriptor and does not open anything.
#
# A held descriptor is reused only if it is what the environment claims: a
# regular file of ours whose dev:inode is the plain entry at KIRINUKI_FILE
# right now. Anything else -- wrong file, closed, replaced, a descriptor
# planted by a caller -- is dropped and the capture is opened afresh through
# bin/open, never on the say-so of an environment variable.
kirinuki_hold() {
  local path="${1:-}" type uid held named
  shift
  if [[ ${KIRINUKI_FD:-} == 3 && -n ${KIRINUKI_FILE:-} \
    && ( $path == "${KIRINUKI_HELD:-}" || $path == "$KIRINUKI_FILE" ) ]]; then
    IFS='|' read -r type uid held < <(stat -L -c '%F|%u|%d:%i' -- /dev/fd/3 2>/dev/null)
    named=$(stat -c '%F|%d:%i' -- "$KIRINUKI_FILE" 2>/dev/null)
    [[ $type == 'regular file' && $uid == "$(id -u)" && $named == "regular file|$held" ]] && return 0
  fi
  exec 3<&-
  unset KIRINUKI_FILE KIRINUKI_HELD KIRINUKI_FD
  local -a kirinuki_roots
  kirinuki_root_args
  exec "$(kirinuki_open_helper)" "${kirinuki_roots[@]}" -- "$path" -- "$@"
}

# Run one guard function with <path> held open on fd 3, in a child. For a
# script that needs a capture open for one step rather than for its whole
# run (bin/capture transcoding, then saving). Prints whatever the function
# prints; returns its status.
#
#   kirinuki_with_fd "$file" kirinuki_save_into 3 name dir
kirinuki_with_fd() {
  local path="${1:-}"
  shift
  local -a kirinuki_roots
  kirinuki_root_args
  "$(kirinuki_open_helper)" "${kirinuki_roots[@]}" -- "$path" -- \
    "$BASH" -c 'source -- "$1" && shift && "$@"' _ "${BASH_SOURCE[0]}" "$@"
}

# Whether <path> is a capture right now: opened and verified exactly as above,
# then let go. Prints the canonical path. For bin/summon, which hands the
# panel a name to display and cannot hand it a descriptor; the panel only
# shows the image, and every side effect holds its own descriptor.
kirinuki_safe_image() {
  local -a kirinuki_roots
  kirinuki_root_args
  "$(kirinuki_open_helper)" "${kirinuki_roots[@]}" -- "${1:-}"
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
#
#   kirinuki_copy_png <fd> <png|jpg>
kirinuki_copy_png() {
  local fd="${1:-}" fmt="${2:-}" tmpdir png rc=1
  [[ $fd =~ ^[0-9]+$ ]] || return 1
  if [[ $fmt == png ]]; then
    wl-copy --type image/png <"/dev/fd/$fd" && rc=0
    return $rc
  fi
  [[ $fmt == jpg ]] || return 1
  tmpdir=$(mktemp -d) || return 1
  png="$tmpdir/clip.png"
  if kirinuki_magick "jpg:/dev/fd/$fd" -background white -flatten "png:$png" 2>/dev/null \
    && kirinuki_output_ok "$png"; then
    wl-copy --type image/png <"$png" && rc=0
  fi
  rm -rf "$tmpdir"
  return $rc
}

# Put the capture behind <fd> into <dir> as <name>. Prints the destination.
#
# The bytes come from the descriptor, so they are the verified capture and not
# whatever the source name means by the time Save is pressed. They land in a
# private temp file beside the destination and are renamed over it: rename(2)
# swaps the directory entry itself, so a symlink planted at that predictable
# name is replaced rather than written through, and -T refuses to descend into
# a directory of that name. Overwriting is deliberate -- saving the same
# capture twice, typically after annotating it, should update that file.
#
#   kirinuki_save_into <fd> <name> <dir>
kirinuki_save_into() {
  local fd="${1:-}" name="${2:-}" dir="${3:-}" tmp dest
  [[ $fd =~ ^[0-9]+$ ]] || return 1
  [[ -n $name && $name != */* && $name != .* ]] || return 1
  [[ -n $dir && $dir == /* ]] || return 1
  mkdir -p -- "$dir" 2>/dev/null
  [[ -d $dir && $(stat -L -c '%u' -- "$dir" 2>/dev/null) == "$(id -u)" ]] || return 1
  tmp=$(mktemp -- "$dir/.kirinuki.XXXXXXXX") || return 1
  dest="$dir/$name"
  if cat -- "/dev/fd/$fd" >"$tmp" && kirinuki_output_ok "$tmp" \
    && chmod "$(printf '%o' $((0666 & ~0$(umask))))" -- "$tmp" \
    && mv -fT -- "$tmp" "$dest"; then
    printf '%s' "$dest"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Write the PNG on fd 3 as a JPEG at <dest>, via a temp file beside it and a
# rename. Runs beneath bin/open (see kirinuki_with_fd). JPEG has no alpha
# channel, so the image is flattened onto white -- otherwise transparency
# comes out black.
#
#   kirinuki_transcode_jpg <dest> <quality>
kirinuki_transcode_jpg() {
  local dest="${1:-}" quality="${2:-92}" tmp
  [[ -n $dest && $dest == /* ]] || return 1
  tmp=$(mktemp -- "$(dirname -- "$dest")/.kirinuki.XXXXXXXX") || return 1
  if kirinuki_magick "png:/dev/fd/$KIRINUKI_FD" -background white -flatten \
    -quality "$quality" "jpg:$tmp" 2>/dev/null && kirinuki_output_ok "$tmp" \
    && mv -fT -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# The no-panel fallback: save the capture on fd 3 into <dir> as <name> and
# put it on the clipboard, from that one descriptor. Prints the destination.
# Runs beneath bin/open (see kirinuki_with_fd).
#
#   kirinuki_promote <name> <dir>
kirinuki_promote() {
  local name="${1:-}" dir="${2:-}" dest
  dest=$(kirinuki_save_into "$KIRINUKI_FD" "$name" "$dir") || return 1
  kirinuki_copy_png "$KIRINUKI_FD" "$(kirinuki_format "$KIRINUKI_FILE")" >/dev/null 2>&1
  printf '%s' "$dest"
}
