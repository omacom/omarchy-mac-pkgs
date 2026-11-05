#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 -B - "$ROOT/lib/touchid-policy" <<'PY'
from pathlib import Path
import importlib.machinery, importlib.util, json, sys, tempfile
loader=importlib.machinery.SourceFileLoader('policy',sys.argv[1]);spec=importlib.util.spec_from_loader(loader.name,loader);p=importlib.util.module_from_spec(spec);loader.exec_module(p)
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp);options=root/'options.conf';driver=root/'apple_sep';diag=driver/'28.sep/diag';diag.mkdir(parents=True)
 parameters=root/'module/parameters';parameters.mkdir(parents=True);(parameters/'sensor_spi_mode').write_text('0\n')
 options.write_text('options apple_sep '+' '.join(k+'='+v for k,v in p.EXPECTED.items())+'\n')
 values={**p.EXPECTED,'refkey_v2':'0','identity_override':'0','identity_source':'dt'}
 (diag/'policy').write_text(' '.join(k+'='+v for k,v in values.items())+'\n')
 result=p.report(options,driver,'',True)
 assert result['status']=='verified' and result['active']==values,result
 (diag/'policy').unlink();(diag/'xart').write_text('enabled\n');(diag/'xart_guard').write_text('1\n')
 log='apple_sep: xART guard level 1\napple_sep: writes ENABLED\napple_sep: xART: using /chosen/apfs-preboot-uuid\n'
 result=p.report(options,driver,log,True)
 assert result['status']=='partially-observed' and not result['mismatches'] and result['active']['identity_source']=='dt',result
 (diag/'xart').write_text('disabled\n')
 assert p.report(options,driver,log,True)['status']=='mismatch','cached contradictory evidence must beat old logs'
 (diag/'xart').unlink();(diag/'xart_guard').unlink()
 result=p.report(options,driver,'',True)
 assert result['status']=='partially-observed' and not result['mismatches'],'absence is not contradiction'
 result=p.report(options,driver,'apple_sep: using explicit OS UUID DO-NOT-OUTPUT',True)
 assert result['status']=='mismatch' and 'DO-NOT-OUTPUT' not in json.dumps(result)
 options.write_text(options.read_text()+'options apple_sep os_uuid_hi=0x123456789 os_uuid_lo=0 refkey_v2=1\n')
 result=p.report(options,driver,'',True)
 assert result['status']=='mismatch' and '123456789' not in json.dumps(result)
 options.write_text('options apple_sep xart_writes=1 provision_keybag=1\n')
 assert p.report(options,driver,'')['status']=='observed','normal first-time profile stays unchanged'
print('ok - cached policy, old-ABI diagnostics/logs and missing parameter files stay distinct; no identity values leaked')
PY
