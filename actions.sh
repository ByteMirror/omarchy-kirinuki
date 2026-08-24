#!/bin/bash

# Side-effect actions for the screenshot preview panel. The QML side stays
# declarative and hands work here so shell quoting lives in one place.
#
# Every action starts by putting its argument through lib/guard.sh: the panel's
# IPC is reachable by anything that can talk to the shell, so a path only
# counts if it names a staged or saved capture of ours. And the name is only
# used to open the file once: the open descriptor is what gets verified --
# regular, ours, still the plain entry at that name, decodable within the
# guard's size, dimension and time limits -- and every action below reads
# /dev/fd/N, never the path again. Nothing swapped in at the name between the
# check and the use can be what gets copied, saved, read or edited.
#
# Usage: actions.sh <copy|save|ocr|edit> <file>

set -uo pipefail

here=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd) || exit 1
source "$here/lib/guard.sh" || exit 1

action="${1:-}"
file=$(kirinuki_safe_path "${2:-}") || exit 1
fd=-1
kirinuki_open_image fd "$file" || exit 1
fmt=$(kirinuki_format "$file") || exit 1

notify() { omarchy-notification-send "$@" >/dev/null 2>&1 || true; }

case "$action" in
  copy)
    kirinuki_copy_png "$fd" "$fmt" || { notify "Could not copy screenshot"; exit 1; }
    notify "Screenshot copied to clipboard" -t 2000
    ;;

  save)
    # Captures stage in a scratch dir (see bin/capture); Save is what promotes
    # one into the screenshots folder. No file dialog: the destination is the
    # configured folder, same as the stock capture flow. The write itself is
    # the guard's: from the descriptor, via a temp file and a rename, so the
    # predictable destination name cannot be a symlink into something else.
    dest=$(kirinuki_save_into "$fd" "$(basename "$file")" "$(kirinuki_screenshot_dir)") \
      || { notify "Could not save screenshot" "$(kirinuki_screenshot_dir)"; exit 1; }
    notify "Screenshot saved" "$dest" --image "$dest"
    ;;

  ocr)
    # Tesseract is not part of the Omarchy package set, so say so plainly
    # rather than reporting an empty result as "no text in the screenshot".
    if ! command -v tesseract >/dev/null 2>&1; then
      notify -g 󰴑 "OCR needs tesseract" "Install tesseract and a language pack"
      exit 1
    fi
    # Bounded like every other decode here: a wall-clock ceiling on the run,
    # and a ceiling on how much text may reach the clipboard.
    text=$(timeout "$KIRINUKI_TIMEOUT" tesseract "/dev/fd/$fd" stdout --oem 1 --psm 6 \
      -l "$(kirinuki_ocr_langs)" --dpi 300 \
      -c preserve_interword_spaces=1 2>/dev/null | head -c "$KIRINUKI_MAX_TEXT_BYTES")
    if [[ -z ${text//[[:space:]]/} ]]; then
      notify -g 󰴑 "No text found in screenshot"
      exit 1
    fi
    printf "%s" "$text" | wl-copy
    notify -g 󰴑 "Copied text from screenshot to clipboard"
    ;;

  edit)
    # bin/edit holds the capture open for the whole editing session and folds
    # the result back into that same inode, so it takes its own descriptor.
    kirinuki_close fd
    exec "$here/bin/edit" "$file"
    ;;

  *)
    exit 2
    ;;
esac
