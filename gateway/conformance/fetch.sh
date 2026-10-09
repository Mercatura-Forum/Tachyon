#!/usr/bin/env bash
# Fetches the independent FIX engine the conformance sessions run (QuickFIX/J 2.3.1, its FIX 4.4, FIXT.1.1 and FIX 5.0 SP2
# dictionaries, and its dependencies) from Maven Central into <dir>, checks each jar against its pinned SHA-1 (each pin
# Maven Central's published .sha1), and compiles Conformance.java and Conformance50.java into <dir>/classes.
#   gateway/conformance/fetch.sh <dir>
set -eu
dir="$1"; here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$dir/classes"
M=https://repo1.maven.org/maven2
while read -r path sha; do
  f="$dir/$(basename "$path")"
  [ -f "$f" ] || curl -sfL -o "$f" "$M/$path"
  got="$(sha1sum "$f" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || { echo "SHA-1 of $(basename "$f") is $got, pinned $sha"; exit 1; }
done <<'PINS'
org/quickfixj/quickfixj-core/2.3.1/quickfixj-core-2.3.1.jar 193116a9adde3a0fa52344c41bcd355123a0626c
org/quickfixj/quickfixj-messages-fix44/2.3.1/quickfixj-messages-fix44-2.3.1.jar 66df535895fbc9d211d648b4fd9c45f932593233
org/quickfixj/quickfixj-messages-fixt11/2.3.1/quickfixj-messages-fixt11-2.3.1.jar a77b99a58f143bc5e1140f2873a488dc6b5879cf
org/quickfixj/quickfixj-messages-fix50sp2/2.3.1/quickfixj-messages-fix50sp2-2.3.1.jar a2e71d2aac008227a1ecb7404eb8b3be6bac7368
org/apache/mina/mina-core/2.1.6/mina-core-2.1.6.jar ba4b9e10f13958ae1222b0e8ebfbbc5117408668
org/slf4j/slf4j-api/1.7.36/slf4j-api-1.7.36.jar 6c62681a2f655b49963a5983b8b0950a6120ae14
org/slf4j/slf4j-simple/1.7.36/slf4j-simple-1.7.36.jar a41f9cfe6faafb2eb83a1c7dd2d0dfd844e2a936
PINS
javac -d "$dir/classes" -cp "$(ls "$dir"/*.jar | tr '\n' ':')" "$here/Conformance.java" "$here/Conformance50.java"
echo "conformance engine ready in $dir"
