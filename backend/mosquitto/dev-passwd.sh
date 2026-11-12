#!/bin/sh
# Legt mosquitto/passwd für die Entwicklung an (nur Testpasswörter!):
#   elrd-backend / entwicklung-backend   – das Backend
#   test-rd      / entwicklung-fe2       – „FE2“ der Organisation test-rd (Skript tools/alamos)
# Im Betrieb eigene, lange Passwörter verwenden (README, Abschnitt „Broker“).
set -e
cd "$(dirname "$0")"
rm -f passwd && touch passwd && chmod 600 passwd
if command -v mosquitto_passwd >/dev/null 2>&1; then
  mosquitto_passwd -b passwd elrd-backend entwicklung-backend
  mosquitto_passwd -b passwd test-rd entwicklung-fe2
else
  docker run --rm -v "$PWD:/w" eclipse-mosquitto:2 sh -c \
    "mosquitto_passwd -b /w/passwd elrd-backend entwicklung-backend && mosquitto_passwd -b /w/passwd test-rd entwicklung-fe2"
fi
# Der Container liest die Datei als Benutzer „mosquitto“.
chmod 644 passwd
echo "mosquitto/passwd angelegt."
