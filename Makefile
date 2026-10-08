# One entry point for the C and Fortran translations. Keep C as the default
# when both source sets exist and no compiler/language has been selected.
.DEFAULT_GOAL := all
BENCH_LANG ?= auto
# LANGUAGE is accepted as a command-line alias, without reading locale settings.
ifeq ($(origin LANGUAGE),command line)
BENCH_LANG := $(LANGUAGE)
endif

USER_CC := $(if $(filter command line environment override,$(origin CC)),$(strip $(CC)))
USER_FC := $(if $(filter command line environment override,$(origin FC)),$(strip $(FC)))
COMPILER_NAME = $(notdir $(lastword $(1)))
compiler_language = $(if $(filter gfortran gfortran-% nvfortran ifort ifx flang flang-new flang-% amdflang ftn,$(call COMPILER_NAME,$(1))),fortran,$(if $(filter cc gcc gcc-% nvc clang clang-% amdclang icc icx,$(call COMPILER_NAME,$(1))),c))
config_language = $(if $(filter Makefile.defs.gfortran Makefile.defs.nvfortran,$(notdir $(1))),fortran,$(if $(filter Makefile.defs.nvc Makefile.defs.gcc Makefile.defs.clang Makefile.defs.aocc Makefile.defs.cray Makefile.defs.MI300X Makefile.defs.host,$(notdir $(1))),c))
COMPILER_LANGUAGE := $(call compiler_language,$(COMPILER))
CONFIG_LANGUAGE := $(call config_language,$(CONFIG))

ifeq ($(BENCH_LANG),auto)
ifneq ($(strip $(COMPILER)),)
ifeq ($(COMPILER_LANGUAGE),)
$(error Cannot infer the language of COMPILER=$(COMPILER); set BENCH_LANG=c or fortran)
endif
SELECTED_LANGUAGE := $(COMPILER_LANGUAGE)
else ifneq ($(strip $(USER_CC)$(USER_FC)),)
ifneq ($(strip $(USER_CC)),)
ifneq ($(strip $(USER_FC)),)
$(error Both CC and FC are set; select BENCH_LANG=c or fortran explicitly)
endif
SELECTED_LANGUAGE := c
else
SELECTED_LANGUAGE := fortran
endif
else ifneq ($(CONFIG_LANGUAGE),)
SELECTED_LANGUAGE := $(CONFIG_LANGUAGE)
else ifneq ($(wildcard src/microbenchmark.c),)
SELECTED_LANGUAGE := c
else ifneq ($(wildcard src/microbenchmark.F90),)
SELECTED_LANGUAGE := fortran
else
$(error No benchmark sources found in src/)
endif
else ifneq ($(filter $(BENCH_LANG),c fortran),)
SELECTED_LANGUAGE := $(BENCH_LANG)
else
$(error BENCH_LANG must be auto, c or fortran)
endif

ifneq ($(COMPILER_LANGUAGE),)
ifneq ($(COMPILER_LANGUAGE),$(SELECTED_LANGUAGE))
$(error COMPILER=$(COMPILER) conflicts with BENCH_LANG=$(SELECTED_LANGUAGE))
endif
endif
ifneq ($(CONFIG_LANGUAGE),)
ifneq ($(CONFIG_LANGUAGE),$(SELECTED_LANGUAGE))
$(error CONFIG=$(CONFIG) is for $(CONFIG_LANGUAGE), not $(SELECTED_LANGUAGE))
endif
endif

ifneq ($(strip $(COMPILER)),)
ifeq ($(SELECTED_LANGUAGE),fortran)
ifneq ($(USER_FC),)
ifneq ($(USER_FC),$(strip $(COMPILER)))
$(error COMPILER and FC select different compilers; set only one or make them match)
endif
endif
else
ifneq ($(USER_CC),)
ifneq ($(USER_CC),$(strip $(COMPILER)))
$(error COMPILER and CC select different compilers; set only one or make them match)
endif
endif
endif
endif

