# Common Makefile parts for BPF-building with libbpf
# --------------------------------------------------
# SPDX-License-Identifier: (GPL-2.0 OR BSD-2-Clause)
#
# This file should be included from your Makefile like:
#  COMMON_DIR = ../common/
#  include $(COMMON_DIR)/common.mk
#
# It is expected that you define the variables:
#  XDP_TARGETS and USER_TARGETS
# as a space-separated list
#
LLC ?= llc
CLANG ?= clang
CC ?= gcc

XDP_C = ${XDP_TARGETS:=.c}
XDP_OBJ = ${XDP_C:.c=.o}
USER_C := ${USER_TARGETS:=.c}
USER_OBJ := ${USER_C:.c=.o}

# Expect this is defined by including Makefile, but define if not
KERNEL_DIR ?= /opt/net-next
COMMON_DIR ?= ../common
HEADER_DIR ?= ../headers
LIBBPF_DIR ?= ${KERNEL_DIR}/tools/bpf/resolve_btfids/libbpf
LIBBPF_OBJ = ${LIBBPF_DIR}/libbpf.a

COPY_LOADER ?=
LOADER_DIR ?= $(COMMON_DIR)/../basic-solutions

# Extend if including Makefile already added some
#COMMON_OBJS += $(COMMON_DIR)/common_params.o $(COMMON_DIR)/common_user_bpf_xdp.o

# Create expansions for dependencies
#COMMON_H := ${COMMON_OBJS:.o=.h}

EXTRA_DEPS +=

# BPF-prog kern and userspace shares struct via header file:
KERN_USER_H ?= $(wildcard common_kern_user.h)

CFLAGS ?= -g
CFLAGS += -I${KERNEL_DIR}/tools/include
CFLAGS += -I${KERNEL_DIR}/tools/lib
CFLAGS += -I${KERNEL_DIR}/tools/perf
CFLAGS += -I${KERNEL_DIR}/tools/testing/selftests/bpf
CFLAGS += -I$(HEADER_DIR)
LDFLAGS ?= -L$(LIBBPF_DIR)

BPF_CFLAGS ?=
BPF_CFLAGS += -I$(HEADER_DIR)
BPF_CFLAGS += -I${KERNEL_DIR}/usr/include
BPF_CFLAGS += -I${KERNEL_DIR}/tools/include
BPF_CFLAGS += -I${KERNEL_DIR}/tools/lib
BPF_CFLAGS += -I${KERNEL_DIR}/tools/bpf/resolve_btfids/libbpf
BPF_CFLAGS += -I${KERNEL_DIR}/tools/testing/selftests/bpf
BPF_CFLAGS += -I${KERNEL_DIR}/include
LIBS = -l:libbpf.a -lelf $(USER_LIBS)

all: llvm-check $(USER_TARGETS) $(XDP_OBJ) $(COPY_LOADER) $(COPY_STATS)

.PHONY: clean $(CLANG) $(LLC)

clean:
	rm -f $(USER_TARGETS) $(USER_TARGETS:_user=) .$(USER_TARGETS).d $(XDP_OBJ) $(USER_OBJ) $(COPY_LOADER) $(COPY_STATS)
	rm -f *.ll
	rm -f *~

ifdef COPY_LOADER
$(COPY_LOADER): $(LOADER_DIR)/${COPY_LOADER:=.c} $(COMMON_H)
	make -C $(LOADER_DIR) $(COPY_LOADER)
	cp $(LOADER_DIR)/$(COPY_LOADER) $(COPY_LOADER)
endif

ifdef COPY_STATS
$(COPY_STATS): $(LOADER_DIR)/${COPY_STATS:=.c} $(COMMON_H)
	make -C $(LOADER_DIR) $(COPY_STATS)
	cp $(LOADER_DIR)/$(COPY_STATS) $(COPY_STATS)
# Needing xdp_stats imply depending on header files:
EXTRA_DEPS += $(COMMON_DIR)/xdp_stats_kern.h $(COMMON_DIR)/xdp_stats_kern_user.h
endif

# For build dependency on this file, if it gets updated
COMMON_MK = $(COMMON_DIR)/common.mk

#vmlinux.h:
#	sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > $(HEADER_DIR)/vmlinux.h

llvm-check: $(CLANG) $(LLC)
	@for TOOL in $^ ; do \
		if [ ! $$(command -v $${TOOL} 2>/dev/null) ]; then \
			echo "*** ERROR: Cannot find tool $${TOOL}" ;\
			exit 1; \
		else true; fi; \
	done

$(LIBBPF_OBJ):
	@if [ ! -d $(LIBBPF_DIR) ]; then \
		echo "Error: Need libbpf submodule"; \
		echo "May need to run git submodule update --init"; \
		exit 1; \
	else \
		cd $(LIBBPF_DIR) && $(MAKE) all OBJDIR=.; \
		mkdir -p build; $(MAKE) install_headers DESTDIR=build OBJDIR=.; \
	fi

# Create dependency: detect if C-file change and touch H-file, to trigger
# target $(COMMON_OBJS)
$(COMMON_H): %.h: %.c
	touch $@

# Detect if any of common obj changed and create dependency on .h-files
$(COMMON_OBJS): %.o: %.h
	make -C $(COMMON_DIR)

$(USER_TARGETS): %: %.c  $(LIBBPF_OBJ) Makefile $(COMMON_MK) $(COMMON_OBJS) $(KERN_USER_H) $(EXTRA_DEPS)
	$(CC)  -Wp,-MD,.$@.d \
	    -Wall -O2 -Wmissing-prototypes -Wstrict-prototypes \
	    $(CFLAGS) \
	    $(LDFLAGS)\
	    -o ${@:_user=} $(COMMON_OBJS) \
	    $< $(LIBS)

$(XDP_OBJ): %.o: %.c  Makefile $(COMMON_MK) $(KERN_USER_H) $(EXTRA_DEPS) $(OBJECT_LIBBPF)
	$(CLANG) -S \
	    -nostdinc \
	    -target bpf \
	    -D__KERNEL__ \
	    -D__BPF_TRACING__ \
	    -include ${KERNEL_DIR}/include/linux/compiler-version.h \
	    -include ${KERNEL_DIR}/include/linux/kconfig.h \
	    $(BPF_CFLAGS) \
	    -fno-stack-protector -g \
	    -Wall \
	    -Werror \
	    -Wno-unused-value \
	    -Wno-pointer-sign \
	    -Wno-compare-distinct-pointer-types \
	    -Wno-gnu-variable-sized-type-not-at-end \
	    -Wno-address-of-packed-member \
	    -Wno-tautological-compare \
	    -Wno-unknown-warning-option  \
	    -fno-asynchronous-unwind-tables \
	    -O2 -emit-llvm -c -o ${@:.o=.ll} $<
	$(LLC) -march=bpf -filetype=obj -o $@ ${@:.o=.ll}
