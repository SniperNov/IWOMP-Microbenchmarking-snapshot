#!/usr/bin/env python3
"""CPU functional smoke test; run after make distribution check-build."""
import csv
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
env = dict(os.environ, OMP_TARGET_OFFLOAD='DISABLED', OMP_NUM_THREADS='2', OMP_THREAD_LIMIT='2')
args = ['--allow-host', 'N=2', 'Delay=1,4', 'thread_count=2', 'team_count=2']
with tempfile.TemporaryDirectory(prefix='fortran-target-') as work:
    for binary in ('microbenchmark_check', 'microbenchmark_distribution'):
        result = subprocess.run([str(root / binary), *args], cwd=work, env=env,
                                capture_output=True, text=True, check=True)
        assert 'Finalizing benchmark.' in result.stdout
        with open(Path(work) / 'raw_times.csv') as f:
            rows = list(csv.DictReader(f))
        assert len(rows) == 12 * 2 * 5 * 20
        # Rounded delay labels are not unique; validate counts per run instead.
        assert {int(r['method_id']) for r in rows} == set(range(12))
        for m in range(12):
            for s in range(2):
                for r in range(5):
                    group = [x for x in rows if (int(x['method_id']),int(x['set']),int(x['run'])) == (m,s,r)]
                    assert len(group) == 20
        assert all(math.isfinite(float(r['exec_time_us'])) and float(r['exec_time_us']) >= 0 for r in rows)
    # CSV stores rounded x; reconstruct the original shuffled floating x for independent regression.
    x = [2 ** (i * 2 / 19) for i in range(20)]
    fits = []
    for m in range(12):
        intercepts, minima = [], []
        for s in range(2):
            for r in range(5):
                perm = list(range(20)); seed = 12345 + 97*s + 1009*(r+1)
                for i in range(19,0,-1):
                    seed = (1664525*seed + 1013904223) % 2**32
                    j = seed % (i+1); perm[i],perm[j] = perm[j],perm[i]
                group = [v for v in rows if (int(v['method_id']),int(v['set']),int(v['run'])) == (m,s,r)]
                y = [0.0]*20
                for logical, row in zip(perm,group):
                    y[logical] = float(row['exec_time_us'])
                    assert abs(float(row['delaylength'])-x[logical]) <= 0.5
                best = (math.inf,0)
                for k in range(11):
                    xx, yy = x[k:],y[k:]; n = len(xx)
                    sx,sy = sum(xx),sum(yy)
                    denom = n*sum(v*v for v in xx)-sx*sx
                    b = (n*sum(v*w for v,w in zip(xx,yy))-sx*sy)/denom
                    a = (sy-b*sx)/n
                    rss = sum((v-(a+b*w))**2 for v,w in zip(yy,xx))
                    if rss <= 0: continue
                    bic = n*math.log(rss/n)+2*math.log(n)
                    if bic < best[0]: best = (bic,a)
                intercepts.append(best[1]); minima.append(min(y))
        fits.append((statistics.mean(intercepts),statistics.stdev(intercepts),
                     statistics.mean(minima),statistics.stdev(minima)))
    text = (Path(work)/'overhead_distribution.txt').read_text()
    reported = re.findall(r'Average Intercept =\s*([\d.+-]+) ±\s*([\d.+-]+) us\s*Average Lowest\s*=\s*([\d.+-]+) ±\s*([\d.+-]+)',text)
    assert len(reported)==12
    for expected,actual in zip(fits,reported):
        assert all(abs(e-float(a)) < 2e-5 for e,a in zip(expected,actual)), (expected,actual)
    for bad in ('Method=12','N=0','Delay=0,4','Delay=2,2','N=','thread_count=0','Unknown=2'):
        result = subprocess.run([str(root/'microbenchmark'),bad],cwd=work,env=env,capture_output=True)
        assert result.returncode != 0, bad
    result = subprocess.run([str(root/'microbenchmark'),'Method=0'],cwd=work,env=env,capture_output=True,text=True,check=True)
    assert 'Target region executed on host. Terminating' in result.stdout
print('PASS: both builds, all 12 methods, 2400 samples per build, independent BIC/minimum statistics, invalid arguments, host guard')
