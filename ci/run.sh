#!/usr/bin/env sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
stage=${1:-all}; profile=${CI:+github-actions}; profile=${profile:-local}
record() {
  python3 - "$1" "$2" "$profile" <<'PY'
import hashlib,json,pathlib,subprocess,sys
name,outcome,profile=sys.argv[1:]; allowed={'ci.validate','ci.test','ci.security','ci.package','ci.evidence'}
if name not in allowed or outcome not in {'passed','failed'}: raise SystemExit(2)
base=pathlib.Path('.ci/evidence'); base.mkdir(parents=True,exist_ok=True)
try: sha=subprocess.check_output(['git','-c','safe.directory=.','rev-parse','HEAD'],text=True).strip(); dirty=bool(subprocess.check_output(['git','-c','safe.directory=.','status','--porcelain'],text=True).strip())
except Exception: sha,dirty='unknown',True
report=base/(name.replace('.','-')+'.json'); report.write_text(json.dumps({'check':name,'outcome':outcome})+'\n')
path=base/'manifest.json'; old=json.loads(path.read_text()) if path.exists() else {'checks':[]}; checks={x['name']:x for x in old['checks']}
checks[name]={'name':name,'outcome':outcome,'report':str(report).replace('\\','/'),'sha256':hashlib.sha256(report.read_bytes()).hexdigest()}
path.write_text(json.dumps({'schemaVersion':'llm-council.ci-evidence/v1','contractVersion':'llm-council.ci-contract/v1','repository':'llm-council-infra','source':{'commit':sha,'workingTree':'dirty' if dirty else 'clean'},'profile':profile,'checks':[checks[k] for k in sorted(checks)]},indent=2)+'\n')
PY
}
run(){ check=$1; shift; if "$@"; then record "$check" passed; else record "$check" failed; exit 1; fi; }
powershell_file() {
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$@"
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$@"
  else
    echo "PowerShell 7 or Windows PowerShell is required" >&2
    return 127
  fi
}
render_all(){ for option in dev-full-http dev-full-https dev-local-ai prod-full-local-http prod-full-local-https prod-full-local-https-tunnel prod-full-local-observability prod-lite-local; do sh scripts/config.sh "$option"; done; }
one(){ case "$1" in
 validate) run ci.validate render_all ;;
 test) run ci.test powershell_file scripts/check-bp175-safety.ps1 ;;
 security) run ci.security powershell_file projects/scripts/check-image-digests.ps1 ;;
 package) run ci.package sh scripts/config.sh prod-full-local-observability ;;
 evidence) record ci.evidence passed ;;
 *) exit 2;; esac; }
if [ "$stage" = all ]; then for item in validate test security package evidence; do one "$item"; done; else one "$stage"; fi
