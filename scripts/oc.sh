#!/usr/bin/env bash
# Wrapper to launch opencode with Exa web search enabled.
# opencode has no config file setting for this — env var is the only way.
# See: https://github.com/anomalyco/opencode/issues/309
exec env OPENCODE_ENABLE_EXA=true opencode "$@"
