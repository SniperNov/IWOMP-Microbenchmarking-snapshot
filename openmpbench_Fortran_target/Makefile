FC = gfortran
FFLAGS = -O0 -fopenmp -cpp -ffree-line-length-none
LDFLAGS =
SRC = src/common.f90 src/microbenchmark.F90

all: microbenchmark
microbenchmark: $(SRC) Makefile
	$(FC) $(FFLAGS) $(SRC) $(LDFLAGS) -o $@
distribution: $(SRC) Makefile
	$(FC) $(FFLAGS) -DPRINT_DISTRIBUTION $(SRC) $(LDFLAGS) -o microbenchmark_distribution
check-build: $(SRC) Makefile
	$(FC) -O0 -g -fopenmp -cpp -ffree-line-length-none -fcheck=all -Wall -Wextra $(SRC) $(LDFLAGS) -o microbenchmark_check
clean:
	rm -f microbenchmark microbenchmark_distribution microbenchmark_check *.mod *.o
.PHONY: all distribution check-build clean

check: all distribution check-build
	python3 tests/smoke.py
	python3 tests/semantics.py
.PHONY: check
