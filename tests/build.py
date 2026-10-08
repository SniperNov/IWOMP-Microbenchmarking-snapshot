#!/usr/bin/env python3
"""Verify the shared build interface in an isolated source copy.

GPU profiles are inspected without invoking their compilers. Actual GNU builds
stop at the existing host-device guard, before any benchmark measurement.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
fc = os.environ.get('TEST_FC', 'gfortran')
cc = os.environ.get('TEST_CC', 'gcc-14')
for compiler in (fc, cc):
    words = shlex.split(compiler)
    if not words or not shutil.which(words[0]):
        raise SystemExit('Set TEST_FC and TEST_CC to installed GNU OpenMP compilers')

# Selection tests must not inherit a caller's compiler or locale preference.
env = dict(os.environ)
for variable in ('CC', 'FC', 'COMPILER', 'CONFIG', 'BENCH_LANG', 'LANGUAGE',
                 'CFLAGS', 'FFLAGS', 'CPPFLAGS', 'LDFLAGS', 'LIBS', 'FMOD_FLAG',
                 'MAKEFLAGS', 'MFLAGS', 'MAKELEVEL', 'MAKEOVERRIDES'):
    env.pop(variable, None)
env.update(OMP_TARGET_OFFLOAD='DISABLED', OMP_NUM_THREADS='1', OMP_THREAD_LIMIT='1')


with tempfile.TemporaryDirectory(prefix='benchmark-build-interface-') as directory:
    work = Path(directory)
    shutil.copytree(root / 'src', work / 'src')
    shutil.copy2(root / 'Makefile', work / 'Makefile')
    for profile in root.glob('Makefile.defs.*'):
        shutil.copy2(profile, work / profile.name)

    def run(command, overrides=None, timeout=90):
        result = subprocess.run(command, cwd=work, env=dict(env, **(overrides or {})),
                                capture_output=True, text=True, timeout=timeout)
        return result, result.stdout + result.stderr

    def make(*arguments, overrides=None, error=None):
        result, output = run(['make', *arguments], overrides)
        if error is None:
            assert result.returncode == 0, (arguments, output)
        else:
            assert result.returncode != 0 and error in output, (arguments, output)
        return output

    def selection(arguments, language, compiler, profile, overrides=None):
        output = make('-s', *arguments, 'show-config', overrides=overrides)
        values = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
        assert values.get('language') == language, (arguments, output)
        assert values.get('compiler') == compiler, (arguments, output)
        assert values.get('config') == profile, (arguments, output)
        return values

    # Built-in CC=cc and FC=f77 must not count as an explicit choice.
    default = selection([], 'c', 'nvc', 'Makefile.defs.nvc')
    assert default['flags'] == '-mp=gpu -O0', default
    dry = make('-n', 'all', 'distribution')
    assert 'nvc -mp=gpu -O0' in dry and 'src/microbenchmark.c' in dry, dry
    assert 'src/microbenchmark.F90' not in dry, dry

    selection(['BENCH_LANG=c'], 'c', 'nvc', 'Makefile.defs.nvc')
    selection(['BENCH_LANG=fortran'], 'fortran', 'gfortran', 'Makefile.defs.gfortran')
    selection(['LANGUAGE=fortran'], 'fortran', 'gfortran', 'Makefile.defs.gfortran')
    selection(['COMPILER=gfortran'], 'fortran', 'gfortran', 'Makefile.defs.gfortran')
    selection(['COMPILER=nvfortran'], 'fortran', 'nvfortran', 'Makefile.defs.nvfortran')
    selection(['FC=gfortran'], 'fortran', 'gfortran', 'Makefile.defs.gfortran')
    selection(['CONFIG=Makefile.defs.gfortran'], 'fortran', 'gfortran', 'Makefile.defs.gfortran')
    selection(['CONFIG=Makefile.defs.nvfortran'], 'fortran', 'nvfortran', 'Makefile.defs.nvfortran')
    selection(['CONFIG=Makefile.defs.host'], 'c', 'gcc', 'Makefile.defs.host')
    selection(['CONFIG=Makefile.defs.gcc'], 'c', 'cc', 'Makefile.defs.gcc')
    gpu = make('-n', 'COMPILER=nvfortran', 'all', 'distribution')
    assert '-mp=gpu' in gpu and '-Mpreprocess' in gpu and '-Mfree' in gpu, gpu
    assert 'src/microbenchmark.F90' in gpu and '-DPRINT_DISTRIBUTION' in gpu, gpu

    # Includes must preserve explicit environment compiler choices.
    selection([], 'fortran', fc, 'Makefile.defs.gfortran', overrides={'FC': fc})
    selection(['CONFIG=Makefile.defs.host'], 'c', cc, 'Makefile.defs.host', overrides={'CC': cc})
    selection([], 'c', 'nvc', 'Makefile.defs.nvc', overrides={'LANGUAGE': 'fr_FR:fr'})
    selection(['BENCH_LANG=c', 'CONFIG=Makefile.defs.host', f'CC={cc}', f'FC={fc}'],
              'c', cc, 'Makefile.defs.host')

    make(f'CC={cc}', f'FC={fc}', 'show-config', error='Both CC and FC')
    make('BENCH_LANG=c', 'COMPILER=gfortran', 'show-config', error='conflicts')
    make('BENCH_LANG=fortran', 'CONFIG=Makefile.defs.nvc', 'show-config', error='not fortran')
    make('BENCH_LANG=c', 'CONFIG=Makefile.defs.gfortran', 'show-config', error='not c')
    make('CONFIG=Makefile.defs.nvfortran', 'COMPILER=gfortran', 'show-config', error='requires nvfortran')
    make('CONFIG=Makefile.defs.gfortran', 'COMPILER=nvfortran', 'show-config', error='requires gfortran')
    make('BENCH_LANG=python', 'show-config', error='BENCH_LANG must be')
    make('COMPILER=custom-wrapper', 'show-config', error='Cannot infer')
    make('FC=custom-wrapper', 'show-config', error='specify CONFIG')
    make('COMPILER=nvfortran', 'FC=gfortran', 'show-config', error='different compilers')
    selection(['BENCH_LANG=fortran', 'CONFIG=Makefile.defs.gfortran', 'COMPILER=custom-wrapper'],
              'fortran', 'custom-wrapper', 'Makefile.defs.gfortran')

    def host_guard(language):
        for binary in ('microbenchmark', 'microbenchmark_distribution'):
            result, output = run([str(work / binary), 'Method=0', 'N=2', 'Delay=1,4',
                                  'thread_count=1', 'team_count=1'], timeout=20)
            assert result.returncode == 0, (binary, output)
            if language == 'fortran':
                assert 'Terminating (use --allow-host only for smoke tests).' in output, output
            else:
                assert 'Target region executed on host. Terminating...' in output, output
                assert '--allow-host' not in output, output
            assert 'Initializing benchmark' not in output, output
        assert not (work / 'raw_times.csv').exists(), 'Host guard must precede measurement'

    c_arguments = ['BENCH_LANG=c', 'CONFIG=Makefile.defs.host', f'CC={cc}']
    fortran_arguments = ['BENCH_LANG=fortran', 'CONFIG=Makefile.defs.gfortran', f'FC={fc}']
    # Build both modes concurrently, then repeatedly overwrite the same public
    # executable names with the other language and verify which program runs.
    for language, arguments in (('c', c_arguments), ('fortran', fortran_arguments),
                                ('c', c_arguments), ('fortran', fortran_arguments)):
        output = make('-j2', *arguments, 'all', 'distribution')
        assert f'Building microbenchmark [{language}]' in output, output
        assert f'Building microbenchmark_distribution [{language}]' in output, output
        host_guard(language)
    for mode in ('normal', 'distribution'):
        modules = {path.name for path in (work / '.build' / 'fortran' / mode).glob('*.mod')}
        assert {'benchmark_common.mod', 'target_benchmark.mod'} <= modules, (mode, modules)
        assert (work / '.build' / 'c' / mode).is_dir()
    assert not list(work.glob('*.mod')), 'Fortran modules must stay in their mode directories'

    before = (work / 'microbenchmark').stat().st_mtime_ns
    changed_flags = '-O0 -fopenmp -cpp -ffree-line-length-none -DBUILD_INTERFACE_FLAG=1'
    output = make(*fortran_arguments, f'FFLAGS={changed_flags}', 'all')
    assert '-DBUILD_INTERFACE_FLAG=1' in output, output
    assert (work / 'microbenchmark').stat().st_mtime_ns > before, output
    host_guard('fortran')

    # A relative compiler wrapper must resolve from the repository root.
    toolchain = work / 'toolchain'
    toolchain.mkdir()
    wrapper = toolchain / 'gfortran'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(shlex.split(fc)) + ' "$@"\n')
    wrapper.chmod(0o755)
    make('COMPILER=./toolchain/gfortran', 'all')
    host_guard('fortran')

print('PASS: build selection/errors, environment overrides, GNU parallel builds, '
      'language switching, isolated modules, flag rebuilds, relative compiler path; no measurements')
