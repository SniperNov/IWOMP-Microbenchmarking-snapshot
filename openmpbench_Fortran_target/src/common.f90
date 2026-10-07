module benchmark_common
  use iso_fortran_env, only: real64
  implicit none
contains
  subroutine init()
    print '(a)', 'Initializing benchmark runtime environment...'
  end subroutine

  subroutine delay_kernel(delaylength, value)
    !$omp declare target
    integer, intent(in) :: delaylength
    real(real64), intent(inout) :: value
    integer :: i
    value = 1.0_real64
    do i = 0, delaylength - 1
      value = value + real(i, real64)
    end do
    if (value < 0.0_real64) print *, value
  end subroutine

  subroutine finalise()
    print '(a)', 'Finalizing benchmark.'
  end subroutine
end module
