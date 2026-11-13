#!/bin/bash
# FE2-Simulator starten – Doppelklick im Finder (macOS) oder ./FE2-Simulator.command im Terminal.
# Sucht ein Python 3 mit Tk 8.6 oder neuer (Homebrew oder python.org). Das Python von macOS
# (/usr/bin/python3) bringt nur Tk 8.5 mit und wird übersprungen. Anleitung: ANLEITUNG-macOS.md
cd "$(dirname "$0")" || exit 1

for candidate in \
  /opt/homebrew/bin/python3 \
  /usr/local/bin/python3 \
  /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
  python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c "import sys, tkinter; sys.exit(0 if sys.version_info >= (3, 9) and tkinter.TkVersion >= 8.6 else 1)" >/dev/null 2>&1; then
    exec "$candidate" fe2_simulator.py "$@"
  fi
done

echo "Kein passendes Python gefunden (Python 3.9+ mit Tk 8.6+)."
echo "Installieren mit Homebrew:  brew install python python-tk"
echo "oder Python von https://www.python.org/downloads/macos/ installieren."
echo
read -r -n 1 -p "Taste drücken zum Schließen …"
exit 1
