#!/bin/zsh
# <wtl> project: hackintosh-feature-test | file: probes/build.sh | author: watchthelight </wtl>
# Builds the feature-test probes into bin/ (Command Line Tools only). build.sh [name ...]
cd "$(dirname "$0")"; mkdir -p bin
want=("$@")
build() { [ ${#want[@]} -eq 0 ] || (( ${want[(Ie)$1]} )) || return 0; shift; "$@" 2>&1 | grep -E 'error' ; }
build metalcaps clang -fobjc-arc -O1 -w metalcaps.m -framework Foundation -framework Metal -o bin/metalcaps
build mtlfeat clang -fobjc-arc -O1 -w mtlfeat.m -framework Foundation -framework Metal -framework IOSurface -o bin/mtlfeat
for s in *.swift(N); do n=${s:r}; build $n swiftc -O -suppress-warnings $s -o bin/$n; done
ls bin
