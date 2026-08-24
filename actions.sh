#!/bin/bash

# Side-effect actions for the screenshot preview panel. The QML side stays
# declarative and hands work here so shell quoting lives in one place.
#
# Usage: actions.sh <copy|save|ocr|edit> <file>

set -uo pipefail

action="${1:-}"
file="${2:-}"

[[ -n $file && -f $file ]] || exit 1

here=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd) || exit 1

notify() { omarchy-notification-send "$@" >/dev/null 2>&1 || true; }

# Same resolution order as omarchy-capture-screenshot, so Save lands where the
# stock flow would have put it.
screenshot_dir() {
  [[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
  printf '%s' "${OMARCHY_SCREENSHOT_DIR:-${XDG_PICTURES_DIR:-$HOME/Pictures}}"
}

# wl-copy advertises only the type it is given and most apps ask for
# image/png when pasting, so JPEG captures are transcoded on the way to the
# clipboard. See omarchy-screenshot-jpeg for the same reasoning.
copy_image() {
  case "${file,,}" in
    *.png) wl-copy --type image/png <"$file" ;;
    *) magick "$file" png:- | wl-copy --type image/png ;;
  esac
}

case "$action" in
  copy)
    copy_image
    notify "Screenshot copied to clipboard" -t 2000
    ;;

  save)
    # Captures stage in a scratch dir (see omarchy-screenshot-jpeg); Save is
    # what promotes one into the screenshots folder. No file dialog: the
    # destination is the configured folder, same as the stock capture flow.
    dir=$(screenshot_dir)
    mkdir -p "$dir" || { notify "Could not save screenshot" "$dir"; exit 1; }
    dest="$dir/$(basename "$file")"

    # Overwrite deliberately: saving the same capture twice -- typically
    # after annotating it -- should update that file, not litter copies.
    cp -f "$file" "$dest" || { notify "Could not save screenshot" "$dest"; exit 1; }
    notify "Screenshot saved" "$dest" --image "$dest"
    ;;

  ocr)
    # Tesseract is not part of the Omarchy package set, so say so plainly
    # rather than reporting an empty result as "no text in the screenshot".
    if ! command -v tesseract >/dev/null 2>&1; then
      notify -g 󰴑 "OCR needs tesseract" "Install tesseract and a language pack"
      exit 1
    fi
    text=$(tesseract "$file" stdout --oem 1 --psm 6 \
      -l "${OMARCHY_OCR_LANGS:-eng}" --dpi 300 \
      -c preserve_interword_spaces=1 2>/dev/null)
    if [[ -z ${text//[[:space:]]/} ]]; then
      notify -g 󰴑 "No text found in screenshot"
      exit 1
    fi
    printf "%s" "$text" | wl-copy
    notify -g 󰴑 "Copied text from screenshot to clipboard"
    ;;

  edit)
    # bin/edit hands PNG straight to Omarchy's editor and round-trips JPEG
    # through a scratch PNG, then summons the panel again either way.
    exec "$here/bin/edit" "$file"
    ;;

  *)
    exit 2
    ;;
esac
