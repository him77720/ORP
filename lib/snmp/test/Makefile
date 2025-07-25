#-*-makefile-*-   ; force emacs to enter makefile-mode

# %CopyrightBegin%
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright Ericsson AB 1997-2025. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# %CopyrightEnd%

include $(ERL_TOP)/make/target.mk
include $(ERL_TOP)/make/$(TARGET)/otp.mk


# ----------------------------------------------------
# Application version
# ----------------------------------------------------
include ../vsn.mk

VSN = $(SNMP_VSN)


# ----------------------------------------------------
# Target Specs
# ----------------------------------------------------

include modules.mk

SNMP_ROOT = ..

ERL_FILES = $(MODULES:%=%.erl)

SNMP_TEST_DATA    = snmp_test_data
NETSNMP_TEST_DATA = snmp_to_snmpnet_SUITE_data

SNMP_MIB_DIR    = $(SNMP_TEST_DATA)
NETSNMP_MIB_DIR = $(NETSNMP_TEST_DATA)

SNMP_BIN_TARGET_DIR    = $(SNMP_TEST_DATA)
NETSNMP_BIN_TARGET_DIR = $(NETSNMP_TEST_DATA)

SNMP_MIB_SOURCES    = $(MIB_FILES:%.mib=$(SNMP_MIB_DIR)/%.mib)
NETSNMP_MIB_SOURCES = $(NETSNMP_MIB_FILES:%.mib=$(NETSNMP_MIB_DIR)/%.mib)

SNMP_MIB_TARGETS = \
	$(MIB_FILES:%.mib=$(SNMP_BIN_TARGET_DIR)/%.bin) \
	$(MIB_FILES:%.mib=$(SNMP_BIN_TARGET_DIR)/%.hrl)
NETSNMP_MIB_TARGETS = \
	$(NETSNMP_MIB_FILES:%.mib=$(NETSNMP_BIN_TARGET_DIR)/%.bin) \
	$(NETSNMP_MIB_FILES:%.mib=$(NETSNMP_BIN_TARGET_DIR)/%.hrl)
MIB_TARGETS = \
	$(SNMP_MIB_TARGETS) \
	$(NETSNMP_MIB_TARGETS)

ERL_TARGETS = $(MODULES:%=$(EBIN)/%.$(EMULATOR))

TEST_SERVER_TARGETS = $(TEST_SERVER_MODULES:%=$(EBIN)/%.$(EMULATOR))

TARGET_FILES = $(ERL_TARGETS) 

SOURCE = $(ERL_FILES) $(HRL_FILES) 

# The script 'make_emakefile' only exist in R9 and later
# So, if it does not exist, then use the old method
# (compile the erl-files and install the beam-files)
EMAKEFILE  = Emakefile
MAKE_EMAKE = $(wildcard $(ERL_TOP)/make/make_emakefile)

ifeq ($(MAKE_EMAKE),)
BUILDTARGET   = $(TARGET_FILES)
RELTEST_FILES = $(SPECS) $(SOURCE) $(TARGET_FILES)
else
BUILDTARGET   = $(MIB_TARGETS) emakebuild
RELTEST_FILES = $(EMAKEFILE) $(SPECS) $(SOURCE) 
endif

COVER_SPEC_FILE = snmp.cover


# ----------------------------------------------------
# Release directory specification
# ----------------------------------------------------
RELSYSDIR = $(RELEASE_PATH)/snmp_test


# ----------------------------------------------------
# SNMP FLAGS
# ----------------------------------------------------
ifeq ($(SNMP_DEBUG),)
  # SNMP_DEBUG = d
endif

ifeq ($(SNMP_DEBUG),d)
  SNMP_FLAGS += -Dsnmp_debug
endif

ifeq ($(DONT_USE_TS),true)
  SNMP_FLAGS += -DDONT_USE_TEST_SERVER
endif

SNMP_MIB_FLAGS += -pa ../ebin +version 

ifneq ($(MIBS_VERBOSITY),) 
  SNMP_MIB_FLAGS += +'{verbosity,$(MIBS_VERBOSITY)}'
endif

ifeq ($(SNMP_DESC),true)
  USE_DESCRIPTION = +'{description,true}'
endif

GROUP_CHECK = +'{group_check,false}'

SNMP_MIB_FLAGS += $(GROUP_CHECK) $(USE_DESCRIPTION) -I$(SNMP_BIN_TARGET_DIR)

ESTOP = -s init stop

ifeq ($(DONT_STOP),true)
MAYBE_ESTOP =
else
MAYBE_ESTOP = $(ESTOP)
endif

ifeq ($(MERL),)
MERL = erl
endif

ARGS += -noshell

ifeq ($(DISABLE_TC_TIMEOUT),true)
ARGS += -snmp_test_timeout
endif


# ----------------------------------------------------
# FLAGS
# ----------------------------------------------------
EBIN = .

ifeq ($(SNMP_WARNING_AS_ERROR),)
  ERL_COMPILE_FLAGS += -Werror
else
  ifeq ($(SNMP_WARNING_AS_ERROR),true)
    ERL_COMPILE_FLAGS += -Werror
  endif
endif

ifeq ($(WARN_UNUSED_VARS),)
  ERL_COMPILE_FLAGS += +warn_unused_vars
else
  ifeq ($(WARN_UNUSED_VARS),true)
    ERL_COMPILE_FLAGS += +warn_unused_vars
  endif
endif

ERL_COMPILE_FLAGS += -I../../snmp/src/app \
                     -I../../snmp/src/misc \
                     -I../../snmp/src/agent \
                     -I../../snmp/src/manager \
                     -I../../snmp/include \
                     -Dsnmp_test_data=snmp_test_data \
                     -Dversion=\"$(VSN)$(PRE_VSN)\" \
                     +'{parse_transform,sys_pre_attributes}' \
                     +'{attribute,insert,app_vsn,$(APP_VSN)}' \
                     $(SNMP_FLAGS) \
		     +nowarn_missing_spec_documented
