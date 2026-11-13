#!/bin/bash
# ELRD-Backend (Python) starten – Doppelklick im Finder (macOS) oder ./ELRD-Backend.command im Terminal.
# Braucht nur Python 3.9+; das Python von macOS (/usr/bin/python3, Xcode-Werkzeuge) reicht.
# Anleitung: README.md in diesem Ordner. Beenden: Ctrl-C oder Terminal-Fenster schließen.
cd "$(dirname "$0")" || exit 1

for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3 /usr/bin/python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)" >/dev/null 2>&1; then
    "$candidate" elrd_server.py "$@"
    status=$?
    if [ $status -ne 0 ]; then
      echo
      read -r -n 1 -p "Backend beendet (Code $status). Taste drücken zum Schließen …"
    fi
    exit $status
  fi
done

echo "Kein Python 3.9+ gefunden."
echo "Am einfachsten: im Terminal  xcode-select --install  (Xcode-Werkzeuge mit Python 3)"
echo "oder  brew install python"
echo
read -r -n 1 -p "Taste drücken zum Schließen …"
exit 1