# Select a supplied toolchain profile, or accept an explicit/custom CONFIG.
ifeq ($(strip $(CONFIG)),)
ifeq ($(SELECTED_LANGUAGE),fortran)
REQUESTED_COMPILER := $(if $(strip $(COMPILER)),$(COMPILER),$(USER_FC))
ifneq ($(filter nvfortran,$(call COMPILER_NAME,$(REQUESTED_COMPILER))),)
CONFIG := Makefile.defs.nvfortran
else ifneq ($(filter gfortran gfortran-%,$(call COMPILER_NAME,$(REQUESTED_COMPILER))),)
CONFIG := Makefile.defs.gfortran
else ifeq ($(strip $(REQUESTED_COMPILER)),)
CONFIG := Makefile.defs.gfortran
else
$(error No supplied Fortran profile for $(REQUESTED_COMPILER); specify CONFIG)
endif
else
REQUESTED_COMPILER := $(if $(strip $(COMPILER)),$(COMPILER),$(USER_CC))
ifneq ($(filter gcc gcc-%,$(call COMPILER_NAME,$(REQUESTED_COMPILER))),)
CONFIG := Makefile.defs.gcc
else ifneq ($(filter clang clang-% amdclang,$(call COMPILER_NAME,$(REQUESTED_COMPILER))),)
CONFIG := Makefile.defs.clang
else ifneq ($(filter icc icx,$(call COMPILER_NAME,$(REQUESTED_COMPILER))),)
$(error No supplied C profile for $(REQUESTED_COMPILER); specify CONFIG)
else ifneq ($(filter cc nvc,$(call COMPILER_NAME,$(REQUESTED_COMPILER))),)
CONFIG := Makefile.defs.nvc
else ifeq ($(strip $(REQUESTED_COMPILER)),)
CONFIG := Makefile.defs.nvc
else
$(error No supplied C profile for $(REQUESTED_COMPILER); specify CONFIG)
endif
endif
endif
include $(CONFIG)

# Preserve explicit environment choices as well as command-line overrides.
ifneq ($(USER_CC),)
CC := $(USER_CC)
endif
ifneq ($(USER_FC),)
FC := $(USER_FC)
endif
ifneq ($(strip $(COMPILER)),)
ifeq ($(SELECTED_LANGUAGE),fortran)
FC := $(COMPILER)
else
CC := $(COMPILER)
endif
endif

ifeq ($(SELECTED_LANGUAGE),fortran)
SRC := src/common.f90 src/microbenchmark.F90
DRIVER := $(FC)
BUILD_FLAGS := $(FFLAGS)
FMOD_FLAG ?= -J
MODULE_OPTION = $(FMOD_FLAG) $(BUILD_DIR)/$(1)
else
SRC := src/microbenchmark.c src/common.c
DRIVER := $(CC)
# Preserve the original C flags. Some old profiles set CPPFLAGS=-E;
# the original recipe did not consume those preprocessing-only flags.
BUILD_FLAGS := $(CFLAGS)
endif
EFFECTIVE_LANGUAGE := $(call compiler_language,$(DRIVER))
ifneq ($(EFFECTIVE_LANGUAGE),)
ifneq ($(EFFECTIVE_LANGUAGE),$(SELECTED_LANGUAGE))
$(error Selected $(SELECTED_LANGUAGE) but compiler $(DRIVER) is for $(EFFECTIVE_LANGUAGE); use COMPILER or the matching CC/FC variable)
endif
endif

# Diagnose the two supplied Fortran compiler families before invoking either.
ifeq ($(SELECTED_LANGUAGE),fortran)
ifeq ($(notdir $(CONFIG)),Makefile.defs.nvfortran)
ifneq ($(filter gfortran gfortran-%,$(call COMPILER_NAME,$(DRIVER))),)
$(error CONFIG=$(CONFIG) requires nvfortran, not $(DRIVER); choose Makefile.defs.gfortran)
endif
else ifeq ($(notdir $(CONFIG)),Makefile.defs.gfortran)
ifneq ($(filter nvfortran,$(call COMPILER_NAME,$(DRIVER))),)
$(error CONFIG=$(CONFIG) requires gfortran, not $(DRIVER); choose Makefile.defs.nvfortran)
endif
endif
endif

BIN := microbenchmark
BIN_DISTRIBUTION := microbenchmark_distribution
BUILD_DIR := .build/$(SELECTED_LANGUAGE)

