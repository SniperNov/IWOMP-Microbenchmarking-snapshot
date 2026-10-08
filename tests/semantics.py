#!/usr/bin/env python3
"""Compare host execution against the C combined branch; never edits the snapshot.

Checks use a small harness-controlled workload and deterministic sentinels.
Temporary instrumented copies inspect tmp only after timing/data copy-out.
This is functional equivalence, not GPU transfer/performance validation.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
croot = root / 'src'
fc = shlex.split(os.environ.get('TEST_FC', 'gfortran'))
cc = shlex.split(os.environ.get('TEST_CC', 'gcc-14'))
if not shutil.which(fc[0]) or not shutil.which(cc[0]):
    raise SystemExit('Set TEST_FC and TEST_CC to GNU Fortran/C compilers supporting OpenMP')
env = dict(os.environ, OMP_TARGET_OFFLOAD='DISABLED', OMP_NUM_THREADS='2', OMP_THREAD_LIMIT='2', OMP_DYNAMIC='FALSE')
with tempfile.TemporaryDirectory(prefix='fortran-c-semantics-') as directory:
    work = Path(directory)
    source = (root/'src/microbenchmark.F90').read_text().split('\nprogram microbenchmark\n')[0]
    source = source.replace('          deallocate(tmp)', '''          if (method==8 .or. method==9) then
            do i=0,n-1
              if (tmp(i)/=real(innerreps*(workload/n+merge(1,0,i<modulo(workload,n))),real64)) &
                error stop 'Incorrect atomic/reduction bucket'
            end do
          end if
          deallocate(tmp)''')
    (work/'target.F90').write_text(source)
    (work/'driver.f90').write_text('''program check_semantics
  use target_benchmark
  implicit none
  real(real64) :: a(0:32)
  integer :: m,n,threads,teams,i,scenario
  integer, parameter :: lower(3)=[1,3,1], upper(3)=[8096,1572864,8192]
  g_max_array_size=33; g_max_iter=17
  g_min_delaylength=3; g_max_delaylength=19
  do threads=1,2
    do teams=1,2
    do n=2,3
      do m=0,11
        a=7.0_real64
        call device_target(m,0,-1,a,n,threads,teams)
        write(*,'(a,4(i0,1x),33(f0.0,1x))') 'K ',m,n,threads,teams,a
      end do
    end do
  end do
  end do
  do scenario=1,3
    g_min_delaylength=lower(scenario); g_max_delaylength=upper(scenario)
    call sample_delays()
    do i=1,num_samples
      write(*,'(a,4(i0,1x),es26.17e3)') 'S ',g_min_delaylength,g_max_delaylength,i-1,int(delays(i)),delays(i)
    end do
  end do
end program
''')
    csource = (croot/'microbenchmark.c').read_text().replace('                free(tmp);', '''                if (method == 8 || method == 9) {
                    for (int j=0; j<N; j++) {
                        double expected=INNERREPS*(g_max_iter/N+(j<g_max_iter%N));
                        if (tmp[j]!=expected) { fprintf(stderr,"Incorrect atomic/reduction bucket\\n"); exit(2); }
                    }
                }
                free(tmp);''')
    (work/'snapshot.c').write_text(csource)
    sampling = csource[csource.index('    double log_min ='):csource.index('    // Create a shuffled order')]
    (work/'sampling.inc').write_text(sampling)
    (work/'driver.c').write_text('''#define main unused_snapshot_main
#include "snapshot.c"
#undef main
void sample_only(void) {
#include "sampling.inc"
}
int main(void) {
  double a[33];
  g_max_array_size=33; g_max_iter=17;
  g_min_delaylength=3; g_max_delaylength=19;
  for (int threads=1; threads<=2; threads++) {
  for (int teams=1; teams<=2; teams++) {
    for (int n=2; n<=3; n++) {
      for (int m=0; m<12; m++) {
        for (int i=0; i<33; i++) a[i]=7.0;
        device_target(m,0,-1,a,n,threads,teams);
        printf("K %d %d %d %d ",m,n,threads,teams);
        for (int i=0; i<33; i++) printf("%.0f ",a[i]);
        puts("");
      }
    }
  }
  }
  int lower[]={1,3,1}, upper[]={8096,1572864,8192};
  for(int scenario=0;scenario<3;scenario++) {
    g_min_delaylength=lower[scenario]; g_max_delaylength=upper[scenario];
    sample_only();
    for(int i=0;i<NUM_SAMPLES;i++)
      printf("S %d %d %d %d %.17g\\n",g_min_delaylength,g_max_delaylength,i,(int)delays[i],delays[i]);
  }
}
''')
    subprocess.run([*fc,'-O0','-fopenmp','-cpp','-ffree-line-length-none','-fcheck=all',
                    str(root/'src/common.f90'),'target.F90','driver.f90','-o','fcheck'],cwd=work,check=True)
    # __NVCOMPILER selects the snapshot's combined Method6/9 source branch only.
    # GCC is the compiler; this neither simulates NVHPC codegen nor verifies other C branches.
    subprocess.run([*cc,'-O0','-fopenmp','-D__NVCOMPILER','-I'+str(croot),
                    'driver.c',str(croot/'common.c'),'-lm','-o','ccheck'],cwd=work,check=True)
    outputs = []
    for binary in ('ccheck','fcheck'):
        result = subprocess.run([str(work/binary)],cwd=work,env=env,capture_output=True,text=True,check=True)
        outputs.append([[line[0],*map(float,line.split()[1:])] for line in result.stdout.splitlines()])
    assert len(outputs[0])==len(outputs[1])==156
    assert outputs[0]==outputs[1], 'C and Fortran final array values differ'
print('PASS: C/Fortran kernel and index equivalence for 12 methods × 2 N × 2 thread counts × 2 team counts; every atomic/reduction bucket; exact delays/truncation for 3 ranges')
