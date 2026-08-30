---
name: polish
description: Analyze code changes, auto-fix high-confidence issues, and report remaining findings
argument-hint: "[commit ref — defaults to all changes on the current branch] [--fix] [--path <dir>]"
---

# Polish — Review & Fix

Load the `polish-core` skill with the `read` tool and follow it with `$ARGUMENTS` unchanged.

If no arguments were supplied, follow `polish-core` without arguments so it uses its default range (all changes on the current branch since it diverged from the default branch).

Return the skill's report directly. Do not duplicate, reinterpret, or shorten its workflow.