all: $(BIN)
# Always rebuild this small suite: language/compiler/flag switches cannot
# silently reuse the other language's binary. Separate module directories
# also avoid Fortran .mod races when all/distribution are built with make -j.
$(BIN): $(SRC) Makefile $(CONFIG) FORCE
	@mkdir -p $(BUILD_DIR)/normal
	@echo "Building $@ [$(SELECTED_LANGUAGE)] with $(DRIVER) ($(CONFIG))"
	$(DRIVER) $(BUILD_FLAGS) $(if $(filter fortran,$(SELECTED_LANGUAGE)),$(call MODULE_OPTION,normal)) $(SRC) $(LDFLAGS) $(LIBS) -o $(BUILD_DIR)/normal/$(BIN)
	cp $(BUILD_DIR)/normal/$(BIN) $@

$(BIN_DISTRIBUTION): $(SRC) Makefile $(CONFIG) FORCE
	@mkdir -p $(BUILD_DIR)/distribution
	@echo "Building $@ [$(SELECTED_LANGUAGE)] with $(DRIVER) ($(CONFIG))"
	$(DRIVER) $(BUILD_FLAGS) $(if $(filter fortran,$(SELECTED_LANGUAGE)),$(call MODULE_OPTION,distribution)) -DPRINT_DISTRIBUTION $(SRC) $(LDFLAGS) $(LIBS) -o $(BUILD_DIR)/distribution/$(BIN_DISTRIBUTION)
	cp $(BUILD_DIR)/distribution/$(BIN_DISTRIBUTION) $@
distribution: $(BIN_DISTRIBUTION)

# Functional verification explicitly uses GNU compilers and CPU execution,
# independent of the selected GPU compiler/profile for production builds.
TEST_FC ?= gfortran
TEST_CC ?= gcc-14
check-build: src/common.f90 src/microbenchmark.F90
	@mkdir -p .build/fortran/check
	$(TEST_FC) -O0 -g -fopenmp -cpp -ffree-line-length-none -fcheck=all -Wall -Wextra -J .build/fortran/check src/common.f90 src/microbenchmark.F90 -lm -o .build/fortran/check/microbenchmark_check
	cp .build/fortran/check/microbenchmark_check microbenchmark_check
check:
	$(MAKE) BENCH_LANG=fortran CONFIG=Makefile.defs.gfortran COMPILER='$(TEST_FC)' FC='$(TEST_FC)' CC='$(TEST_CC)' FFLAGS='-O0 -fopenmp -cpp -ffree-line-length-none' FMOD_FLAG=-J LDFLAGS=-fopenmp LIBS=-lm all distribution check-build
	python3 tests/smoke.py
	TEST_FC='$(TEST_FC)' TEST_CC='$(TEST_CC)' python3 tests/semantics.py
	TEST_FC='$(TEST_FC)' TEST_CC='$(TEST_CC)' python3 tests/build.py

run_all: $(BIN)
	mkdir -p Output
	./$(BIN) Method=1,2,3,4,5,6,7,8,9,10,11 N=16384 thread_count=32 team_count=4 > Output/full_run_$(shell date +%Y%m%d_%H%M%S).out 2>&1
run_plot: $(BIN_DISTRIBUTION)
	./$(BIN_DISTRIBUTION) Method=5,6,10,11 N=16384 thread_count=32 team_count=4

show-config:
	@echo "language=$(SELECTED_LANGUAGE)"
	@echo "compiler=$(DRIVER)"
	@echo "config=$(CONFIG)"
	@echo "flags=$(BUILD_FLAGS)"
help:
	@echo "make [BENCH_LANG=auto|c|fortran] [COMPILER=...] [CONFIG=Makefile.defs.*] <target>"
	@echo "Explicit FC/CC or a supplied CONFIG also selects the language automatically."
	@echo "Both source sets, no selection: C (original NVHPC profile)."
	@echo "Targets: all distribution run_all run_plot show-config check check-build clean"
	@echo "Examples: make BENCH_LANG=fortran; make COMPILER=nvfortran distribution"
	@echo "          make CONFIG=Makefile.defs.host; make FC=gfortran show-config"
clean:
	rm -rf .build
	rm -f $(BIN) $(BIN_DISTRIBUTION) microbenchmark_check *.mod *.o
	rm -rf $(BIN).dSYM $(BIN_DISTRIBUTION).dSYM microbenchmark_check.dSYM
FORCE:
.PHONY: all distribution check check-build run_all run_plot show-config help clean FORCE
