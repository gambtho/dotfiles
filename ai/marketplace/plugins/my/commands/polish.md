---
name: polish
description: Analyze code changes, auto-fix high-confidence issues, and report remaining findings
argument-hint: "[commit ref — defaults to HEAD~1] [--fix] [--path <dir>]"
allowed-tools: Skill
---

# Polish — Review & Fix

Invoke the `my:polish` skill through the Skill tool with `$ARGUMENTS` unchanged.

If no arguments were supplied, invoke `my:polish` without arguments so it uses its default `HEAD~1` range.

Return the skill's report directly. Do not duplicate, reinterpret, or shorten its workflow.
