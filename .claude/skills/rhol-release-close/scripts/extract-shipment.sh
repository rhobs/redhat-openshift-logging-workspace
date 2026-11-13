#!/usr/bin/env bash
# Extract release-close data from an ART shipment MR in ocp-shipment-data.
#
# Usage: extract-shipment.sh <mr-url-or-version>
#   mr-url:  https://gitlab.cee.redhat.com/<project>/-/merge_requests/<iid>
#   version: a bare X.Y.Z — the MR is found by its title
#            "Shipment for openshift-logging X.Y.Z (ship date: YYYY-Mmm-DD)"
#
# Prints shell assignments (for eval) on stdout:
#   MR_IID, MR_STATE, VERSION, RELEASE_DATE (ISO YYYY-MM-DD), ERRATA_URL
# Progress and errors go to stderr; exits non-zero on failure.

set -euo pipefail
API="https://gitlab.cee.redhat.com/api/v4"
DEFAULT_PROJECT="hybrid-platforms%2Fart%2Focp-shipment-data"

INPUT="${1:-}"
[[ -n "$INPUT" ]] || { echo "ERROR: usage: extract-shipment.sh <mr-url-or-version>" >&2; exit 1; }

if [[ "$INPUT" =~ ^https://gitlab\.cee\.redhat\.com/(.+)/-/merge_requests/([0-9]+) ]]; then
  PROJECT="${BASH_REMATCH[1]//\//%2F}"
  MR_IID="${BASH_REMATCH[2]}"
else
  VERSION="$INPUT"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: not an MR URL or X.Y.Z version: $INPUT" >&2; exit 1; }
  # Find the MR by exact title; search opened first, then merged, then all —
  # the matching MR is often already merged.
  MATCHES=""
  for STATE in opened merged all; do
    MATCHES="$(SEARCH_VERSION="$VERSION" curl -sf \
      "$API/projects/$DEFAULT_PROJECT/merge_requests?state=$STATE&search=openshift-logging%20$VERSION&per_page=20" | \
      SEARCH_VERSION="$VERSION" python3 -c "
import json,os,re,sys
pat = re.compile(r'^Shipment for openshift-logging ' + re.escape(os.environ['SEARCH_VERSION']) + r' \(ship date: \d{4}-[A-Z][a-z]{2}-\d{2}\)$')
for m in json.load(sys.stdin):
    if pat.match(m['title']):
        print(m['iid'], m['state'], m['title'])
")" || true
    [[ -n "$MATCHES" ]] && break
  done
  [[ -n "$MATCHES" ]] || { echo "ERROR: no shipment MR found for openshift-logging $VERSION in any state" >&2; exit 1; }
  if [[ "$(wc -l <<<"$MATCHES")" -ne 1 ]]; then
    echo "ERROR: multiple matching shipment MRs — pick one:" >&2
    sed 's/^/       /' <<<"$MATCHES" >&2
    exit 1
  fi
  read -r MR_IID _ <<<"$MATCHES"
  PROJECT="$DEFAULT_PROJECT"
  echo "found shipment MR !$MR_IID (matched in state=$STATE search)" >&2
fi

MR_JSON="$(curl -sf "$API/projects/$PROJECT/merge_requests/$MR_IID")" \
  || { echo "ERROR: could not fetch MR !$MR_IID (network or auth problem)" >&2; exit 1; }
MR_STATE="$(python3 -c "import json,sys; print(json.load(sys.stdin)['state'])" <<<"$MR_JSON")"
MR_TITLE="$(python3 -c "import json,sys; print(json.load(sys.stdin)['title'])" <<<"$MR_JSON")"

# Parse version and ship date from the title (GNU date rejects YYYY-Mmm-DD).
read -r VERSION RELEASE_DATE < <(MR_TITLE="$MR_TITLE" python3 -c "
import datetime,os,re,sys
m = re.match(r'^Shipment for openshift-logging (\d+\.\d+\.\d+) \(ship date: (\d{4}-[A-Z][a-z]{2}-\d{2})\)\$',
             os.environ['MR_TITLE'])
if not m:
    sys.exit('ERROR: unexpected MR title: ' + os.environ['MR_TITLE'])
print(m.group(1), datetime.datetime.strptime(m.group(2), '%Y-%b-%d').strftime('%Y-%m-%d'))
") || { echo "ERROR: could not parse version/ship date from MR title" >&2; exit 1; }

# Extract the prod advisory URL from the image advisory file (not the .fbc.
# files, and not the stage environment). Sanity-check the assembly.
ERRATA_URL="$(curl -sf "$API/projects/$PROJECT/merge_requests/$MR_IID/diffs" | python3 -c "
import json,re,sys
diffs = json.load(sys.stdin)
imgs = [f for f in diffs if re.search(r'/prod/[^/]*\.image\.[0-9]+\.yaml\$', f['new_path'])]
if len(imgs) != 1:
    sys.exit('ERROR: expected exactly 1 image advisory file, got %d' % len(imgs))
d = imgs[0]['diff']
asm = re.search(r'assembly: (\S+)', d)
url = re.search(r'url: (https://access\.redhat\.com/errata/RH[A-Z]+-[0-9]+:[0-9]+)', d)
if not asm or not url:
    sys.exit('ERROR: could not parse assembly or prod advisory url from %s' % imgs[0]['new_path'])
if asm.group(1) != '$VERSION':
    sys.exit('ERROR: assembly %s does not match version $VERSION from the MR title' % asm.group(1))
print(url.group(1))
")" || exit 1

echo "MR_IID=$MR_IID"
echo "MR_STATE=$MR_STATE"
echo "VERSION=$VERSION"
echo "RELEASE_DATE=$RELEASE_DATE"
echo "ERRATA_URL=$ERRATA_URL"
