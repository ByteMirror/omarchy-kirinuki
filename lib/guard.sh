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
# And a path that passes is still only a name. The entry it names can be
# swapped -- for a symlink, for another file -- in the instant between the
# check and the open, so nothing with a side effect ever acts on a name. It
# asks kirinuki_open_image for a file descriptor, whose open object is what
# gets verified, and reads it as /dev/fd/N, which on Linux resolves to that
# inode and not to whatever the name has come to mean since. Writes go the
# same way: a save lands beside its destination and is renamed into place, so
# a symlink planted at the destination is replaced rather than written
# through.
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

# The name-level half of the boundary. Prints the canonical path on success,
# nothing on refusal. Enough to decide what a name *may* be; only
# kirinuki_open_image below decides what it *is*.
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

# The object-level half of the boundary. Opens the capture and verifies what
# was actually opened, then hands the descriptor back in the named variable.
#
#   kirinuki_open_image fd /path/to/capture.png || exit 1
#   ... "/dev/fd/$fd" ...
#   kirinuki_close fd
#
# fstat on the descriptor says it is a regular file, ours, and within the size
# ceiling; lstat on the name says the name is still a plain entry -- not a
# symlink -- for that same inode, so the object held is the one that was vetted
# at that location and not something reached through a link planted since.
# Only then is the header read, from the descriptor, and only the first frame:
# a multi-frame file costs nothing extra to refuse here but a lot to decode
# later. Its real format has to match the extension, and its pixel count and
# sides have to fit the ceilings.
#
# Consumers must read /dev/fd/N rather than the descriptor itself: each open of
# that path is a fresh view of the same inode from offset zero, so several
# readers in a row all see the whole file.
kirinuki_open_image() {
  local -n kirinuki_out_fd=$1
  local canon opened=-1 type uid size held named fmt out m w h
  canon=$(kirinuki_safe_path "${2:-}") || return 1
  # Opened read-write on purpose. A plain read open of a FIFO blocks until a
  # writer shows up, so a FIFO swapped in at the name after the check above
  # would park this shell inside open(2) before fstat ever gets to reject it.
  # On Linux, open(O_RDWR) on a FIFO returns at once (fifo(7)), a regular file
  # we own is writable anyway, and whatever came back is judged by fstat below
  # before a byte is read. Anything else that could stall an open -- a device
  # node -- cannot be created without CAP_MKNOD, and is refused by fstat too.
  { exec {opened}<>"$canon"; } 2>/dev/null || return 1

  IFS='|' read -r type uid size held < <(stat -L -c '%F|%u|%s|%d:%i' -- "/dev/fd/$opened" 2>/dev/null)
  [[ $type == 'regular file' ]] || { exec {opened}<&-; return 1; }
  [[ $uid == "$(id -u)" ]] || { exec {opened}<&-; return 1; }
  [[ $size =~ ^[0-9]+$ ]] && (( size > 0 && size <= KIRINUKI_MAX_BYTES )) || { exec {opened}<&-; return 1; }

  named=$(stat -c '%F|%d:%i' -- "$canon" 2>/dev/null)
  [[ $named == "regular file|$held" ]] || { exec {opened}<&-; return 1; }

  if command -v magick >/dev/null 2>&1; then
    fmt=$(kirinuki_format "$canon") || { exec {opened}<&-; return 1; }
    out=$(timeout "$KIRINUKI_TIMEOUT" magick identify -quiet "${kirinuki_im_limits[@]}" \
      -format '%m %w %h' "${fmt}:/dev/fd/${opened}[0]" 2>/dev/null) || { exec {opened}<&-; return 1; }
    read -r m w h <<<"$out"
    case "$fmt:$m" in png:PNG | jpg:JPEG | jpg:JPG) ;; *) exec {opened}<&-; return 1 ;; esac
    [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || { exec {opened}<&-; return 1; }
    (( w > 0 && h > 0 )) || { exec {opened}<&-; return 1; }
    (( w <= KIRINUKI_MAX_DIMENSION && h <= KIRINUKI_MAX_DIMENSION )) || { exec {opened}<&-; return 1; }
    (( w * h <= KIRINUKI_MAX_PIXELS )) || { exec {opened}<&-; return 1; }
  fi

  kirinuki_out_fd=$opened
}

kirinuki_close() {
  local -n kirinuki_out_fd=$1
  [[ $kirinuki_out_fd =~ ^[0-9]+$ ]] && exec {kirinuki_out_fd}<&-
  kirinuki_out_fd=-1
}

# Both halves, for a caller that only needs to know whether a name is a
# capture right now -- bin/summon, which hands the panel a name to display and
# cannot hand it a descriptor. Prints the canonical path. The panel only ever
# shows the image; every side effect re-opens and re-verifies at the moment of
# use.
kirinuki_safe_image() {
  local canon fd=-1
  canon=$(kirinuki_safe_path "${1:-}") || return 1
  kirinuki_open_image fd "$canon" || return 1
  kirinuki_close fd
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
