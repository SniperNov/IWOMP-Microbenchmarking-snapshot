module target_benchmark
  use iso_fortran_env, only: real64, int64, error_unit
  use iso_c_binding, only: c_double
  use omp_lib
  use, intrinsic :: ieee_arithmetic, only: ieee_value, ieee_positive_inf
  use benchmark_common
  implicit none
  integer, parameter :: num_samples=20, innerreps=20, outerreps=1, warmup_iterations=10
  integer, parameter :: benchmark_sets=2, benchmark_runs=5, num_methods=12, num_sizes=16
  integer, parameter :: max_iter_def=6656, max_array_size_def=65536, n_def=16382
  integer :: g_max_iter=max_iter_def, g_max_array_size=max_array_size_def
  integer :: g_min_delaylength=1, g_max_delaylength=8096
  character(32), parameter :: method_names(0:11) = [character(32) :: &
    'pure delay kernel', 'map(tofrom: a)', 'map(to: a)', 'map(from: a)', 'map(alloc: a)', &
    'teams (scalar)', 'teams distribute parallel for', 'nowait', 'teams atomic', &
    'teams reduction', 'teams parallel', 'teams + parallel inside']
  real(real64) :: delays(num_samples)
  real(real64) :: execution_times(num_samples,outerreps,benchmark_runs,benchmark_sets)
  ! Host-only standard libm calls preserve the C snapshot's delay samples at integer boundaries.
  interface
    function host_log2(x) bind(C, name='log2') result(y)
      import c_double
      real(c_double), value :: x
      real(c_double) :: y
    end function
    function host_pow(x, exponent) bind(C, name='pow') result(y)
      import c_double
      real(c_double), value :: x, exponent
      real(c_double) :: y
    end function
  end interface
