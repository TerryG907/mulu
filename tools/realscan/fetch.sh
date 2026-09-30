#!/usr/bin/env bash
# Re-download the public-domain scanned books used by Mulu's real-scan test
# (Internet Archive, all published 1928 or earlier) and verify their SHA-1.
# Usage: tools/realscan/fetch.sh [DEST_DIR]   (default: ./realscan-books)
set -euo pipefail
DEST="${1:-realscan-books}"; mkdir -p "$DEST"
sha1() { shasum -a 1 "$1" | awk '{print $1}'; }
fetch() { # id file sha1
  local out="$DEST/$1.pdf"
  if [[ -f "$out" && "$(sha1 "$out")" == "$3" ]]; then echo "ok (cached) $1"; return; fi
  curl --fail --retry 3 --location --silent --show-error -o "$out.part" "https://archive.org/download/$1/$2"
  [[ "$(sha1 "$out.part")" == "$3" ]] || { echo "CHECKSUM MISMATCH $1" >&2; rm -f "$out.part"; exit 1; }
  mv "$out.part" "$out"; echo "ok $1"
}
fetch analyticalgeometry00bake analyticalgeometry00bake.pdf f625e27702a3684b3311ba2d2f712512c1790e52
fetch historyofsteamna00kennuoft historyofsteamna00kennuoft.pdf ef79dd9eeab94eba35d958d45a89f914c626787a
fetch thirdreader0000unse thirdreader0000unse.pdf e1875a4a580032711d85a2dfb1e487f6ddc6d6a6
fetch elementaryenglis0000unse_k0j8 elementaryenglis0000unse_k0j8.pdf 4728e21c7a220b21d36ecc6ab53cec2d536104e7
fetch practicalmathema00castrich practicalmathema00castrich.pdf 75c8a520ef176eadf0a5dd84a3b3ce505079bc92
fetch spacetimegravita00eddirich spacetimegravita00eddirich.pdf a75a40c313eb242dd9f330e33895509266bcc790
fetch mathematicsofacc00walt mathematicsofacc00walt.pdf 8f23b1a0c4ad861bb605e2e9410d376fa6de7d2a
fetch manualofenglishg00nesf manualofenglishg00nesf.pdf 6de08f1360a5fc6be1db1de4d6724a42d50c6aaa
fetch firstvoyageround00piga firstvoyageround00piga.pdf 43b80e69788b4d67063dfec5c5151ec288a30ed0
fetch historyoflehighc00hause historyoflehighc00hause.pdf 9a34d78b87d1771eb384414c10acb90cbeddca69
fetch theorysound06raylgoog theorysound06raylgoog_text.pdf 88bd5b1044b9962c58c52f7090db06f79147a2c8
fetch upfromslaveryan08washgoog upfromslaveryan08washgoog_text.pdf 50f83a9a82248ff074ade2c403c204aba211fded
fetch cu31924002967382 cu31924002967382.pdf b66d2bedbb664e5fe90406b9a716c7ecda3bb625
fetch newmcguffeythird00mcgu newmcguffeythird00mcgu.pdf 8af6956b05dd12164f1fd91646eccfcfd95263a6
fetch zhiwudefenbu00wuku zhiwudefenbu00wuku.pdf e41711b4ab07a90ab3c671e94ceef9329a3265b8
fetch nanyangzhiwuzhi00wuyux nanyangzhiwuzhi00wuyux.pdf 78a9b79b975d772f172fa78324fb368999581ec4
fetch emeiyouji00zhan emeiyouji00zhan.pdf ef1202d6b7e9cbb4d3499f414218c9c9016eb609
