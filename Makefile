MODULE_big = oracle_fdw
OBJS = oracle_fdw.o oracle_utils.o oracle_gis.o
EXTENSION = oracle_fdw
DATA = oracle_fdw--1.2.sql oracle_fdw--1.0--1.1.sql oracle_fdw--1.1--1.2.sql
DOCS = README.oracle_fdw
REGRESS = oracle_fdw oracle_gis oracle_import oracle_join
REGRESS_PYTHON ?= python3
REGRESS_LABELS ?=
REGRESS_TMP = $(CURDIR)/regress-tmp
REGRESS_OUTPUTDIR ?= $(REGRESS_TMP)
REGRESS_PREP += regress-tmp
EXTRA_CLEAN += $(REGRESS_TMP)

# try to find Instant Client installations installed in standard paths
FIND_INCLUDE := $(wildcard /usr/include/oracle/*/client64 /usr/include/oracle/*/client)
FIND_LIBDIRS := $(wildcard /usr/lib/oracle/*/client64/lib /usr/lib/oracle/*/client/lib)

FIND_CPPFLAGS = $(foreach DIR,$(FIND_INCLUDE),-I$(DIR))
FIND_LDFLAGS = $(foreach DIR,$(FIND_LIBDIRS),-L$(DIR))

# add include and library paths for both Instant Client and regular Client
PG_CPPFLAGS = -I"$(ORACLE_HOME)/sdk/include" -I"$(ORACLE_HOME)/oci/include" -I"$(ORACLE_HOME)/rdbms/public" -I"$(ORACLE_HOME)/" $(FIND_CPPFLAGS)
SHLIB_LINK = -L"$(ORACLE_HOME)/" -L"$(ORACLE_HOME)/bin" -L"$(ORACLE_HOME)/lib" -L"$(ORACLE_HOME)/lib/amd64" $(FIND_LDFLAGS) -l$(ORACLE_SHLIB)

# don't build LLVM byte code
override with_llvm := no

ifdef NO_PGXS
subdir = contrib/oracle_fdw
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
else
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
endif

# Use expectations generated before pg_regress starts.
override REGRESS_OPTS += --inputdir="$(REGRESS_TMP)" \
 --outputdir="$(REGRESS_OUTPUTDIR)"

# PostgreSQL 16 added --expecteddir and changed the expected-file search order.
# Older versions find the generated expectations through --inputdir.
ifneq ($(shell test $(firstword $(subst ., ,$(MAJORVERSION))) -ge 16 && echo yes),)
override REGRESS_OPTS += --expecteddir="$(REGRESS_TMP)"
endif

# Oracle's shared library is oci.dll on Windows and libclntsh elsewhere
ifeq ($(PORTNAME),win32)
ORACLE_SHLIB=oci
else
ifeq ($(PORTNAME),cygwin)
ORACLE_SHLIB=oci
else
ORACLE_SHLIB=clntsh
endif
endif

# Rebuild expectations for the selected labels and remove stale files.
.PHONY: regress-tmp
regress-tmp:
	rm -rf "$(REGRESS_TMP)"
	$(MKDIR_P) "$(REGRESS_TMP)/expected"
	$(MKDIR_P) "$(REGRESS_TMP)/sql"
	$(MKDIR_P) "$(REGRESS_OUTPUTDIR)"
	$(REGRESS_PYTHON) "$(srcdir)/test/regress.py" "$(srcdir)/expected" "$(REGRESS_TMP)/expected" $(REGRESS_LABELS)
	cp "$(srcdir)"/sql/*.sql "$(REGRESS_TMP)/sql/"
