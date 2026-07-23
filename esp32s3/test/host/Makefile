# Host-based unit tests (docs/implementation.md §7.1).
# Pure-logic firmware components compiled with the host toolchain + sanitizers.
#
#   make        build everything
#   make run    build + run all suites (fails on first failing suite)
#   make clean

FW := ../../firmware/components
CC ?= cc
SAN ?= -fsanitize=address,undefined -fno-sanitize-recover=all
CFLAGS ?= -std=c11 -g -O1 -Wall -Wextra -Werror $(SAN) \
          -I$(FW)/ctrl_proto/include -I$(FW)/cat_bridge/include -Iunity \
          -DUNITY_OUTPUT_COLOR
LDFLAGS ?= $(SAN) -pthread

BUILD := build

CORE_SRCS := $(FW)/ctrl_proto/ctrl_proto.c \
             $(FW)/cat_bridge/ring_buf.c \
             $(FW)/cat_bridge/coalescer.c \
             $(FW)/cat_bridge/radio_detect.c \
             $(FW)/cat_bridge/bridge_core.c
UNITY_SRC := unity/unity.c

TESTS := test_ctrl_proto test_ring_buf test_coalescer test_radio_detect \
         test_bridge_e2e

BINS := $(addprefix $(BUILD)/,$(TESTS))

.PHONY: all run clean
all: $(BINS)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%: %.c $(CORE_SRCS) $(UNITY_SRC) | $(BUILD)
	$(CC) $(CFLAGS) $< $(CORE_SRCS) $(UNITY_SRC) $(LDFLAGS) -o $@

run: $(BINS)
	@set -e; for t in $(BINS); do echo "== $$t =="; ./$$t; done; \
	echo "ALL HOST SUITES PASSED"

clean:
	rm -rf $(BUILD)