contains
  subroutine fail(message)
    character(*), intent(in) :: message
    write(error_unit,'(a)') 'ERROR: '//message
    stop 1
  end subroutine

  function lowercase(s) result(out)
    character(*), intent(in) :: s
    character(len(s)) :: out
    integer :: i, c
    out=s
    do i=1,len(s)
      c=iachar(s(i:i))
      if (c>=65 .and. c<=90) out(i:i)=achar(c+32)
    end do
  end function

  subroutine parse_list(s, values, count)
    character(*), intent(in) :: s
    integer, intent(out) :: values(:), count
    integer :: first, last, relative, ios, i
    count=0
    first=1
    if (len_trim(s)==0) call fail('Empty argument list')
    do
      relative=index(s(first:),',')
      last=len_trim(s)
      if (relative>0) last=first+relative-2
      if (last<first .or. count==size(values)) call fail('Empty item or too many list values')
      do i=first,last
        if (index('0123456789',s(i:i))==0) call fail('Expected a nonnegative integer: '//s)
      end do
      count=count+1
      read(s(first:last),*,iostat=ios) values(count)
      if (ios/=0) call fail('Integer out of range: '//s)
      if (relative==0) exit
      first=last+2
      if (first>len_trim(s)) call fail('Trailing comma')
    end do
  end subroutine

  subroutine shuffle_indices_local(perm, seed_in)
    integer, intent(out) :: perm(num_samples)
    integer(int64), intent(in) :: seed_in
    integer(int64) :: seed
    integer :: i,j,t
    seed=seed_in
    if (seed==0) seed=12345
    do i=1,num_samples
      perm(i)=i
    end do
    do i=num_samples,2,-1
      ! Explicit modulo 2**32 reproduces C unsigned arithmetic without signed overflow.
      seed=modulo(1664525_int64*seed+1013904223_int64,4294967296_int64)
      j=int(modulo(seed,int(i,int64)))+1
      t=perm(i); perm(i)=perm(j); perm(j)=t
    end do
  end subroutine

  subroutine sample_delays()
    real(real64) :: log_min, log_max, ratio, log_value
    integer :: i
    log_min=host_log2(real(g_min_delaylength,c_double))
    log_max=host_log2(real(g_max_delaylength,c_double))
    do i=1,num_samples
      if (i==1) then
        delays(i)=real(g_min_delaylength,real64)
      else if (i==num_samples) then
        delays(i)=real(g_max_delaylength,real64)
      else
        ratio=real(i-1,real64)/real(num_samples-1,real64)
        log_value=log_min+(log_max-log_min)*ratio
        delays(i)=host_pow(2.0_c_double,log_value)
      end if
    end do
  end subroutine

  subroutine device_target(method, set, run, a, n, thread_count, team_count)
    integer, intent(in) :: method,set,run,n,thread_count,team_count
    ! Explicit shape avoids transferring assumed-shape offset/stride metadata per target launch.
    real(real64), intent(inout) :: a(0:g_max_array_size-1)
    real(real64), allocatable :: tmp(:)
    real(real64) :: start, finish, elapsed_us, delay
    integer :: perm(num_samples), logical, sidx, orep, rep, i, r, idx, team_id, stride, unit
    ! Local scalars are explicitly firstprivate on target regions; module globals are host configuration.
    integer :: workload, array_size
    workload=g_max_iter; array_size=g_max_array_size
    call sample_delays()
    call shuffle_indices_local(perm,12345_int64+97_int64*set+1009_int64*(run+1))
    do sidx=1,num_samples
      logical=perm(sidx)
      ! Match C: transfer the real delay, convert at the device call, and fit against the unrounded value.
      delay=delays(logical)
      do orep=1,outerreps
        if (method>=1 .and. method<=4) then
          start=omp_get_wtime()
          do rep=1,innerreps
            select case(method)
            case(1)
              !$omp target map(tofrom:a(0:n-1)) firstprivate(delay)
              call delay_kernel(int(delay),a(0))
              !$omp end target
            case(2)
              !$omp target map(to:a(0:n-1)) firstprivate(delay)
              call delay_kernel(int(delay),a(0))
              !$omp end target
            case(3)
              !$omp target map(from:a(0:n-1)) firstprivate(delay)
              call delay_kernel(int(delay),a(0))
              !$omp end target
            case(4)
              !$omp target map(alloc:a(0:n-1)) firstprivate(delay)
              call delay_kernel(int(delay),a(0))
              !$omp end target
            end select
            a(0)=a(0)+1.0_real64
            if (a(0)<0) print *, a(0)
          end do
          finish=omp_get_wtime()
        else
          allocate(tmp(0:n-1)); tmp=0.0_real64
          !$omp target data map(tofrom:a(0:array_size-1),tmp(0:n-1))
          start=omp_get_wtime()
          do rep=1,innerreps
            select case(method)
            case(0)
              !$omp target firstprivate(delay)
              call delay_kernel(int(delay),a(0))
              !$omp end target
            case(5)
              !$omp target teams num_teams(team_count) firstprivate(delay,array_size,team_count)
              call delay_kernel(int(delay),a(omp_get_team_num()*array_size/team_count))
              !$omp end target teams
            case(6)
              !$omp target teams distribute parallel do num_teams(team_count) thread_limit(thread_count) &
              !$omp& firstprivate(delay,workload)
              do i=0,workload-1
                call delay_kernel(int(delay),a(i))
              end do
              !$omp end target teams distribute parallel do
            case(7)
              !$omp target nowait firstprivate(delay)
              call delay_kernel(int(delay),a(0))
              !$omp end target
              !$omp taskwait
            case(8)
              !$omp target teams distribute parallel do firstprivate(delay,workload,n)
              do i=0,workload-1
                call delay_kernel(int(delay),a(i))
                !$omp atomic update
                tmp(modulo(i,n))=tmp(modulo(i,n))+1.0_real64
              end do
              !$omp end target teams distribute parallel do
            case(9)
              ! Whole tmp is the Fortran equivalent of the C tmp[0:N] array-section reduction.
              !$omp target teams distribute parallel do reduction(+:tmp) firstprivate(delay,workload,n)
              do i=0,workload-1
                call delay_kernel(int(delay),a(i))
                tmp(modulo(i,n))=tmp(modulo(i,n))+1.0_real64
              end do
              !$omp end target teams distribute parallel do
            case(10)
              !$omp target teams num_teams(team_count) thread_limit(thread_count) &
              !$omp& firstprivate(delay,array_size,team_count) private(team_id,stride)
              team_id=omp_get_team_num()
              stride=array_size/team_count
              !$omp parallel
              call delay_kernel(int(delay),a(team_id*stride+omp_get_thread_num()))
              !$omp end parallel
              !$omp end target teams
            case(11)
              !$omp target teams num_teams(team_count) thread_limit(thread_count) &
              !$omp& firstprivate(delay,n,thread_count,array_size) private(team_id,r)
              team_id=omp_get_team_num()
              do r=1,n
                !$omp parallel private(idx)
                idx=modulo(team_id*thread_count+omp_get_thread_num(),array_size)
                call delay_kernel(int(delay),a(idx))
                !$omp end parallel
              end do
              !$omp end target teams
            end select
            a(0)=a(0)+1.0_real64
            if (a(0)<0) print *, a(0)
          end do
          finish=omp_get_wtime()
          !$omp end target data
          deallocate(tmp)
        end if
        elapsed_us=(finish-start)*1.0e6_real64/innerreps
        if (run>=0) then
          execution_times(logical,orep,run+1,set+1)=elapsed_us
          open(newunit=unit,file='raw_times.csv',status='old',position='append',action='write')
          write(unit,'(i0,a,a,a,5(i0,a),f0.0,a,i0,a,f0.9)') method,',"',trim(method_names(method)),'",', &
            n,',',thread_count,',',team_count,',',set,',',run,',',delays(logical),',',orep-1,',',elapsed_us
          close(unit)
        end if
      end do
    end do
  end subroutine

  subroutine warmup_cache(method,n,threads,teams)
    integer, intent(in) :: method,n,threads,teams
    real(real64), allocatable :: a(:)
    integer :: i
    allocate(a(0:g_max_array_size-1)); a=0.0_real64
    do i=1,warmup_iterations
      call device_target(method,0,-1,a,n,threads,teams)
    end do
    deallocate(a)
  end subroutine

  subroutine compute_offloading_time(intercept_avg,intercept_err,min_avg,min_err,method,n)
    real(real64), intent(out) :: intercept_avg,intercept_err,min_avg,min_err
    integer, intent(in) :: method,n
    real(real64) :: intercepts(benchmark_sets*benchmark_runs), mins(benchmark_sets*benchmark_runs)
    real(real64) :: y(num_samples), sx,sy,sxx,sxy,denom,b,a,rss,tss,r2,bic
    real(real64) :: best_bic,best_a,best_b,best_r2, run_min, run_min_delay
    integer :: set,run,k,points,best_k,idx,unit,min_index
    if (method<0 .or. method>=num_methods .or. n<1) call fail('Invalid summary configuration')
    open(newunit=unit,file='overhead_distribution.txt',status='unknown',position='append',action='write')
#ifdef PRINT_DISTRIBUTION
    write(unit,'(/,a,i0,1x,a,a,i0,a)') '[Method=',method,trim(method_names(method)),' N=',n,']'
#endif
    idx=0
    do set=1,benchmark_sets
      do run=1,benchmark_runs
        y=sum(execution_times(:,:,run,set),dim=2)/outerreps
        min_index=minloc(y,dim=1); run_min=y(min_index); run_min_delay=delays(min_index)
        best_bic=ieee_value(0.0_real64,ieee_positive_inf); best_k=1; best_a=0; best_b=0; best_r2=0
        do k=1,num_samples-ceiling(num_samples*0.5_real64)+1
          points=num_samples-k+1
          sx=sum(delays(k:)); sy=sum(y(k:)); sxx=sum(delays(k:)**2); sxy=sum(delays(k:)*y(k:))
          denom=points*sxx-sx*sx
          if (denom<=0) cycle
          b=(points*sxy-sx*sy)/denom; a=(sy-b*sx)/points
          rss=sum((y(k:)-(a+b*delays(k:)))**2); tss=sum((y(k:)-sy/points)**2)
          if (rss<=0) cycle
          r2=1.0_real64
          if (tss>0) r2=1.0_real64-rss/tss
          bic=points*log(rss/points)+2*log(real(points,real64))
          if (bic<best_bic) then
            best_bic=bic; best_k=k; best_a=a; best_b=b; best_r2=r2
          end if
        end do
        idx=idx+1; intercepts(idx)=best_a; mins(idx)=run_min
#ifdef PRINT_DISTRIBUTION
        write(unit,'(a,i0,a,i0,a,f0.0,a,f0.6,a,f0.6,a,f0.5,a,f0.3,a,f0.6,a,f0.0)') &
          'Set=',set-1,' Run=',run-1,'  Lmin=',delays(best_k),'  Intercept=',best_a, &
          ' us  Slope=',best_b,'  R2=',best_r2,'  BIC=',best_bic,'  Lowest=',run_min,' us @ delay=',run_min_delay
#endif
      end do
    end do
    intercept_avg=sum(intercepts)/idx; min_avg=sum(mins)/idx
    intercept_err=sqrt(sum((intercepts-intercept_avg)**2)/(idx-1))
    min_err=sqrt(sum((mins-min_avg)**2)/(idx-1))
#ifdef PRINT_DISTRIBUTION
    write(unit,'(a,f0.6,a,f0.6,a)') 'Average Intercept = ',intercept_avg,' ± ',intercept_err,' us'
    write(unit,'(a,f0.6,a,f0.6,a)') 'Average Lowest    = ',min_avg,' ± ',min_err,' us'
#endif
    close(unit)
  end subroutine
end module

program microbenchmark
  use target_benchmark
  implicit none
  integer :: ns(num_sizes),threads(num_sizes),teams(num_sizes),methods(num_methods),bounds(2),single(1)
  integer :: nn,nt,nteams,nmethods,nb,i,eq,m,mi,t,tm,ni,set,run,unit,ios,maxprod
  character(4096) :: arg
  character(:), allocatable :: key,value
  logical :: allow_host,targetdev
  real(real64), allocatable :: a(:)
  real(real64) :: intercept,intercept_err,lowest,min_err
  nn=1; nt=1; nteams=1; nmethods=0
  ns(1)=n_def; threads(1)=32; teams(1)=max(1,4*omp_get_num_devices())
  allow_host=.false.
  do i=1,command_argument_count()
    call get_command_argument(i,arg)
    if (trim(arg)=='--allow-host') then
      allow_host=.true.; cycle
    end if
    eq=index(arg,'=')
    if (eq<=1) call fail('Expected key=value argument')
    key=lowercase(arg(:eq-1)); value=trim(arg(eq+1:))
    select case(key)
    case('method')
      call parse_list(value,methods,nmethods)
      if (any(methods(:nmethods)>11)) call fail('Method must be 0 through 11')
    case('n')
      call parse_list(value,ns,nn)
    case('thread_count')
      call parse_list(value,threads,nt)
    case('team_count')
      call parse_list(value,teams,nteams)
    case('delay')
      call parse_list(value,bounds,nb)
      g_min_delaylength=1; g_max_delaylength=bounds(1)
      if (nb==2) then
        g_min_delaylength=minval_int(bounds); g_max_delaylength=maxval(bounds)
      end if
    case('max_iter')
      call parse_list(value,single,nb); g_max_iter=single(1)
    case('max_array_size')
      call parse_list(value,single,nb); g_max_array_size=single(1)
    case default
      call fail('Unknown option: '//key)
    end select
  end do
  if (any(ns(:nn)<1) .or. any(threads(:nt)<1) .or. any(teams(:nteams)<1)) call fail('Sizes must be positive')
  if (g_min_delaylength<1 .or. g_max_delaylength<=g_min_delaylength) call fail('Delay requires 0 < min < max')
  if (int(maxval(threads(:nt)),int64)*maxval(teams(:nteams))>huge(maxprod)) call fail('threads*teams overflow')
  maxprod=maxval(threads(:nt))*maxval(teams(:nteams))
  g_max_iter=max(g_max_iter,max_iter_def,maxprod,maxval(ns(:nn)))
  g_max_array_size=max(g_max_array_size,max_array_size_def,maxprod,maxval(ns(:nn)))
  if (g_max_iter>g_max_array_size) call fail('MAX_ITER > MAX_ARRAY_SIZE; increase MAX_ARRAY_SIZE')
  if (nmethods==0) then
    nmethods=num_methods
    methods=[(i,i=0,11)]
  end if
  print '(a)', '========== Runtime Configuration =========='
  print *, 'Methods: ',methods(:nmethods)
  print *, 'Delay range: ',g_min_delaylength,g_max_delaylength
  print *, 'Array sizes: ',ns(:nn)
  print *, 'Thread counts: ',threads(:nt)
  print *, 'Team counts: ',teams(:nteams)
  print *, 'MAX_ITER: ',g_max_iter,' MAX_ARRAY_SIZE: ',g_max_array_size
  print *, 'NUM_SAMPLES:',num_samples,' INNERREPS:',innerreps,' OUTERREPS:',outerreps
  print *, 'WARMUP_ITERS:',warmup_iterations,' BENCHMARK_SETS:',benchmark_sets,' BENCHMARK_RUNS:',benchmark_runs
  !$omp target map(from:targetdev)
  targetdev=omp_is_initial_device()
  !$omp end target
  print *, 'Available devices: ',omp_get_num_devices(),' Host device: ',omp_get_initial_device()
  if (targetdev) then
    if (.not.allow_host) then
      print '(a)', 'Target region executed on host. Terminating (use --allow-host only for smoke tests).'
      stop
    end if
    print '(a)', 'HOST SMOKE TEST: these timings are not GPU offload measurements.'
  end if
  call init()
  open(newunit=unit,file='raw_times.csv',status='replace',action='write',iostat=ios)
  if (ios/=0) call fail('Cannot open raw_times.csv')
  write(unit,'(a)') 'method_id,method_name,N,thread_count,team_count,set,run,delaylength,outerreps,exec_time_us'
  close(unit)
  do mi=1,nmethods
    m=methods(mi)
    do t=1,nt
      do tm=1,nteams
        do ni=1,nn
          allocate(a(0:g_max_array_size-1),stat=ios)
          if (ios/=0) call fail('Allocation failed')
          ! Initialize host storage outside timing; the C snapshot uses malloc without initialization.
          a=0.0_real64
          call warmup_cache(m,ns(ni),threads(t),teams(tm))
          do set=0,benchmark_sets-1
            do run=0,benchmark_runs-1
              call device_target(m,set,run,a,ns(ni),threads(t),teams(tm))
            end do
          end do
          call compute_offloading_time(intercept,intercept_err,lowest,min_err,m,ns(ni))
          write(*,'(a,a,i0,a,i0,a,i0,a,f10.3,a,f10.3,a,f10.3,a,f10.3)') trim(method_names(m)), &
            ' N=',ns(ni),' threads=',threads(t),' teams=',teams(tm),' BIC intercept: ',intercept,' ± ', &
            intercept_err,' us | Lowest: ',lowest,' ± ',min_err
          deallocate(a)
        end do
      end do
    end do
  end do
  call finalise()
contains
  function minval_int(x) result(v)
    integer, intent(in) :: x(:)
    integer :: v
    v=minval(x)
  end function
end program