ERL_COMPILE_FLAGS := $(filter-out +deterministic,$(ERL_COMPILE_FLAGS))

ERL_SNMP_FLAGS = $(SNMP_MIB_FLAGS) \
                 -I../priv/mibs

$(SNMP_BIN_TARGET_DIR)/%.bin: $(SNMP_MIB_DIR)/%.mib
	$(ERLC) $(ERL_SNMP_FLAGS) -o $(SNMP_MIB_DIR) $<

$(SNMP_BIN_TARGET_DIR)/%.hrl: $(SNMP_BIN_TARGET_DIR)/%.bin
	$(ERLC) $(ERL_SNMP_FLAGS) -o $(SNMP_BIN_TARGET_DIR) $<

$(NETSNMP_BIN_TARGET_DIR)/%.hrl: $(NETSNMP_BIN_TARGET_DIR)/%.bin
	$(ERLC) $(ERL_SNMP_FLAGS) -o $(NETSNMP_BIN_TARGET_DIR) $<

$(NETSNMP_BIN_TARGET_DIR)/%.bin: $(NETSNMP_MIB_DIR)/%.mib
	$(ERLC) $(ERL_SNMP_FLAGS) -o $(NETSNMP_MIB_DIR) $<


# ----------------------------------------------------
# Targets
# ----------------------------------------------------

tests $(TYPES): $(BUILDTARGET)

.PHONY: emakebuild

emakebuild: $(EMAKEFILE)

targets: mib $(EMAKEFILE) 
	erl -make

old_targets: mib $(TARGET_FILES)

$(EMAKEFILE):  Makefile
	$(MAKE_EMAKE) $(ERL_COMPILE_FLAGS) -o$(EBIN) '*_SUITE_make' > $(EMAKEFILE)
	$(MAKE_EMAKE) $(ERL_COMPILE_FLAGS) -o$(EBIN) $(MODULES) >> $(EMAKEFILE)

clean:
	rm -f $(EMAKEFILE)
	rm -f $(TARGET_FILES) 
	rm -f core

docs:

mib: $(MIB_TARGETS)

make: old_targets

test: agent manager

agent: make
	$(MERL) $(ARGS) -sname snmp_agent_test $(ERL_PATH) \
            -s snmp_test_server run snmp_agent_SUITE \
            $(MAYBE_ESTOP)

manager: make
	$(MERL) $(ARGS) -sname snmp_manager_test $(ERL_PATH) \
            -s snmp_test_server run snmp_manager_SUITE \
            $(MAYBE_ESTOP)


$(SNMP_BIN_TARGET_DIR)/Klas4.bin: $(SNMP_BIN_TARGET_DIR)/Klas3.bin

$(SNMP_BIN_TARGET_DIR)/SA-MIB.bin: $(SNMP_BIN_TARGET_DIR)/OLD-SNMPEA-MIB.bin

$(SNMP_BIN_TARGET_DIR)/Test3.bin: $(SNMP_BIN_TARGET_DIR)/Test2.bin


# ----------------------------------------------------
# Release Target
# ---------------------------------------------------- 
include $(ERL_TOP)/make/otp_release_targets.mk

release_spec:

release_tests_spec: opt
	$(INSTALL_DIR) "$(RELSYSDIR)"
	$(INSTALL_DATA) $(RELTEST_FILES) $(COVER_SPEC_FILE) "$(RELSYSDIR)"
	chmod -R u+w "$(RELSYSDIR)"
	tar cf - snmp_test_data | (cd "$(RELSYSDIR)"; tar xf -)
	tar cf - *_SUITE_data | (cd "$(RELSYSDIR)"; tar xf -)

release_docs_spec:


info:
	@echo "SNMP_DEBUG             = $(SNMP_DEBUG)"
	@echo "SNMP_FLAGS             = $(SNMP_FLAGS)"
	@echo ""
	@echo "SNMP_MIB_DIR           = $(SNMP_MIB_DIR)"
	@echo "NETSNMP_MIB_DIR        = $(NETSNMP_MIB_DIR)"
	@echo ""
	@echo "SNMP_BIN_TARGET_DIR    = $(SNMP_BIN_TARGET_DIR)"
	@echo "NETSNMP_BIN_TARGET_DIR = $(NETSNMP_BIN_TARGET_DIR)"
	@echo ""
	@echo "SNMP_MIB_SOURCES    = $(SNMP_MIB_SOURCES)"
	@echo "NETSNMP_MIB_SOURCES = $(NETSNMP_MIB_SOURCES)"
	@echo ""
	@echo "MIB_TARGETS         = $(MIB_TARGETS)"
	@echo ""
	@echo "SNMP_MIB_FLAGS      = $(SNMP_MIB_FLAGS)"
	@echo ""
	@echo "ERL_COMPILE_FLAGS   = $(ERL_COMPILE_FLAGS)"
	@echo ""
	@echo "RELSYSDIR           = "$(RELSYSDIR)""
	@echo ""
	@echo "SOURCE              = $(SOURCE)"
	@echo ""
	@echo "TARGET_FILES        = $(TARGET_FILES)"
	@echo ""
	@echo "EMAKEFILE           = $(EMAKEFILE)"
	@echo "MAKE_EMAKE          = $(MAKE_EMAKE)"
	@echo "BUILDTARGET         = $(BUILDTARGET)"
	@echo "RELTEST_FILES       = $(RELTEST_FILES)"
	@echo ""


