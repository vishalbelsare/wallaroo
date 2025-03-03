# include root makefile
ifndef ROOT_MAKEFILE_MK
include ../../../../Makefile
endif

# prevent rules from being evaluated/included multiple times
ifndef $(abspath $(lastword $(MAKEFILE_LIST)))_MK
$(abspath $(lastword $(MAKEFILE_LIST)))_MK := 1


# The following are control variables that determine what logic from `rules.mk` is enabled

# `true`/`false` to enable/disable the actual unit test command so it can be overridden (the targets are still created)
# applies to both the pony and elixir test targets
$(abspath $(lastword $(MAKEFILE_LIST)))_UNIT_TEST_COMMAND := false

# `true`/`false` to enable/disable generate pony related targets (build/test/clean) for pony sources in this directory
# otherwise targets only get created if there are pony sources (*.pony) in this directory.
$(abspath $(lastword $(MAKEFILE_LIST)))_PONY_TARGET := true

# `true`/`false` to enable/disable generate final file build target using ponyc command for the pony build target so
# it can be overridden manually
$(abspath $(lastword $(MAKEFILE_LIST)))_PONYC_TARGET := true

# `true`/`false` to enable/disable generate exs related targets (build/test/clean) for elixir sources in this directory
# otherwise targets only get created if there are elixir sources (*.exs) in this directory.
$(abspath $(lastword $(MAKEFILE_LIST)))_EXS_TARGET := true

# `true`/`false` to enable/disable generate docker related targets (build/push) for a Dockerfile in this directory
# otherwise targets only get created if there is a Dockerfile in this directory
$(abspath $(lastword $(MAKEFILE_LIST)))_DOCKER_TARGET := true

# `true`/`false` to enable/disable recursing into Makefiles of subdirectories if they exist
# (and by recursion every makefile in the tree that is referenced)
$(abspath $(lastword $(MAKEFILE_LIST)))_RECURSE_SUBMAKEFILES := true


LOCAL_SEQUENCE_DETECTOR_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
local_sequence_detector_tests: LOGLEVEL = error

# standard rules generation makefile
include $(rules_mk_path)

# build-testing-correctness-apps-local_sequence_detector: build-machida
# build-testing-correctness-apps-local_sequence_detector: build-machida3
# integration-tests-testing-correctness-apps-local_sequence_detector: build-testing-correctness-apps-local_sequence_detector
# integration-tests-testing-correctness-apps-local_sequence_detector: local_sequence_detector_tests

# Group the tests under a single target
local_sequence_detector_tests: local_sequence_detector_tests_pony

# Pony
local_sequence_detector_tests_pony: local_sequence_detector_test_pony_gen_source_2_worker

# Individual test definitions below
local_sequence_detector_test_pony_gen_source_2_worker:
	cd $(MULTI_PARTITION_DETECTOR_PATH) && \
	integration_test \
		--log-level $(LOGLEVEL) \
		--command './local_sequence_detector --source gensource $(RUN_WITH_RESILIENCE)' \
		--validation-cmd 'python _validate.py --output' \
		--output 'received.txt' \
		--batch-size 10 \
		--workers 2 \
		--sink-expect 10000 \
		--sink-expect-allow-more

# end of prevent rules from being evaluated/included multiple times
endif
